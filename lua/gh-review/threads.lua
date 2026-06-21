-- gh-review/threads.lua
-- Thread list buffer: shows all PR review threads, lets you jump to each one
-- in DiffView, reply, and resolve/unresolve.

local M = {}
local dv       = require("gh-review.diffview")
local comments = require("gh-review.comments")

-- ── state ─────────────────────────────────────────────────────────────────────

local _buf   = nil  -- the thread list buffer
local _win   = nil  -- the window showing it
local _state = nil  -- reference to current pr state
local _filter = "all"
local _me = nil
local _thread_starts = {}
local _current_file = nil

-- ── buffer name ───────────────────────────────────────────────────────────────

local BUFNAME = "gh-review://threads"

-- ── helpers ───────────────────────────────────────────────────────────────────

local function rel_time(iso)
  if not iso then return "" end
  local y,mo,d,h,mi,s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "" end
  local ok, epoch = pcall(os.time, {
    year=tonumber(y), month=tonumber(mo), day=tonumber(d),
    hour=tonumber(h), min=tonumber(mi), sec=tonumber(s),
  })
  if not ok then return "" end
  local diff = math.max(0, os.time() - epoch)
  if diff < 3600    then return math.floor(diff/60)     .. "m"
  elseif diff < 86400   then return math.floor(diff/3600)   .. "h"
  elseif diff < 604800  then return math.floor(diff/86400)  .. "d"
  else                       return math.floor(diff/604800) .. "w"
  end
end

-- ── line map ──────────────────────────────────────────────────────────────────
-- Maps buffer line number → thread index, so <cr> knows which thread to jump to.
local _line_to_thread = {}

local function thread_status(thread)
  if thread.is_resolved then return "resolved" end
  if thread.is_outdated then return "outdated" end
  return "open"
end

local function thread_has_author(thread, author)
  if not author then return false end
  for _, comment in ipairs(thread.comments or {}) do
    if comment.author == author then return true end
  end
  return false
end

local function editable_comment(thread)
  if not _me then return nil end
  local thread_comments = thread.comments or {}
  for i = #thread_comments, 1, -1 do
    if thread_comments[i].author == _me then
      return thread_comments[i]
    end
  end
  return nil
end

local function thread_visible(thread)
  if _filter == "open" then return not thread.is_resolved end
  if _filter == "resolved" then return thread.is_resolved end
  if _filter == "outdated" then return thread.is_outdated end
  if _filter == "mine" then return thread_has_author(thread, _me) end
  if _filter == "file" then return _current_file ~= nil and thread.path == _current_file end
  return true
end

local function current_diff_file()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if dv.is_diff_buf(buf) and not dv.is_null_buf(buf) then
    return dv.buf_file_path(buf)
  end

  local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if dv.is_diff_buf(b) and not dv.is_null_buf(b) then
      return dv.buf_file_path(b)
    end
  end

  return nil
end

local function thread_panel_config()
  local cfg = require("gh-review").config.view or {}
  return cfg.threads or {}
end

local function one_line(text, limit)
  text = (text or ""):gsub("\n", " "):gsub("%s+", " ")
  limit = limit or 72
  if #text > limit then return text:sub(1, limit - 1) .. "…" end
  return text
end

local function clip_middle(text, limit)
  text = text or ""
  limit = limit or 64
  if #text <= limit then return text end
  if limit < 10 then return text:sub(1, limit) end
  local head = math.floor((limit - 1) * 0.65)
  local tail = math.max(3, limit - head - 1)
  return text:sub(1, head) .. "…" .. text:sub(-tail)
end

local function count_visible_threads(threads)
  local count = 0
  for _, thread in ipairs(threads or {}) do
    if thread_visible(thread) then
      count = count + 1
    end
  end
  return count
end

