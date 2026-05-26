local hook_events = require("wayfinder.hook_events")

local M = {}

local valid_events = {}
for _, event_name in pairs(hook_events) do
  valid_events[event_name] = true
end

local handlers = {}

local function is_valid_event(event)
  return valid_events[event] == true
end

local function notify_error(message)
  vim.notify("wayfinder.hooks: " .. message, vim.log.levels.ERROR)
end

local function notify_warn(message)
  vim.notify("wayfinder.nvim: " .. message, vim.log.levels.WARN)
end

function M.on(event, fn)
  if not is_valid_event(event) then
    notify_error("unknown event '" .. tostring(event) .. "'")
    return false
  end

  if type(fn) ~= "function" then
    notify_error("must register a function")
    return false
  end

  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], fn)
  return true
end

function M.off(event, fn)
  if not is_valid_event(event) then
    notify_error("unknown event '" .. tostring(event) .. "'")
    return false
  end

  if not handlers[event] then
    return false
  end

  for index, callback in ipairs(handlers[event]) do
    if callback == fn then
      table.remove(handlers[event], index)
      return true
    end
  end

  return false
end

function M.once(event, fn)
  if type(fn) ~= "function" then
    notify_error("must register a function")
    return false
  end

  local wrapper
  wrapper = function(ctx)
    M.off(event, wrapper)
    fn(ctx)
  end

  return M.on(event, wrapper)
end

function M.emit(event, ctx)
  if not is_valid_event(event) then
    notify_error("unknown event '" .. tostring(event) .. "'")
    return 0, false
  end

  if not handlers[event] then
    return 0, true
  end

  local unpack_fn = table.unpack or unpack
  local snapshot = { unpack_fn(handlers[event]) }
  local total = 0
  local all_succeeded = true

  for _, fn in ipairs(snapshot) do
    total = total + 1
    local ok, err = pcall(fn, ctx)
    if not ok then
      all_succeeded = false
      notify_warn("hook error for event [" .. event .. "]:\n" .. tostring(err))
    end
  end

  return total, all_succeeded
end

for _, event in pairs(hook_events) do
  M["on_" .. event] = function(fn)
    return M.on(event, fn)
  end

  M["once_" .. event] = function(fn)
    return M.once(event, fn)
  end

  M["off_" .. event] = function(fn)
    return M.off(event, fn)
  end

  M["emit_" .. event] = function(ctx)
    return M.emit(event, ctx)
  end
end

function M._reset_for_testing()
  handlers = {}
end

return M
