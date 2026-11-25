import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// omabateq: headset battery in the bar, and a panel with the battery, the
// live Easy Effects equalizer (preset, response curve, bypass switch, output
// level, preset buttons) and, when there is one, the mouse battery.
//
// Where the data comes from:
//   headset        bin/read-headset (headsetcontrol) writes a shared file that
//                  every bar watches: once a minute, and right away when a USB
//                  device comes or goes (e.g. the charging cable; inotifywait),
//                  and when the receiver says the headset was switched on or
//                  off (bin/watch-headset)
//   mouse          bin/read-mouse (`solaar show`) into a shared file, when
//                  Solaar is installed and sees one; otherwise UPower
//   Easy Effects   bin/eq-state (its CLI), polled while the panel is open
//   EQ curve       the active preset's JSON file, watched for changes
//   live / meter   the PipeWire graph, through Quickshell
Panel {
  id: root
  moduleName: "lidoliver.omabateq"
  ipcTarget: "lidoliver.omabateq"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }


  // ================= State =================

  // Headset, from headsetcontrol.
  property var battery: Model.EMPTY_BATTERY
  // A reading that differs from `battery`, waiting for a second read to agree.
  property var pendingBattery: null
  property int confirmAttempts: 0
  readonly property bool present: battery.present
  readonly property bool hasLevel: battery.level >= 0
  readonly property bool charging: battery.status === "charging"
  readonly property bool headsetOff: battery.status === "off"

  // Mouse: from Solaar when it's installed and sees one, since it talks to the
  // mouse directly, on the receiver or on the cable. UPower is the fallback,
  // and doesn't help with the cable: the kernel then treats the mouse as a
  // plain wired one, and UPower keeps showing it as on battery for a few
  // seconds before dropping it. With neither, nothing shows.
  // `showMouse: false` in the widget's shell.json entry turns it off.
  readonly property bool showMouse: setting("showMouse", true) === true
  readonly property var mouseDevice: {
    var devices = UPower.devices ? UPower.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].type === UPowerDeviceType.Mouse && devices[i].isPresent) return devices[i]
    return null
  }
  readonly property var upowerMouse: Model.mouseBattery(mouseDevice, {
    charging: UPowerDeviceState.Charging,
    fullyCharged: UPowerDeviceState.FullyCharged,
    unknown: UPowerDeviceState.Unknown
  })
  property var solaarMouse: Model.EMPTY_MOUSE
  readonly property var mouse: !showMouse ? Model.EMPTY_MOUSE
    : (solaarMouse.present ? solaarMouse : upowerMouse)

  // Easy Effects, from bin/eq-state.
  property var eq: Model.EMPTY_EQ
  // Set while a bypass/preset command runs, so a poll that started before it
  // cannot overwrite the optimistic state with the old one.
  property bool eqBusy: false

  // Bands of the active preset, from its JSON file.
  property var preset: Model.EMPTY_PRESET
  readonly property var curvePoints: Model.response(preset.bands, 160)
  readonly property string presetFile: Model.isPresetName(eq.preset)
    ? Quickshell.env("HOME") + "/.local/share/easyeffects/output/" + eq.preset + ".json"
    : ""

  // Easy Effects removes its filter nodes from the graph when nothing plays,
  // so its equalizer node being there means audio is flowing through it.
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property bool eqLive: {
    if (!eq.running || eq.bypassed) return false
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && String(nodes[i].name) === "ee_soe_equalizer") return true
    return false
  }

  readonly property string eqStateScript: scriptPath("bin/eq-state")
  readonly property string readHeadsetScript: scriptPath("bin/read-headset")
  readonly property string readMouseScript: scriptPath("bin/read-mouse")
  readonly property string watchHeadsetScript: scriptPath("bin/watch-headset")

  function scriptPath(relative) {
    return String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, "")
  }


  // ================= Text =================

  readonly property string headsetGlyph: "󰋎"
  // The bar uses a waveform, not the headset: the audio widget right next
  // to it is already a pair of headphones.
  readonly property string barHeadsetGlyph: "󱑽"
  readonly property string mouseGlyph: "󰍽"
  readonly property string chargingGlyph: "󰂄"

  readonly property string percentText: hasLevel ? Commons.I18n.formatNumber(battery.level) + "%" : ""
  readonly property string mousePercentText: mouse.level >= 0 ? Commons.I18n.formatNumber(mouse.level) + "%" : ""

  // The bar shows the headset; while it is switched off or not around, the
  // mouse instead (if there is one).
  readonly property bool barShowsMouse: mouse.present && (!present || headsetOff)
  readonly property string barGlyph: barShowsMouse ? mouseGlyph : barHeadsetGlyph

  // Next to the bar icon: the level, or a charging glyph when there is none.
  readonly property string barLabel: {
    if (barShowsMouse) return mousePercentText
    if (!present || headsetOff) return ""
    if (hasLevel) return percentText
    return charging ? chargingGlyph : ""
  }

  readonly property string statusText: {
    if (charging && !hasLevel) return strings.t("status.chargingNoLevel")
    return strings.t("status." + battery.status)
  }

  readonly property string eqStatusText: {
    if (eq.bypassed) return strings.t("eq.bypassed")
    return eqLive ? strings.t("eq.live") : strings.t("eq.idle")
  }

  readonly property color dimForeground: Qt.darker(bar ? bar.foreground : Commons.Color.foreground, 1.4)


  // ================= Actions =================

  // Asks for a battery read. Every bar asks, so a bar takes a reading that
  // is younger than `maxAge` seconds instead of reading again; the result
  // reaches all bars through the shared file (headsetFile below).
  function refreshBattery(maxAge) {
    if (batteryProc.running) return
    batteryProc.command = ["sh", root.readHeadsetScript, String(maxAge || 0)]
    batteryProc.running = true
  }

  // A reading that would change what is shown waits for a second read to
  // agree, because headsetcontrol sometimes returns a bogus one (see
  // Model.confirmBattery). Every bar sees the same readings in the same
  // order, so they all come to the same answer.
  function takeBatteryReading(reading) {
    var next = Model.confirmBattery({ shown: battery, pending: pendingBattery, attempts: confirmAttempts }, reading)
    battery = next.shown
    pendingBattery = next.pending
    confirmAttempts = next.attempts
    if (next.recheck) confirmTimer.restart()
  }
  function refreshEq() { if (!eqProc.running) eqProc.running = true }

  // Same max-age idea as the headset.
  function refreshMouse(maxAge) {
    if (!showMouse || mouseProc.running) return
    mouseProc.command = ["sh", root.readMouseScript, String(maxAge || 0)]
    mouseProc.running = true
  }

  function setBypassed(bypassed) {
    runEqCommand(["easyeffects", "-b", bypassed ? "1" : "2"], { bypassed: bypassed })
  }

  function loadPreset(name) {
    if (!Model.isPresetName(name)) return
    runEqCommand(["easyeffects", "-l", name], { preset: name })
  }

  // Runs an Easy Effects command and shows its result right away.
  function runEqCommand(command, optimistic) {
    if (!eq.running || actionProc.running) return
    eqBusy = true
    eq = Object.assign({}, eq, optimistic)
    actionProc.command = command
    actionProc.running = true
  }

  function startEasyEffects() {
    Quickshell.execDetached(["easyeffects", "--service-mode", "--hide-window"])
    afterStart.restart()
  }


  // ================= Data sources =================

  // bin/read-headset and bin/read-mouse do the reading: one at a time across
  // bars, safe to kill, and into shared files (see the scripts).
  Process { id: batteryProc; onExited: root.headsetFileReady = true }
  Process { id: mouseProc; onExited: root.mouseFileReady = true }

  // A FileView only watches a file that exists when it starts: one pointed at
  // a missing file never hears about it being created. After a reboot the
  // files don't exist yet when the bars start (they live in XDG_RUNTIME_DIR),
  // so a bar that started too early showed no headset until the next shell
  // restart. The scripts create the files first, and a bar points its
  // FileViews at them only once one of its own scripts has run.
  property bool headsetFileReady: false
  property bool mouseFileReady: false
  readonly property string sharedDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omabateq"

  FileView {
    path: root.mouseFileReady ? root.sharedDir + "/solaar.txt" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.solaarMouse = Model.parseSolaarMouse(text())
    onLoadFailed: root.solaarMouse = Model.EMPTY_MOUSE
  }

  FileView {
    id: headsetFile
    path: root.headsetFileReady ? root.sharedDir + "/headset.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = text()
      if (raw.trim() !== "") root.takeBatteryReading(Model.parseBattery(raw))
    }
  }

  Process {
    id: eqProc
    command: ["sh", root.eqStateScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.eqBusy) root.eq = Model.parseEqState(text)
    }
  }

  Process {
    id: actionProc
    onExited: { root.eqBusy = false; root.refreshEq() }
  }

  FileView {
    path: root.presetFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.preset = Model.parsePreset(text())
    onLoadFailed: root.preset = Model.EMPTY_PRESET
  }
  onPresetFileChanged: if (presetFile === "") preset = Model.EMPTY_PRESET

  // Level of whatever reaches the output device, i.e. after the equalizer.
  PwObjectTracker { objects: [Pipewire.defaultAudioSink] }
  PwNodePeakMonitor {
    id: outputPeak
    node: Pipewire.defaultAudioSink
    enabled: root.opened && !!Pipewire.defaultAudioSink
  }

  // Battery: every minute, every 10 s while the panel is open.
  Timer { interval: root.opened ? 10000 : 60000; running: true; repeat: true; onTriggered: { root.refreshBattery(root.opened ? 5 : 20); root.refreshMouse(root.opened ? 5 : 20) } }
  // Easy Effects can change preset by itself (per-device autoload).
  Timer { interval: 3000; running: root.opened; repeat: true; onTriggered: root.refreshEq() }
  Timer { id: afterStart; interval: 1500; onTriggered: root.refreshEq() }
  Timer { id: confirmTimer; interval: 1000; onTriggered: root.refreshBattery(1) }

  // Plugging or unplugging a USB device (the headset's charging cable, its
  // receiver) re-reads the battery a moment later instead of at the next poll.
  // Every USB device has a node in /dev/bus/usb/<bus>/, so a file appearing or
  // disappearing there is a plug or unplug. (inotifywait writes each event
  // out as it happens; `udevadm monitor` held them back when not printing to
  // a terminal.)
  Process {
    id: usbEvents
    command: ["inotifywait", "-m", "-r", "-q", "-e", "create,delete", "/dev/bus/usb"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { usbSettle.restart() }
    }
    onExited: usbRestart.restart()
  }
  Timer { id: usbSettle; interval: 1500; onTriggered: { root.refreshBattery(1); root.refreshMouse(1); usbLate.restart(); root.startHeadsetWatch() } }
  // A mouse switching between cable and receiver can take a few seconds to
  // answer on its new connection, so it gets a second look.
  Timer { id: usbLate; interval: 5000; onTriggered: root.refreshMouse(1) }
  Timer { id: usbRestart; interval: 5000; onTriggered: usbEvents.running = true }

  // Switching the headset on or off plugs nothing in, so the USB watch above
  // doesn't see it. bin/watch-headset listens to the receiver instead, which
  // announces it, and reads the battery right away. One bar gets to run it
  // (the others' copies exit at once); it ends when the receiver is unplugged
  // and starts again after the next USB event, or within a minute.
  Process { id: headsetWatch; command: ["sh", root.watchHeadsetScript] }
  function startHeadsetWatch() { if (!headsetWatch.running) headsetWatch.running = true }
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.startHeadsetWatch() }

  Component.onCompleted: { refreshBattery(20); refreshMouse(20); startHeadsetWatch() }
  onOpenedChanged: if (opened) { refreshBattery(2); refreshMouse(2); refreshEq() }


  // ================= Bar button =================

  // Hidden while there is neither a supported headset nor a mouse battery.
  readonly property bool anything: present || mouse.present
  visible: anything
  implicitWidth: anything ? button.implicitWidth : 0
  implicitHeight: anything ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    labelText: vertical ? "" : root.barLabel
    slotSize: Style.bar.iconSlot * (labelText !== "" ? 2 : 1)
    opacity: !root.barShowsMouse && root.headsetOff ? 0.45 : 1
    tooltipText: ""
    onPressed: root.toggle()
  }


  // ================= Panel =================

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.anything
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onActivateRequested: root.setBypassed(!root.eq.bypassed)   // Enter toggles the EQ
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Headset: icon · name / status · percentage ----------
        Column {
          visible: root.present
          width: parent.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight, heroPercent.implicitHeight)

            Label {
              id: heroIcon
              text: root.headsetGlyph
              font.pixelSize: Style.font.display
              opacity: root.headsetOff ? 0.45 : 1
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroText
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroPercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Label {
                width: parent.width
                text: root.battery.name || strings.t("title")
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Caption {
                width: parent.width
                text: root.statusText
                elide: Text.ElideRight
              }
            }

            Label {
              id: heroPercent
              text: root.percentText || "—"
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Without a level (charging on the cable) the bar stays full and faint.
          LevelBar {
            width: parent.width
            foreground: root.bar.foreground
            value: root.hasLevel ? root.battery.level / 100 : (root.charging ? 1 : 0)
            fillOpacity: root.hasLevel ? 1 : 0.35
            pulsing: root.charging && root.opened
          }

          PanelSeparator { foreground: root.bar.foreground }
        }

        // ---------- Equalizer: title · status dot · bypass switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(eqTitle.implicitHeight, eqSwitch.implicitHeight)

          PanelSectionHeader {
            id: eqTitle
            text: strings.t("eq.section").toUpperCase()
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            visible: root.eq.running
            spacing: Style.space(6)
            anchors.left: eqTitle.right
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
              id: liveDot
              width: Style.space(6); height: width; radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: root.eqLive ? Commons.Color.accent : Qt.darker(root.bar.foreground, 1.8)

              SequentialAnimation on opacity {
                running: root.eqLive && root.opened && !Style.reduceMotion
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { from: 1.0; to: 0.35; duration: Style.duration(900); easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.35; to: 1.0; duration: Style.duration(900); easing.type: Easing.InOutSine }
              }
            }
            Caption {
              text: root.eqStatusText
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          ToggleSwitch {
            id: eqSwitch
            visible: root.eq.running
            checked: !root.eq.bypassed
            busy: root.eqBusy
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setBypassed(!root.eq.bypassed)

            PanelToolTip {
              visible: eqSwitch.containsMouse
              text: root.eq.bypassed ? strings.t("eq.turnOn") : strings.t("eq.bypass")
            }
          }
        }

        // ---------- Easy Effects not running ----------
        Column {
          visible: !root.eq.running
          width: parent.width
          spacing: Style.space(10)

          Label {
            text: strings.t("eq.notRunning")
            opacity: 0.6
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            iconText: "󰐊"
            text: strings.t("eq.start")
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.startEasyEffects()
          }
        }

        // ---------- Running: preset, curve, output level ----------
        Column {
          visible: root.eq.running
          width: parent.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            implicitHeight: presetName.implicitHeight

            Label {
              id: presetName
              text: Model.prettyPreset(root.eq.preset) || "—"
              font.bold: true
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.right: preamp.left
              anchors.rightMargin: Style.space(8)
            }
            Label {
              id: preamp
              visible: root.preset.bands.length > 0
              text: strings.t("eq.preamp").arg(Commons.I18n.formatNumber(root.preset.inputGain, 1))
              opacity: 0.6
              font.pixelSize: Style.font.bodySmall
              anchors.right: parent.right
              anchors.baseline: presetName.baseline
            }
          }

          EqCurve {
            width: parent.width
            height: Style.space(120)
            points: root.curvePoints
            dimmed: root.eq.bypassed
            foreground: root.bar.foreground
            accent: Commons.Color.accent
            fontFamily: root.bar.fontFamily

            Label {
              visible: root.preset.bands.length === 0
              anchors.centerIn: parent
              text: strings.t("eq.noEqualizer")
              opacity: 0.5
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Caption {
              id: outputLabel
              text: strings.t("eq.output")
              anchors.verticalCenter: parent.verticalCenter
            }
            LevelBar {
              width: parent.width - outputLabel.implicitWidth - parent.spacing
              implicitHeight: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.bar.foreground
              fillColor: root.eqLive ? Commons.Color.accent : root.bar.foreground
              value: outputPeak.peak
              fillDuration: 70
            }
          }
        }

        // ---------- Preset buttons ----------
        Column {
          visible: root.eq.running && root.eq.presets.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: strings.t("eq.presets").toUpperCase()
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.eq.presets
              Button {
                required property var modelData
                text: Model.prettyPreset(modelData)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: root.eq.preset === modelData
                onClicked: root.loadPreset(modelData)
              }
            }
          }
        }

        // ---------- Mouse: icon · name / status · percentage ----------
        Column {
          visible: root.mouse.present
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.bar.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(mouseIcon.implicitHeight, mouseText.implicitHeight, mousePercent.implicitHeight)

            Label {
              id: mouseIcon
              text: root.mouseGlyph
              font.pixelSize: Style.font.title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Column {
              id: mouseText
              anchors.left: mouseIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: mousePercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Label {
                width: parent.width
                text: root.mouse.name || strings.t("mouse.title")
                font.bold: true
                elide: Text.ElideRight
              }
              Caption {
                width: parent.width
                text: root.mouse.charging ? strings.t("status.charging") : strings.t("mouse.onBattery")
                elide: Text.ElideRight
              }
            }
            Label {
              id: mousePercent
              text: root.mousePercentText || "—"
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          LevelBar {
            width: parent.width
            implicitHeight: Style.space(4)
            foreground: root.bar.foreground
            value: root.mouse.level >= 0 ? root.mouse.level / 100 : 0
            pulsing: root.mouse.charging && root.opened
          }
        }
      }
    }
  }


  // ================= Text styles =================

  // All text is plain: names come from devices and files.
  component Label: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  // Small spaced capitals, like the shell's own status lines.
  component Caption: Label {
    color: root.dimForeground
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    font.capitalization: Font.AllUppercase
  }
}
