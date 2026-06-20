-- gh-review/review.lua
-- High-level review actions: approve, request changes, add inline comment,
-- resolve/unresolve threads. Coordinates gh.lua + ui.lua + comments.lua.

local M = {}

local function state()
  return require("gh-review.diffview")._state
end

local function require_state()
  local s = state()
  if not s then
    vim.notify("gh-review: no PR open in DiffView", vim.log.levels.WARN)
    return nil
  end
  return s
end

local function ensure_commentable_lines(s, cb)
  if s.commentable_lines then
    cb(true)
    return
  end

  local gh = require("gh-review.gh")
  local dv = require("gh-review.diffview")

  gh.get_pr_files(s.owner, s.repo, s.number, function(ok, files)
    if not ok then
      cb(false, files)
      return
    end

    s.commentable_lines = dv.build_commentable_lines(files)
    cb(true)
  end)
end

local function commentable_warning(ctx)
  return string.format(
    "gh-review: %s:%d is not in a GitHub diff hunk on the %s side",
    ctx.file,
    ctx.line,
    ctx.side
  )
end

-- ── inline comment ────────────────────────────────────────────────────────────

-- Add an inline comment at the current cursor position in a DiffView diff pane.
function M.add_comment()
  local s = require_state()
  if not s then return end

  local dv  = require("gh-review.diffview")
  local gh  = require("gh-review.gh")
  local ui  = require("gh-review.ui")
  local ctx = dv.get_cursor_context()

  if not ctx then
    vim.notify("gh-review: cursor not on a commentable diff line", vim.log.levels.WARN)
    return
  end

  ensure_commentable_lines(s, function(ok, err)
    if not ok then
      vim.notify("gh-review: failed to load PR diff hunks: " .. tostring(err), vim.log.levels.ERROR)
      return
    end

    if not dv.is_commentable(ctx, s.commentable_lines) then
      vim.notify(commentable_warning(ctx), vim.log.levels.WARN)
      return
    end

    ui.open_comment_input({
      title     = string.format("Comment on %s:%d (%s)", ctx.file, ctx.line, ctx.side),
      on_submit = function(body)
        -- Need the head SHA to post the comment.
        gh.get_head_sha(s.owner, s.repo, s.number, function(ok, sha)
          if not ok then
            vim.notify("gh-review: could not get head SHA: " .. tostring(sha), vim.log.levels.ERROR)
            return
          end

          gh.post_comment({
            owner     = s.owner,
            repo      = s.repo,
            number    = s.number,
            commit_id = sha,
            path      = ctx.file,
            line      = ctx.line,
            side      = ctx.side,
            body      = body,
          }, function(post_ok, result)
            if not post_ok then
              vim.notify("gh-review: comment failed: " .. tostring(result), vim.log.levels.ERROR)
              return
            end
            vim.notify("gh-review: comment posted", vim.log.levels.INFO)
            M._reload_and_render()
          end)
        end)
      end,
    })
  end)
end

-- ── reply ─────────────────────────────────────────────────────────────────────

