.pragma library
// Shared by the lock and the settings panel.

// Average of unlocks that leaves out unusually slow ones (walked away mid-chord, got
// distracted): once there are at least 4, anything above Q3 + 1.5×IQR is skipped.
function typical(list) {
  if (!list || !list.length) return { secs: 0, cents: 0, kept: 0, total: 0 }
  let keep = list
  if (list.length >= 4) {
    const t = list.map(u => u.secs).sort((a, b) => a - b)
    const q = p => t[Math.floor(p * (t.length - 1))]
    const cutoff = q(0.75) + 1.5 * (q(0.75) - q(0.25))
    keep = list.filter(u => u.secs <= cutoff)
  }
  const avg = f => keep.reduce((a, u) => a + u[f], 0) / keep.length
  const withSteady = keep.filter(u => typeof u.steady === "number")
  const steady = withSteady.length ? withSteady.reduce((a, u) => a + u.steady, 0) / withSteady.length : -1
  return { secs: avg("secs"), cents: avg("cents"), steady: steady, kept: keep.length, total: list.length }
}

// Unlocks recorded at one difficulty and voice type (scores are kept separately for each).
function forCombo(list, difficulty, voice, kind) {
  return (list || []).filter(u => u.difficulty === difficulty && u.voice === voice
                                  && (!kind || (u.kind || "chord") === kind))
}

// How steady a held note was: 100% is dead steady; each cent of wobble (standard
// deviation of the pitch while holding) costs 3%.
function steadiness(wobbleCents) {
  return Math.max(0, Math.min(100, 100 - 3 * wobbleCents))
}
function stdDev(values) {
  if (values.length < 2) return 0
  const mean = values.reduce((a, v) => a + v, 0) / values.length
  return Math.sqrt(values.reduce((a, v) => a + (v - mean) * (v - mean), 0) / values.length)
}

function best(list) {
  return list && list.length ? Math.min.apply(null, list.map(u => u.secs)) : 0
}

// ── Achievements ───────────────────────────────────────────────────────────
// All reachable with ordinary use; none ask for a fast time (times vary a lot), except
// "Getting better", which only compares you with your own earlier self.
const FAMILY = { major: "major", maj7: "major", dom7: "major", minor: "minor", min7: "minor",
                 dim: "diminished", m7b5: "diminished", dim7: "diminished",
                 aug: "augmented", aug7: "augmented", augmaj7: "augmented", sus4: "sus", sus7: "sus" }

function longestDayStreak(list) {
  const days = Array.from(new Set(list.map(u => { const d = new Date(u.at); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() }))).sort((a, b) => a - b)
  let best = 0, run = 0, prev = null
  for (const d of days) {
    run = prev !== null && Math.round((d - prev) / 86400000) === 1 ? run + 1 : 1
    best = Math.max(best, run)
    prev = d
  }
  return best
}

// unlocks: the lock's saved unlocks; ear: {right, total, bestStreak} from ear training.
function achievements(unlocks, ear) {
  const u = unlocks || []
  const e = ear || { right: 0, total: 0, bestStreak: 0 }
  const n = u.length
  const count = f => u.filter(f).length
  const hour = x => new Date(x.at).getHours()
  const families = new Set(u.map(x => FAMILY[x.quality]).filter(Boolean))
  const diffs = new Set(u.map(x => x.difficulty).filter(Boolean))
  const melodies = count(x => x.kind === "melody" || x.quality === "melody")
  const streak = longestDayStreak(u)
  const improving = n >= 20 && typical(u.slice(0, 10)).secs > typical(u.slice(-10)).secs
  const step = (title, desc, have, need) => ({ title: title, desc: desc, done: have >= need, progress: Math.min(have, need) + "/" + need })
  const once = (title, desc, done) => ({ title: title, desc: desc, done: !!done, progress: done ? "✓" : "" })
  return [
    step("First song", "Unlock by singing", n, 1),
    step("Regular", "10 unlocks", n, 10),
    step("Choir member", "50 unlocks", n, 50),
    step("Soloist", "100 unlocks", n, 100),
    step("Diva", "250 unlocks", n, 250),
    step("Three in a row", "Unlock on 3 days running", streak, 3),
    step("A week of song", "Unlock on 7 days running", streak, 7),
    step("Explorer", "Unlock on Easy, Normal and Hard", ["easy", "normal", "hard"].filter(d => diffs.has(d)).length, 3),
    once("Perfect pitch", "Unlock once on Perfect pitch", diffs.has("perfect")),
    step("Chord collector", "Unlock with major, minor, diminished, augmented and sus chords", families.size, 5),
    step("Melodist", "Sing 10 melodies to unlock", melodies, 10),
    once("Steady voice", "An unlock at 85% steady or more", u.some(x => x.steady >= 85)),
    once("Bullseye", "An unlock averaging 15¢ off or better", u.some(x => x.cents > 0 && x.cents <= 15)),
    once("Early bird", "Unlock before 8 am", u.some(x => hour(x) < 8)),
    once("Night owl", "Unlock after 11 pm", u.some(x => hour(x) >= 23)),
    once("Getting better", "Your last 10 unlocks are quicker than your first 10", improving),
    step("Good ear", "10 right answers in ear training", e.right, 10),
    step("Golden ear", "50 right answers in ear training", e.right, 50),
    step("Hot streak", "10 ear-training answers right in a row", e.bestStreak, 10)
  ]
}

