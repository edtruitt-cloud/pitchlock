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

static int listen(FILE *in) {
  float hop[HOP];
  size_t filled = 0;
  setvbuf(stdout, NULL, _IOLBF, 0);

  while (fread(hop, sizeof(float), HOP, in) == HOP) {
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
    printf("%.2f %.3f %.4f\n", hz, clarity, rms);
  }
  return 0;
}

static int tone(FILE *out_f, double secs, double gain, int n, double *hz) {
  size_t total = (size_t)(secs * RATE);
  const double attack = 0.04 * RATE, release = 0.35 * RATE;
  float out[512];
  size_t i = 0;
  while (i < total) {
    size_t k = 0;
    for (; k < 512 && i < total; k++, i++) {
      double env = 1.0;
      if (i < attack) env = i / attack;
      else if (i > total - release) env = (total - i) / release;
      double t = (double)i / RATE, s = 0;
      for (int v = 0; v < n; v++) {
        double p = 2 * M_PI * hz[v] * t;
        // Fundamental plus overtones. Laptop speakers barely reproduce bass notes (C2 is
        // 65 Hz), but the ear still hears the right pitch from the harmonic series.
        s += sin(p) + 0.6 * sin(2 * p) + 0.4 * sin(3 * p) + 0.25 * sin(4 * p) + 0.12 * sin(5 * p);
      }
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
