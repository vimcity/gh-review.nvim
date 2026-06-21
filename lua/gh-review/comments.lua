-- gh-review/comments.lua
-- Compact inline thread summaries in DiffView plus full markdown popup.

local M = {}
local dv = require("gh-review.diffview")

local NS = vim.api.nvim_create_namespace("gh_review_comments")
local _popup = { buf = nil, win = nil, thread_id = nil }
local _active = {} -- per buffer: bufnr -> thread_key
local _author_groups = {}
local _next_author_group = 1
local _author_palette = {
  "#f38ba8",
  "#89b4fa",
  "#a6e3a1",
  "#fab387",
  "#cba6f7",
  "#f9e2af",
  "#74c7ec",
  "#f5c2e7",
  "#94e2d5",
  "#eba0ac",
  "#b4befe",
  "#89dceb",
}

local function assign_author_group(author)
  author = author or "unknown"
  if not _author_groups[author] then
    _author_groups[author] = "GhReviewAuthor" .. tostring(_next_author_group)
    _next_author_group = (_next_author_group % #_author_palette) + 1
  end
  return _author_groups[author]
end

function M.set_author_context(threads)
  _author_groups = {}
  _next_author_group = 1
  for _, thread in ipairs(threads or {}) do
    for _, comment in ipairs(thread.comments or {}) do
      assign_author_group(comment.author)
    end
  end
end

function M.author_highlight(author)
  return assign_author_group(author)
end

function M.time_highlight(age)
  if not age or age == "" then return "GhReviewTime" end
  if age:match("m$") or age:match("h$") then return "GhReviewTimeRecent" end
  local days = tonumber(age:match("^(%d+)d$"))
  if days then
    if days < 2 then return "GhReviewTimeRecent" end
    if days < 4 then return "GhReviewTimeStale" end
    return "GhReviewTimeOld"
  end
  if age:match("w$") then return "GhReviewTimeOld" end
  return "GhReviewTime"
end

function M.setup_highlights()
  local hi = vim.api.nvim_set_hl
  hi(0, "GhReviewBorder",   { fg = "#585b70", default = true })
  hi(0, "GhReviewAuthor",   { fg = "#cba6f7", bold = true, default = true })
  hi(0, "GhReviewTime",     { fg = "#6c7086", default = true })
  hi(0, "GhReviewTimeRecent", { fg = "#a6e3a1", bold = true, default = true })
  hi(0, "GhReviewTimeStale", { fg = "#f9e2af", default = true })
  hi(0, "GhReviewTimeOld", { fg = "#f38ba8", default = true })
  hi(0, "GhReviewResolved", { fg = "#a6e3a1", default = true })
  hi(0, "GhReviewOutdated", { fg = "#f9e2af", default = true })
  hi(0, "GhReviewBody",     { fg = "#cdd6f4", default = true })
  hi(0, "GhReviewPath",     { fg = "#cba6f7", default = true })
  hi(0, "GhReviewGuide",    { fg = "#45475a", default = true })
  hi(0, "GhReviewCount",    { fg = "#89b4fa", default = true })
  hi(0, "GhReviewDim",      { fg = "#7f849c", default = true })
  hi(0, "GhReviewAction",   { fg = "#94e2d5", default = true })
  hi(0, "GhReviewMetric",   { fg = "#89b4fa", bold = true, default = true })
  hi(0, "GhReviewFilter",   { fg = "#fab387", bold = true, default = true })
  hi(0, "GhReviewReplyCount", { fg = "#b4befe", bold = true, default = true })
  hi(0, "GhReviewSide", { fg = "#fab387", default = true })
  hi(0, "GhReviewLabel", { fg = "#7f849c", default = true })
  hi(0, "GhReviewValue", { fg = "#cdd6f4", default = true })
  hi(0, "GhReviewInlineOpen", { bg = "#1f2335", default = true })
  hi(0, "GhReviewInlineResolved", { bg = "#1d2b27", default = true })
  hi(0, "GhReviewInlineOutdated", { bg = "#2c2720", default = true })
  hi(0, "GhReviewInlineActive", { bg = "#2a2f44", default = true })
  hi(0, "GhReviewAnchor", { fg = "#f5c2e7", bold = true, default = true })
  for i, color in ipairs(_author_palette) do
    hi(0, "GhReviewAuthor" .. tostring(i), { fg = color, bold = true, default = true })
  end
end

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
  if diff < 3600 then return math.floor(diff/60) .. "m"
  elseif diff < 86400 then return math.floor(diff/3600) .. "h"
  elseif diff < 604800 then return math.floor(diff/86400) .. "d"
  else return math.floor(diff/604800) .. "w" end
end

local function wrap(text, width)
  text = (text or ""):gsub("\r", "")
  width = math.max(width, 12)
  local lines = {}
  for _, raw in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if raw == "" then
      table.insert(lines, "")
    else
      local current = ""
      for word in raw:gmatch("%S+") do
        if current == "" then
          current = word
        elseif #current + 1 + #word <= width then
          current = current .. " " .. word
        else
          table.insert(lines, current)
          current = word
        end
      end
      if current ~= "" then table.insert(lines, current) end
    end
  end
  return lines
end

local function sanitize_text(text)
  return (text or ""):gsub("\r", "")
end

local function thread_key(thread)
  return thread.id or (thread.path or "?") .. ":" .. tostring(thread.line or 1)
end

function M.set_active(buf, thread)
  if not buf or not thread then return end
  _active[buf] = thread_key(thread)
end

function M.get_active_key(buf)
  return _active[buf]
end

function M.is_active(buf, thread)
  return _active[buf] == thread_key(thread)
end

function M.reset()
  _active = {}
  M.close_popup()
end

local function render_summary(thread, active, width)
  local root = thread.comments and thread.comments[1] or nil
  local author = root and root.author or "unknown"
  local age = root and rel_time(root.created_at) or ""
  local body = root and (root.body or "") or ""
  body = body:gsub("\n", " ")
  local comment_count = #(thread.comments or {})
  local replies = math.max(0, comment_count - 1)
  local badge = thread.is_resolved and "✓ resolved"
    or thread.is_outdated and "outdated"
    or "open"
  local side = thread.side == "LEFT" and "base" or "head"
  local reply_label = replies == 1 and "1 reply" or (replies .. " replies")
  local meta = string.format("%s · %s · %s · %s · %s  ", author, age, reply_label, side, badge)
  local text_width = math.max((width or 72) - vim.fn.strdisplaywidth(meta) - 2, 20)
  local wrapped = wrap(body, text_width)
  local preview = wrapped[1] or ""
  local truncated = #wrapped > 1
  if truncated then preview = preview .. "…" end
  local prefix = "•"
  local marker_hl = active and "GhReviewAuthor" or "GhReviewCount"

  return {
    {
      { prefix .. " ",                     marker_hl },
      { author,                             M.author_highlight(author) },
      { " · " .. age .. " · ",            M.time_highlight(age) },
      { reply_label,                        "GhReviewReplyCount" },
      { " · " .. side .. " · ",           "GhReviewSide" },
      { badge,                              thread.is_resolved and "GhReviewResolved" or thread.is_outdated and "GhReviewOutdated" or "GhReviewCount" },
      { "  " .. preview,                   "GhReviewBody" },
    },
  }
end

local function score_thread_distance(thread, cursor_line)
  if not cursor_line then return 0 end
  local distance = math.abs((thread.line or 1) - cursor_line)
  if distance == 0 then return 0 end
  if distance <= 2 then
    return distance
  end
  return nil
end

local function get_diff_wins()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)
  local result = {}
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if dv.is_diff_buf(b) and not dv.is_null_buf(b) then
      table.insert(result, {
        win = w,
        buf = b,
        col = vim.api.nvim_win_get_position(w)[2],
        file = dv.buf_file_path(b),
      })
    end
  end
  table.sort(result, function(a, b) return a.col < b.col end)
  for i, dw in ipairs(result) do
    dw.side = (i == 1) and "LEFT" or "RIGHT"
  end
  return result
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end
end

