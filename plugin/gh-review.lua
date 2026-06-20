-- gh-review.nvim entry point.
-- Registers user commands. setup() is called by the user's lazy config.

if vim.g.loaded_gh_review then return end
vim.g.loaded_gh_review = true

local function command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts)
end

command("GhReviewOpen", function(args)
  local input = args.args
  if input:match("^https?://") then
    require("gh-review").open(input)
  elseif input:match("^%d+$") then
    require("gh-review").open_number(tonumber(input))
  else
    vim.notify("GhReviewOpen: pass a PR URL or number", vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  desc  = "Open a PR in DiffView (URL or number)",
})

command("GhReviewThreads", function()
  local dv    = require("gh-review.diffview")
  local state = dv._state
  if not state then
    vim.notify("gh-review: no PR open", vim.log.levels.WARN)
    return
  end
  local t = require("gh-review.threads")
  if t.is_open() then t.close() else t.open(state) end
end, { desc = "Toggle PR thread list panel" })

command("GhReviewSubmit", function()
  require("gh-review.review").submit_review()
end, { desc = "Submit PR review (approve / request changes / comment)" })

command("GhReviewInbox", function()
  require("gh-review.inbox").open()
end, { desc = "Open PR inbox" })

command("GhReviewCycleLayout", function()
  require("gh-review.view").cycle_layout()
end, { desc = "Cycle Diffview layout for current PR" })

command("GhReviewToggleFiles", function()
  require("gh-review.view").toggle_files()
end, { desc = "Toggle Diffview file panel" })

command("GhReviewFocusFiles", function()
  require("gh-review.view").focus_files()
end, { desc = "Focus Diffview file panel" })

command("GhReviewFocusThreads", function()
  require("gh-review.view").focus_threads()
end, { desc = "Open or focus PR thread list" })

command("GhReviewHelp", function()
  require("gh-review.help").open()
end, { desc = "Open gh-review help" })
