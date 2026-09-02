-- Move the *current* workspace one slot along the order, applied immediately.
--
-- This runs inside the compositor as a Lua keybinding function, so a whole
-- shift costs no subprocess and no frame is drawn mid-permutation.
--
-- Loaded from ~/.config/hypr/bindings.lua:
--   local ws = dofile(os.getenv("HOME")
--     .. "/.config/omarchy/plugins/minyona.workspaces/workspace-shift.lua")
--   o.bind("SHIFT + left",  "Move workspace left",  function() ws.shift(-1) end)

local M = {}

-- Every positive-id workspace, ascending. Negative ids are special/named
-- workspaces, which Hyprland refuses to renumber ("managed id").
local function live_ids()
  local ids = {}
  for _, w in ipairs(hl.get_workspaces()) do
    if w.id > 0 then ids[#ids + 1] = w.id end
  end
  table.sort(ids)
  return ids
end

-- The order that results from moving the active workspace by `delta` slots.
-- Returns nil plus a reason when the move is not possible.
function M.plan(delta)
  local ids = live_ids()
  local cur = hl.get_active_workspace()
  if not cur or cur.id <= 0 then return nil, "no ordinary workspace focused" end

  local at
  for i, id in ipairs(ids) do
    if id == cur.id then at = i break end
  end
  if not at then return nil, "focused workspace is not orderable" end

  local to = at + delta
  if to < 1 or to > #ids then return nil, "already at the edge" end

  local order = {}
  for i, id in ipairs(ids) do order[i] = id end
  table.insert(order, to, table.remove(order, at))
  return order, at, to
end

-- Apply an order as a compaction to 1..N.
--
-- Two phases, never interleaved: park everything in a scratch band well above
-- any live id, then bring each down into its slot. Hyprland refuses a colliding
-- change_id ("ID is taken") but only warns, so every result is checked and any
-- failure unwinds the calls already made.
function M.apply(order)
  if not order or #order == 0 then return true end

  local ids = live_ids()
  if #ids ~= #order then return false, "workspace set changed" end

  local scratch = ids[#ids] + 1000000
  if scratch + #order >= 4294967294 then return false, "no scratch id available" end

  local applied = {}

  local function change(from, to)
    local r = hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(from), id = to }))
    if type(r) ~= "table" then return false, "rejected " .. from .. "->" .. to end
    if not r.ok then return false, tostring(r.error or r.code) end
    applied[#applied + 1] = { from, to }
    return true
  end

  local function rollback()
    for i = #applied, 1, -1 do
      hl.dispatch(hl.dsp.workspace.change_id({
        workspace = tostring(applied[i][2]), id = applied[i][1]
      }))
    end
  end

  for i, id in ipairs(order) do
    local ok, err = change(id, scratch + i)
    if not ok then rollback() return false, err end
  end
  for i = 1, #order do
    local ok, err = change(scratch + i, i)
    if not ok then rollback() return false, err end
  end

  return true
end

-- Move the focused workspace by `delta` slots. Focus rides along with the
-- workspace object, so the same windows stay in front under a new number.
function M.shift(delta)
  local order, at, to = M.plan(delta)
  if not order then return false, at end

  local ok, err = M.apply(order)
  if not ok then return false, err end
  return true, to
end

return M