function M.clear_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and dv.is_diff_buf(buf) then
      M.clear(buf)
    end
  end
end

local function place_thread(thread, diff_wins)
  for _, dw in ipairs(diff_wins) do
    if dw.file == thread.path and dw.side == thread.side then
      local line_count = vim.api.nvim_buf_line_count(dw.buf)
      local target = math.min(thread.line or 1, line_count) - 1
      local active = M.is_active(dw.buf, thread)
      local width = math.floor(vim.api.nvim_win_get_width(dw.win) * 0.9)
      local anchor = thread.is_resolved and "✓ " or (thread.is_outdated and "! " or "● ")
      local virt_lines = render_summary(thread, active, width)
      vim.api.nvim_buf_set_extmark(dw.buf, NS, target, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
        virt_text = {
          { anchor, "GhReviewAnchor" },
        },
        virt_text_pos = "inline",
        sign_text = active and "◆" or (thread.is_resolved and "✓" or (thread.is_outdated and "!" or "●")),
        sign_hl_group = active and "GhReviewAuthor" or (thread.is_resolved and "GhReviewResolved" or "GhReviewCount"),
        line_hl_group = active and "GhReviewInlineActive" or (thread.is_resolved and "GhReviewInlineResolved" or (thread.is_outdated and "GhReviewInlineOutdated" or "GhReviewInlineOpen")),
        number_hl_group = active and "GhReviewAnchor" or (thread.is_resolved and "GhReviewResolved" or (thread.is_outdated and "GhReviewOutdated" or "GhReviewCount")),
        priority = 200,
      })
      return
    end
  end
