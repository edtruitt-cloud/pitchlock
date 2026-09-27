import QtQuick
import Quickshell
import Quickshell.Io

// Every tunable setting, stored in ~/.config/pitchlock/settings.json. The lock service,
// the practice window and the settings panel all share this; edits apply live.
QtObject {
  id: settings

  property string path: Quickshell.env("HOME") + "/.config/pitchlock/settings.json"

  // Voice presets: the pocket is the middle octave of the voice's typical range,
  // where it's strongest. Chords always fit inside the pocket.
  readonly property var presets: [
    { value: "bass", label: "Bass", low: 46, high: 58 },          // Bb2–Bb3 (range ~E2–E4)
    { value: "baritone", label: "Baritone", low: 51, high: 63 },  // Eb3–Eb4 (range ~A2–A4)
    { value: "tenor", label: "Tenor", low: 54, high: 66 },        // F#3–F#4 (range ~C3–C5)
    { value: "alto", label: "Alto", low: 59, high: 71 },          // B3–B4   (range ~F3–F5)
    { value: "mezzo", label: "Mezzo-soprano", low: 63, high: 75 },// Eb4–Eb5 (range ~A3–A5)
    { value: "soprano", label: "Soprano", low: 66, high: 78 },    // F#4–F#5 (range ~C4–C6)
    { value: "all", label: "All (wide-range voices)", low: 46, high: 78 }, // Bb2–F#5: every preset's pocket
    { value: "custom", label: "Custom", low: -1, high: -1 }
  ]
  readonly property var chordTypes: [
    { value: "major", label: "Major" }, { value: "minor", label: "Minor" },
    { value: "dim", label: "Diminished" }, { value: "aug", label: "Augmented" },
    { value: "sus4", label: "Sus4" }
  ]
  readonly property int minPocketSpan: 9   // every 4-note chord fits 9 notes in some inversion

  // Difficulty presets set accuracy, hold time and how often colour chords appear.
  readonly property var difficulties: [
    { value: "easy", label: "Easy", tolerance: 40, holdSeconds: 0.3, colourChordChance: 0 },
    { value: "normal", label: "Normal", tolerance: 26.875, holdSeconds: 0.375, colourChordChance: 0.25 },
    { value: "hard", label: "Hard", tolerance: 15, holdSeconds: 0.75, colourChordChance: 0.5 },
    { value: "perfect", label: "Perfect pitch", tolerance: 10, holdSeconds: 1.5, colourChordChance: 1.0 },
    { value: "custom", label: "Custom" }
  ]

  property alias voice: data.voice
  property alias pocketLow: data.pocketLow
  property alias pocketHigh: data.pocketHigh
  property alias tolerance: data.tolerance
  property alias holdSeconds: data.holdSeconds
  property alias difficulty: data.difficulty
  property alias randomOrder: data.randomOrder
  property alias chordTypesEnabled: data.chordTypesEnabled
  property alias colourChordChance: data.colourChordChance
  property alias toneVolume: data.toneVolume
  property alias playFirstNote: data.playFirstNote
  property alias playNextNote: data.playNextNote
  property alias unlockChord: data.unlockChord
  property alias micSleepSeconds: data.micSleepSeconds
  property alias micSensitivity: data.micSensitivity
  property alias bypassWord: data.bypassWord
  property alias showStats: data.showStats
  property alias unlockPauseSeconds: data.unlockPauseSeconds

  function applyPreset(name) {
    const p = presets.find(x => x.value === name)
    data.voice = name
    if (p && p.low > 0) { data.pocketLow = p.low; data.pocketHigh = p.high }
  }
  function setPocket(low, high) {
    data.voice = "custom"
    data.pocketLow = Math.max(28, Math.min(low, high - minPocketSpan))
    data.pocketHigh = Math.min(84, Math.max(high, low + minPocketSpan))
  }
  function applyDifficulty(name) {
    const d = difficulties.find(x => x.value === name)
    data.difficulty = name
    if (!d || d.tolerance === undefined) return
    data.tolerance = d.tolerance
    data.holdSeconds = d.holdSeconds
    data.colourChordChance = d.colourChordChance
    // Perfect pitch is every time a diminished, augmented or sus4 chord.
    if (name === "perfect")
      for (const t of ["dim", "aug", "sus4"]) if (!chordTypeOn(t)) data.chordTypesEnabled = data.chordTypesEnabled.concat([t])
  }
  // Moving a difficulty slider by hand makes it a custom difficulty.
  function setTuning(key, value) { data[key] = value; data.difficulty = "custom" }
  function setChordType(type, on) {
    let list = (data.chordTypesEnabled || []).filter(t => t !== type)
    if (on) list.push(type)
    if (list.length === 0) return            // always keep at least one chord type
    data.chordTypesEnabled = list
  }
  function chordTypeOn(type) { return (data.chordTypesEnabled || []).indexOf(type) >= 0 }
  function resetToDefaults() {
    for (const k in defaults) if (k !== "bypassWord") data[k] = defaults[k]   // keep the bypass word
  }

  // Defaults are the tuning pitchlock was built around (a bass).
  readonly property var defaults: ({
    voice: "bass", pocketLow: 46, pocketHigh: 58,
    difficulty: "normal", tolerance: 26.875, holdSeconds: 0.375, randomOrder: false,
    chordTypesEnabled: ["major", "minor", "dim", "aug", "sus4"], colourChordChance: 0.25,
    toneVolume: 1.0, playFirstNote: true, playNextNote: true, unlockChord: true,
    micSleepSeconds: 60, micSensitivity: 3.0,
    bypassWord: "", showStats: true, unlockPauseSeconds: 3.0
  })

  // Saving: changes made together (a preset sets several values) are written as one save
  // a moment later. Writing after every single change let this file's own watcher reload
  // the half-written file and undo the rest of the preset.
  property real ignoreChangesUntil: 0
  function save() {
    ignoreChangesUntil = Date.now() + 1000
    file.writeAdapter()
  }

  property FileView file: FileView {
    path: settings.path
    // Read the file before anything uses these values: a game made first would build
    // its opening chord from the defaults instead of the user's range.
    blockLoading: true
    watchChanges: true
    printErrors: false
    // Reload edits made elsewhere (the panel, the lock, by hand), not our own saves.
    onFileChanged: if (!saveTimer.running && Date.now() > settings.ignoreChangesUntil) reload()
    onAdapterUpdated: saveTimer.restart()
    // First run: create the directory and write the defaults.
    onLoadFailed: {
      Quickshell.execDetached(["mkdir", "-p", Quickshell.env("HOME") + "/.config/pitchlock"])
      writeTimer.start()
    }

    JsonAdapter {
      id: data
      property string voice: "bass"
      property int pocketLow: 46
      property int pocketHigh: 58
      property real tolerance: 26.875
      property real holdSeconds: 0.375
      property string difficulty: "normal"
      property bool randomOrder: false       // sing the chord tones in a shuffled order
      property var chordTypesEnabled: ["major", "minor", "dim", "aug", "sus4"]
      property real colourChordChance: 0.25
      property real toneVolume: 1.0
      property bool playFirstNote: true      // a new chord (lock opening, practice) plays its first note
      property bool playNextNote: true
      property bool unlockChord: true
      property real micSleepSeconds: 60
      property real micSensitivity: 3.0      // voice must be this many times the room noise
      property string bypassWord: ""         // empty = no bypass word
      property bool showStats: true
      property real unlockPauseSeconds: 3.0
    }
  }

  property Timer saveTimer: Timer { interval: 150; onTriggered: settings.save() }
  property Timer writeTimer: Timer { interval: 200; onTriggered: settings.save() }
}
