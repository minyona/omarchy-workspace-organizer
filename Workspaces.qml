import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "Reorder.js" as Reorder

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selectedIndex: 0

  // True while SHIFT is held down. Arrows select normally and move the
  // workspace while SHIFT is down, and nothing on screen said which one the
  // next arrow would do. The selected row lifts out of the list to say the
  // workspace is in your hand now, and settles back when you let go.
  property bool grabbed: false

  // The staged model. `snapshot` is live state frozen at open time;
  // `stagedOrder` lists workspace ids in the order the user wants them.
  // Reordering only ever touches stagedOrder -- Hyprland is untouched until
  // Enter, so Escape is a true cancel with nothing to undo.
  property var snapshot: []
  property var stagedOrder: []
  property bool applying: false
  property string errorText: ""

  // Committing is a no-op only when the staged order is already 1..N with no
  // gaps -- a merely-sorted but non-contiguous set (1,2,5,7) still compacts.
  readonly property bool dirty: !Reorder.isIdentity(root.stagedOrder)

  // Shares the [menu] surface tokens — themes that style the menu also style
  // this overlay, so it re-themes for free.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  property color muted: Color.muted

  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(660), panel.width - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(52), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 3)

  function open(payloadJson) {
    root.opened = true
    root.applying = false
    root.errorText = ""
    // A grab never survives a close: the key release lands somewhere else once
    // the overlay is gone, so it would otherwise reopen still holding.
    root.grabbed = false
    // Rows appear immediately from the reactive workspace model; window
    // details arrive a few milliseconds later from hyprctl.
    root.refreshSnapshot()
    root.selectedIndex = root.indexOfFocused()
    clientsProcess.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.grabbed = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "minyona.workspaces")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --- state capture -------------------------------------------------------

  function refreshSnapshot() {
    var out = []
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var w = values[i]
      if (!Reorder.isReorderable(w.id)) continue

      out.push({ id: w.id, windows: [] })
    }

    out.sort(function(a, b) { return a.id - b.id })
    root.snapshot = out
    root.stagedOrder = out.map(function(entry) { return entry.id })
  }

  // Window class and title come from `hyprctl clients -j` rather than from the
  // Quickshell toplevel objects: the typed properties for app class vary across
  // Quickshell versions, while the hyprctl JSON has carried `class`/`title`
  // stably. One subprocess per open is a rounding error next to the redraw.
  function applyClients(raw) {
    var clients = []
    try { clients = JSON.parse(raw) } catch (e) { return }
    if (!clients || !clients.length) return

    var byWorkspace = {}
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || !c.workspace) continue
      var wsid = c.workspace.id
      if (!Reorder.isReorderable(wsid)) continue
      if (!byWorkspace[wsid]) byWorkspace[wsid] = []
      byWorkspace[wsid].push({
        cls: String(c["class"] || c.initialClass || ""),
        title: String(c.title || "")
      })
    }

    // Rebuild wholesale so the property change propagates to the delegates.
    var next = []
    for (var j = 0; j < root.snapshot.length; j++) {
      var entry = root.snapshot[j]
      next.push({ id: entry.id, windows: byWorkspace[entry.id] || [] })
    }
    root.snapshot = next
  }

  Process {
    id: clientsProcess
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      id: clientsOut
      waitForEnd: true
      onStreamFinished: root.applyClients(clientsOut.text)
    }
  }

  function entryFor(id) {
    for (var i = 0; i < root.snapshot.length; i++) {
      if (root.snapshot[i].id === id) return root.snapshot[i]
    }
    return { id: id, windows: [] }
  }

  function indexOfFocused() {
    var focused = Hyprland.focusedWorkspace
    if (!focused) return 0
    var at = root.stagedOrder.indexOf(focused.id)
    return at < 0 ? 0 : at
  }

  // --- interaction ---------------------------------------------------------

  // Number() on the deltas: these double as an IPC surface
  // (`omarchy-shell shell call minyona.workspaces select "1"`), and IPC hands
  // every argument over as a string -- which would otherwise concatenate.
  function select(delta) {
    if (!root.stagedOrder.length) return
    var next = root.selectedIndex + Number(delta)
    root.selectedIndex = Math.max(0, Math.min(root.stagedOrder.length - 1, next))
  }

  function selectSlot(slot) {
    var n = Number(slot)
    if (n < 1 || n > root.stagedOrder.length) return
    root.selectedIndex = n - 1
  }

  // Move the selected workspace through the staged order, carrying the
  // selection with it so repeated Shift+Down keeps moving the same workspace.
  function moveSelected(delta) {
    if (!root.stagedOrder.length) return
    var to = root.selectedIndex + Number(delta)
    if (to < 0 || to >= root.stagedOrder.length) return

    root.stagedOrder = Reorder.moveEntry(root.stagedOrder, root.selectedIndex, to)
    root.selectedIndex = to
  }

  function reset() {
    root.stagedOrder = root.snapshot.map(function(entry) { return entry.id })
    root.selectedIndex = root.indexOfFocused()
  }

  // Commit: renumber to match the staged order, then focus the selected slot.
  // After compaction the selected workspace lives at selectedIndex + 1.
  function commit() {
    if (root.applying) return
    var targetSlot = root.selectedIndex + 1

    if (!root.dirty) {
      root.focusSlot(targetSlot)
      root.dismiss()
      return
    }

    var lua = Reorder.buildApplyLua(root.stagedOrder)
    if (!lua) { root.dismiss(); return }

    root.applying = true
    root.errorText = ""
    applyProcess.pendingSlot = targetSlot
    applyProcess.command = ["hyprctl", "repl", lua]
    applyProcess.running = true
  }

  function focusSlot(slot) {
    Quickshell.execDetached(["hyprctl", "dispatch",
      "hl.dsp.focus({ workspace = \"" + slot + "\" })"])
  }

  Process {
    id: applyProcess
    property int pendingSlot: 1

    stdout: StdioCollector {
      id: applyOut
      waitForEnd: true

      onStreamFinished: {
        var out = String(applyOut.text || "").trim()
        root.applying = false

        // Hyprland announces a renumber as `changeworkspaceid>>old,new` and
        // emits NO workspace/activeworkspace event, so Quickshell never learns
        // the focused workspace's id changed and the bar keeps highlighting the
        // old slot. refreshMonitors() is the one that matters: the focused
        // workspace is read back from the monitor's active workspace.
        root.resync()
        resyncTimer.restart()

        if (out.indexOf("OK") === 0) {
          root.focusSlot(applyProcess.pendingSlot)
          root.dismiss()
        } else {
          // Stay open on failure: the Lua rolls itself back, so the deck the
          // user is looking at is still the truth.
          root.errorText = out || "no response from hyprctl"
          root.refreshSnapshot()
          clientsProcess.running = true
        }
      }
    }
  }

  // Pull every cached Hyprland model back in line with the compositor.
  // Order matters: monitors last, because that is what re-seats
  // `Hyprland.focusedWorkspace` onto the renumbered workspace.
  function resync() {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
  }

  // A second pass after the compositor has settled; the first can land before
  // Hyprland has finished emitting its changeworkspaceid events.
  Timer {
    id: resyncTimer
    interval: 250
    onTriggered: root.resync()
  }


  // --- view ------------------------------------------------------------------

  // A key legend chip: the glyph in a bracketed cell, the action beside it.
  // Pulled out because the footer's readability lives or dies on this pairing.
  component KeyCap: Row {
    property string keyText: ""
    property string label: ""
    // `active` lights the chip that the arrows are about to obey; `dimmed`
    // retires the one they are not. Between them the footer answers the only
    // question a held SHIFT raises: which of these two is live right now.
    property bool active: false
    property bool dimmed: false

    spacing: Style.space(5)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    opacity: dimmed ? 0.35 : 1
    Behavior on opacity { NumberAnimation { duration: 130 } }

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: capText.implicitWidth + Style.space(9)
      height: capText.implicitHeight + Style.space(5)
      radius: Style.space(2)
      color: Util.alpha(root.accent, active ? 0.34 : 0.12)
      border.width: 1
      border.color: Util.alpha(root.accent, active ? 0.95 : 0.45)
      Behavior on color { ColorAnimation { duration: 130 } }

      Text {
        id: capText
        anchors.centerIn: parent
        text: keyText
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        color: root.foreground
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: label
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
      font.bold: active
      color: active ? root.accent : root.muted
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "minyona-workspaces"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem

        // SHIFT is tracked as a key in its own right, not just read off the
        // modifier mask of some other press, so the lift happens the moment it
        // goes down rather than on the first arrow after it.
        //
        // Ending the grab is the harder half. The press arrives as Key_Shift,
        // but the matching release has been observed arriving under a
        // different modifier keycode, so matching Key_Shift on the way out
        // leaves the row stuck in the air. A grab that never ends is far worse
        // than one that ends a touch eagerly, so any modifier release drops it.
        readonly property var modifierKeys: [
          Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_AltGr,
          Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_CapsLock
        ]

        Keys.onReleased: function(event) {
          if (keyCatcher.modifierKeys.indexOf(event.key) !== -1) {
            root.grabbed = false
            event.accepted = true
          }
        }

        // Losing focus means the release will be delivered somewhere else, and
        // the row would still be in the air when the overlay came back.
        onActiveFocusChanged: if (!activeFocus) root.grabbed = false

        Keys.onPressed: function(event) {
          var shifted = (event.modifiers & Qt.ShiftModifier) !== 0

          // Matched by key, not by mask: that is what makes the lift land on
          // the SHIFT press itself rather than on the first arrow after it.
          // Every other press then resyncs from the mask, which repairs the
          // state if a release is ever missed.
          if (event.key === Qt.Key_Shift) {
            root.grabbed = true
            event.accepted = true
            return
          }
          root.grabbed = shifted

          if (event.key === Qt.Key_Escape) {
            root.dismiss()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.commit()
          } else if (event.key === Qt.Key_Backspace) {
            root.reset()
          } else if (event.key === Qt.Key_Down) {
            if (shifted) root.moveSelected(1)
            else root.select(1)
          } else if (event.key === Qt.Key_Up) {
            if (shifted) root.moveSelected(-1)
            else root.select(-1)
          } else if (event.key === Qt.Key_Home) {
            root.selectSlot(1)
          } else if (event.key === Qt.Key_End) {
            root.selectSlot(root.stagedOrder.length)
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            root.selectSlot(event.key - Qt.Key_0)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        id: content
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: root.contentSpacing

        // --- header ---------------------------------------------------------
        Item {
          id: header
          width: content.width
          height: titleRow.height + Style.space(10)

          Row {
            id: titleRow
            spacing: Style.space(7)
            anchors.left: parent.left

            // Terminal prompt block, pulsing while a commit is in flight.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(4)
              height: Style.font.title
              color: root.accent

              SequentialAnimation on opacity {
                running: root.opened && root.applying
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 380 }
                NumberAnimation { to: 1.0;  duration: 380 }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "WORKSPACE"
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.letterSpacing: 3
              font.bold: true
              color: root.foreground
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "//"
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              color: root.accent
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "REORDER"
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.letterSpacing: 3
              color: root.muted
            }
          }

          // Right-hand status readout: slot count, or a STAGED badge once the
          // order diverges from what the compositor currently has.
          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: titleRow.verticalCenter
            width: statusText.implicitWidth + Style.space(12)
            height: statusText.implicitHeight + Style.space(6)
            radius: Style.space(2)
            color: root.dirty ? Util.alpha(root.accent, 0.16) : "transparent"
            border.width: 1
            border.color: root.dirty ? Util.alpha(root.accent, 0.6)
                                     : Util.alpha(root.muted, 0.35)

            Text {
              id: statusText
              anchors.centerIn: parent
              text: root.dirty ? "STAGED"
                               : root.stagedOrder.length + " SLOTS"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
              font.bold: root.dirty
              color: root.dirty ? root.accent : root.muted
            }
          }

          // Rule with a bright leading tick — reads as a readout scale.
          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Util.alpha(root.border, 0.4)
          }
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: root.dirty ? Style.space(64) : Style.space(28)
            height: 1
            color: root.accent
            Behavior on width { NumberAnimation { duration: 140 } }
          }

          // Measuring-scale ticks hanging off the header rule.
          Row {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Style.space(4)

            Repeater {
              model: 12
              Rectangle {
                required property int index
                width: 1
                height: (index % 4 === 0) ? Style.space(5) : Style.space(2.5)
                color: Util.alpha(root.accent, (index % 4 === 0) ? 0.65 : 0.3)
              }
            }
          }
        }

        // --- rows -----------------------------------------------------------
        Column {
          id: list
          width: content.width
          spacing: Style.space(3)

          Repeater {
            model: root.stagedOrder

            Item {
              id: wsRow
              required property int index
              required property var modelData

              readonly property var entry: root.entryFor(modelData)
              readonly property bool current: index === root.selectedIndex
              // The workspace's live id differs from the slot it would land in.
              readonly property bool moved: modelData !== (index + 1)
              // Held, not merely selected. Only the row you could move right
              // now is allowed to look picked up.
              readonly property bool lifted: current && root.grabbed

              // App classes on the primary line, the first window's title
              // beneath it — suppressed when it would just repeat the line above.
              readonly property string primaryText: {
                var wins = entry.windows
                if (!wins.length) return "(empty)"
                var names = []
                for (var i = 0; i < wins.length; i++) {
                  names.push(wins[i].cls || wins[i].title || "?")
                }
                return names.join(" · ")
              }
              readonly property string subText: {
                var wins = entry.windows
                if (!wins.length) return ""
                var first = wins[0].title || ""
                return first === primaryText ? "" : first
              }

              width: list.width
              height: root.rowHeight

              // Cast shadow, left behind on the list surface while the body
              // above it rises. No blur is available here, so the softness is
              // two offset plates: a wider faint one under a tighter darker one.
              Rectangle {
                anchors.fill: parent
                anchors.topMargin: Style.space(7)
                anchors.bottomMargin: -Style.space(7)
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                radius: Style.space(5)
                color: "#000000"
                opacity: wsRow.lifted ? 0.20 : 0
                Behavior on opacity { NumberAnimation { duration: 130 } }
              }
              Rectangle {
                anchors.fill: parent
                anchors.topMargin: Style.space(4)
                anchors.bottomMargin: -Style.space(4)
                anchors.leftMargin: Style.space(2)
                anchors.rightMargin: Style.space(2)
                radius: Style.space(4)
                color: "#000000"
                opacity: wsRow.lifted ? 0.30 : 0
                Behavior on opacity { NumberAnimation { duration: 130 } }
              }

              // Everything above the shadow. The lift is a transform rather
              // than a y offset because the Column owns the layout: a row that
              // genuinely moved would shove its neighbours down the list.
              Item {
                id: rowBody
                anchors.fill: parent

                transform: Translate {
                  y: wsRow.lifted ? -Style.space(4) : 0
                  // OutBack overshoots a little on the way up, which is what
                  // makes it read as picked up rather than nudged.
                  Behavior on y {
                    NumberAnimation { duration: 140; easing.type: Easing.OutBack }
                  }
                }

                // Outer bloom, then the row fill — a blur-free glow built from
                // two stacked translucent accents. Holding the row spreads the
                // bloom and outlines the fill, so it stops reading as a
                // highlighted band and starts reading as a detached object.
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: wsRow.lifted ? -Style.space(6) : -Style.space(3)
                  radius: Style.space(5)
                  color: Util.alpha(root.accent, wsRow.lifted ? 0.13 : 0.07)
                  visible: wsRow.current
                }
                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(3)
                  color: wsRow.current ? Util.alpha(root.accent, wsRow.lifted ? 0.22 : 0.14)
                                       : "transparent"
                  border.width: wsRow.lifted ? Math.max(1, Style.space(1)) : 0
                  border.color: Util.alpha(root.accent, 0.75)
                }

                // Accent spine on the selected row — the cyberpunk "cursor".
                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: wsRow.lifted ? Style.space(4) : Style.space(3)
                  height: parent.height * (wsRow.lifted ? 0.94 : (wsRow.current ? 0.78 : 0.3))
                  radius: width
                  color: wsRow.current ? root.accent : root.border
                  opacity: wsRow.current ? 1 : 0.22
                  Behavior on width { NumberAnimation { duration: 130 } }
                  Behavior on height { NumberAnimation { duration: 90 } }
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(13)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(9)

                  // Selection chevron in its own gutter, so the slot address
                  // never shifts horizontally as the cursor moves.
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(11)
                    // ▸ points at the selection. ⇕ says the arrows are about
                    // to move this row rather than walk past it.
                    text: wsRow.lifted ? "⇕" : (wsRow.current ? "▸" : "")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    color: root.accent
                  }

                  // Slot address: [01]. Brackets stay muted so the digits read.
                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    Text {
                      text: "["
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      color: Util.alpha(root.muted, 0.7)
                    }
                    Text {
                      text: (wsRow.index + 1 < 10 ? "0" : "") + (wsRow.index + 1)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                      color: wsRow.current ? root.accent : root.foreground
                    }
                    Text {
                      text: "]"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      color: Util.alpha(root.muted, 0.7)
                    }
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(95) - fromTag.width
                    spacing: Style.space(2)


                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: wsRow.primaryText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      color: wsRow.entry.windows.length ? root.foreground : root.muted
                      opacity: wsRow.entry.windows.length ? 1 : 0.55
                    }

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      visible: wsRow.subText !== ""
                      text: wsRow.subText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: Util.alpha(root.muted, 0.85)
                    }
                  }

                  // Only the row being moved explains where it came from. Showing
                  // this on every displaced row turns the deck into a wall of
                  // competing numbers, which is exactly what it should not be.
                  Text {
                    id: fromTag
                    anchors.verticalCenter: parent.verticalCenter
                    width: (wsRow.current && wsRow.moved) ? Style.space(52) : 0
                    visible: wsRow.current && wsRow.moved
                    text: "from " + wsRow.modelData
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: Util.alpha(root.muted, 0.9)
                  }

                  // Window count as a right-aligned micro-cap readout.
                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: wsRow.entry.windows.length ? String(wsRow.entry.windows.length) : "—"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      color: wsRow.entry.windows.length ? root.foreground : root.muted
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: wsRow.entry.windows.length > 0
                      text: "WIN"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                      color: Util.alpha(root.muted, 0.8)
                    }
                  }
                }
              }
            }
          }
        }

        // --- footer ---------------------------------------------------------
        Item {
          id: footer
          width: content.width
          height: Math.max(hints.height, errorRow.height) + Style.space(12)

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Util.alpha(root.border, 0.4)
          }

          Row {
            id: hints
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            spacing: Style.space(13)
            visible: root.errorText === "" && !root.applying

            // Labels stay put while SHIFT is held; only the emphasis moves.
            // Retitling a chip would reflow every chip to its right, which
            // reads as the footer twitching rather than as an answer.
            KeyCap { keyText: "↑↓";  label: "SELECT"; dimmed: root.grabbed }
            KeyCap { keyText: "⇧↑↓"; label: "MOVE";   active: root.grabbed }
            KeyCap { keyText: "1-9"; label: "JUMP" }
            KeyCap { keyText: "⌫";   label: "RESET" }
            KeyCap { keyText: "⏎";   label: "COMMIT" }
            KeyCap { keyText: "ESC"; label: "CANCEL" }
          }

          Row {
            id: errorRow
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: parent.width
            spacing: Style.space(6)
            visible: !hints.visible

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.applying ? "▶" : "!"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              color: root.applying ? root.accent : Color.urgent
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(20)
              elide: Text.ElideRight
              text: root.applying ? "APPLYING…" : root.errorText
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: root.applying ? 2 : 0
              color: root.applying ? root.accent : Color.urgent
            }
          }
        }
      }

      // --- chrome (non-interactive, drawn over the content) -----------------

      // Corner brackets. Four L-shapes, drawn inside the card's edges.
      Item {
        anchors.fill: parent
        anchors.margins: Style.space(4)
        z: 8

        readonly property int armLength: Style.space(15)
        readonly property int armWidth: Math.max(1, Style.space(1.5))
        readonly property color armColor: Util.alpha(root.accent, 0.75)

        Item {
          anchors.left: parent.left; anchors.top: parent.top
          width: parent.armLength; height: parent.armLength
          Rectangle { width: parent.width; height: parent.parent.armWidth; color: parent.parent.armColor }
          Rectangle { width: parent.parent.armWidth; height: parent.height; color: parent.parent.armColor }
        }
        Item {
          anchors.right: parent.right; anchors.top: parent.top
          width: parent.armLength; height: parent.armLength
          Rectangle { anchors.right: parent.right; width: parent.width; height: parent.parent.armWidth; color: parent.parent.armColor }
          Rectangle { anchors.right: parent.right; width: parent.parent.armWidth; height: parent.height; color: parent.parent.armColor }
        }
        Item {
          anchors.left: parent.left; anchors.bottom: parent.bottom
          width: parent.armLength; height: parent.armLength
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: parent.parent.armWidth; color: parent.parent.armColor }
          Rectangle { width: parent.parent.armWidth; height: parent.height; color: parent.parent.armColor }
        }
        Item {
          anchors.right: parent.right; anchors.bottom: parent.bottom
          width: parent.armLength; height: parent.armLength
          Rectangle { anchors.bottom: parent.bottom; anchors.right: parent.right; width: parent.width; height: parent.parent.armWidth; color: parent.parent.armColor }
          Rectangle { anchors.right: parent.right; width: parent.parent.armWidth; height: parent.height; color: parent.parent.armColor }
        }
      }

      // CRT scanlines. Deliberately near-invisible per line; the effect is
      // cumulative texture, not stripes you can count.
      Item {
        anchors.fill: parent
        clip: true
        z: 9

        Repeater {
          model: Math.ceil(card.height / Style.space(3))

          Rectangle {
            required property int index
            y: index * Style.space(3)
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.03)
          }
        }
      }
    }
  }
}
