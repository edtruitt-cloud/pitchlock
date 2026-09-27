import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for pitchlock: opens the settings panel, which edits the shared settings file.
BarWidget {
  id: root
  moduleName: "ertiv.lock"

  property bool opened: false
  function close() { opened = false }
  function toggle() { opened = !opened }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "♪"
    tooltipText: "Pitchlock settings"
    useActiveColor: false
    foreground: root.opened ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: kpanel.fittedContentWidth(Style.space(960))
    contentHeight: kpanel.fittedContentHeight(Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Loader {
        anchors.fill: parent
        active: root.opened
        source: "PitchSettingsPanel.qml"
        onLoaded: {
          item.bar = root.bar
          item.closeRequested.connect(root.close)
        }
      }
    }
  }
}
