// pitchd — tiny realtime pitch detector + tone generator for pitchlock.
//
//   pw-record -a --rate 48000 --channels 1 --format f32 - | pitchd listen
//     -> prints "<hz> <clarity> <rms>\n" per analysis frame (hz = 0 when unvoiced)
//
//   pitchd tone <secs> <hz> [hz...] | pw-cat -p -a --rate 48000 --channels 1 --format f32 -
//     -> writes a soft organ-ish tone (or chord) as raw f32 mono
//
//   pitchd mic                      same as `listen`, but spawns pw-record itself
//   pitchd play <secs> <gain> <hz>…  same as `tone`, but spawns pw-cat itself
//   pitchd arp <note-secs> <chord-secs> <gain> <hz>…
//                                   each note in turn, then all of them together
//
// The self-spawning forms exist so a supervisor (Quickshell's Process) can kill
// one pid and have the PipeWire child die with it via SIGPIPE / EOF.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>

#define RATE 48000
#define WIN 2048
#define HALF (WIN / 2)
#define HOP 768
#define MIN_HZ 55.0   /* A1: room below a bass's C2 (65 Hz) for singing flat */
#define MAX_HZ 1100.0
#ifndef YIN_THRESHOLD
#define YIN_THRESHOLD 0.15
#endif
// Voice must be this many times louder than the room's noise floor (tracked live),
// and never quieter than RMS_MIN. A bass's low notes are quiet on laptop mics, so
// this adapts to the room rather than using one fixed cutoff.
#ifndef GATE_OVER_NOISE
#define GATE_OVER_NOISE 3.0
#endif
// Never treat anything louder than this as room noise: with no quiet moment to learn
// from (e.g. already singing when the lock opens), the voice itself would set the floor.
#ifndef NOISE_CEIL
#define NOISE_CEIL 0.002
#endif
#ifndef RMS_MIN
#define RMS_MIN 0.0005
#endif

static float buf[WIN];
static double gate_over_noise = GATE_OVER_NOISE;   // `mic <n>` / `listen <n>` override
static float diff[HALF];

// YIN (de Cheveigné & Kawahara 2002) with cumulative-mean normalisation and
// parabolic interpolation. Returns 0 when no confident period is found.
static double yin(const float *x, double *clarity) {
  int tau_min = (int)(RATE / MAX_HZ);
  int tau_max = (int)(RATE / MIN_HZ);
  if (tau_max >= HALF) tau_max = HALF - 1;

  diff[0] = 1.0f;
  double running = 0.0;
  for (int tau = 1; tau <= tau_max; tau++) {
    double sum = 0.0;
    for (int j = 0; j < HALF; j++) {
      double d = x[j] - x[j + tau];
      sum += d * d;
    }
    running += sum;
    diff[tau] = running > 0 ? (float)(sum * tau / running) : 1.0f;
  }

  int best = -1;
  for (int tau = tau_min; tau <= tau_max; tau++) {
    if (diff[tau] < YIN_THRESHOLD) {
      while (tau + 1 <= tau_max && diff[tau + 1] < diff[tau]) tau++;
      best = tau;
      break;
    }
  }
  if (best < 0) { *clarity = 0; return 0; }

  double t = best;
  if (best > 1 && best < tau_max) {
    double a = diff[best - 1], b = diff[best], c = diff[best + 1];
    double denom = a - 2 * b + c;
    if (fabs(denom) > 1e-12) t = best + 0.5 * (a - c) / denom;
  }
  *clarity = 1.0 - diff[best];
  return RATE / t;
}

// ── Recording the last few seconds (mic mode only) ──────────────────────────
// The mic audio also goes into a rolling 45 s buffer held in memory. Nothing is written
// unless the controller sends "save <path> <seconds>\n" on stdin; then the last
// <seconds> are written as a 16-bit mono WAV (loudness normalised).
#define RING_SECS 45
#define RING (RATE * RING_SECS)
static float *ring = NULL;
static size_t ring_pos = 0, ring_fill = 0;
static int commands = 0;              // read stdin commands (mic mode)
static char cmd[1024];
static size_t cmd_len = 0;

static void put_le(FILE *f, uint32_t v, int bytes) {
  for (int i = 0; i < bytes; i++) fputc((v >> (8 * i)) & 0xff, f);
}

