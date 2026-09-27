import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "pitchstats.js" as Stats

Item {
  id: root
  focus: true

  signal quitRequested()
  signal tabRequested()                 // practice window: switch tabs

  // ── lock-screen mode ─────────────────────────────────────────────────────
  // In lock mode letter keys go to a typed buffer owned by the host (the lock
  // service decides what unlocks), so the shortcuts move to Ctrl combos.
  property bool lockMode: false
  property bool active: true            // the mic runs only while active
  property string typedText: ""
  property string failureMessage: ""
  property bool authenticating: false
  property bool singingOnly: false      // lock in "Singing only" mode: typing does nothing
  property bool heardReference: !lockMode
  signal typedTextEdited(string text)
  signal submitPassword(string text)
  signal unlockRequested()
  signal unlockRecorded(var stats)      // {at, secs, cents, root, quality}; the lock service saves it

  // Pass-notes (secure) mode: no chord, no targets, no tones, nothing that says whether a
  // note was right. Each exact note held in tune for the hold time is reported (noteSung)
  // and the lock service checks the last four. Repeating a note needs a break in between.
  property bool passMode: false
  signal noteSung(int midi)
  property int passNote: -1
  property real passHeldFor: 0
  property bool passCounted: false
  property int passDots: 0              // notes heard since the last pause (shown as plain dots)
  property int passProgress: -1         // from the lock: right notes so far (-1 = not provided)
  property int passCooldown: 0          // from the lock: seconds of guessing cooldown left
  property int lastSung: 0
  property int lastProgress: 0
  // A right pass-note gets a short ding of that same pitch.
  onPassProgressChanged: {
    if (passMode && passProgress > lastProgress && lastSung > 0) play(0.35, 0.8, [lastSung])
    lastProgress = passProgress
  }
  property int passQuiet: 0
  signal wakeRequested()
  property real lastActivity: 0

  property string pitchd: Quickshell.shellPath("pitchd")
  property string fontFamily: ""
  property PitchTheme pal: PitchTheme { font: root.fontFamily || "JetBrainsMono Nerd Font" }
  property string backgroundPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property int backgroundVersion: 0

  // Mic sleeps after this long with no voice, keys or mouse; any input wakes it.
  // Shared settings (PitchSettings); every tunable below falls back to its default without one.
  property QtObject settings: null
  function opt(name, fallback) { return settings && settings[name] !== undefined ? settings[name] : fallback }

  property real micSleepAfter: opt("micSleepSeconds", 60)
  property bool micAsleep: false
  property real lastEngaged: Date.now()
  function engage() {
    lastEngaged = Date.now()
    if (micAsleep) { micAsleep = false; micError = false; firstVoiceAt = 0; micWatchFrom = Date.now() }  // back: restart the clock
  }

  readonly property var noteNames: ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
  function pc(m) { return ((Math.round(m) % 12) + 12) % 12 }
  function noteName(m) { return noteNames[pc(m)] + (Math.floor(Math.round(m) / 12) - 1) }
  function midiToHz(m) { return 440 * Math.pow(2, (m - 69) / 12) }
  function hzToMidi(f) { return 69 + 12 * Math.log2(f / 440) }

  // ── challenge ────────────────────────────────────────────────────────────
  // The root is random every time (a semitone from C3..B3), never the same as the
  // previous one, and not something the singer can pick or re-roll.
  // The lock service supplies pickRootFn so the "not the same as last time" memory
  // outlives each lock screen; standalone just avoids repeating the current root.
  // Singer's ideal pocket: the middle of a bass voice (full range G2..C4), where the
  // recordings were strongest and steadiest. Every note of every chord (root, 3rd, 5th)
  // stays inside it, so roots run Bb2..Eb3; reference tones play in this range too.
  property int rangeLow: opt("pocketLow", 46)     // Bb2
  property int rangeHigh: opt("pocketHigh", 58)   // Bb3
  readonly property int rootLow: rangeLow
  // One challenge = chord type + singing order + root, swapped in as a single value so
  // bindings never see a 4-note order with a 3-note chord mid-update.
  property var challenge: ({ quality: "major", order: [0, 1, 2], root: 48, notes: [48, 52, 55] })
  readonly property string quality: challenge.quality
  readonly property var order: challenge.order
  readonly property int rootMidi: challenge.root
  readonly property var notes: challenge.notes     // the pitch to sing for each chord tone
  property var pickRootFn: null
  // Choose among candidate roots, never the same note name as last time. The lock service
  // supplies pickRootFn so that memory outlives each lock screen.
  function pickRoot(candidates) {
    if (pickRootFn) return pickRootFn(candidates)
    const fresh = candidates.filter(r => pc(r) !== pc(rootMidi))
    const from = fresh.length ? fresh : candidates
    return from[Math.floor(Math.random() * from.length)]
  }
  // Every way to voice a chord on this root: root position and each inversion (the tones
  // below the bass note move up an octave). Keeps only voicings inside the pocket.
  function voicings(root, iv) {
    const out = []
    for (let inv = 0; inv < iv.length; inv++) {
      const v = iv.map((x, i) => root + x + (i < inv ? 12 : 0))
      if (Math.min.apply(null, v) >= rangeLow && Math.max.apply(null, v) <= rangeHigh) out.push(v)
    }
    // the root an octave down can also fit (then the voicing starts below the pocket's root range)
    for (let inv = 1; inv < iv.length; inv++) {
      const v = iv.map((x, i) => root - 12 + x + (i < inv ? 12 : 0))
      if (Math.min.apply(null, v) >= rangeLow && Math.max.apply(null, v) <= rangeHigh
          && !out.some(o => o.join() === v.join())) out.push(v)
    }
    return out
  }
  // Roots (one per note name) that have at least one voicing of this chord in the pocket.
  function rootsFor(q) {
    const iv = qualities[q].iv, out = []
    for (let r = rangeLow; r < rangeLow + 12; r++) if (voicings(r, iv).length) out.push(r)
    return out
  }
  // Mostly major/minor; now and then a "colour" chord; optionally a 7th on top.
  // Every note always fits the pocket (chords too wide for it are skipped).
  readonly property var qualities: ({
    major: { iv: [0, 4, 7], names: ["Root", "Major 3rd", "Perfect 5th"], short: ["R", "3", "5"], label: "major triad" },
    minor: { iv: [0, 3, 7], names: ["Root", "Minor 3rd", "Perfect 5th"], short: ["R", "♭3", "5"], label: "minor triad" },
    dim: { iv: [0, 3, 6], names: ["Root", "Minor 3rd", "Diminished 5th"], short: ["R", "♭3", "♭5"], label: "diminished triad" },
    aug: { iv: [0, 4, 8], names: ["Root", "Major 3rd", "Augmented 5th"], short: ["R", "3", "♯5"], label: "augmented triad" },
    sus4: { iv: [0, 5, 7], names: ["Root", "Perfect 4th", "Perfect 5th"], short: ["R", "4", "5"], label: "sus4 chord" },
    maj7: { iv: [0, 4, 7, 11], names: ["Root", "Major 3rd", "Perfect 5th", "Major 7th"], short: ["R", "3", "5", "7"], label: "major 7th chord" },
    dom7: { iv: [0, 4, 7, 10], names: ["Root", "Major 3rd", "Perfect 5th", "Minor 7th"], short: ["R", "3", "5", "♭7"], label: "dominant 7th chord" },
    min7: { iv: [0, 3, 7, 10], names: ["Root", "Minor 3rd", "Perfect 5th", "Minor 7th"], short: ["R", "♭3", "5", "♭7"], label: "minor 7th chord" },
    m7b5: { iv: [0, 3, 6, 10], names: ["Root", "Minor 3rd", "Diminished 5th", "Minor 7th"], short: ["R", "♭3", "♭5", "♭7"], label: "half-diminished chord" },
    dim7: { iv: [0, 3, 6, 9], names: ["Root", "Minor 3rd", "Diminished 5th", "Diminished 7th"], short: ["R", "♭3", "♭5", "𝄫7"], label: "diminished 7th chord" },
    sus7: { iv: [0, 5, 7, 10], names: ["Root", "Perfect 4th", "Perfect 5th", "Minor 7th"], short: ["R", "4", "5", "♭7"], label: "7sus4 chord" },
    aug7: { iv: [0, 4, 8, 10], names: ["Root", "Major 3rd", "Augmented 5th", "Minor 7th"], short: ["R", "3", "♯5", "♭7"], label: "augmented 7th chord" },
    augmaj7: { iv: [0, 4, 8, 11], names: ["Root", "Major 3rd", "Augmented 5th", "Major 7th"], short: ["R", "3", "♯5", "7"], label: "augmented major 7th chord" }
  })
  // With 7ths on, every chord gets a 7th: each triad maps to its 7th-chord forms.
  readonly property var seventhsOf: ({ major: ["maj7", "dom7"], minor: ["min7"], dim: ["m7b5", "dim7"], aug: ["aug7", "augmaj7"], sus4: ["sus7"] })
  property bool randomOrder: opt("randomOrder", false)
  // When the voice range or chord options change before any singing has started (e.g.
  // settings finish loading, or edited in the panel with the practice window open),
  // replace the chord on screen so it matches.
  readonly property string challengeShape: [rangeLow, rangeHigh, randomOrder, opt("challengeKind", "chord"),
    colourChordChance, JSON.stringify(chordTypesEnabled)].join("|")
  onChallengeShapeChanged: if (!unlocked && stage === 0 && firstVoiceAt === 0) requestNewChallenge()
  // Several things ask for a fresh chord at start-up (built, activated, settings applied);
  // they all land in the same moment, so collapse them into one chord.
  property bool newChallengePending: false
  function requestNewChallenge() {
    if (newChallengePending) return
    newChallengePending = true
    Qt.callLater(function() { root.newChallengePending = false; root.newChallenge() })
  }
  property real colourChordChance: easeActive ? easeTuning[effectiveDifficulty][2] : opt("colourChordChance", 0.25) // share that are dim / aug / sus4

  // Easier early and late: before the morning hour / from the night hour, Easy (same values
  // as PitchSettings' Easy) replaces the chosen difficulty.
  readonly property var easeTuning: ({ easy: [35, 0.4, 0], normal: [26.875, 0.5, 0.25], hard: [15, 0.75, 0.5] })
  property int hourNow: new Date().getHours()
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.hourNow = new Date().getHours() }
  readonly property bool easeActive: !!opt("easeEnabled", false)
    && (hourNow < opt("easeMorningUntil", 9) || hourNow >= opt("easeNightFrom", 22))
  readonly property string effectiveDifficulty: easeActive ? "easy" : opt("difficulty", "normal")
  property var chordTypesEnabled: opt("chordTypesEnabled", ["major", "minor", "dim", "aug", "sus4"])
  // A melody is its own "quality": its notes are the tones, sung in order.
  readonly property bool isMelody: quality === "melody" || quality === "warmup"
  readonly property bool isWarmup: quality === "warmup"
  readonly property bool isDaily: !!challenge.daily
  readonly property var intervals: isMelody ? notes.map(n => n - notes[0]) : qualities[quality].iv
  readonly property var toneNames: isMelody ? notes.map((_, i) => "Note " + (i + 1)) : qualities[quality].names
  readonly property var toneShort: isMelody ? notes.map((_, i) => String(i + 1)) : qualities[quality].short
  function qualityLabel(q) { return q === "melody" ? "melody" : (qualities[q] ? qualities[q].label : q) }
  // one colour per tone; longer tunes (melodies, the warm-up) cycle through the four
  readonly property var toneColors: {
    const base = [pal.root, pal.third, pal.fifth, pal.seventh]
    const out = []
    for (let i = 0; i < Math.max(6, notes.length); i++) out.push(base[i % 4])
    return out
  }
  readonly property int toneCount: intervals.length
  // Singing order: chord-tone indices, root first unless random order is on.
  property int stage: 0                 // position in `order`; toneCount = unlocked
  property var done: [false, false, false]  // per chord tone
  readonly property bool unlocked: stage >= toneCount
  readonly property int tone: unlocked ? -1 : order[stage]   // chord tone being sung now
  readonly property int targetMidi: notes[Math.max(0, tone)] !== undefined ? notes[Math.max(0, tone)] : rootMidi
  // Whole chord is shifted by octaves to meet the singer's register.
  property int octaveShift: 0
  // In pass-notes mode the "target" is just the nearest note to what you're singing.
  readonly property real displayTarget: passMode
    ? (voiced ? Math.round(liveMidi) : (rangeLow + rangeHigh) / 2)
    : targetMidi + 12 * octaveShift
  function chordMidi(i) { return (notes[i] !== undefined ? notes[i] : rootMidi) + 12 * octaveShift }

  // ── settings ─────────────────────────────────────────────────────────────
  // Pass-notes have their own fixed tuning: Normal, or Hard if chosen. Never Easy or
  // Perfect pitch, and the difficulty sliders don't touch it.
  readonly property bool passHard: opt("passNotesDifficulty", "normal") === "hard"
  property real tolerance: passMode ? (passHard ? 15 : 26.875) : easeActive ? easeTuning[effectiveDifficulty][0] : opt("tolerance", 26.875)     // cents either side
  property real holdNeeded: passMode ? (passHard ? 0.75 : 0.5) : easeActive ? easeTuning[effectiveDifficulty][1] : opt("holdSeconds", 0.375)   // seconds of in-tune singing per tone
  // Notes must always be sung in the pocket's own octave (never octave-shifted).
  readonly property bool octaveFree: false

  // ── live pitch state ─────────────────────────────────────────────────────
  readonly property real frameSecs: 768 / 48000
  property real liveMidi: 0
  property real liveHz: 0
  property bool voiced: false
  property real level: 0
  property real hold: 0
  readonly property real errCents: voiced ? (liveMidi - displayTarget) * 100 : 0
  readonly property bool inTune: voiced && !unlocked && Math.abs(errCents) <= tolerance
  property var history: []              // per frame: {m, ok, e} or null (silence)
  readonly property int historyMax: 460
  property var recent: []
  property int silentFrames: 99
  property real muteUntil: 0
  property bool muted: false            // a reference tone is sounding; mic input ignored
  readonly property bool wide: width >= 1000
  property bool micError: false
  property int frameCount: 0
  property real lastMidi: 0             // last voiced pitch, so the monitor never goes blank

  property real lastPlayAt: 0
  function play(secs, gain, midis) {
    lastPlayAt = Date.now()
    const args = [pitchd, "play", "-t", opt("toneSound", "organ"), secs.toFixed(2), (gain * opt("toneVolume", 1.0)).toFixed(2)]
    Quickshell.execDetached(args.concat(midis.map(m => midiToHz(m).toFixed(2))))
    // Ignore the mic while our own tone is audible so speaker bleed can't pass a stage.
    muteUntil = Math.max(muteUntil, Date.now() + secs * 1000 + 300)
  }
  // Sound rules — nothing else ever plays:
  //   a chord appears  → its first note (setting: playFirstNote)
  //   Space            → the note to sing now (root, then 3rd, then 5th)
  //   a note matched   → the next note
  //   unlocked         → the finished chord
  // A melody plays in full (each note in turn) when it appears and on Space.
  function playMelody() {
    const noteSecs = 0.55
    const args = [pitchd, "arp", "-t", opt("toneSound", "organ"), noteSecs.toFixed(2), "0.01", (0.9 * opt("toneVolume", 1.0)).toFixed(2)]
    Quickshell.execDetached(args.concat(notes.map(m => midiToHz(m).toFixed(2))))
    lastPlayAt = Date.now()
    muteUntil = Math.max(muteUntil, Date.now() + noteSecs * notes.length * 1000 + 400)
  }
  function playCurrentNote() {
    if (unlocked || passMode) return
    play(1.4, 1.0, [notes[tone]])
  }
  function playTarget() {
    if (isMelody && !unlocked && !passMode) { heardReference = true; playMelody(); return }
    if (unlocked || passMode) return
    heardReference = true
    play(1.4, 1.0, [notes[tone]])
  }

  // ── progress stats: timed from the first sung note to unlock ────────────
  property real firstVoiceAt: 0
  property real centsSum: 0
  property int centsN: 0
  property real unlockedAt: 0
  property var lastStats: null
  property var newAchievements: []      // titles earned by this unlock
  property bool bestSaved: false        // this unlock was a new best and was recorded
  // Replay your best: the fastest unlock per kind and difficulty is kept as a recording
  // (never in pass-notes mode). Setting: saveBest.
  readonly property string bestDir: Quickshell.env("HOME") + "/.local/state/pitchlock/best"
  property var pastUnlocks: []          // supplied by the lock service (saved history)
  readonly property string statsLine: lastStats
    ? (lastStats.daily ? "daily challenge " : "unlocked ") + "in " + lastStats.secs.toFixed(1) + " s  ·  " + Math.round(lastStats.cents) + "¢ off  ·  " + lastStats.steady + "% steady"
    : ""
  readonly property var difficultyNames: ({ easy: "Easy", normal: "Normal", hard: "Hard", perfect: "Perfect pitch", custom: "Custom" })
  readonly property var voiceNames: ({ bass: "Bass", baritone: "Baritone", tenor: "Tenor", alto: "Alto", mezzo: "Mezzo-soprano", soprano: "Soprano", all: "All", custom: "Custom voice" })
  function comboName(u) { return (difficultyNames[u.difficulty] || u.difficulty) + " · " + (voiceNames[u.voice] || u.voice) + (u.kind === "melody" ? " · melodies" : "") }
  readonly property string historyLine: {
    if (!lastStats) return ""
    // Only compare with unlocks at the same difficulty and voice type.
    const prev = pastUnlocks.filter(u => u.at !== lastStats.at
      && u.difficulty === lastStats.difficulty && u.voice === lastStats.voice && (u.kind || "chord") === lastStats.kind)
    if (!prev.length) return "first unlock at " + comboName(lastStats)
    const best = Stats.best(prev)
    const t = Stats.typical(prev.slice(-10))
    return comboName(lastStats) + "  ·  " + (lastStats.secs < best ? "new best!" : "best " + best.toFixed(1) + " s")
      + "  ·  typical " + t.secs.toFixed(1) + " s, " + Math.round(t.cents) + "¢"
      + (t.steady >= 0 ? ", " + Math.round(t.steady) + "% steady" : "")
  }

  function newChallenge() {
    // First lock of the day (not pass-notes): a warm-up, then the daily challenge.
    if (lockMode && !passMode && !Stats.unlockedToday(pastUnlocks)) {
      if (opt("warmUp", true) && !warmedUp) { newWarmup(); return }
      if (newDaily()) return
    }
    // Chords, melodies or both (settings: challengeKind).
    const kind = opt("challengeKind", "chord")
    if (kind === "melody" || (kind === "both" && Math.random() < 0.5)) { newMelody(); return }
    const fits = q => rootsFor(q).length > 0
    const on = (chordTypesEnabled && chordTypesEnabled.length ? chordTypesEnabled : ["major", "minor"]).filter(fits)
    const plain = on.filter(t => t === "major" || t === "minor")
    const colour = on.filter(t => t !== "major" && t !== "minor")
    const any = list => list[Math.floor(Math.random() * list.length)]
    let q = colour.length && (!plain.length || Math.random() < colourChordChance) ? any(colour)
      : plain.length ? any(plain) : "major"
    // Every chord has a 7th: four notes (a triad only if no 7th voicing fits the pocket).
    const ext = (seventhsOf[q] || []).filter(fits)
    if (ext.length) q = any(ext)
    const iv = qualities[q].iv
    // Root first (random, never the last one's note name). Then the plain root-position
    // chord if it fits; an inversion only when it doesn't.
    const root = pickRoot(rootsFor(q))
    const vs = voicings(root, iv)
    const plainVoicing = vs.find(v => v[0] === Math.min.apply(null, v))
    const voicing = plainVoicing || any(vs)
    // Singing order: root, 3rd, 5th, 7th — or shuffled when random order is on.
    const ord = iv.map((_, i) => i)
    if (randomOrder)
      for (let i = ord.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [ord[i], ord[j]] = [ord[j], ord[i]] }
    stage = 0
    done = ord.map(() => false)
    challenge = { quality: q, order: ord, root: voicing[0], notes: voicing }
    challengeStarted()
  }

  // A singable melody: 4–6 notes of mostly small steps, all inside the pocket, starting on a
  // random note (never the last one's note name).
  function newMelody() {
    const len = 4 + Math.floor(Math.random() * 3)
    const starts = []
    for (let m = rangeLow; m <= rangeHigh; m++) starts.push(m)
    const tune = [pickRoot(starts)]
    const steps = [-4, -3, -2, -2, -1, -1, 1, 1, 2, 2, 3, 4, 5]
    while (tune.length < len) {
      const options = steps.map(st => tune[tune.length - 1] + st).filter(m => m >= rangeLow && m <= rangeHigh)
      tune.push(options[Math.floor(Math.random() * options.length)])
    }
    stage = 0
    done = tune.map(() => false)
    challenge = { quality: "melody", order: tune.map((_, i) => i), root: tune[0], notes: tune }
    challengeStarted()
  }

  // Warm-up: five notes of a major scale up and four back down, in the middle of the pocket.
  // Untimed; finishing it moves on to the daily challenge instead of unlocking.
  property bool warmedUp: false
  function newWarmup() {
    const start = rangeLow + Math.max(0, Math.floor((rangeHigh - rangeLow - 7) / 2))
    const tune = [0, 2, 4, 5, 7, 5, 4, 2, 0].map(x => start + x)
    stage = 0
    done = tune.map(() => false)
    challenge = { quality: "warmup", order: tune.map((_, i) => i), root: tune[0], notes: tune }
    challengeStarted()
  }

  // Daily challenge: the day's chord type and root note name come from the date (see
  // pitchstats.js), voiced in this pocket. Returns false if nothing fits (then: a normal one).
  function newDaily() {
    const key = Stats.dayKey()
    const d = Stats.daily(key)
    if (opt("challengeKind", "chord") === "melody") {
      let m = rangeLow + ((d.pc - rangeLow) % 12 + 12) % 12
      const tune = [m]
      for (let i = 0; i < d.length - 1; i++) {
        let next = tune[tune.length - 1] + d.steps[i]
        if (next < rangeLow || next > rangeHigh) next = tune[tune.length - 1] - d.steps[i]
        tune.push(Math.max(rangeLow, Math.min(rangeHigh, next)))
      }
      stage = 0
      done = tune.map(() => false)
      challenge = { quality: "melody", order: tune.map((_, i) => i), root: tune[0], notes: tune, daily: key }
      challengeStarted()
      return true
    }
    for (const q of d.types) {
      const roots = rootsFor(q).filter(r => pc(r) === d.pc)
      if (!roots.length) continue
      const vs = voicings(roots[0], qualities[q].iv)
      const voicing = vs.find(v => v[0] === Math.min.apply(null, v)) || vs[0]
      const ord = voicing.map((_, i) => i)
      stage = 0
      done = ord.map(() => false)
      challenge = { quality: q, order: ord, root: voicing[0], notes: voicing, daily: key }
      challengeStarted()
      return true
    }
    return false
  }

  function challengeStarted() {
    console.log("pitchlock challenge " + rootMidi + " " + quality + " notes " + notes.join(",") + " order " + order.join(","))
    firstVoiceAt = 0
    centsSum = 0
    holdCents = []
    noteSteadiness = []
    noteCentsList = []
    centsN = 0
    lastStats = null
    newAchievements = []
    bestSaved = false
    hold = 0
    unlockTimer.stop()
    // Play the first note once the chord has settled (a new chord can be replaced right
    // away when settings finish loading; the restart makes that one note, not two).
    if (active && opt("playFirstNote", true)) firstNoteTimer.restart()
  }

  // Steadiness: the pitch wobble while each note was held.
  property var holdCents: []
  property var noteSteadiness: []
  // Trouble notes: the average signed cents while each note was held (flat < 0 < sharp).
  property var noteCentsList: []
  function completeStage() {
    noteSteadiness = noteSteadiness.concat([Stats.steadiness(Stats.stdDev(holdCents.slice(-120)))])
    if (holdCents.length)
      noteCentsList = noteCentsList.concat([{ m: notes[tone], c: Math.round(holdCents.reduce((a, v) => a + v, 0) / holdCents.length * 10) / 10 }])
    holdCents = []
    const d = done.slice(); d[tone] = true; done = d
    hold = 0
    stage++
    if (unlocked && isWarmup) {
      // warmed up: straight on to the daily challenge (no score, no unlock)
      warmedUp = true
      play(1.0, 0.8, [notes[0], notes[0] + 4, notes[0] + 7])
      warmupDone.restart()
      return
    }
    if (unlocked) {
      if (opt("unlockChord", true)) play(2.8, 1.0, notes)
      unlockedAt = Date.now()
      if (firstVoiceAt > 0) {
        lastStats = {
          at: new Date().toISOString(),
          secs: (Date.now() - firstVoiceAt) / 1000,
          cents: centsN ? centsSum / centsN : 0,
          steady: Math.round(noteSteadiness.reduce((a, v) => a + v, 0) / Math.max(1, noteSteadiness.length)),
          noteCents: noteCentsList,
          root: rootMidi,
          quality: quality,
          kind: isMelody ? "melody" : "chord",
          daily: challenge.daily || undefined,
          // scores are kept per difficulty and voice type
          difficulty: effectiveDifficulty,
          voice: opt("voice", "bass")
        }
        const before = pastUnlocks.filter(u => u.at !== lastStats.at)
        const same = before.filter(u => u.difficulty === lastStats.difficulty && (u.kind || "chord") === lastStats.kind)
        bestSaved = false
        if (lockMode && !passMode && opt("saveBest", true) && mic.running
            && (!same.length || lastStats.secs < Stats.best(same))) {
          const file = bestDir + "/" + lastStats.kind + "-" + lastStats.difficulty + ".wav"
          Quickshell.execDetached(["mkdir", "-p", bestDir])
          mic.write("save " + file + " " + Math.min(44, lastStats.secs + 1.5).toFixed(1) + "\n")
          lastStats.recording = file
          bestSaved = true
        }
        // Achievements can be limited to one voice type (setting: achievementsVoice).
        const av = opt("achievementsVoice", "")
        newAchievements = lockMode && (!av || lastStats.voice === av)
          ? Stats.newlyEarned(Stats.forAchievements(before, av), Stats.forAchievements(before, av).concat([lastStats]), null) : []
        if (lockMode) unlockRecorded(lastStats)
        else pastUnlocks = pastUnlocks.concat([lastStats])
      }
      unlockTimer.restart()
    } else {
      if (opt("playNextNote", true)) playCurrentNote()
    }
  }

  function onFrame(line) {
    const p = line.trim().split(" ")
    if (p.length < 3) return
    const hz = +p[0], clarity = +p[1], rms = +p[2]
    muted = Date.now() < muteUntil
    lastFrameAt = Date.now()
    if (+p[2] > 0) lastSoundAt = lastFrameAt
    if (micError && lastSoundAt === lastFrameAt) micError = false   // the mic came back
    level = level * 0.75 + Math.min(1, Math.sqrt(rms) * 3) * 0.25

    if (hz > 0 && clarity > 0.75 && !muted) {
      const m = hzToMidi(hz)
      recent.push(m)
      if (recent.length > 5) recent.shift()
      const med = recent.slice().sort((a, b) => a - b)[recent.length >> 1]
      liveMidi = (!voiced || Math.abs(med - liveMidi) > 0.8) ? med : liveMidi + (med - liveMidi) * 0.45
      liveHz = midiToHz(liveMidi)
      lastMidi = liveMidi
      voiced = true
      silentFrames = 0
      lastEngaged = Date.now()
      if (Date.now() - lastActivity > 2000) { lastActivity = Date.now(); wakeRequested() }
    } else if (++silentFrames > 8) {
      voiced = false
      recent = []
    }

    if (!octaveFree) octaveShift = 0
    else if (voiced && !unlocked && Math.abs(liveMidi - displayTarget) > 7)
      octaveShift = Math.round((liveMidi - targetMidi) / 12)

    if (passMode) {
      hold = 0
      if (voiced) {
        passQuiet = 0
        const n = Math.round(liveMidi)
        if (Math.abs(errCents) <= tolerance) {
          if (n !== passNote) { passNote = n; passHeldFor = 0; passCounted = false }
          passHeldFor += frameSecs
          if (!passCounted && passHeldFor >= holdNeeded) {
            passCounted = true
            passDots = Math.min(4, passDots + 1)
            lastSung = n
            noteSung(n)
          }
        } else if (n !== passNote) {
          passNote = -1; passHeldFor = 0; passCounted = false
        }
      } else if (++passQuiet > 8) {
        passNote = -1; passHeldFor = 0; passCounted = false
        if (passQuiet > 5 / frameSecs) passDots = 0     // a 5 s pause starts over
      }
    } else {
      if (voiced && !unlocked && firstVoiceAt === 0) firstVoiceAt = Date.now()
      if (inTune) { centsSum += Math.abs(errCents); centsN++; holdCents.push(errCents) }
      if (inTune) hold = Math.min(holdNeeded, hold + frameSecs)
      else if (!unlocked) hold = Math.max(0, hold - frameSecs * (voiced ? 0.8 : 0.3))
    }

    history.push(voiced ? { m: liveMidi, ok: inTune, e: errCents } : null)
    if (voiced && frameCount % 9 === 0 && floats.visible) floats.spawn(liveMidi, inTune)
    if (history.length > historyMax) history.shift()

    if (!passMode && hold >= holdNeeded && !unlocked) completeStage()
    frameCount++
    trace.requestPaint()
    ring.requestPaint()
  }

  Process {
    id: mic
    running: root.active && !root.micAsleep
    stdinEnabled: true                  // "save <file> <secs>" keeps a best unlock as a recording
    command: [root.pitchd, "mic", String(root.opt("micSensitivity", 3.0))]
    stdout: SplitParser { onRead: data => root.onFrame(data) }
    // (stopping it for mic sleep isn't a failure)
    onExited: if (root.active && !root.micAsleep) root.micError = true
  }

  // Harmony drone (headphones): while you sing the other notes, the root keeps sounding
  // quietly underneath, like singing harmony against it. Off by default.
  Process {
    running: !!root.opt("harmonyDrone", false) && root.active && !root.micAsleep && !root.passMode
             && root.quality !== "melody" && !root.unlocked && root.tone > 0
    command: [root.pitchd, "play", "-t", root.opt("toneSound", "organ") === "piano" ? "organ" : root.opt("toneSound", "organ"),
              "600", (0.35 * root.opt("toneVolume", 1.0)).toFixed(2), root.midiToHz(root.rootMidi).toFixed(2)]   // a piano can't sustain a drone
  }

  Timer { id: warmupDone; interval: 1300; onTriggered: root.newChallenge() }

  Timer {
    id: firstNoteTimer
    interval: 600
    onTriggered: if (root.active && !root.micAsleep && !root.unlocked && root.stage === 0
                     && Date.now() - root.lastPlayAt > 1000) root.playTarget()
  }

  Timer {
    id: unlockTimer
    interval: root.lockMode ? root.opt("unlockPauseSeconds", 3.0) * 1000 : 4200  // time to see the unlock moment
    onTriggered: root.lockMode ? root.unlockRequested() : root.newChallenge()
  }

  Component.onCompleted: {
    requestNewChallenge()
    if (lockMode) forceActiveFocus()
  }
  onActiveChanged: if (active) { engage(); micError = false; micWatchFrom = Date.now(); requestNewChallenge(); forceActiveFocus() }

  // Microphone watchdog. "Singing only" relies on the mic, so a mic that never starts,
  // stops sending audio, or sends pure digital silence (muted/dead) counts as failed,
  // which brings the password back. A real room is never exactly silent.
  property real micWatchFrom: Date.now()
  property real lastFrameAt: 0
  property real lastSoundAt: 0
  Timer {
    running: root.lockMode && root.active && !root.micAsleep
    interval: 1000
    repeat: true
    onTriggered: {
      const now = Date.now()
      const since = t => now - Math.max(t, root.micWatchFrom)
      if (since(root.lastFrameAt) > 3000 || since(root.lastSoundAt) > 5000) root.micError = true
    }
  }

  Timer {
    running: root.lockMode && root.active && !root.micAsleep
    interval: 1000
    repeat: true
    onTriggered: {
      if (Date.now() - root.lastEngaged < root.micSleepAfter * 1000) return
      root.micAsleep = true
      root.voiced = false
      root.level = 0
      root.hold = 0
    }
  }

  // Only real mouse movement counts; the compositor can re-send hover events for a still pointer.
  HoverHandler {
    enabled: root.lockMode
    property point last: Qt.point(-1, -1)
    onPointChanged: {
      const p = point.position
      if (Math.abs(p.x - last.x) + Math.abs(p.y - last.y) > 6) {
        if (last.x >= 0) root.engage()
        last = p
      }
    }
  }

  function lockKey(e) {
    if (singingOnly) {
      if (e.key === Qt.Key_Space) { playTarget(); return true }
      return false
    }
    const ctrl = e.modifiers & Qt.ControlModifier
    if (ctrl) {
      switch (e.key) {
      case Qt.Key_U: typedTextEdited(""); return true
      }
      return false
    }
    switch (e.key) {
    case Qt.Key_Space: playTarget(); return true
    case Qt.Key_Escape: typedTextEdited(""); return true
    case Qt.Key_Backspace: typedTextEdited(typedText.slice(0, -1)); return true
    case Qt.Key_Return: case Qt.Key_Enter:
      if (typedText.length > 0 && !authenticating) submitPassword(typedText)
      return true
    }
    if (e.text.length === 1 && e.text >= " " && !authenticating) {
      typedTextEdited(typedText + e.text)
      return true
    }
    return false
  }

  Keys.onTabPressed: e => { if (!lockMode) { tabRequested(); e.accepted = true } }
  Keys.onPressed: e => {
    if (lockMode) {
      wakeRequested()
      engage()
      e.accepted = lockKey(e)
      return
    }
    switch (e.key) {
    case Qt.Key_Space: playTarget(); break
    case Qt.Key_Escape: case Qt.Key_Q: quitRequested(); break
    default: return
    }
    e.accepted = true
  }

  // ── layout ───────────────────────────────────────────────────────────────
  // Blurred wallpaper under a theme-coloured tint, so the game reads on any image.
  Rectangle {
    anchors.fill: parent
    color: root.pal.bg

    Image {
      id: wallpaper
      anchors.fill: parent
      visible: false
      source: root.backgroundPath
        ? "file://" + root.backgroundPath.split("/").map(encodeURIComponent).join("/") + "?v=" + root.backgroundVersion
        : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: parent
      source: wallpaper
      visible: wallpaper.status === Image.Ready
      autoPaddingEnabled: false
      blurEnabled: true
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
    }

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(root.pal.bgGlow.r, root.pal.bgGlow.g, root.pal.bgGlow.b, wallpaper.status === Image.Ready ? 0.55 : 1) }
        GradientStop { position: 0.55; color: Qt.rgba(root.pal.bg.r, root.pal.bg.g, root.pal.bg.b, wallpaper.status === Image.Ready ? 0.72 : 1) }
      }
    }
  }

  PitchFloatingNotes {
    id: floats
    anchors.fill: parent
    game: root
    hideNames: root.passMode
    visible: !!root.opt("floatingNotes", true)
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 32
    spacing: 20

    // header
    RowLayout {
      Layout.fillWidth: true
      spacing: 16

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        Text {
          id: brand
          text: (root.lockMode ? Qt.formatDateTime(clock.now, "dddd  ·  HH:mm") : "PITCHLOCK")
            + (root.isWarmup ? "  ·  WARM-UP" : root.isDaily ? "  ·  DAILY CHALLENGE" : "")
          color: root.pal.dim
          font { family: root.pal.font; pixelSize: 13; letterSpacing: 5; weight: Font.DemiBold }
          QtObject { id: clock; property date now: new Date() }
          Timer { running: root.lockMode; repeat: true; interval: 10000; triggeredOnStart: true; onTriggered: clock.now = new Date() }
        }
        Text {
          text: root.passMode ? "Sing your pass-notes"
              : root.unlocked && root.isWarmup ? "Warmed up! Now the daily challenge…"
              : root.unlocked ? "Unlocked"
              : root.isWarmup ? "Warm up: note " + (root.stage + 1) + " of " + root.toneCount
              : root.isMelody ? "Sing note " + (root.stage + 1) + " of " + root.toneCount
              : root.tone === 0 ? "Match the root"
              : "Sing the " + String(root.toneNames[root.tone] || "note").toLowerCase()
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          color: root.unlocked ? root.pal.good : root.pal.text
          font { family: root.pal.font; pixelSize: root.wide ? 34 : 24; weight: Font.Bold }
        }
        Text {
          text: root.passMode ? (root.passCooldown > 0 ? "Too many wrong notes — try again in " + root.passCooldown + " s  ·  or type your pass-code"
                                                     : "From memory  ·  or type your pass-code")
            : root.unlocked
            ? (root.isMelody ? "Melody complete" : root.noteNames[root.pc(root.rootMidi)] + " " + root.qualityLabel(root.quality) + " complete")
            : "Target " + root.noteName(root.displayTarget) + "  ·  "
              + root.midiToHz(root.displayTarget).toFixed(1) + " Hz  ·  hold " + Number(root.holdNeeded.toFixed(3)) + " s"
              + "  ·  space: hear it"
              + (root.easeActive ? "  ·  " + (root.hourNow < 12 ? "early" : "late") + ": " + root.effectiveDifficulty : "")
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          color: root.passMode ? root.pal.dim : root.unlocked ? root.pal.good : root.toneColors[Math.max(0, root.tone)]
          font { family: root.pal.font; pixelSize: root.wide ? 16 : 13 }
        }
      }

      ColumnLayout {
        Layout.alignment: Qt.AlignTop | Qt.AlignRight
        spacing: 8
        RowLayout {
          Layout.alignment: Qt.AlignRight
          spacing: 8
          Text {
            readonly property int streak: Stats.currentStreak(root.pastUnlocks)
            visible: root.lockMode && streak >= 2
            Layout.alignment: Qt.AlignVCenter
            text: "🔥 " + streak + "-day streak"
            color: root.pal.warn
            font { family: root.pal.font; pixelSize: 13; bold: true }
          }
          PitchBadge {
            text: root.micError ? "mic error" : root.micAsleep ? "mic asleep" : "mic"
            on: !root.micError && !root.micAsleep
            pal: root.pal
            alert: root.micError
          }
        }
        Rectangle {
          Layout.alignment: Qt.AlignRight
          implicitWidth: 220; implicitHeight: 6; radius: 3
          color: root.pal.grid
          Rectangle {
            height: parent.height; radius: 3
            width: parent.width * root.level
            color: root.muted ? root.pal.dim : root.pal.good
            Behavior on width { NumberAnimation { duration: 60 } }
          }
        }
      }
    }

    // main: trace beside the ring when wide, stacked above it when narrow
    GridLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      columns: root.wide ? 2 : 1
      rowSpacing: 16
      columnSpacing: 20

      Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 160
        radius: 18
        // translucent enough for the floating notes behind it to show through
        color: Qt.rgba(root.pal.panel.r, root.pal.panel.g, root.pal.panel.b, root.opt("floatingNotes", true) ? 0.62 : 0.86)
        border { color: root.pal.grid; width: 1 }

        PitchTrace {
          id: trace
          anchors.fill: parent
          anchors.margins: 1
          game: root
        }

        Column {
          anchors.centerIn: parent
          spacing: 14
          opacity: root.unlocked && !root.isWarmup ? 1 : 0
          scale: root.unlocked && !root.isWarmup ? 1 : 0.85
          Behavior on opacity { NumberAnimation { duration: 500 } }
          Behavior on scale { NumberAnimation { duration: 700; easing.type: Easing.OutBack } }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "UNLOCKED"
            color: root.pal.good
            font { family: root.pal.font; pixelSize: 72; weight: Font.Black; letterSpacing: 14 }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.statsLine
            visible: text.length > 0 && root.opt("showStats", true)
            color: root.pal.text
            font { family: root.pal.font; pixelSize: 20 }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.bestSaved && root.opt("showStats", true)
            text: "🎙  new best — saved a recording (♪ panel → Best recordings)"
            color: root.pal.good
            font { family: root.pal.font; pixelSize: 15 }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.newAchievements.length > 0
            text: "🏆  " + root.newAchievements.join("  ·  ")
            color: root.pal.warn
            font { family: root.pal.font; pixelSize: 18; weight: Font.Bold }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.historyLine
            visible: text.length > 0 && root.opt("showStats", true)
            color: root.historyLine.indexOf("new best") >= 0 ? root.pal.good : root.pal.dim
            font { family: root.pal.font; pixelSize: 15; letterSpacing: 1 }
          }
        }
      }

      ColumnLayout {
        id: side
        readonly property real ringSize: root.wide
          ? Math.max(220, Math.min(420, root.width * 0.32, root.height - 380))
          : Math.max(150, Math.min(root.width - 64, root.height * 0.3))
        Layout.preferredWidth: root.wide ? ringSize : -1
        Layout.maximumWidth: root.wide ? ringSize : Number.POSITIVE_INFINITY
        Layout.fillWidth: !root.wide
        Layout.fillHeight: root.wide
        spacing: 16

        PitchChordRing {
          id: ring
          Layout.alignment: Qt.AlignHCenter
          Layout.preferredWidth: side.ringSize
          Layout.preferredHeight: side.ringSize
          game: root
        }

        PitchCentsMeter {
          Layout.fillWidth: true
          Layout.preferredHeight: 54
          game: root
        }

        Item { Layout.fillHeight: true; visible: root.wide }
      }
    }

    // pass-notes mode: one plain dot per note heard (never shows which were right)
    Row {
      visible: root.passMode
      Layout.alignment: Qt.AlignHCenter
      Layout.preferredHeight: 64
      spacing: 22
      Repeater {
        model: 4
        Rectangle {
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          width: 22; height: 22; radius: 11
          color: index < (root.passProgress >= 0 ? root.passProgress : root.passDots) ? root.pal.text : "transparent"
          border { width: 2; color: root.pal.dim }
          Behavior on color { ColorAnimation { duration: 120 } }
        }
      }
    }

    // stage chips
    RowLayout {
      visible: !root.passMode
      Layout.fillWidth: true
      spacing: 14
      Repeater {
        model: root.order               // chips in singing order
        PitchStageChip {
          required property var modelData
          Layout.fillWidth: true
          game: root
          idx: modelData
        }
      }
    }

    // lock mode: typed input (password fallback). Dots only; nothing hints at other words.
    Rectangle {
      visible: root.lockMode
      Layout.alignment: Qt.AlignHCenter
      implicitWidth: Math.min(420, root.width - 64)
      implicitHeight: 44
      radius: 22
      color: Qt.rgba(root.pal.panel.r, root.pal.panel.g, root.pal.panel.b, 0.9)
      border.width: 1
      border.color: root.failureMessage.length > 0 ? root.pal.bad : root.typedText.length > 0 ? root.pal.dim : root.pal.grid

      Text {
        anchors.centerIn: parent
        width: parent.width - 32
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideLeft
        text: root.authenticating ? "Checking…"
            : root.typedText.length > 0 ? "●".repeat(Math.min(root.typedText.length, 32))
            : root.failureMessage.length > 0 ? root.failureMessage
            : root.micAsleep ? "mic asleep  ·  press any key to wake it"
            : root.singingOnly ? "singing only  ·  sing the chord to unlock"
            : root.passMode ? "type your pass-code  ·  or your password + Enter"
            : root.micError ? "microphone unavailable  ·  type your password"
            : "sing to unlock  ·  or type your password"
        color: root.failureMessage.length > 0 && root.typedText.length === 0 ? root.pal.bad
             : root.typedText.length > 0 || root.authenticating ? root.pal.text : root.pal.dim
        font { family: root.pal.font; pixelSize: root.typedText.length > 0 ? 16 : 13; letterSpacing: root.typedText.length > 0 ? 3 : 1 }
      }
    }

    Text {
      Layout.alignment: Qt.AlignHCenter
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: root.lockMode
        ? (root.passMode ? "sing your four pass-notes, or type your pass-code" : "space  hear the note to sing")
        : "space  hear the note to sing     esc  quit"
      color: root.pal.dim
      font { family: root.pal.font; pixelSize: 12; letterSpacing: 1 }
    }
  }
}
