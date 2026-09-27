import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "pitchstats.js" as Stats

// Pitchlock settings. Every control writes straight to ~/.config/pitchlock/settings.json,
// which the lock watches and applies live. The panel never talks to the lock service
// itself: Omarchy keeps authentication services unreachable from other plugin code.
Rectangle {
  id: panel

  property QtObject bar: null
  signal closeRequested()

  PitchSettings { id: localSettings }
  readonly property var s: localSettings
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
  readonly property var noteNames: ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
  function noteName(m) { const r = Math.round(m); return noteNames[((r % 12) + 12) % 12] + (Math.floor(r / 12) - 1) }
  function filePath(name) { return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")) }

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

  color: Color.popups.background
  implicitWidth: Style.space(560)
  implicitHeight: Style.space(760)

  // ── building blocks ──────────────────────────────────────────────────────
  component Label: Text {
    color: panel.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
  component Hint: Text {
    color: panel.dim
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
  }
  component Section: PanelSectionHeader {
    foreground: panel.fg
    Layout.fillWidth: true
    Layout.topMargin: Style.space(10)
  }
  component SettingSlider: ColumnLayout {
    id: ss
    property string label
    property string valueText
    property real value
    property real from
    property real to
    property real step: 0.01
    signal changed(real value)
    Layout.fillWidth: true
    spacing: Style.space(4)
    RowLayout {
      Layout.fillWidth: true
      Label { text: ss.label; Layout.fillWidth: true }
      Label { text: ss.valueText; color: Color.accent }
    }
    PanelSlider {
      Layout.fillWidth: true
      implicitHeight: Style.space(22)
      bar: panel.bar
      minimum: ss.from
      maximum: ss.to
      step: ss.step
      value: ss.value
      // snap to the step so settings.json holds 0.5, not 0.5039…
      function snap(v) { return Number((Math.round(v / ss.step) * ss.step).toFixed(3)) }
      onMoved: v => ss.changed(snap(v))
      onReleased: v => ss.changed(snap(v))
    }
  }
  component NoteStepper: RowLayout {
    id: ns
    property string label
    property int value
    signal stepped(int delta)
    Layout.fillWidth: true
    Label { text: ns.label; Layout.fillWidth: true }
    Button { text: "−"; bordered: true; foreground: panel.fg; onClicked: ns.stepped(-1) }
    Label {
      text: panel.noteName(ns.value)
      color: Color.accent
      horizontalAlignment: Text.AlignHCenter
      Layout.preferredWidth: Style.space(52)
    }
    Button { text: "+"; bordered: true; foreground: panel.fg; onClicked: ns.stepped(1) }
  }
  component SettingToggle: Toggle {
    Layout.fillWidth: true
    foreground: panel.fg
  }

  // ── content ──────────────────────────────────────────────────────────────
  Flickable {
    id: scroll
    anchors.fill: parent
    anchors.margins: Style.space(16)
    contentHeight: col.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    ColumnLayout {
      id: col
      width: scroll.width - Style.space(12)
      spacing: Style.space(8)

      RowLayout {
        Layout.fillWidth: true
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 2
          Text {
            text: "Pitchlock"
            color: panel.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Hint { text: "Sing the chord to unlock. Changes apply to the lock right away." }
        }
        Button {
          text: "Practice"
          bordered: true
          foreground: panel.fg
          tooltipText: "Open a practice window with these settings (nothing is locked)"
          onClicked: { Quickshell.execDetached([panel.filePath("pitchlock")]); panel.closeRequested() }
        }
        Button {
          text: "Preview"
          bordered: true
          foreground: panel.fg
          tooltipText: "Show the lock screen without locking (type the bypass word or right-click to close)"
          onClicked: { Quickshell.execDetached(["omarchy-shell", "lock", "preview"]); panel.closeRequested() }
        }
      }

      // ── Voice ──
      Section { text: "VOICE" }
      Dropdown {
        Layout.fillWidth: true
        label: "Voice type"
        value: panel.s.voice
        options: panel.s.presets
        onChanged: v => panel.s.applyPreset(v)
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
        text: "Every note of every chord stays between " + panel.noteName(panel.s.pocketLow) + " and "
          + panel.noteName(panel.s.pocketHigh) + ", sung in that octave. Pick where your voice is strongest, not your full range."
      }

      // Measure my voice
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: wizCol.implicitHeight + Style.space(20)
        radius: Style.cornerRadius
        color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.05)
        border.color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.15)

        ColumnLayout {
          id: wizCol
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(10) }
          spacing: Style.space(6)

          RowLayout {
            Layout.fillWidth: true
            Label { text: "Measure my voice"; font.bold: true; Layout.fillWidth: true }
            Button {
              visible: wizard.step !== 0
              text: "Cancel"
              foreground: panel.fg
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
          Text {
            visible: wizard.message.length > 0
            text: wizard.message
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }
          Label {
            visible: wizard.step === 1 || wizard.step === 3
            text: panel.micHeard ? "hearing " + panel.noteName(panel.micMidi) : "listening…"
            color: panel.micHeard ? Color.accent : panel.dim
          }
          RowLayout {
            Button {
              visible: wizard.step === 0 || wizard.step === 2
              text: wizard.step === 0 ? "Start: lowest note" : "Record highest note"
              bordered: true
              foreground: panel.fg
              onClicked: wizard.start(wizard.step === 0 ? 1 : 3)
            }
            Button {
              visible: wizard.step === 4
              readonly property bool ok: wizard.pocket[1] - wizard.pocket[0] >= panel.s.minPocketSpan
              text: ok ? "Use this range" : "Range too small — try again"
              enabled: ok
              bordered: true
              foreground: panel.fg
              onClicked: { panel.s.setPocket(wizard.pocket[0], wizard.pocket[1]); wizard.step = 0 }
            }
            Button {
              visible: wizard.step === 4
              text: "Again"
              foreground: panel.fg
              onClicked: wizard.step = 0
            }
          }
        }
      }

      // ── Challenge ──
      Section { text: "CHALLENGE" }
      Label { text: "Difficulty" }
      Flow {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Repeater {
          model: panel.s.difficulties
          Button {
            required property var modelData
            visible: modelData.value !== "custom" || panel.s.difficulty === "custom"
            text: modelData.label
            bordered: true
            selected: panel.s.difficulty === modelData.value
            foreground: panel.fg
            onClicked: panel.s.applyDifficulty(modelData.value)
          }
        }
      }
      SettingSlider {
        label: "Pitch accuracy"
        valueText: "±" + panel.s.tolerance.toFixed(1) + "¢"
        from: 10; to: 50; step: 0.5
        value: panel.s.tolerance
        onChanged: v => panel.s.setTuning("tolerance", v)
      }
      Hint { text: "How close to the note counts as in tune. 100¢ is a semitone; smaller is stricter." }
      SettingSlider {
        label: "Hold each note"
        valueText: panel.s.holdSeconds.toFixed(2) + " s"
        from: 0.2; to: 1.5; step: 0.05
        value: panel.s.holdSeconds
        onChanged: v => panel.s.setTuning("holdSeconds", v)
      }
      Label { text: "Chord types" }
      Flow {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Repeater {
          model: panel.s.chordTypes
          Button {
            required property var modelData
            text: modelData.label
            bordered: true
            selected: panel.s.chordTypeOn(modelData.value)
            foreground: panel.fg
            onClicked: panel.s.setChordType(modelData.value, !panel.s.chordTypeOn(modelData.value))
          }
        }
      }
      SettingSlider {
        label: "How often diminished / augmented / sus4"
        valueText: Math.round(panel.s.colourChordChance * 100) + "%"
        from: 0; to: 1; step: 0.05
        value: panel.s.colourChordChance
        onChanged: v => panel.s.setTuning("colourChordChance", v)
      }
      Hint { text: "Every chord has four notes (a 7th chord), voiced in whichever inversion fits your range." }
      SettingToggle {
        label: "Random note order"
        description: "Sing the chord's notes in a shuffled order instead of always root first."
        checked: panel.s.randomOrder
        onClicked: panel.s.randomOrder = !panel.s.randomOrder
      }

      // ── Sound ──
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
        label: "Play the chord on unlock"
        checked: panel.s.unlockChord
        onClicked: panel.s.unlockChord = !panel.s.unlockChord
      }
      SettingSlider {
        label: "Tone volume"
        valueText: Math.round(panel.s.toneVolume * 100) + "%"
        from: 0.1; to: 1.5; step: 0.05
        value: panel.s.toneVolume
        onChanged: v => panel.s.toneVolume = v
      }

      // ── Microphone ──
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
          color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.12)
          Rectangle {
            width: parent.width * panel.micLevel
            height: parent.height
            radius: parent.radius
            color: panel.micHeard ? Color.accent : panel.dim
          }
        }
        Label {
          Layout.preferredWidth: Style.space(160)
          horizontalAlignment: Text.AlignRight
          text: panel.micHeard
            ? panel.noteName(panel.micMidi) + "  " + (440 * Math.pow(2, (panel.micMidi - 69) / 12)).toFixed(1) + " Hz"
            : "not hearing a note"
          color: panel.micHeard ? Color.accent : panel.dim
        }
      }
      SettingSlider {
        label: "Noise rejection"
        valueText: panel.s.micSensitivity.toFixed(1) + "×"
        from: 1.5; to: 8; step: 0.5
        value: panel.s.micSensitivity
        onChanged: v => panel.s.micSensitivity = v
      }
      Hint { text: "How much louder than the room your voice must be. Lower hears quiet voices; higher ignores more noise. Turn the mic test off and on to try a new value." }
      SettingSlider {
        label: "Mic sleeps after"
        valueText: Math.round(panel.s.micSleepSeconds) + " s"
        from: 15; to: 300; step: 5
        value: panel.s.micSleepSeconds
        onChanged: v => panel.s.micSleepSeconds = v
      }

      // ── Unlock ──
      Section { text: "UNLOCK" }
      Label { text: "Bypass word" }
      TextField {
        Layout.fillWidth: true
        password: true
        echoMode: TextInput.Password
        placeholderText: "none — only singing or your password"
        text: panel.s.bypassWord
        onEditingFinished: panel.s.bypassWord = text.trim().toLowerCase()
      }
      Hint { text: "Typing this anywhere on the lock screen unlocks it. Leave blank to turn it off. Your password always works." }
      SettingToggle {
        label: "Show time and accuracy on unlock"
        checked: panel.s.showStats
        onClicked: panel.s.showStats = !panel.s.showStats
      }
      SettingSlider {
        label: "Unlock screen stays for"
        valueText: panel.s.unlockPauseSeconds.toFixed(1) + " s"
        from: 0.5; to: 6; step: 0.5
        value: panel.s.unlockPauseSeconds
        onChanged: v => panel.s.unlockPauseSeconds = v
      }

      // ── Scores: one per voice type and difficulty ──
      Section { text: "SCORES" }
      Hint { text: "Typical unlock time for each voice type and difficulty (your last 10 there, leaving out unusually slow ones), with the best underneath. Yours right now is highlighted." }
      GridLayout {
        id: scoreGrid
        Layout.fillWidth: true
        columns: panel.s.difficulties.length + 1
        columnSpacing: Style.space(4)
        rowSpacing: Style.space(4)
        readonly property var voices: panel.s.presets
        readonly property var diffs: panel.s.difficulties
        readonly property var cells: {
          const out = [{ kind: "corner" }]
          for (const d of diffs) out.push({ kind: "head", text: d.label === "Perfect pitch" ? "Perfect" : d.label })
          for (const v of voices) {
            out.push({ kind: "voice", text: v.value === "mezzo" ? "Mezzo" : v.value === "all" ? "All" : v.label })
            for (const d of diffs) {
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
            Layout.preferredWidth: modelData.kind === "voice" || modelData.kind === "corner" ? Style.space(70) : Style.space(60)
            implicitHeight: modelData.kind === "score" ? Style.space(34) : Style.space(20)
            radius: Style.space(4)
            color: modelData.kind !== "score" ? "transparent"
              : modelData.current ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
              : Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, modelData.count ? 0.07 : 0.03)
            border.width: modelData.kind === "score" && modelData.current ? 1 : 0
            border.color: Color.accent
            Column {
              anchors.centerIn: parent
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.kind === "score" ? (modelData.count ? modelData.typical.toFixed(1) + " s" : "—") : (modelData.text || "")
                color: modelData.kind === "head" || modelData.kind === "voice" ? panel.dim : panel.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: modelData.kind === "score" && modelData.count > 0
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: modelData.kind === "score" && modelData.count > 0
                text: visible ? "best " + modelData.best.toFixed(1) : ""
                color: panel.dim
                font.family: Style.font.family
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
        Layout.topMargin: Style.space(12)
        Button {
          text: "Reset scores"
          bordered: true
          foreground: panel.fg
          enabled: (pitchState.unlocks || []).length > 0
          onClicked: pitchState.unlocks = []
        }
        Item { Layout.fillWidth: true }
        Button {
          text: "Restore defaults"
          bordered: true
          foreground: panel.fg
          tooltipText: "Back to the original bass tuning (keeps your bypass word)"
          onClicked: panel.s.resetToDefaults()
        }
      }
    }
  }
}