local function add_thread_line(lines, ti, text)
  table.insert(lines, text)
  _line_to_thread[#lines] = ti
end

local function add_plain_line(lines, text)
  table.insert(lines, text)
end

local function highlight_author_span(buf, ns, line_0, text, author)
  if not author or author == "" then return end
  local start_col = text:find(author, 1, true)
  if not start_col then return end
  vim.api.nvim_buf_add_highlight(
    buf,
    ns,
    require("gh-review.comments").author_highlight(author),
    line_0,
    start_col - 1,
    start_col - 1 + #author
  )
end

local function highlight_time_span(buf, ns, line_0, text)
  local age = text:match("·%s+([%d]+[mhdw])")
  if not age then return end
  local start_col = text:find(age, 1, true)
  if not start_col then return end
  vim.api.nvim_buf_add_highlight(
    buf,
    ns,
    require("gh-review.comments").time_highlight(age),
    line_0,
    start_col - 1,
    start_col - 1 + #age
  )
end

local function highlight_reply_span(buf, ns, line_0, text)
  local icon_col = text:find("", 1, true)
  if icon_col then
    vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewReplyCount", line_0, icon_col - 1, icon_col)
  end

  local replies = text:match("%s+(%d+)")
  if not replies then return end
  local start_col = text:find(" " .. replies, 1, true)
  if not start_col then return end
  local num_col = start_col + 2
  vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewReplyCount", line_0, num_col, num_col + #replies)
end

local function highlight_reply_meta(buf, ns, line_0, text)
  local icon_col = text:find("", 1, true)
  if icon_col then
    vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewReplyCount", line_0, icon_col - 1, icon_col)
  end

  local replies = text:match("%s+(%d+)")
  if not replies then return end
  local start_col = text:find(replies, 1, true)
  if not start_col then return end
  vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewReplyCount", line_0, start_col - 1, start_col - 1 + #replies)
end

local function highlight_summary_metrics(buf, ns, line_0, text)
  local segments = {
    { icon = "", group = "GhReviewCount" },
    { icon = "", group = "GhReviewResolved" },
    { icon = "󰛨", group = "GhReviewOutdated" },
    { icon = "", group = "GhReviewAuthor" },
  }

  for _, segment in ipairs(segments) do
    local col = text:find(segment.icon, 1, true)
    if col then
      vim.api.nvim_buf_add_highlight(buf, ns, segment.group, line_0, col - 1, col)
      local num = text:match(vim.pesc(segment.icon) .. "%s+(%d+)")
      if num then
        local num_col = text:find(segment.icon .. " " .. num, 1, true)
        if num_col then
          local start = num_col + #segment.icon + 1
          vim.api.nvim_buf_add_highlight(buf, ns, segment.group, line_0, start, start + #num)
        end
      end
    end
  end
end

local function highlight_action_row(buf, ns, line_0, text)
  local key_end = 0
  for token in text:gmatch("%S+") do
    local col = text:find(token, key_end + 1, true)
    if col then
      if token:match("^<[^>]+>$") or token:match("^[a-zA-Z]$") then
        vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewFilter", line_0, col - 1, col - 1 + #token)
        key_end = col - 1 + #token
      end
    end
  end
end

local function highlight_filter_header(buf, ns, line_0, text, filter_value)
  local label = "FILTER"
  local label_col = text:find(label, 1, true)
  if label_col then
    vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewFilter", line_0, label_col - 1, label_col - 1 + #label)
  end

  if filter_value and filter_value ~= "" then
    local value_col = text:find(filter_value, 1, true)
    if value_col then
      vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewFilter", line_0, value_col - 1, value_col - 1 + #filter_value)
    end
  end

  local shown_value = text:match("|%s+([^|]+)%s+shown")
  if shown_value then
    local shown_col = text:find(shown_value, 1, true)
    if shown_col then
      vim.api.nvim_buf_add_highlight(buf, ns, "GhReviewMetric", line_0, shown_col - 1, shown_col - 1 + #shown_value)
    end
  end
end

-- ── render ────────────────────────────────────────────────────────────────────

local function render(state)
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then return end

  local threads = state.threads or {}
  local pr      = state.pr
  local lines   = {}
  comments.set_author_context(threads)
  _line_to_thread = {}
  _thread_starts = {}

  -- Header
  local header = string.format("PR #%d  %s", pr.number, one_line(pr.title, 56))
  table.insert(lines, header)
  table.insert(lines, string.rep("─", math.max(#header, 56)))

  -- Thread count summary
  local open_count     = 0
  local resolved_count = 0
  local outdated_count = 0
  local mine_count     = 0
  for _, t in ipairs(threads) do
    if t.is_resolved then resolved_count = resolved_count + 1
    else open_count = open_count + 1 end
    if t.is_outdated then outdated_count = outdated_count + 1 end
    if thread_has_author(t, _me) then mine_count = mine_count + 1 end
  end
  local visible_count = count_visible_threads(threads)
  local filter_label = _filter
  if _filter == "file" and _current_file then
    filter_label = "current diff"
  end
  local filter_value = string.upper(filter_label)
  add_plain_line(lines, string.format(
    "FILTER %s  |  %d/%d shown  |   %d   %d  󰛨 %d   %d",
    filter_value, visible_count, #threads, open_count, resolved_count, outdated_count, mine_count
  ))
  add_plain_line(lines, "<cr> open  r reply  e edit  R toggle  v view  f filter  q close")
  add_plain_line(lines, string.rep("─", 72))
  add_plain_line(lines, "")

  -- One entry per thread
  for ti, thread in ipairs(threads) do
    if not thread_visible(thread) then
      goto continue
    end

    local thread_start = #lines + 1  -- 1-based
    _thread_starts[#_thread_starts + 1] = thread_start

    -- Status glyph + path:line
    local glyph = thread.is_resolved and "✓" or (thread.is_outdated and "!" or "●")
    local path_info = string.format("%s:%s", thread.path or "?", thread.line or "?")
    local thread_comments = thread.comments or {}
    local root = thread_comments[1]
    local preview = one_line(root and root.body or "", 68)
    local reply_count = math.max(0, #thread_comments - 1)
    local reply_label = tostring(reply_count)
    local head = string.format("  %s  %s", glyph, path_info)
    local meta = string.format("     %s  ·  %s  ·   %s",
      root and root.author or "unknown",
      root and rel_time(root.created_at) or "",
      reply_label
    )
    add_thread_line(lines, ti, head)
    add_thread_line(lines, ti, meta)
    add_thread_line(lines, ti, "     " .. preview)

    table.insert(lines, "")

    -- Map every line in this thread entry → thread index
    for li = thread_start, #lines do
      _line_to_thread[li] = ti
    end

    ::continue::
  end

  if vim.tbl_isempty(_line_to_thread) then
    table.insert(lines, "  No matching review threads.")
    table.insert(lines, "")
  end

  -- Write to buffer (unlock first)
  vim.bo[_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
  vim.bo[_buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("gh_review_thread_list")
  vim.api.nvim_buf_clear_namespace(_buf, ns, 0, -1)

  -- Header highlight
  vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewAuthor", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewBorder", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewLabel", 2, 0, -1)
  vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewValue", 3, 0, -1)
  highlight_summary_metrics(_buf, ns, 2, lines[3] or "")
  highlight_action_row(_buf, ns, 3, lines[4] or "")
  highlight_filter_header(_buf, ns, 2, lines[3] or "", filter_value)

  -- Per-thread highlights
  for li, ti in pairs(_line_to_thread) do
    local thread = threads[ti]
    if thread then
      local line_0 = li - 1
      local text   = lines[li] or ""
      if text:match("^%s+[✓●!]") then
        local hl = thread.is_resolved and "GhReviewResolved"
               or  thread.is_outdated  and "GhReviewOutdated"
               or  "GhReviewCount"
        vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewBody", line_0, 0, -1)
        vim.api.nvim_buf_add_highlight(_buf, ns, hl, line_0, 2, 3)
        local path_start = text:find("  ", 4, true)
        if path_start then
          vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewPath", line_0, path_start + 1, -1)
        end
      elseif text:match("r reply") or text:match("v view") then
        vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewAction", line_0, 0, -1)
      elseif text:match("^%s+%S+%s+·%s+") then
        vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewBody", line_0, 0, -1)
        local root = (thread.comments or {})[1]
        highlight_author_span(_buf, ns, line_0, text, root and root.author or "unknown")
        highlight_time_span(_buf, ns, line_0, text)
        highlight_reply_span(_buf, ns, line_0, text)
      elseif text:match("%s+%d+") then
        vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewBody", line_0, 0, -1)
        highlight_reply_meta(_buf, ns, line_0, text)
      else
        vim.api.nvim_buf_add_highlight(_buf, ns, "GhReviewBody", line_0, 0, -1)
      end
    end
  end
end

-- ── open / close ──────────────────────────────────────────────────────────────

function M.open(state)
  _state = state
  _current_file = current_diff_file()
  require("gh-review.gh").whoami(function(ok, username)
    if ok then
      _me = username
      if _state == state and M.is_open() then
        render(state)
      end
    end
  end)

  -- Reuse existing buffer if valid.
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then
    _buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(_buf, BUFNAME)
    vim.bo[_buf].buftype    = "nofile"
    vim.bo[_buf].bufhidden  = "wipe"
    vim.bo[_buf].swapfile   = false
    vim.bo[_buf].filetype   = "gh-review-threads"
    M._setup_keymaps()
  end

  -- Open in a vertical split to the right.
  if not _win or not vim.api.nvim_win_is_valid(_win) then
    local cfg = thread_panel_config()
    if cfg.mode == "popup" then
      local width = math.min(cfg.width or 72, math.floor(vim.o.columns * 0.78))
      local height = math.min(cfg.height or 22, math.floor(vim.o.lines * 0.72))
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)
      _win = vim.api.nvim_open_win(_buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Review Threads ",
        title_pos = "center",
      })
    else
      local position = cfg.position == "left" and "topleft" or "botright"
      vim.cmd(position .. " vsplit")
      _win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(_win, _buf)
      vim.api.nvim_win_set_width(_win, cfg.width or 72)
    end

    -- Window options
    local wo = vim.wo[_win]
    wo.number         = false
    wo.relativenumber = false
    wo.signcolumn     = "no"
    wo.wrap           = false
    wo.cursorline     = true
    wo.winfixwidth    = true
    wo.foldcolumn     = "0"
    wo.colorcolumn    = ""
  else
    vim.api.nvim_set_current_win(_win)
  end

  render(state)
end

function M.close()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
  _buf = nil
end

function M.is_open()
  return _win and vim.api.nvim_win_is_valid(_win)
end

-- Refresh content (call after resolving/replying to reload threads).
function M.refresh(state)
  _state = state
  render(state)
end

-- ── actions ───────────────────────────────────────────────────────────────────

-- Get thread under cursor in the thread list buffer.
local function current_thread()
  if not _state or not _state.threads then return nil, nil end
  local cursor = vim.api.nvim_win_get_cursor(_win or 0)[1]
  local ti     = _line_to_thread[cursor]
  if not ti then return nil, nil end
  return _state.threads[ti], ti
end

-- Jump to the thread's location in DiffView.
local function jump_to_thread(thread)
  if not thread then return end
  local jumped = dv.jump_to(thread.path, thread.line or 1, thread.side)
  if not jumped then
    vim.notify(
      string.format("gh-review: file %s not open in DiffView", thread.path),
      vim.log.levels.WARN
    )
    return
  end
  comments.set_active(vim.api.nvim_get_current_buf(), thread)
  comments.render((_state or {}).threads)
end

local function reply_to_thread(thread)
  if not thread or not _state then return end
  local ui = require("gh-review.ui")
  local root_comment = (thread.comments or {})[1]
  if not root_comment or not root_comment.database_id then
    vim.notify("gh-review: no root comment to reply to", vim.log.levels.WARN)
    return
  end
  ui.open_comment_input({
    title     = "Reply to thread",
    on_submit = function(body)
      local gh = require("gh-review.gh")
      gh.reply_comment({
        owner       = _state.owner,
        repo        = _state.repo,
        number      = _state.number,
        in_reply_to = root_comment.database_id,
        body        = body,
      }, function(ok, err)
        if not ok then
          vim.notify("gh-review: reply failed: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify("gh-review: reply posted", vim.log.levels.INFO)
        M._reload_threads()
      end)
    end,
  })
end

local function edit_thread_comment(thread)
  if not thread or not _state then return end
  local gh = require("gh-review.gh")
  local ui = require("gh-review.ui")

  gh.whoami(function(ok, me)
    if not ok then
      vim.notify("gh-review: could not detect current user", vim.log.levels.ERROR)
      return
    end

    _me = me
    local target = editable_comment(thread)

    if not target or not target.database_id then
      vim.notify("gh-review: no editable comment by you in this thread", vim.log.levels.WARN)
      return
    end

    ui.open_comment_input({
      title = "Edit comment",
      prefill = target.body or "",
      on_submit = function(body)
        gh.edit_comment({
          owner = _state.owner,
          repo = _state.repo,
          comment_id = target.database_id,
          body = body,
        }, function(edit_ok, err)
          if not edit_ok then
            vim.notify("gh-review: edit failed: " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          vim.notify("gh-review: comment updated", vim.log.levels.INFO)
          M._reload_threads()
        end)
      end,
    })
  end)
end

local function toggle_thread_resolved(thread)
  if not thread or not _state then return end
  local gh = require("gh-review.gh")
  if thread.is_resolved then
    gh.unresolve_thread(_state.owner, _state.repo, thread.id, function(ok, err)
      if not ok then
        vim.notify("gh-review: unresolve failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      thread.is_resolved = false
      vim.notify("gh-review: thread unresolved", vim.log.levels.INFO)
      M._reload_threads()
    end)
  else
    gh.resolve_thread(_state.owner, _state.repo, thread.id, function(ok, err)
      if not ok then
        vim.notify("gh-review: resolve failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      thread.is_resolved = true
      vim.notify("gh-review: thread resolved", vim.log.levels.INFO)
      M._reload_threads()
    end)
  end
end

local function move_thread(delta)
  if not _win or not vim.api.nvim_win_is_valid(_win) or #_thread_starts == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(_win)[1]
  local target = nil

  if delta > 0 then
    for _, line in ipairs(_thread_starts) do
      if line > cursor then
        target = line
        break
      end
    end
    target = target or _thread_starts[1]
  else
    for i = #_thread_starts, 1, -1 do
      if _thread_starts[i] < cursor then
        target = _thread_starts[i]
        break
      end
    end
    target = target or _thread_starts[#_thread_starts]
  end

  vim.api.nvim_win_set_cursor(_win, { target, 0 })
end

-- ── keymaps ───────────────────────────────────────────────────────────────────

function M._setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = _buf, nowait = true }

  -- Jump to diff location
  vim.keymap.set("n", "<cr>", function()
    local thread = current_thread()
    jump_to_thread(thread)
  end, opts)

  vim.keymap.set("n", "r", function()
    local thread = current_thread()
    reply_to_thread(thread)
  end, opts)

  vim.keymap.set("n", "e", function()
    local thread = current_thread()
    if thread and not editable_comment(thread) then
      vim.notify("gh-review: no editable comment by you in this thread", vim.log.levels.WARN)
      return
    end
    edit_thread_comment(thread)
  end, opts)

  vim.keymap.set("n", "v", function()
    local thread = current_thread()
    comments.open_popup(thread)
  end, opts)

  vim.keymap.set("n", "R", function()
    local thread = current_thread()
    toggle_thread_resolved(thread)
  end, opts)

  vim.keymap.set("n", "f", function()
    if _filter == "all" then
      _filter = "open"
    elseif _filter == "open" then
      _filter = "mine"
    elseif _filter == "mine" then
      _current_file = current_diff_file()
      _filter = _current_file and "file" or "resolved"
    elseif _filter == "file" then
      _filter = "resolved"
    elseif _filter == "resolved" then
      _filter = "outdated"
    else
      _filter = "all"
    end
    render(_state)
  end, opts)

  -- Close thread list
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)

  vim.keymap.set("n", "j", function() move_thread(1) end, opts)
  vim.keymap.set("n", "k", function() move_thread(-1) end, opts)
  vim.keymap.set("n", "J", function() move_thread(1) end, opts)
  vim.keymap.set("n", "K", function() move_thread(-1) end, opts)
end

-- Reload threads from GitHub and re-render.
function M._reload_threads()
  if not _state then return end
  require("gh-review.diffview").refresh_threads(function(state)
    _state = state
    if _filter == "file" then
      _current_file = current_diff_file()
    end
    render(_state)
  end)
end

return M
