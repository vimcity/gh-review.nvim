local M = {}

local function in_diffview()
  return require("gh-review.diffview")._state ~= nil
end

local function with_action(action, on_missing)
  if not in_diffview() then
    vim.notify(on_missing or "gh-review: no PR open", vim.log.levels.WARN)
    return false
  end

  local ok, actions = pcall(require, "diffview.actions")
  if not ok then
    vim.notify("gh-review: diffview.actions unavailable", vim.log.levels.ERROR)
    return false
  end

  local fn = actions[action]
  if type(fn) ~= "function" then
    vim.notify("gh-review: unsupported Diffview action: " .. tostring(action), vim.log.levels.ERROR)
    return false
  end

  fn()
  return true
end

function M.cycle_layout()
  with_action("cycle_layout")
end

function M.toggle_files()
  with_action("toggle_files")
end

function M.focus_files()
  with_action("focus_files")
end

function M.focus_threads()
  local state = require("gh-review.diffview")._state
  if not state then
    vim.notify("gh-review: no PR open", vim.log.levels.WARN)
    return
  end

  require("gh-review.threads").open(state)
end

function M.apply_open_state()
  local cfg = require("gh-review").config.view or {}

  if cfg.open_files then
    with_action("focus_files")
  end

  if cfg.open_threads then
    local state = require("gh-review.diffview")._state
    if state then
      require("gh-review.threads").open(state)
    end
  end

  if cfg.focus == "files" then
    with_action("focus_files")
  elseif cfg.focus == "threads" then
    local state = require("gh-review.diffview")._state
    if state then
      require("gh-review.threads").open(state)
    end
  end
end

return M
