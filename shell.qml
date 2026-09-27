import QtQuick
import Quickshell

// Practice window: the same game and settings as the lock, in a normal window.
// Launched by ./pitchlock (or the settings panel's Practice button).
ShellRoot {
  FloatingWindow {
    title: "pitchlock practice"
    implicitWidth: 1220
    implicitHeight: 780
    color: "#070a12"

    PitchGame {
      anchors.fill: parent
      settings: PitchSettings {}
      onQuitRequested: Qt.quit()
    }
  }
}
