-- gh-review/gh.lua
-- Direct gh CLI wrapper. No Snacks dependency.
-- All calls use vim.system (non-blocking, callback-based).

local M = {}
local _whoami = nil

-- ── config ────────────────────────────────────────────────────────────────────

-- Set by init.lua from user config
M._host = nil  -- e.g. "github.example.com"

local function gh_env()
  if M._host then
    return { GH_HOST = M._host }
  end
  return {}
end

-- ── low-level ─────────────────────────────────────────────────────────────────

-- Run gh CLI, call cb(ok, data) on the main thread.
-- ok: boolean. data: parsed JSON table on success, error string on failure.
local function gh_json(args, cb)
  vim.system(
    vim.list_extend({ "gh" }, args),
    { text = true, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local err = (result.stderr or ""):gsub("%s+$", "")
        cb(false, err)
        return
      end
      local ok, parsed = pcall(vim.json.decode, result.stdout or "")
      if not ok then
        cb(false, "JSON parse error: " .. tostring(parsed))
        return
      end
      cb(true, parsed)
    end)
  )
end

-- Run gh CLI, call cb(ok, stdout_string) — no JSON parsing.
local function gh_cmd(args, cb)
  vim.system(
    vim.list_extend({ "gh" }, args),
    { text = true, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local err = (result.stderr or ""):gsub("%s+$", "")
        cb(false, err)
      else
        cb(true, (result.stdout or ""):gsub("%s+$", ""))
      end
    end)
  )
end

local function trim(s)
  return (s or ""):gsub("%s+$", "")
end

-- GraphQL helper — strips the data.<key>.nodes wrapper automatically.
-- query: GraphQL query string with $owner, $name, $number variables.
-- vars: { owner, name, number }
-- cb(ok, data) where data is the raw `data` field of the response.
local function gh_graphql(query, vars, cb)
  local args = {
    "api", "graphql",
    "--field", "query=" .. query,
    "--field", "owner=" .. vars.owner,
    "--field", "name=" .. vars.name,
    "--field", "number=" .. tostring(vars.number),
  }
  gh_json(args, function(ok, result)
    if not ok then cb(false, result); return end
    cb(true, result.data or result)
  end)
end

-- ── repo detection ─────────────────────────────────────────────────────────────

-- Extract "owner/repo" from a GitHub URL.
-- e.g. "https://github.example.com/org/repo/pull/42" → "org", "repo"
function M.parse_pr_url(url)
  -- strip protocol + host, leaving /owner/repo/pull/N
  local path = url:match("https?://[^/]+/(.+)")
  if not path then return nil, nil, nil end
  local owner, repo, number = path:match("^([^/]+)/([^/]+)/pull/(%d+)")
  return owner, repo, tonumber(number)
end

-- Get "owner/repo" for the current git directory (async).
-- cb(ok, owner, repo)
function M.detect_repo(cb)
  vim.system(
    { "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" },
    { text = true, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, nil, nil)
        return
      end
      local nwo = (result.stdout or ""):gsub("%s+$", "")
      local owner, repo = nwo:match("^([^/]+)/(.+)$")
      cb(true, owner, repo)
    end)
  )
end

-- ── PR metadata ───────────────────────────────────────────────────────────────

-- Fetch minimal PR metadata needed to open DiffView.
-- cb(ok, pr) where pr = { number, title, head_sha, base_ref, head_ref, repo, owner }
function M.get_pr(owner, repo, number, cb)
  gh_json({
    "pr", "view", tostring(number),
    "--repo", owner .. "/" .. repo,
    "--json", "number,title,headRefOid,baseRefName,headRefName,state,isDraft",
  }, function(ok, data)
    if not ok then cb(false, data); return end
    cb(true, {
      number   = data.number,
      title    = data.title,
      head_sha = data.headRefOid,
      base_ref = data.baseRefName,
      head_ref = data.headRefName,
      state    = data.state,
      is_draft = data.isDraft,
      owner    = owner,
      repo     = repo,
    })
  end)
end

-- Fetch files changed in a PR, including GitHub's unified patch hunks.
-- cb(ok, files) where files = [{ filename, previous_filename, status, patch }]
function M.get_pr_files(owner, repo, number, cb)
  gh_json({
    "api",
    string.format("/repos/%s/%s/pulls/%d/files?per_page=100", owner, repo, number),
    "--paginate",
    "--slurp",
  }, function(ok, pages)
    if not ok then cb(false, pages); return end

    local files = {}
    for _, page in ipairs(pages or {}) do
      for _, file in ipairs(page or {}) do
        table.insert(files, {
          filename          = type(file.filename) == "string" and file.filename or nil,
          previous_filename = type(file.previous_filename) == "string" and file.previous_filename or nil,
          status            = type(file.status) == "string" and file.status or nil,
          patch             = type(file.patch) == "string" and file.patch or nil,
        })
      end
    end

    cb(true, files)
  end)
end

-- ── comments / review threads ─────────────────────────────────────────────────

