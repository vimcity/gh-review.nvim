-- gh-review/diffview.lua
-- DiffView integration: open PRs, detect diff buffers, extract file/line/side context.

local M = {}
local gh = require("gh-review.gh")

-- ── state ─────────────────────────────────────────────────────────────────────

-- Current open PR. Set when DiffView is opened via open_pr().
-- { pr, threads, owner, repo, number, head_sha }
M._state = nil

-- Callbacks to run once DiffviewViewOpened fires.
local _on_opened = {}

-- ── buffer detection ──────────────────────────────────────────────────────────

-- Returns true if buf is a DiffView diff pane (not the file panel or history).
function M.is_diff_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  local ft   = vim.bo[buf].filetype
  if ft == "DiffviewFiles" or ft == "DiffviewFileHistory" then return false end
  return ft == "diff" or name:match("^diffview://") ~= nil
end

-- Returns true if buf is the null placeholder (added/deleted file).
function M.is_null_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name:match("diffview://null") ~= nil
end

-- Extract repo-relative file path from a diffview:// buffer name.
-- diffview:// bufnames look like:
--   diffview:///abs/path/to/.git/abc1234/path/to/file.lua
--   diffview:///abs/path/to/.git/abc1234/  (null)
function M.buf_file_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  -- strip diffview:// prefix
  local path = name:match("^diffview://(.+)$")
  if not path then return nil end
  -- strip .git/<hash>/ prefix
  path = path:gsub("^.*/%.git/[0-9a-f]+/", "")
  if path == "" or path:match("^null") then return nil end
  return path
end