static void save_wav(const char *path, double secs) {
  size_t n = (size_t)(secs * RATE);
  if (n > ring_fill) n = ring_fill;
  if (n == 0) return;
  size_t start = (ring_pos + RING - n) % RING;
  float peak = 1e-6f;
  for (size_t i = 0; i < n; i++) { float v = fabsf(ring[(start + i) % RING]); if (v > peak) peak = v; }
  float gain = 0.9f / peak;
  if (gain > 30.0f) gain = 30.0f;
  char tmp[1100];
  snprintf(tmp, sizeof tmp, "%s.part", path);
  FILE *f = fopen(tmp, "wb");
  if (!f) return;
  fwrite("RIFF", 1, 4, f); put_le(f, 36 + n * 2, 4); fwrite("WAVEfmt ", 1, 8, f);
  put_le(f, 16, 4); put_le(f, 1, 2); put_le(f, 1, 2); put_le(f, RATE, 4); put_le(f, RATE * 2, 4);
  put_le(f, 2, 2); put_le(f, 16, 2); fwrite("data", 1, 4, f); put_le(f, n * 2, 4);
  for (size_t i = 0; i < n; i++) {
    float v = ring[(start + i) % RING] * gain;
    if (v > 1) v = 1; else if (v < -1) v = -1;
    put_le(f, (uint32_t)(int16_t)(v * 32767), 2);
  }
  fclose(f);
  rename(tmp, path);
  fprintf(stderr, "pitchd: saved %.1f s\n", (double)n / RATE);
}

static void poll_commands(void) {
  char chunk[256];
  ssize_t got;
  while ((got = read(0, chunk, sizeof chunk)) > 0) {
    for (ssize_t i = 0; i < got; i++) {
      if (chunk[i] == '\n') {
        cmd[cmd_len] = 0;
        char path[1000];
        double secs = 0;
        if (sscanf(cmd, "save %999s %lf", path, &secs) == 2) save_wav(path, secs);
        cmd_len = 0;
      } else if (cmd_len < sizeof cmd - 1) {
        cmd[cmd_len++] = chunk[i];
      }
    }
  }
}

static int listen(FILE *in) {
  float hop[HOP];
  size_t filled = 0;
  setvbuf(stdout, NULL, _IOLBF, 0);

  while (fread(hop, sizeof(float), HOP, in) == HOP) {
    if (commands) {
      for (int i = 0; i < HOP; i++) { ring[ring_pos] = hop[i]; ring_pos = (ring_pos + 1) % RING; }
      if (ring_fill < RING) ring_fill += HOP;
      poll_commands();
    }
    memmove(buf, buf + HOP, (WIN - HOP) * sizeof(float));
    memcpy(buf + WIN - HOP, hop, HOP * sizeof(float));
    if (filled < WIN) { filled += HOP; if (filled < WIN) continue; }

    double energy = 0;
    for (int i = 0; i < WIN; i++) energy += buf[i] * buf[i];
    double rms = sqrt(energy / WIN);

    // Noise floor = quietest moment of the last ~10 s (per-second minima in a ring).
    // Breaths between notes keep it pinned to the room, so continuous singing can't
    // drag it up toward the voice the way a slowly-rising tracker does.
    static double sec_min[10];
    static int n_secs = 0, sec_pos = 0, frames_in_sec = 0;
    static double cur_min = 1.0;
    if (rms < cur_min) cur_min = rms;
    if (++frames_in_sec >= RATE / HOP) {
      sec_min[sec_pos] = cur_min;
      sec_pos = (sec_pos + 1) % 10;
      if (n_secs < 10) n_secs++;
      cur_min = 1.0;
      frames_in_sec = 0;
    }
    double floor_rms = cur_min;
    for (int i = 0; i < n_secs; i++)
      if (sec_min[i] < floor_rms) floor_rms = sec_min[i];
    if (floor_rms > NOISE_CEIL) floor_rms = NOISE_CEIL;
    double gate = floor_rms * gate_over_noise;
    if (gate < RMS_MIN) gate = RMS_MIN;

    double hz = 0, clarity = 0;
    if (rms > gate) hz = yin(buf, &clarity);
    printf("%.2f %.3f %.6f\n", hz, clarity, rms);
  }
  return 0;
}

// Tone sounds: 0 organ, 1 piano, 2 sine, 3 choir ("-t <name>" after the command).
static int timbre = 0;

