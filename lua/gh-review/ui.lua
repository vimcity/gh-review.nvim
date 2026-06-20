-- gh-review/ui.lua
-- Floating scratch buffer for writing comments and review bodies.
-- <C-s> submits, q/<Esc> cancels.

local M = {}

-- ── open comment input float ──────────────────────────────────────────────────

-- opts:
--   title     string    window title (shown in border)
--   on_submit function(body: string)  called with trimmed body on submit
--   on_cancel function?               called if user cancels
--   prefill   string?                 initial content (e.g. for edit)
--   width     number?                 override default width
--   height    number?                 override default height
function M.open_comment_input(opts)
  opts = opts or {}

  local width  = opts.width  or math.min(80, math.floor(vim.o.columns * 0.6))
  local height = opts.height or 12
  local title  = opts.title  or "Add comment"

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "markdown"  -- syntax highlighting for comment body

  -- Pre-fill content if provided
  if opts.prefill and opts.prefill ~= "" then
    local prefill_lines = vim.split(opts.prefill, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill_lines)
  end

  -- Centre the float
  local row = math.floor((vim.o.lines   - height) / 2)
  local col = math.floor((vim.o.columns - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    title    = " " .. title .. " ",
    title_pos = "center",
    footer   = " <C-s> submit  <Esc>/<C-c> cancel ",
    footer_pos = "center",
  })

  -- Window options
  local wo = vim.wo[win]
  wo.wrap        = true
  wo.linebreak   = true
  wo.cursorline  = false
  wo.number      = false
  wo.signcolumn  = "no"

  -- Start in insert mode
  vim.cmd("startinsert")

  -- ── keymaps ──────────────────────────────────────────────────────────────

  local kopt = { noremap = true, silent = true, buffer = buf, nowait = true }

  local function submit()
    local body_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(body_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    vim.api.nvim_win_close(win, true)
    if body ~= "" then
      opts.on_submit(body)
    else
      vim.notify("gh-review: empty comment, not submitted", vim.log.levels.WARN)
    end
  end

  local function cancel()
    vim.api.nvim_win_close(win, true)
    if opts.on_cancel then opts.on_cancel() end
  end

  -- Submit: Ctrl-s in both normal and insert mode
  vim.keymap.set("n", "<C-s>", submit, kopt)
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd("stopinsert")
    submit()
  end, kopt)

  -- Cancel
  vim.keymap.set("n", "q",     cancel, kopt)
  vim.keymap.set("n", "<Esc>", cancel, kopt)
  vim.keymap.set("i", "<C-c>", function()
    vim.cmd("stopinsert")
    cancel()
  end, kopt)

  -- Close on BufLeave (clicking away)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once   = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if opts.on_cancel then opts.on_cancel() end
    end,
  })

  return buf, win
end

-- ── review action picker ──────────────────────────────────────────────────────

-- Show a simple selection menu for review actions.
-- items: list of { label, value }
-- cb(value) called with selected value, or nil if cancelled.
function M.pick(title, items, cb)
  local labels = vim.tbl_map(function(i) return i.label end, items)

  vim.ui.select(labels, { prompt = title }, function(choice)
    if not choice then cb(nil); return end
    for _, item in ipairs(items) do
      if item.label == choice then
        cb(item.value)
        return
      end
    end
    cb(nil)
  end)
end

-- ── review submission flow ────────────────────────────────────────────────────

-- Opens picker to choose review event, then optionally a body input float.
-- on_submit(event, body) called with event ("APPROVE"|"REQUEST_CHANGES"|"COMMENT") and body.
function M.open_review_picker(on_submit)
  M.pick("Submit review", {
    { label = "✓  Approve",          value = "APPROVE"         },
    { label = "✗  Request changes",  value = "REQUEST_CHANGES" },
    { label = "●  Comment only",     value = "COMMENT"         },
  }, function(event)
    if not event then return end

    if event == "APPROVE" then
      -- Approve doesn't need a body — but offer one.
      M.open_comment_input({
        title     = "Approve PR (optional message)",
        on_submit = function(body) on_submit(event, body) end,
        on_cancel = function()    on_submit(event, "")   end,
      })
    else
      M.open_comment_input({
        title     = event == "REQUEST_CHANGES"
                      and "Request changes — describe what to fix"
                       or "Comment on PR",
        on_submit = function(body) on_submit(event, body) end,
      })
    end
  end)
end

return M
