import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "pitchstats.js" as Stats

// Ear training (practice window): it plays a chord or two notes, you name the chord type
// or the interval. Right answers, total and best streak are kept in their own state file
// (~/.local/state/pitchlock-ear.json) for the ear-training achievements.
Item {
  id: ear
  property QtObject settings: null
  property string pitchd: ""
  property PitchTheme pal: PitchTheme {}
  focus: true
  signal tabRequested()
  Keys.onTabPressed: e => { tabRequested(); e.accepted = true }

  readonly property int low: settings ? settings.pocketLow : 46
  readonly property int high: settings ? settings.pocketHigh : 58

  property string kind: "chords"        // "chords" | "intervals"
  property bool sevenths: false
  readonly property var chordAnswers: sevenths
    ? [{ label: "Major 7th", iv: [0, 4, 7, 11] }, { label: "Dominant 7th", iv: [0, 4, 7, 10] },
       { label: "Minor 7th", iv: [0, 3, 7, 10] }, { label: "Half-diminished", iv: [0, 3, 6, 10] },
       { label: "Diminished 7th", iv: [0, 3, 6, 9] }, { label: "7sus4", iv: [0, 5, 7, 10] }]
    : [{ label: "Major", iv: [0, 4, 7] }, { label: "Minor", iv: [0, 3, 7] }, { label: "Diminished", iv: [0, 3, 6] },
       { label: "Augmented", iv: [0, 4, 8] }, { label: "Sus4", iv: [0, 5, 7] }]
  readonly property var intervalAnswers: [
    { label: "Minor 2nd", iv: [0, 1] }, { label: "Major 2nd", iv: [0, 2] }, { label: "Minor 3rd", iv: [0, 3] },
    { label: "Major 3rd", iv: [0, 4] }, { label: "Perfect 4th", iv: [0, 5] }, { label: "Tritone", iv: [0, 6] },
    { label: "Perfect 5th", iv: [0, 7] }, { label: "Minor 6th", iv: [0, 8] }, { label: "Major 6th", iv: [0, 9] },
    { label: "Minor 7th", iv: [0, 10] }, { label: "Major 7th", iv: [0, 11] }, { label: "Octave", iv: [0, 12] }]
  readonly property var answers: kind === "chords" ? chordAnswers : intervalAnswers

  property int current: -1              // index into answers
  property var notes: []
  property int picked: -1               // the user's answer for this question (-1 = not yet)
  property string feedback: ""
  property var newAchievements: []

  function midiToHz(m) { return (440 * Math.pow(2, (m - 69) / 12)).toFixed(2) }
  function play() {
    if (!notes.length) return
    // each note in turn, then together
    Quickshell.execDetached([pitchd, "arp", "-t", (settings && settings.toneSound) || "organ", "0.5", kind === "chords" ? "1.4" : "1.0", "0.9"].concat(notes.map(midiToHz)))
  }
  function next() {
    current = Math.floor(Math.random() * answers.length)
    const iv = answers[current].iv
    const top = iv[iv.length - 1]
    const lo = low, hi = Math.max(low, high - top)
    const root = lo + Math.floor(Math.random() * (hi - lo + 1))
    notes = iv.map(x => root + x)
    picked = -1
    feedback = ""
    newAchievements = []
    play()
  }
  function answer(i) {
    if (current < 0 || picked >= 0) return
    picked = i
    const before = { right: stats.right, total: stats.total, bestStreak: stats.bestStreak }
    stats.total++
    if (i === current) {
      stats.right++
      stats.streak++
      stats.bestStreak = Math.max(stats.bestStreak, stats.streak)
      feedback = "Right — " + answers[current].label
    } else {
      stats.streak = 0
      feedback = "It was " + answers[current].label
    }
    const was = new Set(Stats.achievements([], before).filter(a => a.done).map(a => a.title))
    newAchievements = Stats.achievements([], { right: stats.right, total: stats.total, bestStreak: stats.bestStreak })
      .filter(a => a.done && !was.has(a.title)).map(a => a.title)
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/pitchlock-ear.json"
    printErrors: false
    onAdapterUpdated: writeAdapter()
    onLoadFailed: writeAdapter()
    JsonAdapter {
      id: stats
      property int right: 0
      property int total: 0
      property int streak: 0
      property int bestStreak: 0
    }
  }

  Keys.onPressed: e => {
    if (e.key === Qt.Key_Space) { current < 0 ? next() : play(); e.accepted = true }
    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { next(); e.accepted = true }
    else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) { answer(e.key - Qt.Key_1); e.accepted = true }
    else if (e.key === Qt.Key_0) { answer(9); e.accepted = true }
  }

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property string hintKey: ""
    property bool selected: false
    property color fill: pal.good
    signal clicked()
    implicitWidth: capt.implicitWidth + 28
    implicitHeight: 40
    radius: 8
    color: selected ? fill : Qt.rgba(pal.text.r, pal.text.g, pal.text.b, hit.containsMouse ? 0.14 : 0.06)
    border.color: selected ? fill : Qt.rgba(pal.text.r, pal.text.g, pal.text.b, 0.2)
    Text {
      id: capt
      anchors.centerIn: parent
      text: (chip.hintKey ? chip.hintKey + "  " : "") + chip.text
      color: chip.selected ? pal.bg : pal.text
      font { family: pal.font; pixelSize: 15; bold: true }
    }
    MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 40
    spacing: 22

    Text {
      text: "Ear training"
      color: pal.text
      font { family: pal.font; pixelSize: 34; weight: Font.Bold }
    }
    Text {
      Layout.fillWidth: true
      wrapMode: Text.WordWrap
      text: "Listen, then name it.  space  play (again)   1–9, 0  answer   enter  next"
      color: pal.dim
      font { family: pal.font; pixelSize: 14 }
    }

    RowLayout {
      spacing: 10
      Chip { text: "Chords"; selected: ear.kind === "chords"; onClicked: { ear.kind = "chords"; ear.current = -1; ear.forceActiveFocus() } }
      Chip { text: "Intervals"; selected: ear.kind === "intervals"; onClicked: { ear.kind = "intervals"; ear.current = -1; ear.forceActiveFocus() } }
      Item { width: 20 }
      Chip { visible: ear.kind === "chords"; text: "Triads"; selected: !ear.sevenths; onClicked: { ear.sevenths = false; ear.current = -1; ear.forceActiveFocus() } }
      Chip { visible: ear.kind === "chords"; text: "7th chords"; selected: ear.sevenths; onClicked: { ear.sevenths = true; ear.current = -1; ear.forceActiveFocus() } }
    }

    RowLayout {
      spacing: 14
      Chip {
        text: ear.current < 0 ? "▶  Start" : "▶  Play again"
        selected: true
        onClicked: { ear.current < 0 ? ear.next() : ear.play(); ear.forceActiveFocus() }
      }
      Chip { visible: ear.picked >= 0; text: "Next  ⏎"; onClicked: { ear.next(); ear.forceActiveFocus() } }
      Text {
        text: ear.feedback
        color: ear.picked === ear.current ? pal.good : pal.bad
        font { family: pal.font; pixelSize: 20; bold: true }
      }
    }

    Flow {
      Layout.fillWidth: true
      spacing: 10
      Repeater {
        model: ear.answers
        Chip {
          required property var modelData
          required property int index
          hintKey: index < 9 ? String(index + 1) : index === 9 ? "0" : ""
          text: modelData.label
          enabled: ear.current >= 0
          opacity: enabled ? 1 : 0.4
          selected: ear.picked >= 0 && (index === ear.current || index === ear.picked)
          fill: index === ear.current ? pal.good : pal.bad
          onClicked: { ear.answer(index); ear.forceActiveFocus() }
        }
      }
    }

    Text {
      visible: ear.newAchievements.length > 0
      text: "🏆  " + ear.newAchievements.join("  ·  ")
      color: pal.warn
      font { family: pal.font; pixelSize: 18; bold: true }
    }

    Item { Layout.fillHeight: true }

    Text {
      text: stats.total === 0 ? "No answers yet."
        : stats.right + " right of " + stats.total + " (" + Math.round(stats.right / stats.total * 100) + "%)  ·  streak " + stats.streak + "  ·  best streak " + stats.bestStreak
      color: pal.dim
      font { family: pal.font; pixelSize: 15 }
    }
  }
}
