local M = {}

local gh = require("gh-review.gh")

local BUFNAME = "gh-review://inbox"
local _buf = nil
local _win = nil
local _state = {
  items = {},
  loading = false,
}
local _line_to_item = {}
local NS = vim.api.nvim_create_namespace("gh_review_inbox")

local function config()
  return require("gh-review").config.inbox or {}
end

local function rel_time(iso)
  if not iso then return "" end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "" end
  local ok, epoch = pcall(os.time, {
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  if not ok then return "" end
  local diff = math.max(0, os.time() - epoch)
  if diff < 3600 then return math.floor(diff / 60) .. "m" end
  if diff < 86400 then return math.floor(diff / 3600) .. "h" end
  if diff < 604800 then return math.floor(diff / 86400) .. "d" end
  return math.floor(diff / 604800) .. "w"
end

local function render()
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then return end

  local lines = {
    "PR Inbox",
    string.rep("─", 72),
    "enter open  a assign self  o browser  r refresh  q close",
    "",
  }
  _line_to_item = {}

  if _state.loading then
    table.insert(lines, "Loading PRs...")
  elseif #_state.items == 0 then
    table.insert(lines, "No PRs found.")
  else
    for _, item in ipairs(_state.items) do
      local line_no = #lines + 1
      local repo = item.repository and item.repository.name or "?"
      local author = item.author and item.author.login or "unknown"
      local draft = item.isDraft and "draft" or "open"
      local line = string.format("%-24s #%-6d %-6s %-14s %-4s %s", repo, item.number, draft, author, rel_time(item.updatedAt), item.title)
      table.insert(lines, line)
      _line_to_item[line_no] = item
    end
  end

  vim.bo[_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
  vim.bo[_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(_buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(_buf, NS, "GhReviewAuthor", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(_buf, NS, "GhReviewBorder", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(_buf, NS, "GhReviewAction", 2, 0, -1)

  for line_no, item in pairs(_line_to_item) do
    local text = lines[line_no] or ""
    local author = item.author and item.author.login or "unknown"
    local author_col = text:find(author, 1, true)
    if author_col then
      vim.api.nvim_buf_add_highlight(
        _buf,
        NS,
        require("gh-review.comments").author_highlight(author),
        line_no - 1,
        author_col - 1,
        author_col - 1 + #author
      )
    end
  end
end

local function current_item()
  local win = _win and vim.api.nvim_win_is_valid(_win) and _win or 0
  local line = vim.api.nvim_win_get_cursor(win)[1]
  return _line_to_item[line]
end

local function ensure_window()
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then
    _buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(_buf, BUFNAME)
    vim.bo[_buf].buftype = "nofile"
    vim.bo[_buf].bufhidden = "wipe"
    vim.bo[_buf].swapfile = false
    vim.bo[_buf].filetype = "gh-review-inbox"
  end

  if not _win or not vim.api.nvim_win_is_valid(_win) then
    vim.cmd("botright 16split")
    _win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_win, _buf)
  else
    vim.api.nvim_set_current_win(_win)
  end

  local wo = vim.wo[_win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.wrap = false
  wo.cursorline = true
  wo.winfixheight = true
end

local function refresh()
  local repos = config().repos or {}
  _state.loading = true
  render()

  gh.search_prs({
    repos = repos,
    limit = config().limit or 100,
    sort = "updated",
  }, function(ok, items)
    _state.loading = false
    if not ok then
      vim.notify("gh-review: failed to load inbox: " .. tostring(items), vim.log.levels.ERROR)
      _state.items = {}
      render()
      return
    end
    table.sort(items, function(a, b)
      return (a.updatedAt or "") > (b.updatedAt or "")
    end)
    _state.items = items
    render()
  end)
end

local function open_current()
  local item = current_item()
  if not item then return end
  require("gh-review").open(item.url)
end

local function open_browser()
  local item = current_item()
  if not item then return end
  vim.ui.open(item.url)
end

local function assign_self()
  local item = current_item()
  if not item then return end
  local owner = item.repository and item.repository.owner and item.repository.owner.login
  local repo = item.repository and item.repository.name
  if not owner or not repo then
    owner, repo = require("gh-review.gh").parse_pr_url(item.url)
  end
  if not owner or not repo then
    vim.notify("gh-review: could not determine repo for PR", vim.log.levels.ERROR)
    return
  end

  gh.whoami(function(ok, username)
    if not ok then
      vim.notify("gh-review: could not detect username", vim.log.levels.ERROR)
      return
    end
    gh.request_review(owner, repo, item.number, username, function(req_ok, err)
      if not req_ok then
        vim.notify("gh-review: assign failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("gh-review: assigned " .. username .. " as reviewer", vim.log.levels.INFO)
      refresh()
    end)
  end)
end

local function close()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
end

local function setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = _buf, nowait = true }
  vim.keymap.set("n", "<CR>", open_current, opts)
  vim.keymap.set("n", "o", open_browser, opts)
  vim.keymap.set("n", "a", assign_self, opts)
  vim.keymap.set("n", "r", refresh, opts)
  vim.keymap.set("n", "q", close, opts)
end

function M.open()
  ensure_window()
  setup_keymaps()
  render()
  refresh()
end

return M