static double voice(double f, double t) {
  const double p = 2 * M_PI * f * t;
  switch (timbre) {
  case 1: {  // piano: struck, then fading; higher overtones fade faster
    const double a[] = { 1, 0.5, 0.3, 0.18, 0.1 };
    double s = 0;
    for (int k = 1; k <= 5; k++) s += a[k - 1] * exp(-t * (1.1 + 0.9 * k)) * sin(k * p);
    return 1.6 * s;
  }
  case 2:    // sine: soft and nearly pure (a little 2nd harmonic keeps bass audible)
    return 1.4 * (sin(p) + 0.25 * sin(2 * p));
  case 3: {  // choir "ooh": gentle vibrato, two slightly detuned voices
    double s = 0;
    for (int v = 0; v < 2; v++) {
      const double ff = f * (v ? 1.003 : 1.0);
      const double q = 2 * M_PI * ff * t - (0.005 * ff / 5.5) * cos(2 * M_PI * 5.5 * t + v);
      s += sin(q) + 0.45 * sin(2 * q) + 0.22 * sin(3 * q) + 0.12 * sin(4 * q);
    }
    return 0.75 * s;
  }
  default:   // organ: fundamental plus overtones (laptop speakers barely reproduce bass
             // fundamentals, but the ear still hears the right pitch from the series)
    return sin(p) + 0.6 * sin(2 * p) + 0.4 * sin(3 * p) + 0.25 * sin(4 * p) + 0.12 * sin(5 * p);
  }
}

static int tone(FILE *out_f, double secs, double gain, int n, double *hz) {
  size_t total = (size_t)(secs * RATE);
  const double attack = (timbre == 1 ? 0.005 : timbre == 3 ? 0.15 : 0.04) * RATE, release = 0.35 * RATE;
  float out[512];
  size_t i = 0;
  while (i < total) {
    size_t k = 0;
    for (; k < 512 && i < total; k++, i++) {
      double env = 1.0;
      if (i < attack) env = i / attack;
      else if (i > total - release) env = (total - i) / release;
      double t = (double)i / RATE, s = 0;
      for (int v = 0; v < n; v++) s += voice(hz[v], t);
      out[k] = (float)(gain * 0.17 * env * s / n);
    }
    if (fwrite(out, sizeof(float), k, out_f) != k) return 1;
  }
  return 0;
}

static int parse_freqs(int argc, char **argv, int first, double *hz) {
  int n = argc - first;
  if (n > 16) n = 16;
  for (int i = 0; i < n; i++) hz[i] = atof(argv[first + i]);
  return n;
}

int main(int argc, char **argv) {
  // optional "-t <organ|piano|sine|choir>" right after the command
  char *args[64];
  int nargs = 0;
  for (int i = 0; i < argc && nargs < 64; i++) {
    if (i == 2 && i + 1 < argc && strcmp(argv[i], "-t") == 0) {
      const char *t = argv[++i];
      timbre = !strcmp(t, "piano") ? 1 : !strcmp(t, "sine") ? 2 : !strcmp(t, "choir") ? 3 : 0;
      continue;
    }
    args[nargs++] = argv[i];
  }
  argc = nargs;
  argv = args;

  double hz[16];
  const char *rec = "pw-record -a --rate 48000 --channels 1 --format f32 -";
  const char *cat = "pw-cat -p -a --rate 48000 --channels 1 --format f32 --latency 30ms -";

  if (argc >= 3 && (strcmp(argv[1], "listen") == 0 || strcmp(argv[1], "mic") == 0)) {
    double g = atof(argv[2]);
    if (g >= 1.0 && g <= 20.0) gate_over_noise = g;
  }
  if (argc >= 2 && strcmp(argv[1], "listen") == 0) return listen(stdin);
  if (argc >= 2 && strcmp(argv[1], "mic") == 0) {
    FILE *p = popen(rec, "r");
    if (!p) { perror("pw-record"); return 1; }
    ring = calloc(RING, sizeof(float));
    if (ring) {
      commands = 1;
      fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
    }
    listen(p);
    return pclose(p) == 0 ? 0 : 1;
  }
  if (argc >= 4 && strcmp(argv[1], "tone") == 0)
    return tone(stdout, atof(argv[2]), 1.0, parse_freqs(argc, argv, 3, hz), hz);
  if (argc >= 5 && strcmp(argv[1], "play") == 0) {
    FILE *p = popen(cat, "w");
    if (!p) { perror("pw-cat"); return 1; }
    tone(p, atof(argv[2]), atof(argv[3]), parse_freqs(argc, argv, 4, hz), hz);
    return pclose(p) == 0 ? 0 : 1;
  }
  if (argc >= 6 && strcmp(argv[1], "arp") == 0) {
    FILE *p = popen(cat, "w");
    if (!p) { perror("pw-cat"); return 1; }
    int n = parse_freqs(argc, argv, 5, hz);
    double gain = atof(argv[4]);
    for (int i = 0; i < n; i++) tone(p, atof(argv[2]), gain, 1, &hz[i]);
    tone(p, atof(argv[3]), gain, n, hz);
    return pclose(p) == 0 ? 0 : 1;
  }
  fprintf(stderr, "usage: pitchd listen|mic [sensitivity] | pitchd tone <secs> <hz>... | pitchd play <secs> <gain> <hz>...\n");
  return 2;
}
