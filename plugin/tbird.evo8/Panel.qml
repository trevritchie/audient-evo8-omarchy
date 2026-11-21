import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "tbird.evo8"
  ipcTarget: "tbird.evo8"
  manageIpc: false

  ShellIpc {
    target: root.ipcTarget

    function open(): void { if (root.connected) root.open() }
    function close(): void { root.close() }
    function show(): void { if (root.connected) root.open() }
    function hide(): void { root.close() }
    function toggle(): void { if (root.connected) root.toggle() }
    function refresh(): void { root.refresh() }
  }

  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property bool evoNodePresent: {
    for (var i = 0; i < pwNodes.length; i++) {
      var n = pwNodes[i]
      if (n && n.name && (n.name.indexOf("EVO8") !== -1 || n.name.indexOf("evo8_") === 0)) return true
    }
    return false
  }

  onEvoNodePresentChanged: {
    if (!evoNodePresent) {
      root.connected = false
      if (root.opened) root.close()
    }
    root.refresh()
  }

  visible: root.connected
  implicitWidth: root.connected ? button.implicitWidth : 0
  implicitHeight: root.connected ? button.implicitHeight : 0

  onConnectedChanged: {
    if (!connected && opened) root.close()
  }

  property string evoBin: Quickshell.env("HOME") + "/.local/bin/evo8-audio"
  property bool connected: false
  property int rate: 48000
  property int forceRate: 0
  property int quantum: 1024
  property int forceQuantum: 0
  property real latencyMs: 21.3
  property real out1Vol: -32.5
  property bool out1Mute: false
  property real out2Vol: -32.5
  property bool out2Mute: false
  property bool loopbackOn: true
  property string loopbackSource: "main"
  property string loopbackSourceLabel: "Main Output 1+2 (Headphones)"
  property int loopbackLevel: 100
  property var inputs: [
    { index: 1, gain: -8.0, mute: false, phantom: false, monitor_on: false, monitor_db: 0.0 },
    { index: 2, gain: -8.0, mute: false, phantom: false, monitor_on: false, monitor_db: 0.0 },
    { index: 3, gain: -8.0, mute: false, phantom: false, monitor_on: false, monitor_db: 0.0 },
    { index: 4, gain: -8.0, mute: false, phantom: false, monitor_on: false, monitor_db: 0.0 }
  ]

  readonly property var loopbackOptions: [
    { label: "Main 1+2", value: "main" },
    { label: "Out 3+4", value: "out3_4" },
    { label: "Send 1+2", value: "send5_6" },
    { label: "HW Mix", value: "hwmix" },
    { label: "Off", value: "off" }
  ]

  readonly property var bufferOptions: [
    { label: "64", value: "64" },
    { label: "128", value: "128" },
    { label: "256", value: "256" },
    { label: "512", value: "512" },
    { label: "Auto", value: "auto" }
  ]

  readonly property var rateOptions: [
    { label: "44.1k", value: 44100 },
    { label: "48k", value: 48000 },
    { label: "88.2k", value: 88200 },
    { label: "96k", value: 96000 }
  ]

  readonly property bool anyMonitorOn: {
    for (var i = 0; i < inputs.length; i++) {
      if (inputs[i] && inputs[i].monitor_on) return true
    }
    return false
  }

  readonly property string heroStatusText: {
    if (!connected) return "DISCONNECTED"
    var khz = (rate / 1000).toFixed(rate % 1000 === 0 ? 0 : 1) + " KHZ"
    var bufMode = forceQuantum > 0 ? (quantum + " SPL") : ("AUTO " + quantum)
    return khz + " · " + bufMode + " (" + latencyMs.toFixed(1) + " MS)"
  }

  function inputLabel(idx) {
    if (idx === 1) return "IN 1 · Guitar / Mic 1"
    return "IN " + idx + " · Mic / Line " + idx
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function parseStatus(raw) {
    if (!raw || !raw.trim()) return
    try {
      var data = JSON.parse(raw)
      root.connected = !!data.connected
      if (!root.connected) {
        if (root.opened) root.close()
        return
      }
      root.rate = data.rate || 48000
      root.forceRate = data.force_rate || 0
      root.quantum = data.quantum || 1024
      root.forceQuantum = data.force_quantum || 0
      root.latencyMs = data.latency_ms || 0.0
      if (data.output1) {
        root.out1Vol = data.output1.volume
        root.out1Mute = !!data.output1.mute
      }
      if (data.output2) {
        root.out2Vol = data.output2.volume
        root.out2Mute = !!data.output2.mute
      }
      root.loopbackOn = !!data.loopback_on
      if (data.loopback_source) root.loopbackSource = data.loopback_source
      if (data.loopback_source_label) root.loopbackSourceLabel = data.loopback_source_label
      if (data.loopback_level !== undefined) root.loopbackLevel = data.loopback_level
      if (data.inputs && data.inputs.length === 4) {
        root.inputs = data.inputs
      }
    } catch (e) {
      // Ignore transient parse errors
    }
  }

  property var pendingCmd: null

  function runCmd(args) {
    var cmd = [root.evoBin].concat(args)
    if (actionProc.running) {
      root.pendingCmd = cmd
      return
    }
    actionProc.command = cmd
    actionProc.running = true
  }

  function launchTui() {
    var cmd = "/usr/share/omarchy/bin/omarchy-launch-or-focus-tui --app-id=org.omarchy.evotui " + Quickshell.env("HOME") + "/.local/bin/evotui"
    if (root.bar) {
      root.bar.run(cmd)
    } else {
      root.close()
      Quickshell.execDetached([root.evoBin, "tui"])
    }
  }

  onOpenedChanged: {
    if (opened) refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: [root.evoBin, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }
  }

  Process {
    id: actionProc
    onExited: {
      if (root.pendingCmd !== null) {
        var nextCmd = root.pendingCmd
        root.pendingCmd = null
        actionProc.command = nextCmd
        actionProc.running = true
      } else {
        root.refresh()
      }
    }
  }

  Process {
    id: tuiProc
  }

  Timer {
    interval: 2500
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.connected ? 15000 : 2500
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    visible: root.connected
    text: root.anyMonitorOn ? "󰤽" : "󰤽"
    opacity: root.connected ? 1.0 : 0.45
    tooltipText: root.connected
      ? ("Audient EVO 8 · " + root.heroStatusText + (root.anyMonitorOn ? " · Direct Monitor ON" : ""))
      : "Audient EVO 8 (Disconnected)"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.launchTui()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

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
          spacing: Style.space(12)

          // ---------- Hero Header ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, tuiBtn.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰤽"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: tuiBtn.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Audient EVO 8"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.heroStatusText
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.1
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Button {
              id: tuiBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Mixer TUI"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(5)
              bordered: true
              onClicked: root.launchTui()
            }
          }

          // ---------- Buffer Size & Sample Rate ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "BUFFER SIZE (PIPEWIRE QUANTUM)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Row {
              id: bufRow
              width: parent.width
              spacing: Style.space(5)
              readonly property real cellWidth: (width - spacing * (root.bufferOptions.length - 1)) / root.bufferOptions.length

              Repeater {
                model: root.bufferOptions
                Button {
                  required property var modelData
                  width: bufRow.cellWidth
                  text: modelData.label
                  fontSize: Style.font.bodySmall
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(5)
                  bordered: true
                  active: modelData.value === "auto"
                    ? root.forceQuantum === 0
                    : (root.forceQuantum > 0 && String(root.quantum) === modelData.value)
                  onClicked: root.runCmd(["buffer", modelData.value, "--quiet"])
                }
              }
            }

            PanelSectionHeader {
              text: "SAMPLE RATE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Row {
              id: rateRow
              width: parent.width
              spacing: Style.space(5)
              readonly property real cellWidth: (width - spacing * (root.rateOptions.length - 1)) / root.rateOptions.length

              Repeater {
                model: root.rateOptions
                Button {
                  required property var modelData
                  width: rateRow.cellWidth
                  text: modelData.label
                  fontSize: Style.font.bodySmall
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(5)
                  bordered: true
                  active: root.rate === modelData.value
                  onClicked: root.runCmd(["rate", String(modelData.value), "--quiet"])
                }
              }
            }
          }

          // ---------- Zero-Latency Direct Monitoring ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: monHeader.implicitHeight

              PanelSectionHeader {
                id: monHeader
                text: "DIRECT MONITOR (ZERO LATENCY)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
              }

              Text {
                text: "HW DSP -> OUT 1+2"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Repeater {
              model: root.inputs
              Column {
                required property var modelData
                width: panelColumn.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(monLabel.implicitHeight, monToggle.implicitHeight)

                  Text {
                    id: monLabel
                    text: root.inputLabel(modelData.index)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: modelData.monitor_on
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: modelData.monitor_on
                      ? ((modelData.monitor_db >= 0 ? "+" : "") + modelData.monitor_db.toFixed(1) + " dB")
                      : "DAW Mode"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.right: monToggle.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  ToggleSwitch {
                    id: monToggle
                    checked: !!modelData.monitor_on
                    foreground: root.bar.foreground
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.runCmd(["monitor", String(modelData.index), "toggle", "--quiet"])
                  }
                }

                PanelSlider {
                  visible: !!modelData.monitor_on
                  bar: root.bar
                  width: parent.width
                  minimum: -40
                  maximum: 6
                  step: 1
                  value: modelData.monitor_db
                  onMoved: function(v) {
                    root.runCmd(["monitor", String(modelData.index), "on", "--db", String(Math.round(v)), "--quiet"])
                  }
                }
              }
            }
          }

          // ---------- Preamp Gain & 48V Phantom ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "MIC / INSTRUMENT PREAMPS (-8 TO +50 DB)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.inputs
              Column {
                required property var modelData
                width: panelColumn.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(gainLabel.implicitHeight, phBtn.implicitHeight)

                  Text {
                    id: gainLabel
                    text: "IN " + modelData.index + " Gain: " + (modelData.gain >= 0 ? "+" : "") + modelData.gain.toFixed(0) + " dB"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    opacity: modelData.mute ? 0.5 : 1.0
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)

                    Button {
                      id: phBtn
                      text: "48V"
                      fontSize: Style.font.caption
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      bordered: true
                      active: !!modelData.phantom
                      onClicked: root.runCmd(["phantom", String(modelData.index), "toggle", "--quiet"])
                    }

                    Button {
                      text: modelData.mute ? "Muted" : "Mute"
                      fontSize: Style.font.caption
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      bordered: true
                      active: !!modelData.mute
                      onClicked: root.runCmd(["mute", "input" + modelData.index, "toggle", "--quiet"])
                    }
                  }
                }

                PanelSlider {
                  bar: root.bar
                  width: parent.width
                  minimum: -8
                  maximum: 50
                  step: 1
                  value: modelData.gain
                  opacity: modelData.mute ? 0.5 : 1.0
                  onMoved: function(v) {
                    root.runCmd(["gain", String(modelData.index), String(Math.round(v)), "--quiet"])
                  }
                }
              }
            }
          }

          // ---------- Hardware Outputs & Loopback ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "HARDWARE OUTPUTS & LOOPBACK"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            // OUT 1|2
            Column {
              width: parent.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: out1Text.implicitHeight

                Text {
                  id: out1Text
                  text: "OUT 1+2 (Main / HP 1): " + root.out1Vol.toFixed(1) + " dB"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  opacity: root.out1Mute ? 0.5 : 1.0
                  anchors.left: parent.left
                }

                Button {
                  text: root.out1Mute ? "Muted" : "Mute"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  bordered: true
                  active: root.out1Mute
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.runCmd(["mute", "output1", "toggle", "--quiet"])
                }
              }

              PanelSlider {
                bar: root.bar
                width: parent.width
                minimum: -60
                maximum: 0
                step: 1
                value: Math.max(-60, root.out1Vol)
                opacity: root.out1Mute ? 0.5 : 1.0
                onMoved: function(v) {
                  root.runCmd(["volume", "1", String(Math.round(v)), "--quiet"])
                }
              }
            }

            // OUT 3|4
            Column {
              width: parent.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: out2Text.implicitHeight

                Text {
                  id: out2Text
                  text: "OUT 3+4 (Line / HP 2): " + root.out2Vol.toFixed(1) + " dB"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  opacity: root.out2Mute ? 0.5 : 1.0
                  anchors.left: parent.left
                }

                Button {
                  text: root.out2Mute ? "Muted" : "Mute"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  bordered: true
                  active: root.out2Mute
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.runCmd(["mute", "output2", "toggle", "--quiet"])
                }
              }

              PanelSlider {
                bar: root.bar
                width: parent.width
                minimum: -60
                maximum: 0
                step: 1
                value: Math.max(-60, root.out2Vol)
                opacity: root.out2Mute ? 0.5 : 1.0
                onMoved: function(v) {
                  root.runCmd(["volume", "2", String(Math.round(v)), "--quiet"])
                }
              }
            }

            // Loopback Source Selector & Capture Level
            PanelSeparator { foreground: root.bar.foreground }

            Item {
              width: parent.width
              implicitHeight: loopHeader.implicitHeight

              PanelSectionHeader {
                id: loopHeader
                text: "LOOPBACK RECORDING SOURCE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
              }

              Text {
                text: "Input: EVO 8 Loopback 1+2"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: loopRow
              width: parent.width
              spacing: Style.space(4)
              readonly property real cellWidth: (width - spacing * (root.loopbackOptions.length - 1)) / root.loopbackOptions.length

              Repeater {
                model: root.loopbackOptions
                Button {
                  required property var modelData
                  width: loopRow.cellWidth
                  text: modelData.label
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(2)
                  verticalPadding: Style.space(5)
                  bordered: true
                  active: root.loopbackSource === modelData.value
                  onClicked: root.runCmd(["loopback", modelData.value, "--quiet"])
                }
              }
            }

            Column {
              visible: root.loopbackOn
              width: parent.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: loopLvlText.implicitHeight

                Text {
                  id: loopLvlText
                  text: "Source: " + root.loopbackSourceLabel
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.left: parent.left
                }

                Text {
                  text: "Level: " + root.loopbackLevel + "%"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                }
              }

              PanelSlider {
                bar: root.bar
                width: parent.width
                minimum: 0
                maximum: 150
                step: 5
                value: root.loopbackLevel
                onMoved: function(v) {
                  root.runCmd(["loopback", "level", "--level", String(Math.round(v)), "--quiet"])
                }
              }
            }
          }
        }
      }
    }
  }
}
