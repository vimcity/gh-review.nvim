local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

function M.open()
  local root = plugin_root()
  local docdir = root .. "/doc"
  if vim.fn.isdirectory(docdir) == 0 then
    vim.notify("gh-review: help docs not found", vim.log.levels.ERROR)
    return
  end

  if not vim.o.runtimepath:find(vim.pesc(root), 1, true) then
    vim.opt.runtimepath:append(root)
  end

  vim.cmd("silent! helptags " .. vim.fn.fnameescape(docdir))
  vim.cmd("help gh-review.nvim")
end

return M
