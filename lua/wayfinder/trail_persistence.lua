local state = require("wayfinder.state")
local trail = require("wayfinder.trail")
local trail_store = require("wayfinder.trail_store")
local paths = require("wayfinder.util.paths")
local hooks = require("wayfinder.hooks")
local hook_events = require("wayfinder.hook_events")
local trail_context = require("wayfinder.trail_context")

local M = {}

local function normalize_name(name)
  if type(name) ~= "string" then
    return nil
  end

  local trimmed = vim.trim(name)
  if trimmed == "" then
    return nil
  end

  return trimmed
end

local function resolve_project_root(opts)
  opts = opts or {}
  if opts.project_root then
    return paths.normalize(opts.project_root)
  end

  local session = state.current
  if session and session.project_root then
    return paths.normalize(session.project_root)
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local normalized_path = path ~= "" and vim.fs.normalize(path) or nil
  return trail_store.project_root(normalized_path, vim.uv.cwd())
end

local function attached_name_for(project_root)
  local root = paths.normalize(project_root)
  if not root or root == "" then
    return nil
  end

  local meta = state.trail_persistence
  if meta.project_root ~= root then
    return nil
  end

  return normalize_name(meta.active_name)
end

function M.project_root(opts)
  return resolve_project_root(opts)
end

function M.active_name(opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil
  end

  return attached_name_for(project_root)
end

function M.list(opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  return trail_store.list(project_root, opts)
end

function M.saved_count(opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  return trail_store.count(project_root, opts)
end

function M.last_active(opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  return trail_store.last_active(project_root, opts)
end

function M.cycle(delta, opts)
  opts = opts or {}
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local names, err = trail_store.list(project_root, opts)
  if not names then
    return nil, err
  end

  if #names == 0 then
    return nil, "no_saved_trails"
  end

  local step = delta and delta < 0 and -1 or 1
  local active_name = attached_name_for(project_root)
  local current_index = nil

  if active_name then
    for index, name in ipairs(names) do
      if name == active_name then
        current_index = index
        break
      end
    end
  end

  local target_index
  if current_index then
    target_index = ((current_index - 1 + step) % #names) + 1
  elseif step > 0 then
    target_index = 1
  else
    target_index = #names
  end

  return M.load(names[target_index], opts)
end

function M.new(opts)
  opts = opts or {}

  local meta = state.trail_persistence_state()
  local has_items = #trail.items() > 0

  if meta.active_name and meta.dirty then
    local saved, err = M.save_current(nil, opts)
    if not saved then
      return nil, err
    end
  elseif not meta.active_name and has_items and opts.discard_unsaved ~= true then
    return nil, "unsaved_trail"
  end

  trail.clear({ dirty = false })
  state.detach_trail({ dirty = false })

  return true
end

function M.save_current(name, opts)
  opts = opts or {}
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local found = trail.items()
  if #found == 0 then
    return nil, "empty"
  end

  local target_name = normalize_name(name) or attached_name_for(project_root)
  if not target_name then
    return nil, "missing_name"
  end

  local data, err = trail_store.set(project_root, {
    name = target_name,
    items = found,
  }, opts)
  if not data then
    return nil, err
  end

  state.attach_saved_trail(target_name, {
    project_root = project_root,
    dirty = false,
  })
  local saved = vim.deepcopy(data.trails[target_name])
  hooks.emit_trail_save(trail_context.current({
    event = hook_events.TRAIL_SAVE,
    project_root = project_root,
    name = target_name,
    trail_id = saved and (saved.id or saved.trail_id) or nil,
    items = saved and saved.items or found,
  }))
  return saved
end

function M.save_current_as(name, opts)
  opts = opts or {}
  local target_name = normalize_name(name)
  if not target_name then
    return nil, "missing_name"
  end

  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local active_name = attached_name_for(project_root)
  if active_name ~= target_name and not opts.overwrite then
    local exists, err = trail_store.exists(project_root, target_name, opts)
    if exists == nil then
      return nil, err
    end
    if exists then
      return nil, "name_exists"
    end
  end

  return M.save_current(target_name, opts)
end

function M.load(name, opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local target_name = normalize_name(name)
  if not target_name then
    return nil, "missing_name"
  end

  local entry, err = trail_store.get(project_root, target_name, opts)
  if not entry then
    return nil, err
  end

  local activated, activate_err = trail_store.activate(project_root, target_name, opts)
  if not activated then
    return nil, activate_err
  end

  trail.replace(activated.items, { cursor = 1, dirty = false })
  state.attach_saved_trail(target_name, {
    project_root = project_root,
    dirty = false,
  })
  hooks.emit_trail_load(trail_context.current({
    event = hook_events.TRAIL_LOAD,
    project_root = project_root,
    name = target_name,
    trail_id = activated and (activated.id or activated.trail_id) or nil,
    items = activated and activated.items or {},
  }))
  return activated
end

function M.resume(opts)
  opts = opts or {}
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local name, err = trail_store.last_active(project_root, opts)
  if err then
    return nil, err
  end
  if not name then
    return nil, "no_last_active"
  end

  local loaded, load_err = M.load(name, opts)
  if not loaded then
    return nil, load_err
  end
  hooks.emit_trail_resume(trail_context.current({
    event = hook_events.TRAIL_RESUME,
    project_root = project_root,
    name = loaded.name,
    trail_id = loaded.id or loaded.trail_id,
    items = loaded.items or {},
  }))
  return loaded
end

function M.delete(name, opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local target_name = normalize_name(name)
  if not target_name then
    return nil, "missing_name"
  end

  local existing = trail_store.get(project_root, target_name, opts)
  local updated, removed = trail_store.delete(project_root, target_name, opts)
  if not updated then
    return nil, removed
  end

  if removed and attached_name_for(project_root) == target_name then
    state.detach_trail({ dirty = #trail.items() > 0 })
  end
  if removed then
    hooks.emit_trail_delete(trail_context.current({
      event = hook_events.TRAIL_DELETE,
      project_root = project_root,
      name = target_name,
      trail_id = existing and (existing.id or existing.trail_id) or nil,
      items = existing and existing.items or {},
    }))
  end

  return updated, removed
end

function M.rename(old_name, new_name, opts)
  local project_root = resolve_project_root(opts)
  if not project_root then
    return nil, "missing_project_root"
  end

  local source_name = normalize_name(old_name)
  local target_name = normalize_name(new_name)
  if not source_name or not target_name then
    return nil, "missing_name"
  end

  local updated, err = trail_store.rename(project_root, source_name, target_name, opts)
  if not updated then
    return nil, err
  end

  if attached_name_for(project_root) == source_name then
    state.set_trail_persistence({
      active_name = target_name,
      project_root = project_root,
      detached = false,
      dirty = state.trail_persistence.dirty,
    })
  end
  local renamed = vim.deepcopy(updated.trails[target_name])
  hooks.emit_trail_rename(trail_context.current({
    event = hook_events.TRAIL_RENAME,
    project_root = project_root,
    old_name = source_name,
    new_name = target_name,
    name = target_name,
    trail_id = renamed and (renamed.id or renamed.trail_id) or nil,
    items = renamed and renamed.items or {},
  }))
  return renamed
end

return M
