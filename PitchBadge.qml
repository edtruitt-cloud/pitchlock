import QtQuick

Rectangle {
  property alias text: label.text
  property bool on: false
  property bool alert: false
  property PitchTheme pal

  implicitWidth: label.implicitWidth + 20
  implicitHeight: 24
  radius: 12
  color: "transparent"
  border.width: 1
  border.color: alert ? pal.bad : on ? pal.good : pal.grid

  Text {
    id: label
    anchors.centerIn: parent
    color: parent.alert ? pal.bad : parent.on ? pal.good : pal.dim
    font { family: pal.font; pixelSize: 11; letterSpacing: 1 }
  }
}
