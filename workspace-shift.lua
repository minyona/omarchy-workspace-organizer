-- Move the *current* workspace one slot along the order, applied immediately.
--
-- This runs inside the compositor as a Lua keybinding function, so a whole
-- shift costs no subprocess and no frame is drawn mid-permutation.
--
-- Loaded from ~/.config/hypr/bindings.lua, where M.setup() installs the whole
-- move-mode keybinding:
--   local ok, ws = pcall(dofile, os.getenv("HOME")
--     .. "/.config/omarchy/plugins/minyona.workspaces/workspace-shift.lua")
--   if ok and ws then ws.setup() end
--
-- M.shift() is also usable on its own if you would rather bind your own keys.
--
-- Only the `hl` global is required. Omarchy's `o` helper is not used, so this
-- file works in a plain Hyprland Lua config too.

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

-- Move mode ------------------------------------------------------------------
--
-- A Hyprland submap is what buys us bare arrow keys: every SUPER+arrow chord is
-- already taken by Omarchy's window, group, and monitor actions. Entering the
-- submap makes Left/Right mean "move this workspace" for as long as you are in
-- it, and Esc puts the keyboard back.
--
-- This lives in the plugin rather than in the user's bindings.lua so that a fix
-- here reaches everyone on `omarchy plugin update`, instead of being frozen in
-- whatever they pasted the day they installed.

local DEFAULTS = {
  -- code:49 is the physical ` key. Bound by keycode rather than keysym because
  -- with SHIFT held that key reports "asciitilde", not "grave", so a keysym
  -- bind on GRAVE can never match. Omarchy binds its own number row the same
  -- way (code:10 is workspace 1).
  key = "SUPER + SHIFT + code:49",
  description = "Move workspace (arrows)",
  submap = "workspace-move",
  -- Toast on entry and after each move. The move is otherwise silent, and a
  -- workspace sliding one slot is easy to miss on a busy screen.
  notify = true,
  -- Leave the submap on any key that is not bound below, instead of swallowing
  -- it. Friendlier for anyone who enters the mode and forgets, but it binds
  -- Hyprland's catchall pseudo-key, so it is opt-in until proven on your setup.
  exit_on_unknown = false,
}

-- Never let a missing or renamed notification API turn a working keybinding
-- into an error.
local function toast(enabled, text)
  if not enabled then return end
  pcall(function()
    hl.notification.create({ text = text, timeout = 1400 })
  end)
end

local function leave()
  hl.dispatch(hl.dsp.submap("reset"))
end

-- An error inside a shift must not strand the caller in the submap with a
-- keyboard that looks dead, so a failure resets out of the mode and says so.
local function mover(cfg, delta)
  return function()
    local called, moved, info = pcall(M.shift, delta)
    if not called then
      leave()
      toast(cfg.notify, "workspace move failed: " .. tostring(moved))
    elseif moved then
      toast(cfg.notify, "workspace moved to slot " .. tostring(info))
    else
      toast(cfg.notify, tostring(info))
    end
  end
end

local installed = false

--- Install the move-mode submap and its entry keybinding.
---
--- Returns true on success, or false plus a reason. Calling it twice is a
--- no-op rather than a second set of binds; Hyprland clears binds on config
--- reload, so a reload re-runs this from scratch as intended.
---
---@param opts? table  any of DEFAULTS above
function M.setup(opts)
  if installed then return false, "already set up" end

  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  for k, v in pairs(opts or {}) do
    -- Typos in an options table are otherwise silent, and a mistyped `key`
    -- looks exactly like the plugin not loading at all.
    if DEFAULTS[k] == nil then return false, "unknown option: " .. tostring(k) end
    cfg[k] = v
  end

  hl.define_submap(cfg.submap, function()
    -- Hyprland matches a bind's modmask exactly. Entering this mode takes
    -- SUPER+SHIFT, and nobody releases both before reaching for an arrow, so a
    -- bare `left` (modmask 0) never matches the SUPER+SHIFT+Left that actually
    -- arrives, and the mode looks dead while sitting there active. Bind every
    -- combination that can still be held down. These are scoped to the submap,
    -- so SUPER+Left keeps its global meaning everywhere else.
    for _, held in ipairs({ "", "SHIFT + ", "SUPER + ", "SUPER + SHIFT + " }) do
      hl.bind(held .. "left",   mover(cfg, -1))
      hl.bind(held .. "right",  mover(cfg, 1))
      hl.bind(held .. "escape", leave)
      hl.bind(held .. "return", leave)
    end
    if cfg.exit_on_unknown then hl.bind("catchall", leave) end
  end)

  hl.bind(cfg.key, function()
    hl.dispatch(hl.dsp.submap(cfg.submap))
    toast(cfg.notify, "MOVE MODE  ←/→ move  Esc exit")
  end, { description = cfg.description })

  installed = true
  return true
end

return M
