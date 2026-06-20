local M = {}

function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local err = health.error or health.report_error

  start("gh-review.nvim")

  if vim.fn.executable("gh") == 1 then
    ok("GitHub CLI found")
  else
    err("GitHub CLI not found in PATH")
  end

  local diffview_ok = pcall(require, "diffview")
  if diffview_ok then
    ok("diffview.nvim available")
  else
    err("diffview.nvim not available")
  end

  local auth = vim.system({ "gh", "auth", "status" }, { text = true }):wait()
  if auth.code == 0 then
    ok("gh auth status looks healthy")
  else
    warn("gh auth status failed. Run 'gh auth status' and confirm your target host is authenticated")
  end

  local host = require("gh-review").config.gh_host
  if host and host ~= "" then
    ok("Configured gh host: " .. host)
  else
    warn("No gh_host configured")
  end
end

return M
