import QtQuick

// ±100 cent meter; the shaded window is the pass tolerance.
Item {
  id: meter
  property var game
  readonly property real range: 100
  readonly property real clamped: Math.max(-range, Math.min(range, game.errCents))
  readonly property color needleColor: !game.voiced ? game.pal.dim
    : game.inTune ? game.pal.good
    : Math.abs(game.errCents) < 100 ? game.pal.warn : game.pal.bad

  Rectangle {
    id: track
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; verticalCenterOffset: -8 }
    height: 10; radius: 5
    color: meter.game.pal.grid

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * meter.game.tolerance / meter.range
      x: (parent.width - width) / 2
      height: parent.height; radius: 5
      color: Qt.rgba(meter.game.pal.good.r, meter.game.pal.good.g, meter.game.pal.good.b, 0.25)
    }
    Rectangle { width: 2; height: 18; anchors.centerIn: parent; color: meter.game.pal.dim }

    Rectangle {
      width: 6; height: 26; radius: 3
      anchors.verticalCenter: parent.verticalCenter
      x: (meter.clamped / meter.range + 1) / 2 * track.width - width / 2
      color: meter.needleColor
      opacity: meter.game.voiced ? 1 : 0.3
      Behavior on x { NumberAnimation { duration: 70 } }
    }
  }

  Text { anchors { left: parent.left; top: track.bottom; topMargin: 10 } text: "♭ flat"; color: meter.game.pal.dim; font { family: meter.game.pal.font; pixelSize: 11 } }
  Text { anchors { right: parent.right; top: track.bottom; topMargin: 10 } text: "sharp ♯"; color: meter.game.pal.dim; font { family: meter.game.pal.font; pixelSize: 11 } }
  Text {
    anchors { horizontalCenter: parent.horizontalCenter; top: track.bottom; topMargin: 8 }
    text: meter.game.voiced ? (meter.game.errCents >= 0 ? "+" : "") + Math.round(meter.game.errCents) + " ¢" : "—"
    color: meter.needleColor
    font { family: meter.game.pal.font; pixelSize: 14; weight: Font.Bold }
  }
}
