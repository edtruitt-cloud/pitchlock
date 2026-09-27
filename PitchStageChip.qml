import QtQuick
import QtQuick.Layouts

Rectangle {
  id: chip
  property var game
  property int idx

  // (guards: a chip can briefly outlive its chord while the next challenge swaps in)
  readonly property bool isDone: !!game.done[idx]
  readonly property bool active: game.tone === idx
  readonly property color tone: game.toneColors[idx] || game.pal.dim
  readonly property real progress: isDone ? 1 : active ? game.hold / game.holdNeeded : 0

  implicitHeight: 64
  radius: 14
  color: active ? Qt.rgba(tone.r, tone.g, tone.b, 0.12) : Qt.rgba(game.pal.panel.r, game.pal.panel.g, game.pal.panel.b, 0.86)
  border.width: active ? 2 : 1
  border.color: isDone || active ? tone : game.pal.grid
  Behavior on color { ColorAnimation { duration: 250 } }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: 18
    anchors.rightMargin: 18
    spacing: 14

    Rectangle {
      implicitWidth: 14; implicitHeight: 14; radius: 7
      color: chip.isDone ? chip.tone : "transparent"
      border { width: 2; color: chip.tone }
      opacity: chip.isDone || chip.active ? 1 : 0.4
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 2
      Text {
        text: chip.game.toneNames[chip.idx] || ""
        color: chip.isDone || chip.active ? chip.game.pal.text : chip.game.pal.dim
        Layout.fillWidth: true
        elide: Text.ElideRight
        font { family: chip.game.pal.font; pixelSize: 15; weight: Font.DemiBold }
      }
      Text {
        readonly property int note: chip.game.notes[chip.idx] !== undefined ? chip.game.notes[chip.idx] : chip.game.rootMidi
        text: chip.game.noteName(note)
        color: chip.game.pal.dim
        font { family: chip.game.pal.font; pixelSize: 12 }
      }
    }
  }

  // hold progress, as a strip along the bottom edge
  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12; bottomMargin: 8 }
    height: 4; radius: 2
    color: chip.game.pal.grid
    Rectangle {
      height: parent.height; radius: 2
      width: parent.width * chip.progress
      color: chip.tone
    }
  }
}
