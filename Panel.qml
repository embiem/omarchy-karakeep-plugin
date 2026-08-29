import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "embiem.karakeep"
  // BarWidget.qml owns the widget-level IPC shape the bar routes to.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily:
    bar ? bar.fontFamily : Style.font.family

  property string connectionState: "checking" // checking|disconnected|connected
  property string serverUrl: Model.DEFAULT_SERVER_URL
  property bool editingConnection: false
  readonly property bool showingSetup:
    connectionState !== "connected" || editingConnection
  // Derived: a helper that outlives the panel it started in still reports as
  // in flight, so a second run can never reuse a live Process.
  readonly property bool busy:
    statusProc.running || loginProc.running || addProc.running || clearProc.running
  property string errorText: ""
  property string savedId: ""
  property bool savedExisting: false
  readonly property string savedUrl: Model.previewUrl(serverUrl, savedId)

  property string statusText: ""

  // Live from the setup field, so the link appears as soon as the address is
  // a complete one.
  readonly property string setupApiKeysUrl: Model.apiKeysUrl(urlField ? urlField.text : "")

  // Every helper run is stamped with the session that asked for it. open() and
  // close() both end a session, and a reply from a dead session is dropped.
  property int session: 0

  function persistConnection(url, stored) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.karakeepCredentialStored = stored === true
    entry.karakeepServerUrl = String(url || Model.DEFAULT_SERVER_URL) || Model.DEFAULT_SERVER_URL

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Only decides whether a failed lookup is shown as a keyring problem. A valid
  // secret still wins and repairs the marker after shell.json drift.
  function credentialExpected() {
    return setting("karakeepCredentialStored", false) === true
  }

  function configuredServerUrl() {
    var value = String(setting("karakeepServerUrl", Model.DEFAULT_SERVER_URL) || "").trim()
    return value === "" ? Model.DEFAULT_SERVER_URL : value
  }

  function helperPath() {
    return decodeURIComponent(Qt.resolvedUrl("karakeep-api").toString().replace(/^file:\/\//, ""))
  }

  function open() {
    root.session++
    root.savedId = ""
    root.savedExisting = false
    root.errorText = ""
    root.statusText = ""
    root.serverUrl = configuredServerUrl()
    root.controller.show()
    // After showing, not before: showing hands over the popout coordinator,
    // and the close that comes with it clears this shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
    root.connectionState = "checking"
    // A lookup still in flight answers the same question, so adopt it.
    statusProc.session = root.session
    if (!statusProc.running) {
      statusProc.applied = false
      statusProc.command = [helperPath(), "status"]
      statusProc.running = true
    }
  }

  function close() {
    // Ends the session: a reply that lands after this is dropped.
    root.session++
    // Setup is a two-trip errand — address typed here, key minted in the
    // browser — so the typed address survives the trip. A stale one self-heals
    // from the stored secret on the next successful status.
    if (root.showingSetup && urlField) {
      var typed = String(urlField.text || "").trim()
      if (typed !== "" && typed !== configuredServerUrl())
        persistConnection(typed, credentialExpected())
    }
    setCenterHoverRevealSuppressed(false)
    root.editingConnection = false
    if (keyField) keyField.text = ""
    loginProc.secret = ""
    addProc.payload = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // A hotkey summon moves no pointer, so the reveal stays suppressed until this
  // popup closes rather than inheriting a stale hover.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function focusPrimaryField() {
    Qt.callLater(function() {
      if (root.showingSetup) {
        urlField.text = root.serverUrl || Model.DEFAULT_SERVER_URL
        keyField.text = ""
        urlField.selectAll()
        urlField.forceActiveFocus()
      } else {
        contentField.text = ""
        contentField.forceActiveFocus()
      }
    })
  }

  function applyStatus(raw) {
    var result = Model.parseResult(raw)
    root.statusText = ""

    if (result.ok && result.configured) {
      root.connectionState = "connected"
      root.serverUrl = result.serverUrl
      root.editingConnection = false
      root.errorText = ""
      if (!credentialExpected() || configuredServerUrl() !== root.serverUrl)
        persistConnection(root.serverUrl, true)
      focusPrimaryField()
      return
    }

    root.connectionState = "disconnected"
    root.serverUrl = configuredServerUrl()
    root.editingConnection = false
    root.errorText = credentialExpected()
      ? "Credential unavailable. Unlock Secret Service or reconnect."
      : ""
    focusPrimaryField()
  }

  function connectToServer() {
    if (root.busy) return

    var url = String(urlField.text || "").trim()
    var key = String(keyField.text || "").trim()
    if (url === "") {
      root.errorText = "Enter your Karakeep server address."
      root.statusText = ""
      return
    }
    if (key === "") {
      root.errorText = "Enter a valid Karakeep API key."
      root.statusText = ""
      return
    }

    var secret = JSON.stringify({ serverUrl: urlField.text, apiKey: key })
    keyField.text = ""
    loginProc.secret = ""
    root.errorText = ""
    root.statusText = ""
    root.savedId = ""
    root.savedExisting = false
    loginProc.applied = false
    loginProc.session = root.session
    loginProc.command = [helperPath(), "login"]
    loginProc.secret = secret
    loginProc.running = true
  }

  function applyLoginResult(raw) {
    var result = Model.parseResult(raw)

    if (!result.ok || !result.configured || result.serverUrl === "") {
      // A failed rotation keeps the working connection: the old secret is still
      // in place, and "disconnected" would strand Cancel.
      if (!root.editingConnection) root.connectionState = "disconnected"
      root.errorText = result.error || "Credential unavailable. Unlock Secret Service or reconnect."
      root.statusText = ""
      // Keep the address as typed: a rejected key should not cost the entry.
      Qt.callLater(function() { keyField.forceActiveFocus() })
      return
    }

    root.serverUrl = result.serverUrl
    root.connectionState = "connected"
    root.editingConnection = false
    root.errorText = ""
    root.statusText = ""
    persistConnection(root.serverUrl, true)
    focusPrimaryField()
  }

  function cancelConnectionEditor() {
    root.editingConnection = false
    root.errorText = ""
    root.statusText = ""
    keyField.text = ""
    loginProc.secret = ""
    focusPrimaryField()
  }

  function submit() {
    if (root.busy) return

    var payload = Model.bookmarkPayload(contentField.text)
    if (!payload) return

    addProc.payload = ""
    root.errorText = ""
    root.statusText = ""
    root.savedId = ""
    root.savedExisting = false
    addProc.applied = false
    addProc.session = root.session
    addProc.command = [helperPath(), "add"]
    addProc.payload = JSON.stringify(payload)
    addProc.running = true
  }

  function applyAddResult(raw) {
    var result = Model.parseResult(raw)
    root.statusText = ""

    if (!result.ok || result.id === "") {
      root.savedId = ""
      root.savedExisting = false
      root.errorText = result.error || "Karakeep returned an unreadable response."
      Qt.callLater(function() { contentField.forceActiveFocus() })
      return
    }

    root.errorText = ""
    contentField.text = ""
    root.savedId = result.id
    root.savedExisting = result.existing
    Qt.callLater(function() { contentField.forceActiveFocus() })
  }

  function applyClearResult(raw) {
    var result = Model.parseResult(raw)

    if (!result.ok || result.configured) {
      root.errorText = result.error || "Could not remove the API key. Unlock Secret Service and try again."
      return
    }

    root.connectionState = "disconnected"
    root.editingConnection = false
    root.errorText = ""
    root.statusText = "Forgot local credential — revoke the key in Karakeep Settings > API Keys."
    root.savedId = ""
    root.savedExisting = false
    keyField.text = ""
    loginProc.secret = ""
    persistConnection(root.serverUrl, false)
    focusPrimaryField()
  }

  function forgetConnection() {
    if (root.busy) return

    root.errorText = ""
    root.statusText = ""
    clearProc.applied = false
    clearProc.session = root.session
    clearProc.command = [helperPath(), "clear"]
    clearProc.running = true
  }

  function openSaved() {
    if (root.savedUrl === "") return
    Quickshell.execDetached(["omarchy-launch-browser", root.savedUrl])
    root.close()
  }

  function handleSetupKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.close()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.connectToServer()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  Process {
    id: statusProc
    property bool applied: false
    property int session: -1
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        statusProc.applied = true
        if (statusProc.session === root.session) root.applyStatus(text)
      }
    }
    // A run that produced no output still has to end the "checking" state.
    onExited: function(exitCode) {
      if (!applied && session === root.session) root.applyStatus("")
      applied = false
    }
  }

  // The secret is cleared off the Process before write() so a failed stdin
  // write cannot leave it referenced by a long-lived QML object.
  Process {
    id: loginProc
    property string secret: ""
    property bool applied: false
    property int session: -1
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        loginProc.applied = true
        if (loginProc.session === root.session) root.applyLoginResult(text)
      }
    }
    onStarted: {
      var value = secret
      secret = ""
      write(value + "\n")
    }
    onRunningChanged: if (!running) secret = ""
    onExited: function(exitCode) {
      secret = ""
      if (!applied && session === root.session) root.applyLoginResult("")
      applied = false
    }
  }

  // Same boundary as the login payload: never argv, never env.
  Process {
    id: addProc
    property string payload: ""
    property bool applied: false
    property int session: -1
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        addProc.applied = true
        if (addProc.session === root.session) root.applyAddResult(text)
      }
    }
    onStarted: {
      var value = payload
      payload = ""
      write(value + "\n")
    }
    onRunningChanged: if (!running) payload = ""
    onExited: function(exitCode) {
      payload = ""
      if (!applied && session === root.session) root.applyAddResult("")
      applied = false
    }
  }

  Process {
    id: clearProc
    property bool applied: false
    property int session: -1
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        clearProc.applied = true
        if (clearProc.session === root.session) root.applyClearResult(text)
      }
    }
    onExited: function(exitCode) {
      if (!applied && session === root.session) root.applyClearResult("")
      applied = false
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // PanelKeyCatcher gets keys before descendants, so a focused field must
      // block it or typing would be stolen by the panel hotkeys.
      blocked: urlField.activeFocus || keyField.activeFocus || contentField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.focusPrimaryField()

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Row {
          visible: root.connectionState === "checking"
          width: parent.width
          spacing: Style.space(10)

          Text {
            id: checkingSpinner
            anchors.verticalCenter: parent.verticalCenter
            text: "\uDB82\uDD96"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.icon

            RotationAnimator on rotation {
              from: 0
              to: 360
              duration: 800
              loops: Animation.Infinite
              running: checkingSpinner.visible
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Checking Karakeep connection…"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }

        Column {
          visible: root.showingSetup && root.connectionState !== "checking"
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "CONNECT TO KARAKEEP"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          TextField {
            id: urlField
            width: parent.width
            placeholderText: Model.DEFAULT_SERVER_URL
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            Keys.onPressed: function(event) { root.handleSetupKey(event, keyField) }
          }

          TextField {
            id: keyField
            width: parent.width
            placeholderText: "API key from Settings > API Keys"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            password: true
            Keys.onPressed: function(event) { root.handleSetupKey(event, urlField) }
          }

          Text {
            width: parent.width
            text: "Needs the users:read and bookmarks:readwrite scopes."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.setupApiKeysUrl !== ""
            text: "Create an API key"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.underline: true

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              // Stays open: the key has to come back into keyField.
              onClicked: Quickshell.execDetached(
                ["omarchy-launch-browser", root.setupApiKeysUrl])
            }
          }

          Button {
            width: parent.width
            text: root.busy ? "Checking…" : "Connect"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !root.busy
            onClicked: root.connectToServer()
          }

          Button {
            visible: root.editingConnection && root.credentialExpected()
            width: parent.width
            text: "Cancel"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !root.busy
            onClicked: root.cancelConnectionEditor()
          }

          Button {
            visible: root.editingConnection && root.credentialExpected()
            width: parent.width
            text: "Forget locally"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !root.busy
            onClicked: root.forgetConnection()
          }

          Text {
            visible: root.statusText !== ""
            width: parent.width
            text: root.statusText
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.contentForeground, 1.2)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Column {
          visible: !root.showingSetup
          width: parent.width
          spacing: Style.space(10)

          TextField {
            id: contentField
            width: parent.width
            placeholderText: "Paste a link or type a note"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submit()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                // keyCatcher is blocked here, so provide the panel-switch
                // binding it would otherwise handle.
                root.switchPanel(
                  (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
              }
            }
          }

          Row {
            visible: root.busy
            spacing: Style.space(10)

            Text {
              id: addSpinner
              anchors.verticalCenter: parent.verticalCenter
              text: "\uDB82\uDD96"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.icon

              RotationAnimator on rotation {
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
                running: addSpinner.visible
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Saving to Karakeep…"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
          }

          Row {
            visible: root.savedId !== ""
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uDB81\uDDE0"
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.icon
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.savedExisting ? "Already in Karakeep" : "Saved to Karakeep"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            visible: root.savedUrl !== ""
            text: "Open entry"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.underline: true

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSaved()
            }
          }

          Item {
            width: parent.width
            height: Math.max(serverFooter.implicitHeight, changeConnectionButton.implicitHeight)

            Text {
              id: serverFooter
              anchors.left: parent.left
              anchors.right: changeConnectionButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.serverUrl
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            PanelActionButton {
              id: changeConnectionButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uDB81\uDC93"
              tooltipText: "Change server or API key"
              foreground: root.contentForeground
              hoverColor: Color.accent
              fontFamily: root.contentFontFamily
              enabled: !root.busy
              onClicked: {
                root.editingConnection = true
                root.errorText = ""
                root.statusText = ""
                keyField.text = ""
                loginProc.secret = ""
                root.focusPrimaryField()
              }
            }
          }
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          text: "\uDB80\uDC28 " + root.errorText
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
