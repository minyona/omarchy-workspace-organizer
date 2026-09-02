.pragma library

// Pure list-permutation logic, deliberately free of any Quickshell or Hyprland
// dependency so it can be exercised with plain `qmljs`/node and reasoned about
// without a compositor. Everything here operates on arrays of workspace ids.

// Move the entry at `from` to index `to`, shifting the range between them.
// This is the insert/rotate the overlay is built around: moving 3 to the front
// of [1,2,3] yields [3,1,2], not the swap [3,2,1].
function moveEntry(order, from, to) {
  if (!order || from === to) return (order || []).slice()
  if (from < 0 || from >= order.length) return order.slice()

  var next = order.slice()
  var clampedTo = Math.max(0, Math.min(next.length - 1, to))
  var moved = next.splice(from, 1)[0]
  next.splice(clampedTo, 0, moved)
  return next
}

// Workspaces the overlay is allowed to touch: real, positive-id workspaces.
// Negative ids are special/scratchpad workspaces, which Hyprland refuses to
// renumber ("cannot change id of workspace with a managed id").
function isReorderable(id) {
  return typeof id === "number" && isFinite(id) && id > 0
}

// True when `order` is already 1..N in sequence, i.e. committing would be a
// no-op. Used to keep Enter cheap and to drive the "staged" styling.
function isIdentity(order) {
  if (!order) return true
  for (var i = 0; i < order.length; i++) {
    if (order[i] !== i + 1) return false
  }
  return true
}

// Build the Lua program that applies `order` as a compaction to 1..N.
//
// Runs as a single `hyprctl repl` program, which matters for more than the
// round-trip: the whole thing executes inside one compositor dispatch, so no
// frame is drawn between calls and the scratch ids are never visible.
//
// Two phases, never interleaved: every workspace is first parked in a high
// scratch band, then brought down into its final slot. Phase 2 addresses
// workspaces by their parked ids, so phase 1 must fully complete first.
//
// `hl.dispatch` returns a table with `.ok` on success, `{ok=false, error=...}`
// on a runtime refusal ("ID is taken"), and plain nil when the dispatcher
// itself failed to construct. Every call is checked, and any failure unwinds
// the calls already made -- reversing the list always restores into an id that
// was just vacated, so the rollback cannot collide either.
//
// Returns "OK <n>" or "ERR <reason>" on stdout.
function buildApplyLua(order) {
  var targets = []
  for (var i = 0; i < order.length; i++) {
    if (isReorderable(order[i])) targets.push(order[i])
  }
  if (!targets.length) return ""

  var luaOrder = "{" + targets.join(",") + "}"

  return [
    "local order = " + luaOrder,
    // Refuse to act on a stale view: a workspace may have been created or
    // destroyed while the overlay was open. Abort before any mutation.
    "local live = {}",
    "for _, w in ipairs(hl.get_workspaces()) do if w.id > 0 then live[#live+1] = w.id end end",
    "table.sort(live)",
    "if #live ~= #order then return 'ERR stale: ' .. #live .. ' workspaces, expected ' .. #order end",
    "local want = {}",
    "for _, id in ipairs(order) do want[id] = true end",
    "for _, id in ipairs(live) do if not want[id] then return 'ERR stale: workspace ' .. id .. ' is new' end end",
    // A band far above any live id, so every parked id is free by construction.
    "local scratch = live[#live] + 1000000",
    "if scratch + #order >= 4294967294 then return 'ERR no scratch id available' end",
    "local applied = {}",
    "local function change(from, to)",
    "  local r = hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(from), id = to }))",
    "  if type(r) ~= 'table' then return false, 'rejected ' .. from .. '->' .. to end",
    "  if not r.ok then return false, tostring(r.error or r.code) end",
    "  applied[#applied+1] = { from, to }",
    "  return true",
    "end",
    "local function rollback(msg)",
    "  for i = #applied, 1, -1 do",
    "    hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(applied[i][2]), id = applied[i][1] }))",
    "  end",
    "  return 'ERR ' .. msg .. ' (rolled back ' .. #applied .. ')'",
    "end",
    "for i, id in ipairs(order) do",
    "  local ok, err = change(id, scratch + i)",
    "  if not ok then return rollback(err) end",
    "end",
    "for i = 1, #order do",
    "  local ok, err = change(scratch + i, i)",
    "  if not ok then return rollback(err) end",
    "end",
    "return 'OK ' .. #order"
  ].join("\n")
}
