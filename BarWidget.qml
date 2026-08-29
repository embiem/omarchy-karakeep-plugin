import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// Bookmark button for the Karakeep quick-add panel. The bar-widget root keeps
// the open/close/opened contract Bar.findPanelWidget looks for, while the
// nested panel owns the controller and state.
BarWidget {
  id: root
  moduleName: "embiem.karakeep"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  // Read back off the owner by KeyboardPanel during a popout switch.
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "embiem.karakeep"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uDB80\uDCC0"
    tooltipText: "Save to Karakeep"
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (b === Qt.RightButton) {
        var url = String(root.setting("karakeepServerUrl", "")).trim()
        if (url !== "") Quickshell.execDetached(["omarchy-launch-browser", url])
      }
    }
  }
}