-- Minimal GraphQL query — only inline review comments and their threads.
-- Returns threads with full comment chain, resolved state, and diff side.
local REVIEWS_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          diffSide
          line
          originalLine
          path
          comments(first: 50) {
            nodes {
              databaseId
              id
              body
              createdAt
              author { login }
              replyTo { id }
              diffHunk
              line
              originalLine
              startLine
              originalStartLine
            }
          }
        }
      }
    }
  }
}
]]

-- Fetch all review threads for a PR.
-- cb(ok, threads) where threads is array of thread objects:
-- {
--   id, is_resolved, is_outdated, side ("LEFT"|"RIGHT"),
--   line, path,
--   comments = [{ id, database_id, body, author, created_at,
--                 reply_to_id, diff_hunk, line }]
-- }
function M.get_threads(owner, repo, number, cb)
  gh_graphql(REVIEWS_QUERY, { owner = owner, name = repo, number = number },
    function(ok, data)
      if not ok then cb(false, data); return end

      local raw_threads = vim.tbl_get(data, "repository", "pullRequest", "reviewThreads", "nodes")
      if not raw_threads then
        cb(true, {})
        return
      end

      local threads = {}
      for _, t in ipairs(raw_threads) do
        local comments = {}
        local nodes = type(t.comments) == "table" and t.comments.nodes or {}
        for _, c in ipairs(nodes) do
          -- GraphQL nulls decode as vim.NIL (userdata), not nil. Guard every field.
          local function str(v)  return type(v) == "string"  and v or nil end
          local function num(v)  return type(v) == "number"  and v or nil end
          local function tbl(v)  return type(v) == "table"   and v or nil end
          table.insert(comments, {
            id          = str(c.id),
            database_id = num(c.databaseId),
            body        = str(c.body) or "",
            author      = (tbl(c.author) or {}).login or "unknown",
            created_at  = str(c.createdAt),
            reply_to_id = tbl(c.replyTo) and c.replyTo.id or nil,
            diff_hunk   = str(c.diffHunk),
            line        = num(c.line) or num(c.originalLine),
            start_line  = num(c.startLine) or num(c.originalStartLine),
          })
        end
        table.insert(threads, {
          id          = t.id,
          is_resolved = t.isResolved == true,
          is_outdated = t.isOutdated == true,
          side        = (type(t.diffSide) == "string" and t.diffSide) or "RIGHT",
          line        = (type(t.line) == "number" and t.line)
                     or (type(t.originalLine) == "number" and t.originalLine),
          path        = type(t.path) == "string" and t.path or nil,
          comments    = comments,
        })
      end

      cb(true, threads)
    end)
end

function M.search_prs(opts, cb)
  opts = opts or {}
  local args = {
    "search", "prs",
    "--state", opts.state or "open",
    "--limit", tostring(opts.limit or 100),
    "--json", "number,title,author,updatedAt,isDraft,url,repository,state",
  }

  if opts.owner then
    table.insert(args, "--owner")
    table.insert(args, opts.owner)
  end

  for _, repo in ipairs(opts.repos or {}) do
    table.insert(args, "--repo")
    table.insert(args, repo)
  end

  if opts.review_requested then
    table.insert(args, "--review-requested")
    table.insert(args, opts.review_requested)
  end

  if opts.author then
    table.insert(args, "--author")
    table.insert(args, opts.author)
  end

  if opts.sort then
    table.insert(args, "--sort")
    table.insert(args, opts.sort)
    table.insert(args, "--order")
    table.insert(args, opts.order or "desc")
  end

  local query = opts.query and trim(opts.query) or ""
  if query ~= "" then
    table.insert(args, query)
  end

  gh_json(args, cb)
end

-- ── post comment ──────────────────────────────────────────────────────────────

-- Post a new inline review comment on a specific line.
-- opts = { owner, repo, number, commit_id, path, line, side, body }
-- side: "LEFT" | "RIGHT"
-- cb(ok, comment_id or error)
function M.post_comment(opts, cb)
  vim.system(
    {
      "gh", "api",
      string.format("/repos/%s/%s/pulls/%d/comments", opts.owner, opts.repo, opts.number),
      "--method", "POST",
      "--field", "body=" .. opts.body,
      "--field", "commit_id=" .. opts.commit_id,
      "--field", "path=" .. opts.path,
      "--field", "side=" .. opts.side,
      "--field", "line=" .. tostring(opts.line),
      "--jq", ".id",
    },
    { text = true, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, (result.stderr or ""):gsub("%s+$", ""))
      else
        cb(true, (result.stdout or ""):gsub("%s+$", ""))
      end
    end)
  )
end

-- Reply to an existing comment thread.
-- opts = { owner, repo, number, in_reply_to, body }
-- cb(ok, comment_id or error)
function M.reply_comment(opts, cb)
  vim.system(
    {
      "gh", "api",
      string.format("/repos/%s/%s/pulls/%d/comments", opts.owner, opts.repo, opts.number),
      "--method", "POST",
      "--field", "body=" .. opts.body,
      "--field", "in_reply_to=" .. tostring(opts.in_reply_to),
      "--jq", ".id",
    },
    { text = true, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, (result.stderr or ""):gsub("%s+$", ""))
      else
        cb(true, (result.stdout or ""):gsub("%s+$", ""))
      end
    end)
  )
