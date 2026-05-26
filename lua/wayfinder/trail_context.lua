local M = {}

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.current(extra)
  extra = extra or {}

  local state = require("wayfinder.state")
  local trail = require("wayfinder.trail")

  local persistence = state.trail_persistence or {}

  local ctx = {
    event = extra.event,
    reason = extra.reason,

    project_root = extra.project_root or persistence.project_root,
    name = extra.name or persistence.active_name,
    trail_id = extra.trail_id or extra.id,

    old_name = extra.old_name,
    new_name = extra.new_name,

    item = deepcopy(extra.item),
    items = deepcopy(extra.items or trail.items()),

    cursor = trail.cursor(),
    dirty = persistence.dirty == true,
    timestamp = now(),

    source = extra.source or "wayfinder",
  }

  for key, value in pairs(extra) do
    if ctx[key] == nil then
      ctx[key] = deepcopy(value)
    end
  end

  return ctx
end

return M