end

function M.render(threads)
  M.clear_all()
  if not threads or #threads == 0 then return end
  M.set_author_context(threads)
  local diff_wins = get_diff_wins()
  if #diff_wins == 0 then return end
  for _, dw in ipairs(diff_wins) do
    if not _active[dw.buf] then
      for _, thread in ipairs(threads) do
        if thread.path == dw.file and thread.side == dw.side then
          _active[dw.buf] = thread_key(thread)
          break
        end
      end
    end
  end
  for _, thread in ipairs(threads) do
    place_thread(thread, diff_wins)
  end
end

function M.render_for_buf(buf, threads)
  if not threads or #threads == 0 then return end
  M.set_author_context(threads)
  M.clear(buf)
  local diff_wins = get_diff_wins()
  for _, thread in ipairs(threads) do
    place_thread(thread, diff_wins)
  end
end

function M.thread_at_cursor(threads)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not dv.is_diff_buf(buf) then return nil end
  local file = dv.buf_file_path(buf)
  local side = dv.detect_side(win)
  local ctx = dv.get_cursor_context()
  local cursor_line = ctx and ctx.line or nil
  local best = nil
  local best_distance = nil
  for _, thread in ipairs(threads or {}) do
    if thread.path == file and thread.side == side then
      local distance = score_thread_distance(thread, cursor_line)
      if distance and (not best or distance < best_distance) then
        best = thread
        best_distance = distance
      end
    end
  end
  if best then
    _active[buf] = thread_key(best)
  end
  return best
end

function M.cycle_active(threads, direction)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not dv.is_diff_buf(buf) then return nil end
  local file = dv.buf_file_path(buf)
  local side = dv.detect_side(win)
  local here = {}
  for _, thread in ipairs(threads or {}) do
    if thread.path == file and thread.side == side then
      table.insert(here, thread)
    end
  end
  if #here == 0 then return nil end
  table.sort(here, function(a, b) return (a.line or 0) < (b.line or 0) end)
  local current = _active[buf]
  local idx = 1
  for i, thread in ipairs(here) do
    if thread_key(thread) == current then idx = i break end
  end
  idx = idx + direction
  if idx < 1 then idx = #here end
  if idx > #here then idx = 1 end
  _active[buf] = thread_key(here[idx])
  return here[idx]
end

