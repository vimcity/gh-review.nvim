-- gh-review/init.lua
-- Setup, config, public API, keymaps, autocmds.

local M = {}

-- ── defaults ──────────────────────────────────────────────────────────────────

M.config = {
  gh_host      = "github.com",
  inbox = {
    repos = {},
    limit = 100,
  },
  view = {
    open_files = false,
    open_threads = false,
    focus = "diff", -- diff | files | threads
    threads = {
      mode = "split", -- split | popup
      width = 72,
      height = 22,
      position = "right",
    },
  },
  keymaps = {
    -- In DiffView diff panes:
    add_comment    = "pa",   -- add inline comment at cursor
    reply          = "pr",   -- reply to thread nearest cursor
    edit_comment   = "pe",   -- edit your most recent comment in nearest thread
    toggle_resolve = "pR",   -- resolve / unresolve thread nearest cursor
    next_thread    = "]c",   -- jump to next thread in current file
    prev_thread    = "[c",   -- jump to prev thread in current file
    open_popup     = "pv",   -- open full thread popup
    submit_review  = "ps",   -- open review submission UI
    open_threads   = "pl",   -- open thread list panel
    toggle_files   = "pB",   -- toggle Diffview file panel
    focus_files    = "pE",   -- focus Diffview file panel
    cycle_layout   = "pX",   -- cycle Diffview layout
    close          = "q",    -- close DiffView
  },
}

-- ── setup ─────────────────────────────────────────────────────────────────────

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Propagate host to gh module.
  require("gh-review.gh")._host = M.config.gh_host

  -- Set up highlight groups.
  require("gh-review.comments").setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("GhReviewHighlights", { clear = true }),
    callback = function() require("gh-review.comments").setup_highlights() end,
  })

  -- Set up DiffView lifecycle autocmds.
  require("gh-review.diffview").setup_autocmds()

  -- Set up diff-pane keymaps whenever a DiffView buffer is entered.
  M._setup_diffpane_autocmd()
end

-- ── diff-pane keymaps ─────────────────────────────────────────────────────────

function M._setup_diffpane_autocmd()
  local group = vim.api.nvim_create_augroup("GhReviewKeymaps", { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group    = group,
    pattern  = "diffview://*",
    callback = function(ev)
      local buf = ev.buf
      local dv  = require("gh-review.diffview")
      if not dv.is_diff_buf(buf) then return end
      if vim.b[buf].gh_review_keymaps then return end
      vim.b[buf].gh_review_keymaps = true

      local s   = dv._state
      local rev = require("gh-review.review")
      local view = require("gh-review.view")
      local km  = M.config.keymaps
      local o   = { noremap = true, silent = true, buffer = buf, nowait = true }

      vim.keymap.set("n", km.add_comment,    rev.add_comment,    o)
      vim.keymap.set("n", km.reply,          rev.reply_at_cursor, o)
      vim.keymap.set("n", km.edit_comment,   rev.edit_comment_at_cursor, o)
      vim.keymap.set("n", km.toggle_resolve, rev.toggle_resolve, o)
      vim.keymap.set("n", km.next_thread,    rev.next_thread,    o)
      vim.keymap.set("n", km.prev_thread,    rev.prev_thread,    o)
      vim.keymap.set("n", km.open_popup,     rev.open_thread_popup, o)
      vim.keymap.set("n", km.submit_review,  rev.submit_review,  o)
      vim.keymap.set("n", km.open_threads, function()
        local state = dv._state
        if not state then
          vim.notify("gh-review: no PR open", vim.log.levels.WARN)
          return
        end
        local threads_mod = require("gh-review.threads")
        if threads_mod.is_open() then
          threads_mod.close()
        else
          threads_mod.open(state)
        end
      end, o)
      vim.keymap.set("n", km.toggle_files, view.toggle_files, o)
      vim.keymap.set("n", km.focus_files, view.focus_files, o)
      vim.keymap.set("n", km.cycle_layout, view.cycle_layout, o)
      vim.keymap.set("n", km.close, function()
        require("gh-review.diffview").close()
      end, o)

      -- Render comments for this buffer if threads are already loaded.
      -- If not yet loaded, the _on_diffview_opened callback will call
      -- comments.render() which covers all loaded buffers at that point.
      vim.schedule(function()
        local state = dv._state
        if state and state.threads then
          require("gh-review.comments").render_for_buf(buf, state.threads)
        end
      end)
    end,
  })

  -- Clear keymaps flag when DiffView closes so they re-register on next open.
  vim.api.nvim_create_autocmd("User", {
    group   = group,
    pattern = "DiffviewViewClose",
    callback = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.b[buf].gh_review_keymaps = nil
        end
      end
    end,
  })
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Open a PR by URL in DiffView.
-- Example: require("gh-review").open("https://github.example.com/org/repo/pull/42")
function M.open(pr_url)
  local dv = require("gh-review.diffview")
  dv.open_pr(pr_url, function(s)
    vim.notify(
      string.format("gh-review: PR #%d loaded (%d threads)", s.number, #s.threads),
      vim.log.levels.INFO
    )
  end)
end

-- Open a PR by number in the current repo.
-- Example: require("gh-review").open_number(42)
function M.open_number(number, owner, repo)
  local dv = require("gh-review.diffview")
  if owner and repo then
    dv.open_pr_number(owner, repo, number, nil)
  else
    -- Auto-detect repo from current directory.
    local gh = require("gh-review.gh")
    gh.detect_repo(function(ok, det_owner, det_repo)
      if not ok then
        vim.notify("gh-review: could not detect repo", vim.log.levels.ERROR)
        return
      end
      dv.open_pr_number(det_owner, det_repo, number, nil)
    end)
  end
end

function M.open_inbox()
  require("gh-review.inbox").open()
end

return M
