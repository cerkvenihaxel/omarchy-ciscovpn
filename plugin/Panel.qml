pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Cisco VPN — Omarchy bar widget.
//
// bin/ciscovpn (bash) does the work: `status` reports connection state from the
// openconnect pid/state files, `config`/`set-server` manage the gateway, and
// `connect`/`disconnect` drive openconnect (SAML SSO via the system browser,
// e.g. CyberArk). This panel polls `status`, shows a shield glyph in the bar
// coloured by state, and offers connect/disconnect + gateway config in a popout.
Panel {
  id: root
  moduleName: "custom.ciscovpn"
  ipcTarget: "custom.ciscovpn"
  manageIpc: false

  readonly property string cli: Quickshell.env("HOME") + "/.config/omarchy/plugins/custom.ciscovpn/bin/ciscovpn"

  // ---- data from the backend ----
  property string vpnState: "disconnected"   // disconnected | connecting | connected | error
  property string server: ""
  property string iface: ""
  property string ip: ""
  property bool configured: false
  property bool sudoRuleOk: true
  property bool menuOpen: false
  property string message: ""
  property bool messageIsError: false

  // ---- ui state ----
  property string serverDraft: ""

  readonly property int refreshIntervalSec: Math.max(3, parseInt(String(setting("refreshIntervalSec", 10)), 10) || 10)
  readonly property bool connected: vpnState === "connected"
  readonly property bool connecting: vpnState === "connecting"

  // Shield glyphs (Nerd Font): shield-check when up, shield-off when down,
  // shield-half while connecting.
  readonly property string glyphConnected: "󰞀"      // nf-md-shield_check
  readonly property string glyphDisconnected: "󰦝"   // nf-md-shield_outline
  readonly property string glyphConnecting: "󰦞"     // nf-md-shield_half_full
  readonly property string glyphError: "󰚌"          // nf-md-shield_alert / off

  readonly property string barGlyph: connected ? glyphConnected
    : connecting ? glyphConnecting
    : vpnState === "error" ? glyphError
    : glyphDisconnected

  // Explicit green for the connected state (icon + "Connected" legend), rather
  // than the theme accent which may not be green.
  readonly property color connectedGreen: "#3fb950"

  readonly property color stateColor: connected ? connectedGreen
    : connecting ? Color.foreground
    : vpnState === "error" ? Color.urgent
    : root.bar ? root.bar.foreground : Color.foreground

  readonly property string stateLabel: connected ? "Connected"
    : connecting ? "Connecting…"
    : vpnState === "error" ? "Error"
    : "Disconnected"

  readonly property string tooltip: {
    if (!configured) return "Cisco VPN — no gateway set"
    if (connected) return "Cisco VPN — connected" + (server ? " (" + server + ")" : "") + (ip ? " · " + ip : "") + "\nRight-click to disconnect"
    if (connecting) return "Cisco VPN — connecting to " + server + "…\nRight-click to cancel"
    if (vpnState === "error") return "Cisco VPN — connection error"
    return "Cisco VPN — disconnected (" + server + ")\nRight-click to connect"
  }

  // ---- backend calls ----
  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }
  function loadConfig() {
    if (!configProc.running) configProc.running = true
  }
  function connectVpn() {
    if (!root.configured) { root.message = "Set a gateway first"; root.messageIsError = true; return }
    root.message = "Opening browser for SSO…"
    root.messageIsError = false
    root.vpnState = "connecting"
    connectProc.running = true
  }
  function disconnectVpn() {
    root.message = "Disconnecting…"
    root.messageIsError = false
    disconnectProc.running = true
  }
  function saveServer() {
    var host = root.serverDraft.trim()
    if (host === "") { root.message = "Gateway is empty"; root.messageIsError = true; return }
    setServerProc.command = [root.cli, "set-server", host]
    setServerProc.running = true
  }
  function runInstaller() {
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.ciscovpn-install",
      "bash", "-lc", "bash '" + Quickshell.env("HOME")
        + "/.config/omarchy/plugins/custom.ciscovpn/install.sh'; echo; read -rp 'Press Enter to close'"])
  }
  function checkSudoRule() {
    if (!sudoRuleProc.running) sudoRuleProc.running = true
  }

  Process {
    id: sudoRuleProc
    command: [root.cli, "sudo-rule-ok"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.sudoRuleOk = !!JSON.parse(text).ok } catch (e) { root.sudoRuleOk = false }
      }
    }
  }

  Process {
    id: statusProc
    command: [root.cli, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          root.vpnState = d.state || "disconnected"
          root.server = d.server || ""
          root.iface = d.interface || ""
          root.ip = d.ip || ""
          root.configured = !!d.configured
        } catch (e) {}
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: configProc
    command: [root.cli, "config"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          root.server = d.server || root.server
          if (root.serverDraft === "") root.serverDraft = d.server || ""
          root.configured = (d.server || "") !== ""
        } catch (e) {}
      }
    }
  }

  Process {
    id: connectProc
    command: [root.cli, "connect"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.ok === false) { root.message = "Connect failed: " + (d.error || ""); root.messageIsError = true; root.vpnState = "error" }
          else root.message = "Follow the browser to sign in with SSO."
        } catch (e) {}
        root.refresh()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: disconnectProc
    command: [root.cli, "disconnect"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.ok === false) { root.message = d.error || "Disconnect failed"; root.messageIsError = true }
          else { root.message = "Disconnected"; root.messageIsError = false }
        } catch (e) { root.message = "Disconnected"; root.messageIsError = false }
        root.refresh()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: setServerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.ok) { root.message = "Gateway saved: " + d.server; root.messageIsError = false; root.server = d.server; root.configured = true }
          else { root.message = "Could not save: " + (d.error || ""); root.messageIsError = true }
        } catch (e) {}
        root.refresh()
      }
    }
  }

  // Poll more often while connecting / panel open, slower at rest.
  Timer {
    interval: (root.opened || root.connecting) ? 2000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: { root.loadConfig(); root.refresh(); root.checkSudoRule() }

  onOpenedChanged: {
    if (opened) { root.message = ""; root.loadConfig(); root.refresh(); root.checkSudoRule() }
  }

  IpcHandler {
    target: "custom.ciscovpn"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function connect() { root.connectVpn() }
    function disconnect() { root.disconnectVpn() }
    function refresh() { root.refresh() }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------- bar widget ----------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    tooltipText: root.tooltip
    useActiveColor: false
    foreground: root.stateColor
    opacity: root.connected ? 1.0 : (root.connecting ? 0.85 : 0.6)
    // gentle pulse while connecting
    SequentialAnimation on opacity {
      running: root.connecting
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 650; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 0.9; duration: 650; easing.type: Easing.InOutQuad }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        // right-click: show a context menu with VPN actions
        root.menuOpen = !root.menuOpen
      } else {
        root.menuOpen = false
        root.toggle()
      }
    }
  }

  // ---------------- right-click context menu ----------------
  PopupCard {
    id: ctxMenu
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.menuOpen
    triggerMode: "click"
    contentWidth: ctxMenu.fittedContentWidth(Style.space(220))
    contentHeight: ctxMenu.fittedContentHeight(menuCol.implicitHeight)

    Column {
      id: menuCol
      width: parent.width
      spacing: Style.space(2)

      // Connect
      Rectangle {
        width: parent.width
        implicitHeight: Style.space(32)
        radius: Style.cornerRadius
        visible: !root.connected && !root.connecting
        enabled: root.configured
        opacity: root.configured ? 1.0 : 0.4
        color: connectMa.containsMouse && root.configured ? Util.alpha(root.bar.foreground, 0.12) : "transparent"
        Row {
          anchors.left: parent.left; anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(10)
          Text { text: "󰌘"; color: root.connectedGreen; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
          Text { text: "Connect"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: connectMa; anchors.fill: parent; hoverEnabled: true; cursorShape: root.configured ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: { if (root.configured) { root.menuOpen = false; root.connectVpn() } } }
      }

      // Disconnect / cancel
      Rectangle {
        width: parent.width
        implicitHeight: Style.space(32)
        radius: Style.cornerRadius
        visible: root.connected || root.connecting
        color: discMa.containsMouse ? Util.alpha(Color.urgent, 0.12) : "transparent"
        Row {
          anchors.left: parent.left; anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(10)
          Text { text: "󰌙"; color: Color.urgent; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
          Text { text: root.connecting ? "Cancel connecting" : "Disconnect"; color: Color.urgent; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: discMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: { root.menuOpen = false; root.disconnectVpn() } }
      }

      PanelSeparator { foreground: root.bar.foreground }

      // Open panel
      Rectangle {
        width: parent.width
        implicitHeight: Style.space(32)
        radius: Style.cornerRadius
        color: openMa.containsMouse ? Util.alpha(root.bar.foreground, 0.12) : "transparent"
        Row {
          anchors.left: parent.left; anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(10)
          Text { text: "󰇗"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
          Text { text: "Open panel"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: openMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: { root.menuOpen = false; root.open() } }
      }
    }
  }

  // ---------------- popup ----------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(380)
    contentHeight: Math.min(panelColumn.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

        // ---------- Hero ----------
        PanelHero {
          width: parent.width
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          title: "Cisco VPN"
          meta: root.configured ? (root.server + (root.ip ? "  ·  " + root.ip : "")) : "no gateway configured"
          iconComponent: Component {
            Text {
              text: root.barGlyph
              color: root.stateColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // Connection status legend — green when connected, matching the icon.
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: root.barGlyph
            color: root.stateColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            text: root.stateLabel
            color: root.stateColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        // Passwordless/no-window hint — only when the sudoers rule is missing.
        Rectangle {
          visible: !root.sudoRuleOk
          width: parent.width
          implicitHeight: pwlCol.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Util.alpha(Color.urgent, 0.10)
          border.color: Util.alpha(Color.urgent, 0.45)
          border.width: 1

          Column {
            id: pwlCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "Connect opens a terminal for your sudo password. Enable passwordless connect once to make it fully silent (no window, no prompt)."
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
            Button {
              text: "Enable passwordless connect"
              bordered: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.runInstaller()
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Connect / Disconnect ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: parent.width
            visible: !root.connected && !root.connecting
            text: root.configured ? "Connect with SSO" : "Set a gateway below first"
            iconText: "󰌘"
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.connectVpn()
          }

          Button {
            width: parent.width
            visible: root.connecting
            text: "Connecting… (cancel)"
            iconText: "󰅖"
            iconSpinning: true
            bordered: true
            foreground: Color.urgent
            fontFamily: root.bar.fontFamily
            onClicked: root.disconnectVpn()
          }

          Button {
            width: parent.width
            visible: root.connected
            text: "Disconnect"
            iconText: "󰌙"
            bordered: true
            foreground: Color.urgent
            fontFamily: root.bar.fontFamily
            onClicked: root.disconnectVpn()
          }

          // Live connection facts
          Row {
            visible: root.connected
            width: parent.width
            spacing: Style.space(10)
            Text {
              text: "Interface"
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: root.iface + (root.ip ? "  " + root.ip : "")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Gateway config ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "VPN GATEWAY"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: serverField
              width: parent.width - saveBtn.width - Style.space(8)
              foreground: root.bar.foreground
              placeholderText: "vpn.company.com"
              text: root.serverDraft
              onTextChanged: root.serverDraft = text
              onAccepted: root.saveServer()
            }

            Button {
              id: saveBtn
              text: "Save"
              bordered: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.saveServer()
            }
          }

          Text {
            width: parent.width
            text: "The hostname you'd type into Cisco Secure Client. SSO (CyberArk) opens in your browser on connect."
            color: root.bar.foreground
            opacity: 0.55
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }

        // ---------- Message ----------
        Text {
          visible: root.message !== ""
          width: parent.width
          text: root.message
          color: root.messageIsError ? Color.urgent : root.bar.foreground
          opacity: root.messageIsError ? 1.0 : 0.8
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
        }
      }
    }
  }
}