// Titles earned by `after` that weren't earned by `before`.
function newlyEarned(before, after, ear) {
  const was = new Set(achievements(before, ear).filter(a => a.done).map(a => a.title))
  return achievements(after, ear).filter(a => a.done && !was.has(a.title)).map(a => a.title)
}

// Days in a row with at least one unlock, counting back from today (or from yesterday, so
// the streak still shows before today's first unlock).
function currentStreak(list) {
  const day = t => { const d = new Date(t); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() }
  const days = new Set((list || []).map(u => day(u.at)))
  let d = day(Date.now())
  if (!days.has(d)) d -= 86400000
  let n = 0
  while (days.has(d)) { n++; d = day(d - 86400000 + 3600000 * 3) }   // (DST-safe step back)
  return n
}

// Notes you tend to sing flat or sharp: the average signed cents per note, from the notes
// held in recent unlocks (only notes sung at least 3 times). Most off first.
function troubleNotes(list, limit) {
  const by = {}
  for (const u of (list || []).slice(-100))
    for (const e of (u.noteCents || [])) {
      const k = Math.round(e.m)
      if (!by[k]) by[k] = { m: k, sum: 0, n: 0 }
      by[k].sum += e.c; by[k].n++
    }
  return Object.keys(by).map(k => by[k]).filter(x => x.n >= 3)
    .map(x => ({ m: x.m, cents: x.sum / x.n, n: x.n }))
    .sort((a, b) => Math.abs(b.cents) - Math.abs(a.cents))
    .slice(0, limit || 6)
}

// Unlocks that count toward achievements: only the chosen voice type, if one is set.
function forAchievements(list, voice) {
  return voice ? (list || []).filter(u => u.voice === voice) : (list || [])
}

// ── Daily challenge ────────────────────────────────────────────────────────
// The same on every computer: everything comes from the date. Each computer voices it in
// its own range, so the chord type and root note name match; the octave may not.
const DAILY_TYPES = ["maj7", "dom7", "min7", "m7b5", "dim7", "sus7", "aug7", "augmaj7"]

function dayKey(t) {
  const d = new Date(t === undefined ? Date.now() : t)
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
}

function seeded(key) {
  let h = 2166136261
  for (let i = 0; i < key.length; i++) { h ^= key.charCodeAt(i); h = Math.imul(h, 16777619) }
  return function() {                       // mulberry32
    h |= 0; h = (h + 0x6D2B79F5) | 0
    let t = Math.imul(h ^ (h >>> 15), 1 | h)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// {pc, types (in preference order), steps, length} for that day
function daily(key) {
  const r = seeded("pitchlock-daily-" + key)
  const pc = Math.floor(r() * 12)
  const types = DAILY_TYPES.slice()
  for (let i = types.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [types[i], types[j]] = [types[j], types[i]] }
  const pool = [-4, -3, -2, -2, -1, -1, 1, 1, 2, 2, 3, 4, 5]
  const steps = []
  for (let i = 0; i < 5; i++) steps.push(pool[Math.floor(r() * pool.length)])
  return { pc: pc, types: types, steps: steps, length: 4 + Math.floor(r() * 3) }
}

function unlockedToday(list) {
  const today = dayKey()
  return (list || []).some(u => dayKey(u.at) === today)
}
