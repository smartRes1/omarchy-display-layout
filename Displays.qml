import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Layout.js" as Layout

// Arrange the displays with the mouse. Every display is a rectangle at its
// logical size (pixels / scale). Dropping one snaps it to the nearest edge of
// another display (top, middle and bottom alignment are magnetic) and applies
// the layout live via `hyprctl eval`. Save keeps it as the layout for this
// combination of displays (Layout.js, in ~/.config/hypr/monitors.lua);
// Esc / Discard reloads the saved layout.
Item {
  id: root

  property var shell: null
  property var manifest: null

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string configDir: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string monitorsPath: root.configDir + "/hypr/monitors.lua"
  // Layouts saved so far, read from monitors.lua each time the panel opens
  property var profiles: ({})
  readonly property string profileKey: Layout.profileKey(root.monitors)
  readonly property bool profileSaved: root.profiles[root.profileKey] !== undefined

  property bool opened: false
  // [{ name, label, mode, scale, x, y, w, h }], logical pixels
  property var monitors: []
  property bool changed: false
  // Display being dragged, its offset in canvas pixels while dragging
  property string draggedName: ""
  property real dragX: 0
  property real dragY: 0

  property color foreground: Commons.Color.menu.text
  property color cardBackground: Commons.Color.menu.background
  property color accent: Commons.Color.accent
  property color muted: Commons.Color.muted
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius

  // The screen the panel opened on. Fixed while open: focus follows the
  // mouse, and testing the new layout means moving it to the other screen.
  property var targetScreen: null

  // Canvas mapping, fixed while the panel is open so a drop does not rescale
  property real factor: 0.1
  property real originX: 0
  property real originY: 0

  function screenFor(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function labelFor(m) {
    if (Layout.isInternal(m.name)) return strings.t("display.laptop")
    var label = m.model || m.description || m.name
    return m.make && label.indexOf(m.make) !== 0 ? m.make + " " + label : label
  }

  function open(payloadJson) {
    var focused = Hyprland.focusedMonitor
    root.targetScreen = root.screenFor(focused ? focused.name : "")
    root.changed = false
    root.draggedName = ""
    monitorsFile.reload()
    root.profiles = Layout.readProfiles(monitorsFile.text())
    monitorsProc.fit = true
    monitorsProc.running = true
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.draggedName = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "smartres1.display-layout")
  }

  function toggle() {
    if (root.opened) root.discard()
    else root.open("{}")
  }

  // Keeps the layout shown now as the one for this combination of displays.
  // The first save leaves a copy of monitors.lua as it was beside it.
  function save() {
    if (root.monitors.length === 0) return
    monitorsFile.reload()
    var text = monitorsFile.text()
    if (!backupFile.exists && text.length > 0) backupFile.setText(text)
    var profiles = Layout.readProfiles(text)
    profiles[root.profileKey] = Layout.rulesFor(root.monitors)
    monitorsFile.setText(Layout.writeProfiles(text, profiles))
    root.profiles = profiles
    root.changed = false
    Quickshell.execDetached(["hyprctl", "reload"])
    Quickshell.execDetached(["notify-send", "-a", strings.t("app.name"), strings.t("saved.title"),
      strings.t("saved.body").arg(root.monitors.map(function(m) { return m.label }).join(" + "))])
    root.dismiss()
  }

  // Back to the saved layout
  function discard() {
    if (root.changed) Quickshell.execDetached(["hyprctl", "reload"])
    root.changed = false
    root.dismiss()
  }

  // Scale and offset so the whole layout fits the canvas with room to drag
  function fitCanvas() {
    if (root.monitors.length === 0) return
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      minX = Math.min(minX, m.x); minY = Math.min(minY, m.y)
      maxX = Math.max(maxX, m.x + m.w); maxY = Math.max(maxY, m.y + m.h)
    }
    var w = maxX - minX, h = maxY - minY
    root.factor = Math.min(canvas.width / w, canvas.height / h) * 0.6
    root.originX = minX - (canvas.width / root.factor - w) / 2
    root.originY = minY - (canvas.height / root.factor - h) / 2
  }

  function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
  }

  // Where a display dropped at (x, y) ends up: touching the nearest edge of
  // another display, sharing at least a strip of that edge, aligned top,
  // middle or bottom (left, middle, right) when close to it.
  function snap(d, x, y) {
    var best = null
    var minShare = 100
    for (var i = 0; i < root.monitors.length; i++) {
      var o = root.monitors[i]
      if (o.name === d.name) continue
      var sides = [
        { x: o.x + o.w, y: y, free: "y" },
        { x: o.x - d.w, y: y, free: "y" },
        { x: x, y: o.y + o.h, free: "x" },
        { x: x, y: o.y - d.h, free: "x" }
      ]
      for (var s = 0; s < sides.length; s++) {
        var c = sides[s]
        var threshold, aligns
        if (c.free === "y") {
          c.y = Math.max(o.y - d.h + minShare, Math.min(o.y + o.h - minShare, c.y))
          aligns = [o.y, o.y + (o.h - d.h) / 2, o.y + o.h - d.h]
          threshold = Math.min(d.h, o.h) * 0.08
          for (var a = 0; a < aligns.length; a++) if (Math.abs(c.y - aligns[a]) < threshold) c.y = aligns[a]
        } else {
          c.x = Math.max(o.x - d.w + minShare, Math.min(o.x + o.w - minShare, c.x))
          aligns = [o.x, o.x + (o.w - d.w) / 2, o.x + o.w - d.w]
          threshold = Math.min(d.w, o.w) * 0.08
          for (var b = 0; b < aligns.length; b++) if (Math.abs(c.x - aligns[b]) < threshold) c.x = aligns[b]
        }
        c.x = Math.round(c.x); c.y = Math.round(c.y)
        var placed = { x: c.x, y: c.y, w: d.w, h: d.h }
        var free = true
        for (var k = 0; k < root.monitors.length; k++) {
          var other = root.monitors[k]
          if (other.name !== d.name && root.overlaps(placed, other)) free = false
        }
        if (!free) continue
        var dist = Math.pow(c.x - x, 2) + Math.pow(c.y - y, 2)
        if (!best || dist < best.dist) best = { x: c.x, y: c.y, dist: dist }
      }
    }
    return best
  }

  function drop(name, canvasX, canvasY) {
    var list = root.monitors.map(function(m) { return Object.assign({}, m) })
    var d = list.filter(function(m) { return m.name === name })[0]
    if (!d || list.length < 2) return
    var spot = root.snap(d, canvasX / root.factor + root.originX, canvasY / root.factor + root.originY)
    if (!spot || (spot.x === d.x && spot.y === d.y)) return
    d.x = spot.x; d.y = spot.y

    // Keep the top-left corner of the layout at 0x0
    var minX = Infinity, minY = Infinity
    for (var i = 0; i < list.length; i++) { minX = Math.min(minX, list[i].x); minY = Math.min(minY, list[i].y) }
    var lua = []
    for (var j = 0; j < list.length; j++) {
      var m = list[j]
      m.x -= minX; m.y -= minY
      lua.push("hl.monitor({ output = \"" + m.name + "\", mode = \"" + m.mode + "\", position = \""
        + m.x + "x" + m.y + "\", scale = " + m.scale + " })")
    }
    // The canvas shifts with the layout, so the screens stay where they were dropped
    root.originX -= minX; root.originY -= minY
    root.monitors = list
    root.changed = true
    Quickshell.execDetached(["hyprctl", "eval", lua.join("\n")])
    refreshTimer.restart()
  }

  Process {
    id: monitorsProc
    property bool fit: false
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = []
        try {
          var raw = JSON.parse(text)
          for (var i = 0; i < raw.length; i++) {
            var r = raw[i]
            var scale = Math.round(r.scale * 100) / 100
            var rotated = r.transform % 2 === 1
            var m = {
              name: r.name,
              description: r.description || "",
              make: r.make || "",
              model: r.model || "",
              mode: r.width + "x" + r.height + "@" + r.refreshRate.toFixed(2),
              transform: r.transform || 0,
              resolution: r.width + "×" + r.height + " · " + Math.round(r.refreshRate) + " Hz · " + scale + "×",
              scale: scale,
              x: r.x,
              y: r.y,
              w: Math.round((rotated ? r.height : r.width) / scale),
              h: Math.round((rotated ? r.width : r.height) / scale)
            }
            m.label = root.labelFor(m)
            list.push(m)
          }
        } catch (e) {}
        root.monitors = list
        if (monitorsProc.fit) root.fitCanvas()
        monitorsProc.fit = false
      }
    }
  }

  FileView {
    id: monitorsFile
    path: root.monitorsPath
    blockLoading: true
    printErrors: false
    // In place, so a monitors.lua that is a symlink into a dotfiles repo stays one
    atomicWrites: false
  }

  FileView {
    id: backupFile
    property bool exists: false
    path: root.monitorsPath + ".before-display-layout"
    blockLoading: true
    printErrors: false
    onLoaded: exists = true
    onLoadFailed: exists = false
  }

  // Read back what Hyprland made of the layout
  Timer {
    id: refreshTimer
    interval: 400
    onTriggered: monitorsProc.running = true
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "display-layout"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Qt.alpha(Commons.Color.background, 0.88)
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.discard()
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.save()
        } else {
          return
        }
        event.accepted = true
      }
    }

    Text {
      id: title
      anchors.top: parent.top
      anchors.topMargin: Style.space(40)
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: strings.t("panel.title")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body * 1.6
      font.bold: true
    }

    Text {
      id: subtitle
      anchors.top: title.bottom
      anchors.topMargin: Style.space(8)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(implicitWidth, parent.width - Style.space(80))
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: (root.profileSaved ? strings.t("panel.saved") : strings.t("panel.new"))
        .arg(root.monitors.map(function(m) { return m.label }).join(" + "))
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      id: canvas
      anchors.top: subtitle.bottom
      anchors.bottom: buttons.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(40)
      onWidthChanged: if (root.opened && !root.changed) root.fitCanvas()
      onHeightChanged: if (root.opened && !root.changed) root.fitCanvas()

      Repeater {
        model: root.monitors

        Rectangle {
          id: screenRect
          required property var modelData
          readonly property bool dragged: root.draggedName === modelData.name
          readonly property real homeX: (modelData.x - root.originX) * root.factor
          readonly property real homeY: (modelData.y - root.originY) * root.factor

          x: dragged ? root.dragX : homeX
          y: dragged ? root.dragY : homeY
          z: dragged ? 1 : 0
          width: modelData.w * root.factor
          height: modelData.h * root.factor
          radius: root.cornerRadius
          color: Qt.alpha(root.cardBackground, 0.95)
          border.width: 2
          border.color: dragged || area.containsMouse ? root.accent : Qt.alpha(root.foreground, 0.3)

          Behavior on x { enabled: !screenRect.dragged; NumberAnimation { duration: 120 } }
          Behavior on y { enabled: !screenRect.dragged; NumberAnimation { duration: 120 } }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(4)
            width: parent.width - Style.space(16)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: screenRect.modelData.label
              color: screenRect.dragged ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 1.2
              font.bold: true
            }
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: screenRect.modelData.resolution
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: screenRect.modelData.name + " · " + screenRect.modelData.x + "×" + screenRect.modelData.y
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.85
            }
          }

          MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property real grabX: 0
            property real grabY: 0

            onPressed: function(mouse) {
              grabX = mouse.x; grabY = mouse.y
              root.dragX = screenRect.homeX; root.dragY = screenRect.homeY
              root.draggedName = screenRect.modelData.name
            }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              var p = mapToItem(canvas, mouse.x, mouse.y)
              root.dragX = p.x - grabX; root.dragY = p.y - grabY
            }
            onReleased: {
              var name = root.draggedName
              root.draggedName = ""
              root.drop(name, root.dragX, root.dragY)
            }
          }
        }
      }
    }

    Row {
      id: buttons
      anchors.bottom: hint.top
      anchors.bottomMargin: Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(16)

      Repeater {
        model: [
          { text: strings.t("button.discard"), primary: false },
          { text: strings.t("button.save"), primary: true }
        ]

        Rectangle {
          id: button
          required property var modelData
          width: label.implicitWidth + Style.space(48)
          height: label.implicitHeight + Style.space(20)
          radius: root.cornerRadius
          color: modelData.primary ? Qt.alpha(root.accent, buttonArea.containsMouse ? 0.35 : 0.2) : Qt.alpha(root.foreground, buttonArea.containsMouse ? 0.15 : 0.08)
          border.color: modelData.primary ? root.accent : Qt.alpha(root.foreground, 0.3)
          border.width: 1

          Text {
            id: label
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: button.modelData.text
            color: button.modelData.primary ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 1.1
          }

          MouseArea {
            id: buttonArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.modelData.primary ? root.save() : root.discard()
          }
        }
      }
    }

    Text {
      id: hint
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: root.changed ? strings.t("hint.changed") : strings.t("hint.idle")
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
