# Workspace Organizer

A keyboard-driven workspace switcher and **reorderer** for
[Omarchy](https://omarchy.org/). Select a workspace, move it up or down the
list, commit — the workspaces renumber to match.

```
┌─                                              ─┐
  ▊ WORKSPACE // REORDER              [ STAGED ]
  ──────────────────────────────────── ‧‧|‧‧‧|‧‧
  ▐ ▸ [01]  grok-bot · chrome   from 3   2 WIN
  ▌   [02]  org.omarchy.agent            1 WIN
  ▌   [03]  chromium                     1 WIN
  ▌   [04]  foot · org.omarchy.agent     2 WIN
  ────────────────────────────────────────────────
  [↑↓] SELECT [⇧↑↓] MOVE [1-9] JUMP [⏎] COMMIT
└─                                              ─┘
```

`[01]` is the slot a workspace will land in, and it is the only number on a
row — one address, not a mapping to decode. The row you are actively moving
adds a quiet `from 3`; the others just move, which you can see.

`STAGED` and the lengthened header tick carry the "this differs from reality"
signal. **Red is reserved exclusively for failures**, so an alarm colour never
appears during ordinary editing.

## Why

Hyprland can focus a workspace and move *windows* between workspaces, but it
has no notion of reordering the workspaces themselves. If workspace 3 is where
your work drifted and you want it first, your options were to move every window
by hand or live with the order.

This reorders with **insert semantics**: moving 3 to the front turns
`[1,2,3]` into `[3,1,2]`, the way dragging a row in a list behaves — not a swap.

## Requirements

- **Omarchy Quattro (4.0 or newer).** The `omarchy plugin` command and the
  shell plugin system arrived with Quattro; earlier releases have nowhere to
  install this.
- **Quickshell.** Ships with Omarchy and runs both the overlay and the service.
- **Hyprland**, for the optional move-mode keybinding, which uses the Lua
  config API and submaps.

Developed against Omarchy 4.0.0.alpha, Quickshell 0.3.1, Hyprland 0.56.2.
There are no other runtime dependencies. Nothing is fetched at install time and
no packages beyond the above are pulled in.

## Install

```bash
omarchy plugin add https://github.com/minyona/omarchy-workspace-organizer --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + GRAVE", "Workspace organizer", "omarchy-shell shell toggle minyona.workspaces")
```

`SUPER+GRAVE` is unbound in Omarchy's defaults. Check any key you pick with
`omarchy menu keybindings --print` first — `SUPER+W` is *Close window*.

## Uninstall

```bash
omarchy plugin remove minyona.workspaces
```

That deletes the plugin folder and drops its entry from the `plugins` array in
`~/.config/omarchy/shell.json`. Nothing else is touched: the plugin writes no
files outside its own folder and never edits your Hyprland config, so the
bindings you added are yours to delete from `~/.config/hypr/bindings.lua` by
hand. Then `omarchy restart shell`.

Removal leaves your workspaces at whatever numbers they currently hold. There
is no state to unwind, because a reorder is an ordinary Hyprland renumber and
not something this plugin keeps on the side.

## Keys

| Key | Action |
|---|---|
| `↑` / `↓` | select |
| `⇧↑` / `⇧↓` | move the selected workspace up / down the order |
| `1`–`9` | jump the cursor to that slot |
| `Home` / `End` | first / last |
| `⌫` | discard staged changes, stay open |
| `⏎` | commit the reorder, then focus the selected workspace |
| `Esc` | cancel — nothing is applied |

### Move mode (no overlay)

For the common case — "I'm on this workspace and I want it further left" —
there is a faster path that skips the deck entirely:

**`SUPER+SHIFT+\``** enters the mode. **`←` / `→`** then moves the workspace you
are on one slot, applied immediately, and works whether or not you are still
holding `SHIFT` from the entry chord. **`Esc`** or **`↵`** leaves.

This is a Hyprland *submap*, which is what buys us bare arrow keys: every
`SUPER`+arrow chord is already taken by Omarchy's window, group, and monitor
actions.

It is deliberately **not** bound to plain `SHIFT+\``, which is how you type
`~` — a global bind there would break the tilde key everywhere.

The move logic (`workspace-shift.lua`) runs as a Lua keybinding function
*inside the compositor*, so a shift costs no subprocess at all.

Move mode is opt-in. Paste this into `~/.config/hypr/bindings.lua`:

```lua
-- Workspace Organizer: move mode.
--
-- Guarded load: a bare dofile on a missing file raises, and an error partway
-- through bindings.lua takes every binding after it down with it.
local ok, ws = pcall(dofile, os.getenv("HOME")
  .. "/.config/omarchy/plugins/minyona.workspaces/workspace-shift.lua")

if ok and ws then
  local function move(delta)
    return function()
      local moved, info = ws.shift(delta)
      hl.notification.create({
        text = moved and ("workspace moved to slot " .. info) or tostring(info),
        timeout = 1400,
      })
    end
  end

  local function leave()
    hl.dispatch(hl.dsp.submap("reset"))
  end

  hl.define_submap("workspace-move", function()
    hl.bind("left",  move(-1))
    hl.bind("right", move(1))
    -- Shifted variants, so keeping SHIFT held from the entry chord still
    -- moves rather than silently doing nothing.
    hl.bind("SHIFT + left",  move(-1))
    hl.bind("SHIFT + right", move(1))
    hl.bind("escape", leave)
    hl.bind("return", leave)
  end)

  -- code:49 is the physical ` key. Bound by keycode rather than keysym because
  -- with SHIFT held that key reports "asciitilde", not "grave", so a keysym
  -- bind on GRAVE can never match. Omarchy binds its own number row the same
  -- way (code:10 is workspace 1).
  o.bind("SUPER + SHIFT + code:49", "Move workspace (arrows)", function()
    hl.dispatch(hl.dsp.submap("workspace-move"))
    hl.notification.create({ text = "MOVE MODE  ←/→ move  Esc exit", timeout = 1400 })
  end)
end
```

The submap binds only the six keys above. Anything else is swallowed while the
mode is active, so `Esc` is how you get out.

### IPC

The same actions are reachable over IPC, which makes single-key bindings easy
to build on top:

```bash
omarchy-shell shell call minyona.workspaces selectSlot "3"
omarchy-shell shell call minyona.workspaces moveSelected "-1"
omarchy-shell shell call minyona.workspaces commit ""
```

## How it works

**Nothing touches Hyprland until you press Enter.** The overlay reorders a
purely virtual list, so `Esc` is a true cancel with nothing to undo and the
`STAGED` badge tells you when a commit would change something.

A bundled **service** watches Hyprland's `changeworkspaceid` event and refreshes
Quickshell's cached models. Hyprland emits no `workspace`/`activeworkspace`
event alongside a renumber, and Quickshell 0.3.1 predates `changeworkspaceid`,
so without this the bar keeps highlighting the slot you *were* on until some
unrelated event happens to refresh it. Because the service is driven by the
event rather than by whoever performed the reorder, it fixes the bar for
keybinding-driven moves and third-party renumbers too, not just this plugin.

Commit renumbers workspaces **in place** via
`hl.dsp.workspace.change_id` rather than migrating windows between them. That
preserves window stacking, focus history, and per-workspace tiling layout —
all of which moving windows would destroy — and avoids Hyprland's habit of
destroying a non-persistent workspace the instant it is emptied.

The renumber runs as a single `hyprctl repl` Lua program, so the whole
permutation completes inside one compositor dispatch: no frame is drawn
mid-shuffle. It works in two passes — park every workspace in a scratch id
band far above any live id, then bring them down into their final slots — so
no intermediate state can ever collide. Every `change_id` result is checked,
and any failure unwinds the calls already made.

Before mutating anything it re-reads live state and aborts if a workspace was
created or destroyed while the overlay was open, so a stale view can never be
committed.

Workspace ids **compact to 1..N** on commit, so `SUPER+<n>` always lands on the
row the overlay showed you.

## Notes and limitations

- **Single monitor.** Workspace ids are global in Hyprland; this version sorts
  them globally and does not scope the reorder per-monitor. On a multi-monitor
  setup the deck will list every workspace together.
- **Special workspaces** (scratchpad, named workspaces — anything with a
  negative id) are excluded. Hyprland refuses to renumber them, and the overlay
  never offers them.
- **Id-keyed state.** Omarchy's per-workspace tiling layouts live in
  `~/.local/state/omarchy/workspace-layouts/<id>.lua`, keyed by id. After a
  reorder the saved layout stays with the *slot*, not with the workspace that
  moved into it. This is only visible if you have used `SUPER+L` to pin layouts.
- Editing the plugin while it is installed needs `omarchy restart shell` —
  `keepLoaded: true` keeps the old instance alive through the inotify reload.
- **Move mode is copy-pasted, not linked.** The snippet hardcodes the plugin's
  install path and lives in your config, so it does not update when the plugin
  does, and uninstalling leaves it behind. The `pcall` makes that harmless: the
  load fails, the bindings are skipped, and the rest of `bindings.lua` still
  runs. It also means a genuine error in the plugin file looks exactly like the
  plugin not being installed.

## Development

```bash
omarchy plugin validate .            # manifest contract, exits 0 when valid
node -e '...' Reorder.js             # the permutation logic is dependency-free
omarchy restart shell                # reload after edits
```

`Reorder.js` holds all the list-permutation and Lua-codegen logic with no
Quickshell or Hyprland dependency, so it can be exercised without a compositor.

## License

MIT
