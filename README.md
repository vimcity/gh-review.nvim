# gh-review.nvim

GitHub pull request review inside Neovim.

`gh-review.nvim` uses `diffview.nvim` for diff rendering and adds PR-native review workflow on top:

- open PRs by URL or number
- inspect inline review threads in diff panes
- reply, edit, resolve, and submit reviews
- browse a PR inbox for frequently reviewed repos
- drive review layout and panels from review-focused commands

## Requirements

- Neovim `0.10+`
- [`gh`](https://cli.github.com/) authenticated for your target GitHub host
- [`sindrets/diffview.nvim`](https://github.com/sindrets/diffview.nvim)

## Installation

Lazy.nvim example:

```lua
{
  "yourname/gh-review.nvim",
  dependencies = { "sindrets/diffview.nvim" },
  opts = {
    gh_host = "github.example.com",
  },
}
```

Local development example:

```lua
{
  dir = "~/Projects/gh-review.nvim",
  dependencies = { "sindrets/diffview.nvim" },
  opts = {
    gh_host = "github.example.com",
  },
}
```

Recommended Diffview config:

```lua
{
  "sindrets/diffview.nvim",
  opts = {
    enhanced_diff_hl = true,
    view = {
      default = {
        layout = "diff2_horizontal",
      },
      file_history = {
        layout = "diff2_horizontal",
      },
    },
    file_panel = {
      win_config = {
        position = "left",
        width = 36,
      },
    },
  },
}
```

## Quick Start

Open a PR from inside a repo:

```vim
:GhReviewOpen 123
```

Open a PR from a full URL:

```vim
:GhReviewOpen https://github.example.com/org/repo/pull/123
```

Inside the diff view:

- `pa` add inline comment
- `pr` reply to nearest thread
- `pe` edit your latest comment in nearest thread
- `pR` resolve or unresolve nearest thread
- `pt` expand inline thread under cursor
- `pv` open full popup thread
- `pl` open thread panel
- `ps` submit review
- `pB` toggle Diffview file panel
- `pE` focus Diffview file panel
- `pX` cycle Diffview layout

## Commands

- `:GhReviewOpen <url|number>`
- `:GhReviewThreads`
- `:GhReviewSubmit`
- `:GhReviewInbox`
- `:GhReviewCycleLayout`
- `:GhReviewToggleFiles`
- `:GhReviewFocusFiles`
- `:GhReviewFocusThreads`
- `:GhReviewHelp`

## Configuration

Default configuration:

```lua
require("gh-review").setup({
  gh_host = "github.example.com",
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
      position = "right", -- left | right, split mode only
    },
  },
  keymaps = {
    add_comment = "pa",
    reply = "pr",
    edit_comment = "pe",
    toggle_resolve = "pR",
    next_thread = "]c",
    prev_thread = "[c",
    open_popup = "pv",
    submit_review = "ps",
    open_threads = "pl",
    toggle_files = "pB",
    focus_files = "pE",
    cycle_layout = "pX",
    close = "q",
  },
})
```

### Inbox

Configure frequently reviewed repos:

```lua
inbox = {
  repos = {
    "owner/repo-one",
    "owner/repo-two",
  },
  limit = 100,
}
```

Inbox keys:

- `<CR>` open PR in Diffview
- `a` assign yourself as reviewer
- `o` open PR in browser
- `r` refresh
- `q` close

### Thread Panel

Thread panel keys:

- `<CR>` jump to thread location
- `j` / `k` move between thread entries
- `v` open full thread popup
- `r` reply
- `e` edit your latest comment
- `R` resolve or unresolve
- `f` cycle filters: all, open, mine, current file, resolved, outdated
- `q` close

Use popup mode if you want a transient review surface instead of a persistent side split:

```lua
view = {
  threads = {
    mode = "popup",
    width = 90,
    height = 26,
  },
}
```

## Help

- `:GhReviewHelp` opens native Vim help
- `:checkhealth gh-review` validates core setup

## Notes

- `gh-review.nvim` depends on `diffview.nvim` by design.
- Diffview handles diff rendering, file lists, and layout mechanics.
- `gh-review.nvim` focuses on GitHub review workflow, thread UX, and review actions.

## License

[MIT](./LICENSE)