local function thread_markdown(thread)
  local out = {}
  local status = thread.is_resolved and "resolved" or thread.is_outdated and "outdated" or "open"
  table.insert(out, string.format("# %s:%s", thread.path or "?", thread.line or "?"))
  table.insert(out, "")
  table.insert(out, string.format("%s side, %s", thread.side == "LEFT" and "base" or "head", status))
  table.insert(out, "")
  for i, comment in ipairs(thread.comments) do
    local prefix = comment.reply_to_id and "## Reply" or "## Comment"
    table.insert(out, string.format("%s %d", prefix, i))
    table.insert(out, "")
    table.insert(out, string.format("**%s** · %s", comment.author or "unknown", rel_time(comment.created_at)))
    table.insert(out, "")
    for _, line in ipairs(vim.split(sanitize_text(comment.body), "\n", { plain = true })) do
      table.insert(out, line)
    end
    table.insert(out, "")
  end
  return out
end

local function reply_to_thread_popup(thread)
  local state = require("gh-review.diffview")._state
  if not state then
    vim.notify("gh-review: no PR open", vim.log.levels.WARN)
    return
  end

  local root = (thread.comments or {})[1]
  if not root or not root.database_id then
    vim.notify("gh-review: no root comment to reply to", vim.log.levels.WARN)
    return
  end

  require("gh-review.ui").open_comment_input({
    title = "Reply to thread",
    on_submit = function(body)
      require("gh-review.gh").reply_comment({
        owner = state.owner,
        repo = state.repo,
        number = state.number,
        in_reply_to = root.database_id,
        body = body,
      }, function(ok, err)
        if not ok then
          vim.notify("gh-review: reply failed: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify("gh-review: reply posted", vim.log.levels.INFO)
        require("gh-review.review")._reload_and_render()
      end)
    end,
  })
end

function M.close_popup()
  if _popup.win and vim.api.nvim_win_is_valid(_popup.win) then
    vim.api.nvim_win_close(_popup.win, true)
  end
  _popup = { buf = nil, win = nil, thread_id = nil }
end

function M.open_popup(thread)
  if not thread then return end
  M.close_popup()
  local width = math.min(110, math.floor(vim.o.columns * 0.72))
  local height = math.min(30, math.floor(vim.o.lines * 0.78))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, thread_markdown(thread))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Review Thread ",
    title_pos = "center",
    footer = " r reply  q close ",
    footer_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].conceallevel = 2
  vim.bo[buf].modifiable = false

  local popup_ns = vim.api.nvim_create_namespace("gh_review_popup")
  vim.api.nvim_buf_clear_namespace(buf, popup_ns, 0, -1)
  local popup_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, text in ipairs(popup_lines) do
    local author = text:match("^%*%*([^*]+)%*%*%s+·")
    if author then
      local start_col = text:find(author, 1, true)
      if start_col then
        vim.api.nvim_buf_add_highlight(buf, popup_ns, M.author_highlight(author), i - 1, start_col - 1, start_col - 1 + #author)
      end
      local age = text:match("·%s+([%d]+[mhdw])")
      if age then
        local age_col = text:find(age, 1, true)
        if age_col then
          vim.api.nvim_buf_add_highlight(buf, popup_ns, M.time_highlight(age), i - 1, age_col - 1, age_col - 1 + #age)
        end
      end
    elseif text:match("^# ") then
      vim.api.nvim_buf_add_highlight(buf, popup_ns, "GhReviewMetric", i - 1, 0, -1)
    elseif text:match("^## ") then
      vim.api.nvim_buf_add_highlight(buf, popup_ns, "GhReviewAction", i - 1, 0, -1)
    elseif text:match("resolved$") or text:match("outdated$") or text:match("open$") then
      local hl = text:match("resolved$") and "GhReviewResolved" or (text:match("outdated$") and "GhReviewOutdated" or "GhReviewCount")
      vim.api.nvim_buf_add_highlight(buf, popup_ns, hl, i - 1, 0, -1)
    end
  end

  pcall(function()
    local ok, rm = pcall(require, "render-markdown")
    if ok and rm and rm.enable then
      rm.enable(buf)
    end
  end)

  vim.keymap.set("n", "q", M.close_popup, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", M.close_popup, { buffer = buf, silent = true })
  vim.keymap.set("n", "r", function() reply_to_thread_popup(thread) end, { buffer = buf, silent = true })

  _popup = { buf = buf, win = win, thread_id = thread_key(thread) }
end

return M