-- Detect which side (LEFT/RIGHT) a window is in the diff layout.
-- Looks at all diff windows in the current tabpage sorted by column.
-- leftmost = LEFT (base), rightmost = RIGHT (head).
function M.detect_side(win)
  win = win or vim.api.nvim_get_current_win()
  local tabpage = vim.api.nvim_win_get_tabpage(win)
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)

  local diff_wins = {}
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if M.is_diff_buf(b) then
      local col = vim.api.nvim_win_get_position(w)[2]
      table.insert(diff_wins, { win = w, col = col })
    end
  end

  if #diff_wins == 0 then return "RIGHT" end

  table.sort(diff_wins, function(a, b) return a.col < b.col end)

  -- Handle added/deleted files (one side is null).
  -- If leftmost is null → this file is added → only right side has content.
  -- If rightmost is null → this file is deleted → only left side has content.
  local left_buf  = vim.api.nvim_win_get_buf(diff_wins[1].win)
  local right_buf = vim.api.nvim_win_get_buf(diff_wins[#diff_wins].win)

  if M.is_null_buf(left_buf) then return "RIGHT" end
  if M.is_null_buf(right_buf) then return "LEFT" end

  -- Normal case: find where `win` sits in the sorted list.
  for i, dw in ipairs(diff_wins) do
    if dw.win == win then
      return i == 1 and "LEFT" or "RIGHT"
    end
  end

  return "RIGHT"
end

-- Return sorted diff windows for current tabpage, including null buffers.
function M.diff_windows(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)
  local result = {}
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if M.is_diff_buf(b) then
      table.insert(result, {
        win = w,
        buf = b,
        col = vim.api.nvim_win_get_position(w)[2],
        is_null = M.is_null_buf(b),
      })
    end
  end
  table.sort(result, function(a, b) return a.col < b.col end)
  return result
end

-- Layout adjustment disabled; DiffView default layout used.
function M.adjust_layout_for_null_side(_tabpage) end

-- Get current cursor position for comment placement.
-- DiffView panes show file content, so visible line number is already file line.
-- Returns { file, line, side, win, buf } or nil.
function M.get_cursor_context()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.is_diff_buf(buf) then return nil end
  if M.is_null_buf(buf) then return nil end

  local file = M.buf_file_path(buf)
  if not file then return nil end

  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local side = M.detect_side(win)

  -- Added/deleted files only allow comments on real content side.
  local diff_wins = M.diff_windows(vim.api.nvim_win_get_tabpage(win))
  if #diff_wins >= 2 then
    local left = diff_wins[1]
    local right = diff_wins[#diff_wins]
    if left.is_null and side ~= "RIGHT" then return nil end
    if right.is_null and side ~= "LEFT" then return nil end
  end

  return {
    file = file,
    line = cursor,
    side = side,
    win = win,
    buf = buf,
    cursor_line = cursor,
  }
end

local function mark_commentable(commentable, path, side, line)
  if not path or not line then return end
  commentable[path] = commentable[path] or { LEFT = {}, RIGHT = {} }
  commentable[path][side][line] = true
end

local function parse_patch(commentable, path, patch)
  if not path or type(patch) ~= "string" then return end

  local old_line
  local new_line

  for raw in patch:gmatch("([^\n]*)\n?") do
    if raw == "" then
      goto continue
    end

    local old_start, new_start = raw:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if old_start and new_start then
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
      goto continue
    end

    if old_line and new_line then
      local prefix = raw:sub(1, 1)
      if prefix == " " then
        mark_commentable(commentable, path, "LEFT", old_line)
        mark_commentable(commentable, path, "RIGHT", new_line)
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "-" then
        mark_commentable(commentable, path, "LEFT", old_line)
        old_line = old_line + 1
      elseif prefix == "+" then
        mark_commentable(commentable, path, "RIGHT", new_line)
        new_line = new_line + 1
      end
    end

    ::continue::
  end
end

function M.build_commentable_lines(files)
  local commentable = {}

  for _, file in ipairs(files or {}) do
    parse_patch(commentable, file.filename, file.patch)

    -- Diffview can show the old path for the left side of renamed files.
    if file.previous_filename and file.previous_filename ~= file.filename then
      parse_patch(commentable, file.previous_filename, file.patch)
    end
  end

  return commentable
end

function M.is_commentable(ctx, commentable)
  if not ctx or not commentable then return false end
  local by_file = commentable[ctx.file]
  if not by_file then return false end
  local by_side = by_file[ctx.side]
  return by_side and by_side[ctx.line] == true
end

-- ── open PR ───────────────────────────────────────────────────────────────────

-- Open a PR in DiffView. Fetches PR metadata then opens DiffviewOpen base...head.
-- pr_url: full GitHub URL e.g. "https://github.example.com/org/repo/pull/42"
-- on_ready: optional callback(state) when PR data is loaded and DiffView is open.
function M.open_pr(pr_url, on_ready)
  local owner, repo, number = gh.parse_pr_url(pr_url)
  if not owner then
    vim.notify("gh-review: invalid PR URL: " .. tostring(pr_url), vim.log.levels.ERROR)
    return
  end

  -- Fetch PR metadata first (need head_sha and refs for DiffviewOpen).
  gh.get_pr(owner, repo, number, function(ok, pr)
    if not ok then
      vim.notify("gh-review: failed to fetch PR: " .. tostring(pr), vim.log.levels.ERROR)
      return
    end

    -- Register on_ready callback before opening DiffView.
    if on_ready then
      table.insert(_on_opened, on_ready)
    end

    pcall(function()
      require("gh-review.comments").reset()
    end)

    M._state = {
      pr       = pr,
      threads  = nil,
      owner    = owner,
      repo     = repo,
      number   = number,
      head_sha = pr.head_sha,
    }

    vim.notify("gh-review: fetching PR commits…", vim.log.levels.INFO)

    -- Fetch the PR head via the pull/<N>/head refspec so the SHA exists locally.
    -- This does NOT checkout any branch.
    vim.system(
      { "git", "fetch", "origin",
        string.format("refs/pull/%d/head", number) },
      { text = true },
      vim.schedule_wrap(function(fetch_result)
        if fetch_result.code ~= 0 then
          -- fetch failed (e.g. GHE uses a different refspec) — try plain fetch
          vim.system(
            { "git", "fetch", "origin" },
            { text = true },
            vim.schedule_wrap(function(_)
              M._open_diffview(pr)
            end)
          )
        else
          M._open_diffview(pr)
        end
      end)
    )
  end)
end

-- Build and run the DiffviewOpen command once refs are locally available.
function M._open_diffview(pr)
  -- Prefer origin/<base_ref> (correct base, not just SHA^).
  -- Fall back to SHA^1 if the base ref isn't fetched yet.
  local base_ref = "origin/" .. pr.base_ref
  local result = vim.fn.system("git rev-parse --verify " .. base_ref .. " 2>/dev/null")
  if vim.v.shell_error ~= 0 then
    base_ref = pr.head_sha .. "^"
  end

  local cmd = string.format("DiffviewOpen %s...%s", base_ref, pr.head_sha)
  vim.cmd(cmd)
end

-- Open a PR by owner/repo/number directly (used from Neovim commands).
function M.open_pr_number(owner, repo, number, on_ready)
  local host = require("gh-review").config.gh_host
  local url = string.format("https://%s/%s/%s/pull/%d", host, owner, repo, number)
  M.open_pr(url, on_ready)
end

-- ── load threads after DiffView opens ─────────────────────────────────────────

-- Called when DiffviewViewOpened fires. Loads threads and runs queued callbacks.
function M._on_diffview_opened()
  if not M._state then return end

  M.adjust_layout_for_null_side()

  M.refresh_threads(function(state)
    pcall(function()
      require("gh-review.view").apply_open_state()
    end)

    -- Run queued on_ready callbacks.
    for _, cb in ipairs(_on_opened) do
      pcall(cb, state)
    end
    _on_opened = {}
  end)
end

function M.refresh_threads(cb)
  if not M._state then return end

  local state = M._state
  gh.get_threads(state.owner, state.repo, state.number, function(ok, threads)
    if not ok then
      vim.notify("gh-review: failed to load threads: " .. tostring(threads), vim.log.levels.WARN)
      threads = {}
    end

    state.threads = threads

    -- Render into whatever diff buffers are loaded right now.
    require("gh-review.comments").render(threads)

    if cb then
      pcall(cb, state)
    end
  end)
end

-- ── close ─────────────────────────────────────────────────────────────────────

function M.close()
  vim.cmd("DiffviewClose")
end

function M._on_diffview_closed()
  M._state = nil
  _on_opened = {}
  pcall(function()
    require("gh-review.comments").reset()
  end)
end

-- ── jump to file+line in DiffView ─────────────────────────────────────────────

-- Jump the DiffView diff pane to a specific file and line.
-- side: "LEFT" | "RIGHT"
-- Scans loaded diffview:// buffers for the matching file, then focuses its window.
function M.jump_to(file, line, side)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)

  -- sort by column so we can identify left vs right
  local diff_wins = {}
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if M.is_diff_buf(b) and not M.is_null_buf(b) then
      local col = vim.api.nvim_win_get_position(w)[2]
      local f   = M.buf_file_path(b)
      table.insert(diff_wins, { win = w, buf = b, col = col, file = f })
    end
  end

  table.sort(diff_wins, function(a, b) return a.col < b.col end)

  for i, dw in ipairs(diff_wins) do
    local dw_side = (i == 1) and "LEFT" or "RIGHT"
    if dw.file == file and dw_side == side then
      vim.api.nvim_set_current_win(dw.win)
      -- Move cursor to the target line, clamped to buffer length.
      local line_count = vim.api.nvim_buf_line_count(dw.buf)
      local target = math.min(line, line_count)
      vim.api.nvim_win_set_cursor(dw.win, { target, 0 })
      vim.cmd("normal! zz")  -- center the line
      return true
    end
  end

  return false
end

-- ── autocmds ─────────────────────────────────────────────────────────────────

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("GhReviewDiffview", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group   = group,
    pattern = "DiffviewViewOpened",
    once    = false,
    callback = function()
      vim.schedule(function()
        M._on_diffview_opened()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group   = group,
    pattern = "DiffviewViewClose",
    callback = function()
      vim.schedule(function()
        M._on_diffview_closed()
      end)
    end,
  })
end

return M
