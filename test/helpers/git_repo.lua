-- test/helpers/git_repo.lua
local M = {}

M._test_repos = {}
M._test_counter = 0

function M.unique_name(base)
  M._test_counter = M._test_counter + 1
  return string.format("%s-%d-%d", base or "test", os.time(), M._test_counter)
end

function M.git_cmd(args, opts)
  opts = opts or {}
  local cmd_parts = {}
  if opts.cwd then
    table.insert(cmd_parts, "cd")
    table.insert(cmd_parts, vim.fn.shellescape(opts.cwd))
    table.insert(cmd_parts, "&&")
  end
  table.insert(cmd_parts, "git")
  for _, arg in ipairs(args) do
    table.insert(cmd_parts, arg:match("[%s\"'\\$`]") and vim.fn.shellescape(arg) or arg)
  end
  local cmd = table.concat(cmd_parts, " ")
  local result = vim.fn.systemlist(cmd)
  return table.concat(result, "\n"), vim.v.shell_error
end

function M.create_test_repo(name, files)
  name = M.unique_name(name)
  local repo_path = vim.g.vibe_test_cache .. "/" .. name

  if vim.fn.isdirectory(repo_path) == 1 then vim.fn.delete(repo_path, "rf") end
  vim.fn.mkdir(repo_path, "p")

  M.git_cmd({"init"}, {cwd = repo_path})
  
  for filepath, content in pairs(files or {}) do
    local full_path = repo_path .. "/" .. filepath
    vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
    vim.fn.writefile(vim.split(content, "\n"), full_path)
  end

  M.git_cmd({"add", "-A"}, {cwd = repo_path})
  M.git_cmd({"commit", "--allow-empty", "-m", "Initial"}, {cwd = repo_path})

  table.insert(M._test_repos, repo_path)
  return repo_path, function() M.cleanup_repo(repo_path) end
end

function M.write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n"), path)
end

function M.cleanup_repo(repo_path)
  if vim.fn.isdirectory(repo_path) == 1 then
    M.git_cmd({"worktree", "prune"}, {cwd = repo_path, ignore_error = true})
    vim.fn.delete(repo_path, "rf")
  end
end

function M.cleanup_all()
  for _, repo_path in ipairs(M._test_repos) do M.cleanup_repo(repo_path) end
  M._test_repos = {}
end

return M
