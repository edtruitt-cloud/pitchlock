import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "pitchstats.js" as Stats

// Pitchlock settings, styled after the Matrix Rain plugin's panel. Every control writes
// straight to ~/.config/pitchlock/settings.json, which the lock watches and applies live.
// The panel never talks to the lock service itself: Omarchy keeps authentication services
// unreachable from other plugin code.
Rectangle {
  id: panel

  property QtObject bar: null
  signal closeRequested()

  PitchSettings { id: localSettings }
  readonly property var s: localSettings
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.65)
  readonly property color accent: bar && bar.accent ? bar.accent : Color.accent
  readonly property string fontFamily: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  function luminance(c) {
    function linear(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
  }
  readonly property color onAccent: luminance(accent) > 0.179 ? "#000000" : "#ffffff"
  function tint(a) { return Qt.rgba(fg.r, fg.g, fg.b, a) }

  readonly property var noteNames: ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
  function noteName(m) { const r = Math.round(m); return noteNames[((r % 12) + 12) % 12] + (Math.floor(r / 12) - 1) }
  // Scrolling never changes a setting: wheels over controls scroll the panel instead.
  function scrollBy(wheel) {
    const max = Math.max(0, scroll.contentHeight - scroll.height)
    scroll.contentY = Math.max(0, Math.min(max, scroll.contentY - wheel.angleDelta.y / 120 * Style.space(60)))
    wheel.accepted = true
  }
  function filePath(name) { return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")) }
  function playMidis(midis) {
    const hz = midis.map(m => (440 * Math.pow(2, (m - 69) / 12)).toFixed(2))
    Quickshell.execDetached([filePath("pitchd"), "arp", "0.7", "0.05", "0.9"].concat(hz))
  }

  // Unlock history, read from the lock's state file (the lock watches it, so a reset sticks).
  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/pitchlock.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    JsonAdapter {
      id: pitchState
      property int lastRoot: -1
      property var unlocks: []
    }
  }

  // ── microphone: shared by the mic test and the voice wizard ─────────────
  property bool micTestOn: false
  readonly property bool micOn: micTestOn || wizard.step === 1 || wizard.step === 3
  property real micLevel: 0
  property real micMidi: 0
  property bool micHeard: false
  property int micQuiet: 0

  Process {
    running: panel.micOn
    command: [panel.filePath("pitchd"), "mic", String(panel.s.micSensitivity)]
    stdout: SplitParser {
      onRead: data => {
        const p = data.trim().split(" ")
        if (p.length < 3) return
        const hz = +p[0], clarity = +p[1], rms = +p[2]
        panel.micLevel = panel.micLevel * 0.7 + Math.min(1, Math.sqrt(rms) * 3) * 0.3
        if (hz > 0 && clarity > 0.75) {
          panel.micMidi = 69 + 12 * Math.log2(hz / 440)
          panel.micHeard = true
          panel.micQuiet = 0
          if (wizard.step === 1 || wizard.step === 3) wizard.samples.push(panel.micMidi)
        } else if (++panel.micQuiet > 10) {
          panel.micHeard = false
        }
      }
    }
  }

  // Voice wizard: 0 idle, 1 recording lowest, 2 got lowest, 3 recording highest, 4 result.
  QtObject {
    id: wizard
    property int step: 0
    property var samples: []
    property real low: 0
    property real high: 0
    property real secsLeft: 0
    property string message: ""
    readonly property var pocket: {
      const lo = Math.round(low), hi = Math.round(high)
      if (hi - lo <= 14) return [lo, hi]
      // The pocket is the middle octave of the measured range: where a voice is strongest.
      const c = (lo + hi) / 2
      return [Math.round(c - 6), Math.round(c + 6)]
    }
    function start(n) { samples = []; message = ""; step = n; secsLeft = 4; recordTimer.restart() }
    // A held note: the median of what was heard, ignoring the scoops in and out of it.
    function finish() {
      const t = samples.slice().sort((a, b) => a - b)
      const enough = t.length >= 20
      const mid = enough ? t[Math.floor(t.length / 2)] : 0
      message = enough ? "" : "Didn't hear enough — sing a little louder and hold the note."
      if (step === 1) { if (enough) low = mid; step = enough ? 2 : 0 }
      else if (step === 3) { if (enough) high = mid; step = enough ? 4 : 2 }
    }
  }
  Timer {
    id: recordTimer
    interval: 100
    repeat: true
    onTriggered: {
      wizard.secsLeft = Math.max(0, wizard.secsLeft - 0.1)
      if (wizard.secsLeft <= 0) { stop(); wizard.finish() }
    }
  }

  property var pickNotes: [s.pocketLow, s.pocketLow + 4, s.pocketLow + 7, s.pocketLow + 2]

  color: Color.popups.background
  implicitWidth: Style.space(960)
  implicitHeight: Style.space(720)

  // ── building blocks (after Matrix Rain's panel) ─────────────────────────
  component Label: Text {
    color: panel.fg
    font.family: panel.fontFamily
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
  }
  component Hint: Text {
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
  }
  // "Title  ·  value" in bold, "(what it does)" underneath.
  component FieldLabel: ColumnLayout {
    property string title
    property string value: ""
    property string hint: ""
    Layout.fillWidth: true
    spacing: 2
    Label {
      Layout.fillWidth: true
      wrapMode: Text.WordWrap
      text: parent.title + (parent.value !== "" ? "  ·  " + parent.value : "")
      font.bold: true
    }
    Label {
      Layout.fillWidth: true
      visible: parent.hint.length > 0
      wrapMode: Text.WordWrap
      text: "(" + parent.hint + ")"
      opacity: 0.8
    }
  }
  component Section: Label {
    Layout.fillWidth: true
    color: panel.accent
    font.bold: true
    font.letterSpacing: 1.5
  }
  // A card holding one section.
  component Card: Rectangle {
    default property alias content: cardCol.data
    property bool highlighted: false
    Layout.fillWidth: true
    implicitHeight: cardCol.implicitHeight + Style.space(24)
    radius: 8
    color: panel.tint(0.05)
    border.width: 1
    border.color: highlighted ? panel.accent : panel.tint(0.18)
    ColumnLayout {
      id: cardCol
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
      spacing: Style.space(8)
    }
  }
  // Pill button; the selected one fills with the accent colour.
  component Chip: Rectangle {
    id: chip
    property string text: ""
    property bool selected: false
    property bool small: false
    signal clicked()
    implicitWidth: chipCaption.implicitWidth + (small ? 16 : 22)
    implicitHeight: small ? 26 : 32
    radius: 6
    opacity: enabled ? 1 : 0.4
    color: selected ? panel.accent : panel.tint(chipHit.containsMouse ? 0.18 : 0.08)
    border.color: selected ? panel.accent : panel.tint(0.18)
    Label {
      id: chipCaption
      anchors.centerIn: parent
      text: chip.text
      color: chip.selected ? panel.onAccent : panel.fg
      font.bold: true
      font.pixelSize: chip.small ? Style.font.caption : Style.font.body
    }
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: clicked()
    MouseArea {
      id: chipHit
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
      onWheel: wheel => panel.scrollBy(wheel)
    }
  }
  // Round dial: drag up/down to turn it. The wheel scrolls the panel instead.
  component Knob: Column {
    id: knob
    property string title
    property string valueText
    property real value
    property real from: 0
    property real to: 1
    property real step: 0.01
    signal changed(real value)
    readonly property real frac: Math.max(0, Math.min(1, (value - from) / (to - from)))
    width: 96
    spacing: 5
    Rectangle {
      width: 62; height: 62
      anchors.horizontalCenter: parent.horizontalCenter
      radius: 31
      color: Color.popups.background
      border.color: panel.accent
      border.width: 2
      Rectangle {
        anchors.centerIn: parent
        width: 4; height: 50
        color: "transparent"
        rotation: -135 + knob.frac * 270
        Rectangle { anchors.top: parent.top; width: 4; height: 13; radius: 2; color: panel.accent }
      }
      Label { anchors.centerIn: parent; text: knob.valueText; font.pixelSize: 11 }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.SizeVerCursor
        property real startY
        property real startFrac
        onPressed: mouse => { startY = mouse.y; startFrac = knob.frac }
        onPositionChanged: mouse => {
          if (!pressed) return
          const f = Math.max(0, Math.min(1, startFrac + (startY - mouse.y) / 140))
          const v = knob.from + f * (knob.to - knob.from)
          knob.changed(Number((Math.round(v / knob.step) * knob.step).toFixed(3)))
        }
        onWheel: wheel => panel.scrollBy(wheel)
      }
    }
    Label { anchors.horizontalCenter: parent.horizontalCenter; text: knob.title; font.bold: true; font.pixelSize: 12 }
  }
  component NoteStepper: RowLayout {
    id: ns
    property string label
    property int value
    property bool playable: false
    signal stepped(int delta)
    signal play()
    Layout.fillWidth: true
    Label { text: ns.label; Layout.fillWidth: true }
    Chip { text: "−"; small: true; onClicked: ns.stepped(-1) }
    Label {
      text: panel.noteName(ns.value)
      color: panel.accent
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      Layout.preferredWidth: Style.space(52)
    }
    Chip { text: "+"; small: true; onClicked: ns.stepped(1) }
    Chip { visible: ns.playable; text: "▶"; small: true; onClicked: ns.play() }
  }
  component SettingToggle: Toggle {
    Layout.fillWidth: true
    foreground: panel.fg
    accent: panel.accent
  }

  // ── content ──────────────────────────────────────────────────────────────
  Flickable {
    id: scroll
    anchors.fill: parent
    anchors.margins: Style.space(16)
    contentHeight: page.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    ColumnLayout {
      id: page
      width: scroll.width - Style.space(12)
      spacing: Style.space(14)

      // Title bar
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Label {
          text: "PITCHLOCK / SING TO UNLOCK"
          font.pixelSize: Style.font.heading
          font.bold: true
          font.letterSpacing: 1
          Layout.fillWidth: true
        }
        Chip { text: "▶ Practice"; onClicked: { Quickshell.execDetached([panel.filePath("pitchlock")]); panel.closeRequested() } }
        Chip { text: "Preview lock"; onClicked: { Quickshell.execDetached(["omarchy-shell", "lock", "preview"]); panel.closeRequested() } }
      }
      Hint { text: "Changes apply to the lock right away." }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(14)

        // ════ left column: voice, unlock ════
        ColumnLayout {
          Layout.fillWidth: true
          Layout.preferredWidth: 1
          Layout.alignment: Qt.AlignTop
          spacing: Style.space(14)

          Card {
            Section { text: "VOICE" }
            Flow {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Repeater {
                model: panel.s.presets
                Chip {
                  required property var modelData
                  visible: modelData.value !== "custom" || panel.s.voice === "custom"
                  text: modelData.value === "all" ? "All" : modelData.label
                  selected: panel.s.voice === modelData.value
                  onClicked: panel.s.applyPreset(modelData.value)
                }
              }
            }
            NoteStepper {
              label: "Lowest note"
              value: panel.s.pocketLow
              onStepped: d => panel.s.setPocket(panel.s.pocketLow + d, panel.s.pocketHigh)
            }
            NoteStepper {
              label: "Highest note"
              value: panel.s.pocketHigh
              onStepped: d => panel.s.setPocket(panel.s.pocketLow, panel.s.pocketHigh + d)
            }
            Hint {
              text: "Every note stays between " + panel.noteName(panel.s.pocketLow) + " and " + panel.noteName(panel.s.pocketHigh)
                + ", sung in that octave. Pick where your voice is strongest, not your full range."
            }
          }

          Card {
            highlighted: wizard.step !== 0
            RowLayout {
              Layout.fillWidth: true
              Section { text: "MEASURE MY VOICE" }
              Chip {
                visible: wizard.step !== 0
                text: "Cancel"
                small: true
                onClicked: { recordTimer.stop(); wizard.step = 0; wizard.message = "" }
              }
            }
            Hint {
              text: wizard.step === 0 ? "Sing your lowest and highest comfortable notes; the chords go in the middle of your range."
                : wizard.step === 1 ? "Sing your LOWEST comfortable note and hold it…  " + Math.ceil(wizard.secsLeft) + " s"
                : wizard.step === 2 ? "Lowest: " + panel.noteName(wizard.low) + ". Now your HIGHEST comfortable note."
                : wizard.step === 3 ? "Sing your HIGHEST comfortable note and hold it…  " + Math.ceil(wizard.secsLeft) + " s"
                : "Your range: " + panel.noteName(wizard.low) + " – " + panel.noteName(wizard.high)
                  + ".  Chords will use " + panel.noteName(wizard.pocket[0]) + " – " + panel.noteName(wizard.pocket[1]) + "."
            }
            Hint { visible: wizard.message.length > 0; text: wizard.message; color: Color.urgent }
            Label {
              visible: wizard.step === 1 || wizard.step === 3
              text: panel.micHeard ? "hearing " + panel.noteName(panel.micMidi) : "listening…"
              color: panel.micHeard ? panel.accent : panel.dim
            }
            RowLayout {
              Chip {
                visible: wizard.step === 0 || wizard.step === 2
                text: wizard.step === 0 ? "● Start: lowest note" : "● Record highest note"
                onClicked: wizard.start(wizard.step === 0 ? 1 : 3)
              }
              Chip {
                visible: wizard.step === 4
                readonly property bool ok: wizard.pocket[1] - wizard.pocket[0] >= panel.s.minPocketSpan
                enabled: ok
                selected: ok
                text: ok ? "Use this range" : "Range too small — try again"
                onClicked: { panel.s.setPocket(wizard.pocket[0], wizard.pocket[1]); wizard.step = 0 }
              }
              Chip { visible: wizard.step === 4; text: "Again"; onClicked: wizard.step = 0 }
            }
          }

          Card {
            Section { text: "UNLOCK" }
            FieldLabel { title: "What unlocks it" }
            Flow {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Repeater {
                model: [{ value: "fun", label: "Singing, password or word" }, { value: "singing", label: "Singing only" },
                        { value: "passnotes", label: "Pass-notes (secure)" }]
                Chip {
                  required property var modelData
                  text: modelData.label
                  selected: panel.s.unlockMode === modelData.value
                  onClicked: panel.s.unlockMode = modelData.value
                }
              }
            }
            Hint {
              text: panel.s.unlockMode === "singing"
                ? "Only singing the chord unlocks: no password, bypass word or fingerprint. If the microphone stops working, the password comes back. A sore throat or a loud room won't — you'd be locked out until you can sing it. And anyone who can sing the chord gets in."
                : panel.s.unlockMode === "passnotes"
                ? "Sing your four memorised pass-notes (exact notes, in order), or type your pass-code — no Enter needed, and anything typed before it is ignored. The lock never plays or shows the notes; a wrong note is simply ignored and a right one fills a dot — which also means someone could find them by trying notes one at a time. Your account password + Enter always works too."
                : "Sing the chord, or type your password (or the bypass word, if you set one)."
            }

            // Pass-notes setup
            ColumnLayout {
              visible: panel.s.unlockMode === "passnotes"
              Layout.fillWidth: true
              spacing: Style.space(8)
              RowLayout {
                Layout.fillWidth: true
                Label { text: "Pass-notes"; font.bold: true; Layout.fillWidth: true }
                Label { text: panel.s.passNotesSet ? "set ✓" : "not set"; color: panel.s.passNotesSet ? panel.accent : Color.urgent; font.bold: true }
              }
              Hint { text: "Pick four exact notes you can sing. Listen, learn them, then save. After saving they're stored scrambled and can't be shown or played again — memorise them." }
              Repeater {
                model: 4
                NoteStepper {
                  required property int index
                  label: "Note " + (index + 1)
                  value: panel.pickNotes[index]
                  playable: true
                  onStepped: d => { const n = panel.pickNotes.slice(); n[index] = Math.max(28, Math.min(84, n[index] + d)); panel.pickNotes = n; panel.playMidis([n[index]]) }
                  onPlay: panel.playMidis([panel.pickNotes[index]])
                }
              }
              RowLayout {
                Layout.fillWidth: true
                Chip { text: "▶ Play all four"; onClicked: panel.playMidis(panel.pickNotes) }
                Item { Layout.fillWidth: true }
                Chip {
                  text: panel.s.passNotesSet ? "Replace pass-notes" : "Save pass-notes"
                  selected: true
                  onClicked: { panel.s.setPassNotes(panel.pickNotes); passNotesSaved.visible = true }
                }
              }
              Hint { id: passNotesSaved; visible: false; text: "Saved. Sing them on the lock exactly like this, in this order." }
              RowLayout {
                Layout.fillWidth: true
                Label { text: "Pass-notes difficulty"; Layout.fillWidth: true }
                Repeater {
                  model: [{ value: "normal", label: "Normal" }, { value: "hard", label: "Hard" }]
                  Chip {
                    required property var modelData
                    small: true
                    text: modelData.label
                    selected: (panel.s.passNotesDifficulty || "normal") === modelData.value
                    onClicked: panel.s.passNotesDifficulty = modelData.value
                  }
                }
              }
              Hint { text: (panel.s.passNotesDifficulty === "hard" ? "Hard: within ±15¢, held 0.75 s each." : "Normal: within ±26.9¢, held 0.5 s each.") + " Pass-notes only use Normal or Hard; the challenge settings don't change them." }

              PanelSeparator { Layout.fillWidth: true; foreground: panel.fg }

              RowLayout {
                Layout.fillWidth: true
                Label { text: "Pass-code (typed)"; font.bold: true; Layout.fillWidth: true }
                Label { text: panel.s.passCodeSet ? "set ✓" : "none"; color: panel.s.passCodeSet ? panel.accent : panel.dim; font.bold: true }
              }
              Hint { text: "Typed anywhere on the lock, no Enter: it unlocks the moment the last letters you typed are your pass-code. Not your account password — pick something separate, at least 4 characters." }
              TextField { id: codeField; Layout.fillWidth: true; password: true; echoMode: TextInput.Password; placeholderText: "new pass-code" }
              TextField { id: codeConfirm; Layout.fillWidth: true; password: true; echoMode: TextInput.Password; placeholderText: "type it again" }
              RowLayout {
                Layout.fillWidth: true
                Text {
                  id: codeMsg
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap
                  color: Color.urgent
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Chip { visible: panel.s.passCodeSet; small: true; text: "Remove"; onClicked: { panel.s.setPassCode(""); codeMsg.text = "" } }
                Chip {
                  text: panel.s.passCodeSet ? "Replace pass-code" : "Save pass-code"
                  selected: true
                  onClicked: {
                    if (codeField.text.length < 4) { codeMsg.color = Color.urgent; codeMsg.text = "At least 4 characters."; return }
                    if (codeField.text !== codeConfirm.text) { codeMsg.color = Color.urgent; codeMsg.text = "The two don't match."; return }
                    panel.s.setPassCode(codeField.text)
                    codeField.text = ""; codeConfirm.text = ""
                    codeMsg.color = panel.accent; codeMsg.text = "Saved."
                  }
                }
              }
            }

            // Bypass word (fun mode only)
            FieldLabel {
              visible: panel.s.unlockMode === "fun"
              title: "Bypass word"
              hint: "typing it anywhere on the lock unlocks it; leave blank to turn it off"
            }
            TextField {
              visible: panel.s.unlockMode === "fun"
              Layout.fillWidth: true
              password: true
              echoMode: TextInput.Password
              placeholderText: "none — only singing or your password"
              text: panel.s.bypassWord
              onEditingFinished: panel.s.bypassWord = text.trim().toLowerCase()
            }
            SettingToggle {
              label: "Show time and accuracy on unlock"
              checked: panel.s.showStats
              onClicked: panel.s.showStats = !panel.s.showStats
            }
            Row {
              Knob {
                title: "Unlock screen"
                valueText: panel.s.unlockPauseSeconds.toFixed(1) + " s"
                from: 0.5; to: 6; step: 0.5
                value: panel.s.unlockPauseSeconds
                onChanged: v => panel.s.unlockPauseSeconds = v
              }
            }
          }
        }

        // ════ right column: challenge, sound, microphone, scores ════
        ColumnLayout {
          Layout.fillWidth: true
          Layout.preferredWidth: 1
          Layout.alignment: Qt.AlignTop
          spacing: Style.space(14)

          Card {
            Section { text: "CHALLENGE" }
            Flow {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Repeater {
                model: panel.s.difficulties
                Chip {
                  required property var modelData
                  visible: modelData.value !== "custom" || panel.s.difficulty === "custom"
                  text: modelData.label
                  selected: panel.s.difficulty === modelData.value
                  onClicked: panel.s.applyDifficulty(modelData.value)
                }
              }
            }
            Row {
              spacing: Style.space(4)
              Knob {
                title: "Accuracy"
                valueText: "±" + panel.s.tolerance.toFixed(0) + "¢"
                from: 10; to: 50; step: 0.5
                value: panel.s.tolerance
                onChanged: v => panel.s.setTuning("tolerance", v)
              }
              Knob {
                title: "Hold"
                valueText: panel.s.holdSeconds.toFixed(2) + " s"
                from: 0.2; to: 1.5; step: 0.05
                value: panel.s.holdSeconds
                onChanged: v => panel.s.setTuning("holdSeconds", v)
              }
              Knob {
                title: "Colour chords"
                valueText: Math.round(panel.s.colourChordChance * 100) + "%"
                from: 0; to: 1; step: 0.05
                value: panel.s.colourChordChance
                onChanged: v => panel.s.setTuning("colourChordChance", v)
              }
            }
            Hint { text: "Accuracy: how close to the note counts (100¢ = a semitone). Hold: how long each note must stay in tune. Colour chords: how often diminished, augmented and sus4 chords come up. Drag a dial up or down." }
            FieldLabel { title: "Chord types" }
            Flow {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Repeater {
                model: panel.s.chordTypes
                Chip {
                  required property var modelData
                  text: modelData.label
                  selected: panel.s.chordTypeOn(modelData.value)
                  onClicked: panel.s.setChordType(modelData.value, !panel.s.chordTypeOn(modelData.value))
                }
              }
            }
            Hint { text: "Every chord has four notes (a 7th chord), voiced in whichever inversion fits your range." }
            SettingToggle {
              label: "Random note order"
              description: "Sing the chord's notes in a shuffled order instead of always root first."
              checked: panel.s.randomOrder
              onClicked: panel.s.randomOrder = !panel.s.randomOrder
            }
          }

          Card {
            Section { text: "SOUND" }
            Hint { text: "Space always plays the note to sing. Nothing else plays unless switched on here." }
            SettingToggle {
              label: "Play the first note when a chord appears"
              description: "Including the moment the screen locks — turn off for quiet places."
              checked: panel.s.playFirstNote
              onClicked: panel.s.playFirstNote = !panel.s.playFirstNote
            }
            SettingToggle {
              label: "Play the next note after a match"
              checked: panel.s.playNextNote
              onClicked: panel.s.playNextNote = !panel.s.playNextNote
            }
            SettingToggle {
              label: "Pause music while locked"
              description: "Any player that's playing (Spotify, a browser, Matrix Rain's music) pauses when the lock appears and carries on when you unlock."
              checked: panel.s.pauseMusic
              onClicked: panel.s.pauseMusic = !panel.s.pauseMusic
            }
            SettingToggle {
              label: "Play the chord on unlock"
              checked: panel.s.unlockChord
              onClicked: panel.s.unlockChord = !panel.s.unlockChord
            }
            Row {
              Knob {
                title: "Volume"
                valueText: Math.round(panel.s.toneVolume * 100) + "%"
                from: 0.1; to: 1.5; step: 0.05
                value: panel.s.toneVolume
                onChanged: v => panel.s.toneVolume = v
              }
            }
          }

          Card {
            Section { text: "MICROPHONE" }
            SettingToggle {
              label: "Test microphone"
              description: "Sing a note: it should show up below. If it doesn't, lower noise rejection."
              checked: panel.micTestOn
              onClicked: panel.micTestOn = !panel.micTestOn
            }
            RowLayout {
              visible: panel.micTestOn
              Layout.fillWidth: true
              spacing: Style.space(10)
              Rectangle {
                Layout.fillWidth: true
                implicitHeight: Style.space(8)
                radius: height / 2
                color: panel.tint(0.12)
                Rectangle {
                  width: parent.width * panel.micLevel
                  height: parent.height
                  radius: parent.radius
                  color: panel.micHeard ? panel.accent : panel.dim
                }
              }
              Label {
                Layout.preferredWidth: Style.space(160)
                horizontalAlignment: Text.AlignRight
                text: panel.micHeard
                  ? panel.noteName(panel.micMidi) + "  " + (440 * Math.pow(2, (panel.micMidi - 69) / 12)).toFixed(1) + " Hz"
                  : "not hearing a note"
                color: panel.micHeard ? panel.accent : panel.dim
              }
            }
            Row {
              spacing: Style.space(4)
              Knob {
                title: "Noise rejection"
                valueText: panel.s.micSensitivity.toFixed(1) + "×"
                from: 1.5; to: 8; step: 0.5
                value: panel.s.micSensitivity
                onChanged: v => panel.s.micSensitivity = v
              }
              Knob {
                title: "Mic sleeps"
                valueText: Math.round(panel.s.micSleepSeconds) + " s"
                from: 15; to: 300; step: 5
                value: panel.s.micSleepSeconds
                onChanged: v => panel.s.micSleepSeconds = v
              }
            }
            Hint { text: "Noise rejection: how much louder than the room your voice must be — lower hears quiet voices, higher ignores more noise (turn the mic test off and on to try a new value). Mic sleeps: after this long without sound on the lock." }
          }

          Card {
            Section { text: "SCORES" }
            Hint { text: "Typical unlock time for each voice type and difficulty (your last 10 there, leaving out unusually slow ones), with the best underneath. Yours right now is outlined." }
            GridLayout {
              id: scoreGrid
              Layout.fillWidth: true
              columns: panel.s.difficulties.length + 1
              columnSpacing: Style.space(4)
              rowSpacing: Style.space(4)
              readonly property var cells: {
                const out = [{ kind: "corner" }]
                for (const d of panel.s.difficulties) out.push({ kind: "head", text: d.label === "Perfect pitch" ? "Perfect" : d.label })
                for (const v of panel.s.presets) {
                  out.push({ kind: "voice", text: v.value === "mezzo" ? "Mezzo" : v.value === "all" ? "All" : v.label })
                  for (const d of panel.s.difficulties) {
                    const list = Stats.forCombo(pitchState.unlocks, d.value, v.value)
                    const t = Stats.typical(list.slice(-10))
                    out.push({ kind: "score", count: list.length, typical: t.secs, best: Stats.best(list),
                               current: panel.s.voice === v.value && panel.s.difficulty === d.value })
                  }
                }
                return out
              }
              Repeater {
                model: scoreGrid.cells
                Rectangle {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: modelData.kind === "voice" || modelData.kind === "corner" ? Style.space(70) : Style.space(56)
                  implicitHeight: modelData.kind === "score" ? Style.space(34) : Style.space(20)
                  radius: 4
                  color: modelData.kind !== "score" ? "transparent"
                    : modelData.count ? Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.16) : panel.tint(0.04)
                  border.width: modelData.kind === "score" && modelData.current ? 2 : 0
                  border.color: panel.accent
                  Column {
                    anchors.centerIn: parent
                    Label {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: modelData.kind === "score" ? (modelData.count ? modelData.typical.toFixed(1) + " s" : "·") : (modelData.text || "")
                      color: modelData.kind === "head" || modelData.kind === "voice" ? panel.dim : panel.fg
                      font.pixelSize: Style.font.caption
                      font.bold: modelData.kind !== "voice"
                    }
                    Label {
                      anchors.horizontalCenter: parent.horizontalCenter
                      visible: modelData.kind === "score" && modelData.count > 0
                      text: visible ? "best " + modelData.best.toFixed(1) : ""
                      color: panel.dim
                      font.pixelSize: Math.round(Style.font.caption * 0.85)
                    }
                  }
                }
              }
            }
            Hint {
              readonly property int untagged: (pitchState.unlocks || []).filter(u => !u.difficulty).length
              visible: untagged > 0
              text: untagged + " earlier unlock" + (untagged > 1 ? "s were" : " was") + " recorded before scores were split by difficulty and voice, so " + (untagged > 1 ? "they aren't" : "it isn't") + " shown here."
            }
            RowLayout {
              Layout.fillWidth: true
              Chip {
                small: true
                text: "Reset scores"
                enabled: (pitchState.unlocks || []).length > 0
                onClicked: pitchState.unlocks = []
              }
              Item { Layout.fillWidth: true }
              Chip {
                small: true
                text: "Restore defaults"
                onClicked: panel.s.resetToDefaults()
              }
            }
          }
        }
      }
    }
  }
}
