import QtQuick
import QtQuick.Layouts
import Quickshell

// Practice window: the same game and settings as the lock, plus ear training.
// Launched by ./pitchlock (or the settings panel's Practice button).
ShellRoot {
  FloatingWindow {
    id: win
    title: "pitchlock practice"
    implicitWidth: 1220
    implicitHeight: 820
    color: theme.bg

    property int tab: 0                  // 0 sing, 1 ear training
    PitchSettings { id: sharedSettings }
    PitchTheme { id: theme }


    ColumnLayout {
      anchors.fill: parent
      spacing: 0

      // tab bar
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 46
        color: theme.panel
        Row {
          anchors { left: parent.left; leftMargin: 24; verticalCenter: parent.verticalCenter }
          spacing: 8
          Repeater {
            model: ["Sing", "Ear training"]
            Rectangle {
              required property string modelData
              required property int index
              width: tabText.implicitWidth + 28
              height: 30
              radius: 6
              color: win.tab === index ? theme.good : Qt.rgba(theme.text.r, theme.text.g, theme.text.b, 0.06)
              Text {
                id: tabText
                anchors.centerIn: parent
                text: modelData
                color: win.tab === index ? theme.bg : theme.text
                font { family: theme.font; pixelSize: 14; bold: true }
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.tab = index }
            }
          }
        }
        Text {
          anchors { right: parent.right; rightMargin: 24; verticalCenter: parent.verticalCenter }
          text: "tab  switch"
          color: theme.dim
          font { family: theme.font; pixelSize: 12 }
        }
      }

      StackLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: win.tab

        PitchGame {
          id: game
          settings: sharedSettings
          active: win.tab === 0          // the mic only runs on the Sing tab
          onQuitRequested: Qt.quit()
          onTabRequested: win.tab = 1
        }
        PitchEarTraining {
          id: earTab
          settings: sharedSettings
          pitchd: Quickshell.shellPath("pitchd")
          pal: theme
          Keys.onEscapePressed: Qt.quit()
          onTabRequested: win.tab = 0
        }
      }
    }

    onTabChanged: Qt.callLater(function() { (win.tab === 0 ? game : earTab).forceActiveFocus() })
  }
}
