import QtQuick
import Quickshell.Hyprland

// Keeps Quickshell's cached Hyprland models honest across a workspace renumber.
//
// Hyprland announces a renumber as `changeworkspaceid>>old,new` and emits no
// workspace/activeworkspace event alongside it. Quickshell 0.3.1 predates that
// event, so nothing invalidates its caches: the workspace list keeps the old
// ids and, worse, `Hyprland.focusedWorkspace` keeps pointing at the old number,
// leaving the bar highlighting a slot the user is no longer on until some
// unrelated event happens to refresh it.
//
// This runs in the same process as the bar, so one refresh here fixes every
// consumer at once -- and because it is driven by the event rather than by
// whoever performed the reorder, it covers keybinding-driven shifts and
// third-party renumbers just as well as this plugin's own overlay.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  // Monitors last: that is what re-seats `focusedWorkspace` onto the
  // renumbered workspace.
  function resync() {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
  }

  // A renumber arrives as a burst of changeworkspaceid events (one per
  // workspace, twice over for the park/land passes). Refreshing on every one
  // would mean a dozen round-trips for a single reorder, so the burst is
  // coalesced and settled once it stops.
  Timer {
    id: settle
    interval: 90
    onTriggered: root.resync()
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!event || !event.name) return
      if (String(event.name) === "changeworkspaceid") settle.restart()
    }
  }
}