end

-- Edit an existing review comment authored by the current user.
-- opts = { owner, repo, comment_id, body }
-- cb(ok, comment_id or error)
function M.edit_comment(opts, cb)
  vim.system(
    {
      "gh", "api",
      string.format("/repos/%s/%s/pulls/comments/%d", opts.owner, opts.repo, opts.comment_id),
      "--method", "PATCH",
      "--field", "body=" .. opts.body,
      "--jq", ".id",
    },
    { text = true, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, (result.stderr or ""):gsub("%s+$", ""))
      else
        cb(true, (result.stdout or ""):gsub("%s+$", ""))
      end
    end)
  )
end

-- ── resolve / unresolve thread ────────────────────────────────────────────────

-- GraphQL mutation to resolve a review thread.
local RESOLVE_MUTATION = [[
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
]]

local UNRESOLVE_MUTATION = [[
mutation($threadId: ID!) {
  unresolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
]]

-- cb(ok, is_resolved or error)
function M.resolve_thread(owner, repo, thread_id, cb)
  local args = {
    "api", "graphql",
    "--field", "query=" .. RESOLVE_MUTATION,
    "--field", "threadId=" .. thread_id,
  }
  gh_json(args, function(ok, result)
    if not ok then cb(false, result); return end
    local is_resolved = vim.tbl_get(result, "data", "resolveReviewThread", "thread", "isResolved")
    cb(true, is_resolved)
  end)
end

function M.unresolve_thread(owner, repo, thread_id, cb)
  local args = {
    "api", "graphql",
    "--field", "query=" .. UNRESOLVE_MUTATION,
    "--field", "threadId=" .. thread_id,
  }
  gh_json(args, function(ok, result)
    if not ok then cb(false, result); return end
    local is_resolved = vim.tbl_get(result, "data", "unresolveReviewThread", "thread", "isResolved")
    cb(true, is_resolved)
  end)
end

-- ── review submission ─────────────────────────────────────────────────────────

-- Submit a PR review.
-- event: "APPROVE" | "REQUEST_CHANGES" | "COMMENT"
-- body: optional review body string
-- cb(ok, error_string)
function M.submit_review(owner, repo, number, event, body, cb)
  local args = {
    "pr", "review", tostring(number),
    "--repo", owner .. "/" .. repo,
  }
  if event == "APPROVE" then
    table.insert(args, "--approve")
  elseif event == "REQUEST_CHANGES" then
    table.insert(args, "--request-changes")
  elseif event == "COMMENT" then
    table.insert(args, "--comment")
  end
  if body and body ~= "" then
    table.insert(args, "--body")
    table.insert(args, body)
  end
  gh_cmd(args, cb)
end

-- ── assign self as reviewer ───────────────────────────────────────────────────

-- cb(ok, error_string)
function M.request_review(owner, repo, number, username, cb)
  local payload = vim.json.encode({ reviewers = { username } })
  vim.system(
    {
      "gh", "api",
      string.format("/repos/%s/%s/pulls/%d/requested_reviewers", owner, repo, number),
      "--method", "POST",
      "--input", "-",
    },
    { text = true, stdin = payload, env = gh_env() },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, (result.stderr or ""):gsub("%s+$", ""))
      else
        cb(true, nil)
      end
    end)
  )
end

-- ── current user ──────────────────────────────────────────────────────────────

-- cb(ok, username)
function M.whoami(cb)
  if _whoami then
    cb(true, _whoami)
    return
  end

  gh_cmd({ "api", "/user", "--jq", ".login" }, function(ok, username)
    if ok then
      _whoami = trim(username)
      cb(true, _whoami)
      return
    end
    cb(false, username)
  end)
end

-- ── head commit SHA for a PR ──────────────────────────────────────────────────

-- Needed when posting a comment (commit_id is required by the API).
-- Cached per (owner/repo/number) since it doesn't change during a session.
local _sha_cache = {}

function M.get_head_sha(owner, repo, number, cb)
  local key = owner .. "/" .. repo .. "/" .. tostring(number)
  if _sha_cache[key] then
    cb(true, _sha_cache[key])
    return
  end
  gh_cmd({
    "pr", "view", tostring(number),
    "--repo", owner .. "/" .. repo,
    "--json", "headRefOid",
    "--jq", ".headRefOid",
  }, function(ok, data)
    if ok then
      _sha_cache[key] = tostring(data):gsub("%s+$", "")
    end
    cb(ok, _sha_cache[key])
  end)
end

-- ── git helpers ───────────────────────────────────────────────────────────────

-- Get current git branch. cb(ok, branch_name)
function M.current_branch(cb)
  vim.system(
    { "git", "branch", "--show-current" },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, result.stderr)
      else
        cb(true, (result.stdout or ""):gsub("%s+$", ""))
      end
    end)
  )
end

-- Get git root. cb(ok, path)
function M.git_root(cb)
  vim.system(
    { "git", "rev-parse", "--show-toplevel" },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(false, result.stderr)
      else
        cb(true, (result.stdout or ""):gsub("%s+$", ""))
      end
    end)
  )
end

return M