-- Reply to the thread nearest the cursor in a DiffView diff pane.
function M.reply_at_cursor()
  local s = require_state()
  if not s then return end

  local c_mod  = require("gh-review.comments")
  local gh     = require("gh-review.gh")
  local ui     = require("gh-review.ui")

  local thread = c_mod.thread_at_cursor(s.threads)
  if not thread then
    vim.notify("gh-review: no thread near cursor", vim.log.levels.WARN)
    return
  end

  local root = thread.comments[1]
  ui.open_comment_input({
    title     = string.format("Reply to %s's thread", root.author),
    on_submit = function(body)
      gh.reply_comment({
        owner       = s.owner,
        repo        = s.repo,
        number      = s.number,
        in_reply_to = root.database_id,
        body        = body,
      }, function(ok, err)
        if not ok then
          vim.notify("gh-review: reply failed: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify("gh-review: reply posted", vim.log.levels.INFO)
        M._reload_and_render()
      end)
    end,
  })
end

function M.open_thread_popup()
  local s = require_state()
  if not s then return end
  local c_mod = require("gh-review.comments")
  local thread = c_mod.thread_at_cursor(s.threads)
  if not thread then
    vim.notify("gh-review: no thread near cursor", vim.log.levels.WARN)
    return
  end
  c_mod.open_popup(thread)
end

function M.edit_comment_at_cursor()
  local s = require_state()
  if not s then return end

  local c_mod = require("gh-review.comments")
  local gh = require("gh-review.gh")
  local ui = require("gh-review.ui")

  local thread = c_mod.thread_at_cursor(s.threads)
  if not thread then
    vim.notify("gh-review: no thread near cursor", vim.log.levels.WARN)
    return
  end

  gh.whoami(function(ok, me)
    if not ok then
      vim.notify("gh-review: could not detect current user", vim.log.levels.ERROR)
      return
    end

    local target = nil
    for i = #thread.comments, 1, -1 do
      if thread.comments[i].author == me then
        target = thread.comments[i]
        break
      end
    end

    if not target or not target.database_id then
      vim.notify("gh-review: no editable comment by you in this thread", vim.log.levels.WARN)
      return
    end

    ui.open_comment_input({
      title = "Edit comment",
      prefill = target.body or "",
      on_submit = function(body)
        gh.edit_comment({
          owner = s.owner,
          repo = s.repo,
          comment_id = target.database_id,
          body = body,
        }, function(edit_ok, err)
          if not edit_ok then
            vim.notify("gh-review: edit failed: " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          vim.notify("gh-review: comment updated", vim.log.levels.INFO)
          M._reload_and_render()
        end)
      end,
    })
  end)
end

-- ── resolve / unresolve ───────────────────────────────────────────────────────

-- Toggle resolve state of the thread nearest the cursor.
function M.toggle_resolve()
  local s = require_state()
  if not s then return end

  local c_mod  = require("gh-review.comments")
  local gh     = require("gh-review.gh")

  local thread = c_mod.thread_at_cursor(s.threads)
  if not thread then
    vim.notify("gh-review: no thread near cursor", vim.log.levels.WARN)
    return
  end

  if thread.is_resolved then
    gh.unresolve_thread(s.owner, s.repo, thread.id, function(ok, err)
      if not ok then
        vim.notify("gh-review: unresolve failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      thread.is_resolved = false
      vim.notify("gh-review: thread unresolved", vim.log.levels.INFO)
      M._reload_and_render()
    end)
  else
    gh.resolve_thread(s.owner, s.repo, thread.id, function(ok, err)
      if not ok then
        vim.notify("gh-review: resolve failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      thread.is_resolved = true
      vim.notify("gh-review: thread resolved", vim.log.levels.INFO)
      M._reload_and_render()
    end)
  end
end

-- ── submit review ─────────────────────────────────────────────────────────────

-- Open the review submission UI (approve / request changes / comment).
function M.submit_review()
  local s = require_state()
  if not s then return end

  local gh = require("gh-review.gh")
  local ui = require("gh-review.ui")

  ui.open_review_picker(function(event, body)
    gh.submit_review(s.owner, s.repo, s.number, event, body, function(ok, err)
      if not ok then
        vim.notify("gh-review: review failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local labels = {
        APPROVE          = "approved",
        REQUEST_CHANGES  = "requested changes",
        COMMENT          = "commented",
      }
      vim.notify("gh-review: " .. (labels[event] or "submitted"), vim.log.levels.INFO)
    end)
  end)
end

-- ── assign self as reviewer ───────────────────────────────────────────────────

function M.assign_self()
  local s = require_state()
  if not s then return end

  local gh = require("gh-review.gh")

  gh.whoami(function(ok, username)
    if not ok then
      vim.notify("gh-review: could not detect username", vim.log.levels.ERROR)
      return
    end

    gh.request_review(s.owner, s.repo, s.number, username, function(req_ok, err)
      if not req_ok then
        vim.notify("gh-review: assign failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("gh-review: assigned " .. username .. " as reviewer", vim.log.levels.INFO)
    end)
  end)
end

-- ── thread navigation ─────────────────────────────────────────────────────────

-- Jump to next thread in the current diff pane.
function M.next_thread()
  local s = require_state()
  if not s or not s.threads or #s.threads == 0 then return end

  local dv   = require("gh-review.diffview")
  local cmod = require("gh-review.comments")
  local win  = vim.api.nvim_get_current_win()
  local buf  = vim.api.nvim_win_get_buf(win)
  if not dv.is_diff_buf(buf) then return end

  local file   = dv.buf_file_path(buf)
  local side   = dv.detect_side(win)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]

  -- First try cycling active thread within current file/side.
  local cycled = cmod.cycle_active(s.threads, 1)
  if cycled then
    cmod.render(s.threads)
    vim.api.nvim_win_set_cursor(win, { cycled.line or cursor, 0 })
    vim.cmd("normal! zz")
    return
  end

  -- Otherwise move to next thread in this file/side.
  local here = {}
  for _, t in ipairs(s.threads) do
    if t.path == file and t.side == side then
      table.insert(here, t)
    end
  end
  table.sort(here, function(a, b) return (a.line or 0) < (b.line or 0) end)

  for _, t in ipairs(here) do
    if (t.line or 0) > cursor then
      vim.api.nvim_win_set_cursor(win, { t.line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
  vim.notify("gh-review: no more threads below", vim.log.levels.INFO)
end

-- Jump to previous thread.
function M.prev_thread()
  local s = require_state()
  if not s or not s.threads or #s.threads == 0 then return end

  local dv   = require("gh-review.diffview")
  local cmod = require("gh-review.comments")
  local win  = vim.api.nvim_get_current_win()
  local buf  = vim.api.nvim_win_get_buf(win)
  if not dv.is_diff_buf(buf) then return end

  local file   = dv.buf_file_path(buf)
  local side   = dv.detect_side(win)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]

  local cycled = cmod.cycle_active(s.threads, -1)
  if cycled then
    cmod.render(s.threads)
    vim.api.nvim_win_set_cursor(win, { cycled.line or cursor, 0 })
    vim.cmd("normal! zz")
    return
  end

  local here = {}
  for _, t in ipairs(s.threads) do
    if t.path == file and t.side == side then
      table.insert(here, t)
    end
  end
  table.sort(here, function(a, b) return (a.line or 0) > (b.line or 0) end)

  for _, t in ipairs(here) do
    if (t.line or 0) < cursor then
      vim.api.nvim_win_set_cursor(win, { t.line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
  vim.notify("gh-review: no more threads above", vim.log.levels.INFO)
end

-- ── internal: reload threads + re-render ─────────────────────────────────────

function M._reload_and_render()
  local s = state()
  if not s then return end

  local dv = require("gh-review.diffview")
  local threads_mod = require("gh-review.threads")

  dv.refresh_threads(function(state_after_refresh)
    if threads_mod.is_open() then
      threads_mod.refresh(state_after_refresh)
    end
  end)
end

return M
