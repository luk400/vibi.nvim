local M = {}

local persist = require("vibe.persist")
local config = require("vibe.config")

---@type table<string, WorktreeInfo> worktree_path -> WorktreeInfo
M.worktrees = {}

local random_seeded = false
local function seed_random()
if not random_seeded then
math.randomseed(os.time() * 1000 + vim.loop.hrtime() % 1000000)
math.random()
math.random()
random_seeded = true
end
end

local function generate_timestamped_uuid()
seed_random()
local timestamp = os.time()
local time_str = os.date("%Y%m%d-%H%M%S", timestamp)
local ns = vim.loop.hrtime() % 1000000000
local ns_hex = string.format("%08x", ns)
return time_str .. "-" .. ns_hex, timestamp
end

local function get_vibeinclude_patterns(repo_root)
local vibeinclude_path = repo_root .. "/.vibeinclude"
if vim.fn.filereadable(vibeinclude_path) ~= 1 then return nil end

local patterns = {}
for line in io.lines(vibeinclude_path) do
line = line:gsub("^%s+", ""):gsub("%s+$", "")
if line ~= "" and not line:match("^#") then table.insert(patterns, line) end
end
return #patterns > 0 and patterns or nil
end

local function matches_patterns(file, patterns)
for _, pattern in ipairs(patterns) do
if vim.fn.match(file, pattern) >= 0 then return true end
local glob_as_lua = pattern:gsub("%.", "%%."):gsub("%", "."):gsub("%?", ".")
if file:match("^" .. glob_as_lua .. "$") or file:match(glob_as_lua) then return true end
end
return false
end

local function get_untracked_patterns(repo_root)
local opts = config.options or {}
local worktree_opts = opts.worktree or {}

if worktree_opts.use_vibeinclude ~= false then
local vibeinclude_patterns = get_vibeinclude_patterns(repo_root)
if vibeinclude_patterns then return vibeinclude_patterns end
end

local copy_untracked = worktree_opts.copy_untracked
if copy_untracked == true then return {}
elseif type(copy_untracked) == "table" then return copy_untracked end

return {}
end

local function git_cmd(args, opts)
opts = opts or {}
local cmd_parts = {}
if opts.cwd then
table.insert(cmd_parts, "cd")
table.insert(cmd_parts, vim.fn.shellescape(opts.cwd))
table.insert(cmd_parts, "&&")
end
table.insert(cmd_parts, "git")
for _, arg in ipairs(args) do
table.insert(cmd_parts, arg:match("[%s\"'`$]") and vim.fn.shellescape(arg) or arg)
end
local cmd = table.concat(cmd_parts, " ")
local result = vim.fn.systemlist(cmd)
local exit_code = vim.v.shell_error
local output = table.concat(result, "\n")

if exit_code ~= 0 then
local error_msg = output:gsub("^%s+", ""):gsub("%s+$", "")
if opts.ignore_error then return output, exit_code, error_msg end
return "", exit_code, error_msg
end
return output, exit_code, nil
end

local function get_worktree_base_dir()
return vim.fn.stdpath("cache") .. "/vibe-worktrees"
end

function M.is_git_repo(cwd)
local _, exit_code, _ = git_cmd({ "rev-parse", "--is-inside-work-tree" }, { cwd = cwd, ignore_error = true })
return exit_code == 0
end

function M.get_repo_root(cwd)
local output, exit_code, _ = git_cmd({ "rev-parse", "--show-toplevel" }, { cwd = cwd, ignore_error = true })
if exit_code ~= 0 or not output or output == "" then return nil end
return output:gsub("^%s+", ""):gsub("%s+$", "")
end

function M.get_current_branch(cwd)
local output, exit_code, _ = git_cmd({ "branch", "--show-current" }, { cwd = cwd, ignore_error = true })
if exit_code ~= 0 or not output or output == "" then
output, exit_code, _ = git_cmd({ "rev-parse", "--short", "HEAD" }, { cwd = cwd, ignore_error = true })
if exit_code ~= 0 then return nil end
end
return output:gsub("^%s+", ""):gsub("%s+$", "")
end

local function init_repo(cwd)
local _, exit_code, err = git_cmd({ "init" }, { cwd = cwd })
if exit_code ~= 0 then return false, "git init failed: " .. (err or "unknown error") end
return true, nil
end

local function cleanup_old_vibe_branches(repo_cwd)
local output = git_cmd({ "branch", "--list", "vibe-" }, { cwd = repo_cwd, ignore_error = true })
if output and output ~= "" then
for branch in output:gmatch("[^\r\n]+") do
branch = branch:gsub("^%s", ""):gsub("%s*$", ""):gsub("^%%s", "")
if branch:match("^vibe%-") then git_cmd({ "branch", "-D", branch }, { cwd = repo_cwd, ignore_error = true }) end
end
end

local base_dir = get_worktree_base_dir()
if vim.fn.isdirectory(base_dir) == 1 then
for _, uuid in ipairs(vim.fn.readdir(base_dir) or {}) do
local worktree_path = base_dir .. "/" .. uuid
local wt_list = git_cmd({ "worktree", "list" }, { cwd = repo_cwd, ignore_error = true })
local is_registered = false
if wt_list then
for line in wt_list:gmatch("[^\r\n]+") do
if line:match(vim.pesc(worktree_path)) then is_registered = true; break end
end
end
if not is_registered then vim.fn.delete(worktree_path, "rf") end
end
end
end

function M.create_worktree(session_name, repo_cwd)
repo_cwd = repo_cwd or vim.fn.getcwd()

if not M.is_git_repo(repo_cwd) then
vim.notify("[Vibe] Initializing git repository...", vim.log.levels.INFO)
local ok, err = init_repo(repo_cwd)
if not ok then return nil, "Failed to initialize git repository: " .. (err or "unknown error") end
end

local repo_root = M.get_repo_root(repo_cwd)
if not repo_root then return nil, "Failed to get repository root" end

cleanup_old_vibe_branches(repo_root)

local original_branch = M.get_current_branch(repo_cwd) or "main"
local uuid, created_at = generate_timestamped_uuid()
local branch_name = "vibe-" .. uuid
local base_dir = get_worktree_base_dir()
local worktree_path = base_dir .. "/" .. uuid

vim.fn.mkdir(base_dir, "p")

local _, no_commits_code = git_cmd({ "rev-parse", "HEAD" }, { cwd = repo_cwd, ignore_error = true })
if no_commits_code ~= 0 then
git_cmd({ "add", "-A" }, { cwd = repo_cwd })
local _, _, commit_err = git_cmd({ "commit", "-m", "Initial commit" }, { cwd = repo_cwd })
if commit_err then return nil, "Failed to create initial commit: " .. commit_err end
end

local _, worktree_code, worktree_err = git_cmd({ "worktree", "add", worktree_path, "-b", branch_name }, { cwd = repo_cwd })
if worktree_code ~= 0 then
for _ = 1, 3 do
uuid, created_at = generate_timestamped_uuid()
branch_name = "vibe-" .. uuid
worktree_path = base_dir .. "/" .. uuid
_, worktree_code, worktree_err = git_cmd({ "worktree", "add", worktree_path, "-b", branch_name }, { cwd = repo_cwd })
if worktree_code == 0 then break end
end
if worktree_code ~= 0 then return nil, "Failed to create worktree: " .. (worktree_err or "unknown error") end
end

local changed_output = git_cmd({ "diff", "--name-only", "HEAD" }, { cwd = repo_cwd, ignore_error = true })
local untracked_output = git_cmd({ "ls-files", "--others", "--exclude-standard" }, { cwd = repo_cwd, ignore_error = true })

local files_to_copy = {}
for file in (changed_output or ""):gmatch("[^\r\n]+") do
if file ~= "" then files_to_copy[file] = true end
end

local untracked_patterns = get_untracked_patterns(repo_root)
local copy_all_untracked = config.options and config.options.worktree and config.options.worktree.copy_untracked == true

for file in (untracked_output or ""):gmatch("[^\r\n]+") do
if file ~= "" then
if copy_all_untracked or (#untracked_patterns > 0 and matches_patterns(file, untracked_patterns)) then
files_to_copy[file] = true
end
end
end

for file, _ in pairs(files_to_copy) do
local src_path = repo_root .. "/" .. file
local dst_path = worktree_path .. "/" .. file

if vim.fn.filereadable(src_path) == 1 then
  vim.fn.mkdir(vim.fn.fnamemodify(dst_path, ":h"), "p")
  vim.fn.writefile(vim.fn.readfile(src_path, "b"), dst_path, "b")
elseif vim.fn.isdirectory(src_path) == 1 then
  vim.fn.mkdir(dst_path, "p")
end

end

git_cmd({ "add", "-A" }, { cwd = worktree_path })
local _, commit_code, commit_err = git_cmd({ "commit", "-m", "Vibe snapshot", "--allow-empty" }, { cwd = worktree_path })
if commit_code ~= 0 then
git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = repo_cwd, ignore_error = true })
return nil, "Failed to create snapshot commit: " .. (commit_err or "unknown error")
end

local commit_hash, _, hash_err = git_cmd({ "rev-parse", "HEAD" }, { cwd = worktree_path })
if not commit_hash or commit_hash == "" then
git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = repo_cwd, ignore_error = true })
return nil, "Failed to get commit hash: " .. (hash_err or "unknown error")
end

local info = {
name = session_name, worktree_path = worktree_path, branch = branch_name,
snapshot_commit = commit_hash:gsub("^%s+", ""):gsub("%s+$", ""),
original_branch = original_branch, repo_root = repo_root, uuid = uuid,
created_at = created_at, addressed_hunks = {},
}
M.worktrees[worktree_path] = info

persist.save_session(vim.tbl_extend("force", info, { cwd = repo_cwd, last_active = os.time(), has_terminal = true }))

vim.notify("[Vibe] Created worktree: " .. worktree_path, vim.log.levels.INFO)
return info, nil
end

function M.get_worktrees_with_changes()
M.scan_for_vibe_worktrees()
local result = {}
for _, info in pairs(M.worktrees) do
if #M.get_worktree_changed_files(info.worktree_path) > 0 then table.insert(result, info) end
end
return result
end

function M.get_worktrees_with_unresolved_files()
M.scan_for_vibe_worktrees()
local result = {}
for _, info in pairs(M.worktrees) do
if #M.get_unresolved_files(info.worktree_path) > 0 then table.insert(result, info) end
end
return result
end

function M.scan_for_vibe_worktrees()
  local base_dir = get_worktree_base_dir()
  if vim.fn.isdirectory(base_dir) == 0 then return end

  local persisted = persist.get_valid_persisted_sessions()
  local persisted_by_path = {}
  for _, s in ipairs(persisted) do persisted_by_path[s.worktree_path] = s end

  for _, uuid in ipairs(vim.fn.readdir(base_dir) or {}) do
    local worktree_path = base_dir .. "/" .. uuid
    if vim.fn.isdirectory(worktree_path) == 1 and not M.worktrees[worktree_path] then
      local branch = M.get_current_branch(worktree_path)
      if branch and branch:match("^vibe%-") then
        local main_repo_root = nil
        local wt_list = git_cmd({ "worktree", "list" }, { cwd = worktree_path, ignore_error = true })
        if wt_list then
          local first_line = wt_list:match("[^\r\n]+")
          if first_line then main_repo_root = first_line:match("^%S+") end
        end

        if not main_repo_root then
          local git_file = worktree_path .. "/.git"
          if vim.fn.filereadable(git_file) == 1 then
            local common_dir = vim.fn.readfile(git_file)[1]
            if common_dir and common_dir:match("^git%-dir:") then
              main_repo_root = vim.fn.fnamemodify(common_dir:gsub("^git%-dir:%s*", ""), ":h:h:h")
            end
          end
        end

        if main_repo_root and vim.fn.isdirectory(main_repo_root) == 1 then
          local log_output = git_cmd({ "log", "--reverse", "--format=%H", "-n", "1" }, { cwd = worktree_path, ignore_error = true })
          local snapshot_commit = log_output and log_output:gsub("^%s+", ""):gsub("%s+$", "") or nil

          local persisted_info = persisted_by_path[worktree_path]
          local created_at = persisted_info and persisted_info.created_at or os.time()
          
          if not persisted_info then
            local ts_part = uuid:match("^(%d+%-?%d+)%-")
            if ts_part then
              local year, month, day, hour, min, sec = ts_part:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
              if year then created_at = os.time({ year=tonumber(year), month=tonumber(month), day=tonumber(day), hour=tonumber(hour), min=tonumber(min), sec=tonumber(sec) }) or os.time() end
            end
          end

          M.worktrees[worktree_path] = {
            name = persisted_info and persisted_info.name or uuid:sub(1, 8),
            worktree_path = worktree_path, branch = branch, snapshot_commit = snapshot_commit,
            original_branch = persisted_info and persisted_info.original_branch or "main",
            repo_root = main_repo_root, uuid = uuid, created_at = created_at,
            addressed_hunks = persisted_info and persisted_info.addressed_hunks or {},
            manually_modified_files = persisted_info and persisted_info.manually_modified_files or {},
          }
        end
      end
    end
  end
end

function M.get_unresolved_files(worktree_path)
local info = M.worktrees[worktree_path]
if not info then return {} end

local changed_files = M.get_worktree_changed_files(worktree_path)
local unresolved = {}

for _, filepath in ipairs(changed_files) do
if not M.is_file_fully_addressed(worktree_path, filepath) then
local worktree_file = worktree_path .. "/" .. filepath
local user_file = info.repo_root .. "/" .. filepath

local worktree_exists = vim.fn.filereadable(worktree_file) == 1
  local user_exists = vim.fn.filereadable(user_file) == 1

  if (worktree_exists and not user_exists) or (not worktree_exists and user_exists) then
    table.insert(unresolved, filepath)
  elseif worktree_exists and user_exists then
    local worktree_lines = vim.fn.readfile(worktree_file)
    local user_lines = vim.fn.readfile(user_file)

    if #worktree_lines ~= #user_lines then
      table.insert(unresolved, filepath)
    else
      for i = 1, #worktree_lines do
        if worktree_lines[i] ~= user_lines[i] then table.insert(unresolved, filepath); break end
      end
    end
  end
end

end

return unresolved
end

function M.get_worktree_changed_files(worktree_path)
local info = M.worktrees[worktree_path]
if not info then return {} end

local output = git_cmd({ "diff", "--name-only", info.snapshot_commit }, { cwd = worktree_path, ignore_error = true })
local untracked_output = git_cmd({ "ls-files", "--others", "--exclude-standard" }, { cwd = worktree_path, ignore_error = true })

local files, seen = {}, {}
local function process_output(out)
for file in (out or ""):gmatch("[^\r\n]+") do
if file ~= "" and not seen[file] then seen[file] = true; table.insert(files, file) end
end
end

process_output(output)
process_output(untracked_output)
return files
end

function M.get_worktree_file_hunks(worktree_path, filepath, user_file_path)
local worktree_file = worktree_path .. "/" .. filepath
if vim.fn.filereadable(worktree_file) == 0 then return {} end

local worktree_lines = vim.fn.readfile(worktree_file)
local user_lines = {}
local bufnr = vim.fn.bufnr(user_file_path)
if bufnr ~= -1 then user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
elseif vim.fn.filereadable(user_file_path) == 1 then user_lines = vim.fn.readfile(user_file_path) end

if #worktree_lines == #user_lines then
local same = true
for i = 1, #worktree_lines do
if worktree_lines[i] ~= user_lines[i] then same = false; break end
end
if same then return {} end
end

local tmp_worktree = vim.fn.tempname()
local tmp_user = vim.fn.tempname()
vim.fn.writefile(worktree_lines, tmp_worktree)
vim.fn.writefile(user_lines, tmp_user)

local output = git_cmd({ "diff", "-U0", "--no-color", tmp_user, tmp_worktree }, { ignore_error = true })
vim.fn.delete(tmp_worktree); vim.fn.delete(tmp_user)
if not output or output == "" then return {} end

local hunks, current_hunk = {}, nil
for line in output:gmatch("[^\r\n]+") do
local old_start, old_count, new_start, new_count = line:match("^@@%s*%-(%d+),?(%d*)%s*%+(%d+),?(%d*)%s*@@")

if old_start then
  if current_hunk then table.insert(hunks, current_hunk) end
  old_count = old_count ~= "" and tonumber(old_count) or 1
  new_count = new_count ~= "" and tonumber(new_count) or 1

  current_hunk = {
    old_start = tonumber(old_start), old_count = old_count,
    new_start = tonumber(new_start), new_count = new_count,
    type = old_count == 0 and "add" or (new_count == 0 and "delete" or "change"),
    lines = {}, added_lines = {}, removed_lines = {},
  }
elseif current_hunk then
  if line:sub(1, 1) == "+" then
    table.insert(current_hunk.added_lines, line:sub(2))
    table.insert(current_hunk.lines, { type = "add", text = line:sub(2) })
  elseif line:sub(1, 1) == "-" then
    table.insert(current_hunk.removed_lines, line:sub(2))
    table.insert(current_hunk.lines, { type = "remove", text = line:sub(2) })
  end
end

end
if current_hunk then table.insert(hunks, current_hunk) end

return hunks
end

local function simple_hash(str)
local h = 0
for i = 1, #str do h = (h * 31 + string.byte(str, i)) % 2147483647 end
return tostring(h)
end

function M.hunk_hash(hunk)
local removed_content = table.concat(hunk.removed_lines or {}, "\n")
local added_content = table.concat(hunk.added_lines or {}, "\n")
return table.concat({ tostring(hunk.old_count or 0), tostring(hunk.new_count or 0), simple_hash(removed_content), simple_hash(added_content) }, ":")
end

function M.mark_hunk_addressed(worktree_path, filepath, hunk, action)
local info = M.worktrees[worktree_path]
if not info then return end

info.addressed_hunks = info.addressed_hunks or {}
table.insert(info.addressed_hunks, { filepath = filepath, hunk_hash = M.hunk_hash(hunk), action = action, timestamp = os.time() })

local persisted = persist.load_sessions()
for _, s in ipairs(persisted) do
if s.worktree_path == worktree_path then s.addressed_hunks = info.addressed_hunks; break end
end
persist.save_sessions(persisted)
end

function M.is_file_fully_addressed(worktree_path, filepath)
local info = M.worktrees[worktree_path]
if not info then return false end

local worktree_file = worktree_path .. "/" .. filepath
local user_file = info.repo_root .. "/" .. filepath

if vim.fn.filereadable(worktree_file) == 0 and vim.fn.filereadable(user_file) == 1 then return false end

local hunks = M.get_worktree_file_hunks(worktree_path, filepath, user_file)
if #hunks == 0 then return true end
if not info.addressed_hunks or #info.addressed_hunks == 0 then return false end

local addressed_hashes = {}
for _, addressed in ipairs(info.addressed_hunks) do
if addressed.filepath == filepath then addressed_hashes[addressed.hunk_hash] = true end
end

local addressed_count = 0
for _, hunk in ipairs(hunks) do
if addressed_hashes[M.hunk_hash(hunk)] then addressed_count = addressed_count + 1 end
end

return addressed_count >= #hunks
end

function M.read_file_at_commit(worktree_path, filepath, commit)
commit = commit or "HEAD"
local cmd = string.format("cd %s && git --no-pager show %s:%s", vim.fn.shellescape(worktree_path), commit, filepath)
local result = vim.fn.systemlist(cmd)
if vim.v.shell_error ~= 0 then return {} end
return (not result or #result == 0) and { "" } or result
end

function M.get_worktree_snapshot_lines(worktree_path, filepath)
local info = M.worktrees[worktree_path]
return info and M.read_file_at_commit(worktree_path, filepath, info.snapshot_commit) or {}
end

function M.get_user_added_lines(worktree_path, filepath, user_file_path)
local snapshot_lines = M.get_worktree_snapshot_lines(worktree_path, filepath)
if #snapshot_lines == 0 then return {} end

local user_lines = {}
local bufnr = vim.fn.bufnr(user_file_path)
if bufnr ~= -1 then user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
elseif vim.fn.filereadable(user_file_path) == 1 then user_lines = vim.fn.readfile(user_file_path) end
if #user_lines == 0 then return {} end

local tmp_snapshot, tmp_user = vim.fn.tempname(), vim.fn.tempname()
vim.fn.writefile(snapshot_lines, tmp_snapshot)
vim.fn.writefile(user_lines, tmp_user)
local output = git_cmd({ "diff", "-U0", "--no-color", tmp_snapshot, tmp_user }, { ignore_error = true })
vim.fn.delete(tmp_snapshot); vim.fn.delete(tmp_user)

if not output or output == "" then return {} end

local user_added_lines = {}
for line in output:gmatch("[^\r\n]+") do
local old_start, old_count, new_start, new_count = line:match("^@@%s*%-(%d+),?(%d*)%s*%+(%d+),?(%d*)%s*@@")
if old_start then
new_count = new_count ~= "" and tonumber(new_count) or 1
old_count = old_count ~= "" and tonumber(old_count) or 0
if new_count > 0 and old_count == 0 then
for i = 0, new_count - 1 do user_added_lines[new_start + i] = true end
elseif new_count > old_count then
for i = old_count, new_count - 1 do user_added_lines[new_start + i] = true end
end
end
end
return user_added_lines
end

--- Abstracted read/write file modifications for hunk resolutions
local function modify_user_file(worktree_path, filepath, user_file_path, modify_fn)
if not user_file_path then
local info = M.worktrees[worktree_path]
if not info then return false, "Could not determine user file path" end
user_file_path = info.repo_root .. "/" .. filepath
end

local bufnr = vim.fn.bufnr(user_file_path)
local lines
if bufnr ~= -1 then lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
else lines = vim.fn.filereadable(user_file_path) == 1 and vim.fn.readfile(user_file_path) or {} end

local ok, err = modify_fn(lines)
if not ok then return false, err end

local parent_dir = vim.fn.fnamemodify(user_file_path, ":h")
if vim.fn.isdirectory(parent_dir) == 0 then vim.fn.mkdir(parent_dir, "p") end

if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
else
vim.fn.writefile(lines, user_file_path)
end
return true, nil
end

function M.sync_resolved_file(worktree_path, filepath, user_file_path)
  local info = M.worktrees[worktree_path]
  if not info then return end

  local worktree_file = worktree_path .. "/" .. filepath
  local user_lines = {}

  local bufnr = vim.fn.bufnr(user_file_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  elseif vim.fn.filereadable(user_file_path) == 1 then
    user_lines = vim.fn.readfile(user_file_path)
  end

  local worktree_lines = {}
  if vim.fn.filereadable(worktree_file) == 1 then
    worktree_lines = vim.fn.readfile(worktree_file)
  end

  local is_modified = false
  if #user_lines ~= #worktree_lines then
    is_modified = true
  else
    for i = 1, #user_lines do
      if user_lines[i] ~= worktree_lines[i] then
        is_modified = true
        break
      end
    end
  end

  if is_modified then
    info.manually_modified_files = info.manually_modified_files or {}
    info.manually_modified_files[filepath] = true
  end

  vim.fn.mkdir(vim.fn.fnamemodify(worktree_file, ":h"), "p")
  vim.fn.writefile(user_lines, worktree_file)
end

function M.accept_file_from_worktree(worktree_path, filepath, repo_root)
repo_root = repo_root or (M.worktrees[worktree_path] and M.worktrees[worktree_path].repo_root) or M.get_repo_root(worktree_path)
if not repo_root then return false, "Could not determine repo root" end

local src_path = worktree_path .. "/" .. filepath
local dst_path = repo_root .. "/" .. filepath

vim.fn.mkdir(vim.fn.fnamemodify(dst_path, ":h"), "p")
if vim.fn.filereadable(src_path) == 1 then vim.fn.writefile(vim.fn.readfile(src_path), dst_path)
else vim.fn.delete(dst_path) end

local bufnr = vim.fn.bufnr(dst_path)
if bufnr ~= -1 then vim.cmd("checktime " .. bufnr) end
return true
end

function M.accept_hunk_from_worktree(worktree_path, filepath, hunk, user_file_path)
local user_added_set = {}
for _, idx in ipairs(hunk.user_added_indices or {}) do user_added_set[idx] = true end

if #hunk.user_added_indices == #hunk.removed_lines and #hunk.added_lines == 0 then return true, nil end

return modify_user_file(worktree_path, filepath, user_file_path, function(lines)
local start = hunk.old_start
if hunk.type == "add" then
if start == 0 then
while #lines > 0 do table.remove(lines) end
for _, l in ipairs(hunk.added_lines) do table.insert(lines, l) end
else
for i, l in ipairs(hunk.added_lines) do table.insert(lines, start + i, l) end
end
elseif hunk.type == "delete" then
for i = hunk.old_count, 1, -1 do
if not user_added_set[i] then table.remove(lines, start + i - 1) end
end
else
if next(user_added_set) then
local all_are_user = #hunk.user_added_indices == #hunk.removed_lines
if not all_are_user then
for i = hunk.old_count, 1, -1 do
if not user_added_set[i] then table.remove(lines, start + i - 1) end
end
end
for i, l in ipairs(hunk.added_lines) do table.insert(lines, start + i - 1, l) end
else
for i = hunk.old_count, 1, -1 do table.remove(lines, start + i - 1) end
for i, l in ipairs(hunk.added_lines) do table.insert(lines, start + i - 1, l) end
end
end
return true
end)
end

function M.reject_hunk_from_worktree(worktree_path, filepath, hunk, user_file_path)
if not hunk then return true end
local user_added_set = {}
for _, idx in ipairs(hunk.user_added_indices or {}) do user_added_set[idx] = true end
if vim.tbl_isempty(user_added_set) then return true end

return modify_user_file(worktree_path, filepath, user_file_path, function(lines)
for i = #hunk.removed_lines, 1, -1 do
if user_added_set[i] then table.remove(lines, hunk.old_start + i - 1) end
end
return true
end)
end

function M.keep_both_hunk(worktree_path, filepath, hunk, user_file_path)
local user_added_set = {}
for _, idx in ipairs(hunk.user_added_indices or {}) do user_added_set[idx] = true end

return modify_user_file(worktree_path, filepath, user_file_path, function(lines)
local start = hunk.old_start
if hunk.type == "add" then
if start == 0 then
while #lines > 0 do table.remove(lines) end
for _, l in ipairs(hunk.added_lines) do table.insert(lines, l) end
for _, idx in ipairs(hunk.user_added_indices or {}) do
if hunk.removed_lines[idx] then table.insert(lines, hunk.removed_lines[idx]) end
end
else
for i, l in ipairs(hunk.added_lines) do table.insert(lines, start + i, l) end
end
elseif hunk.type == "delete" then
for i = hunk.old_count, 1, -1 do
if not user_added_set[i] then table.remove(lines, start + i - 1) end
end
else
for i = hunk.old_count, 1, -1 do
if not user_added_set[i] then table.remove(lines, start + i - 1) end
end
for i, l in ipairs(hunk.added_lines) do table.insert(lines, start + i - 1, l) end
end
return true
end)
end

function M.delete_hunk_range(worktree_path, filepath, hunk, user_file_path)
return modify_user_file(worktree_path, filepath, user_file_path, function(lines)
for i = hunk.old_count, 1, -1 do
if hunk.old_start + i - 1 <= #lines then table.remove(lines, hunk.old_start + i - 1) end
end
return true
end)
end

function M.reject_file_from_worktree(worktree_path, filepath) return true end

function M.accept_all_from_worktree(worktree_path)
for _, filepath in ipairs(M.get_worktree_changed_files(worktree_path)) do
local ok, err = M.accept_file_from_worktree(worktree_path, filepath)
if not ok then return false, err end
end
return true, nil
end

function M.remove_worktree(worktree_path)
local info = M.worktrees[worktree_path]
if not info then return false, "Worktree not found" end

local _, remove_code, remove_err = git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = info.repo_root, ignore_error = true })
git_cmd({ "branch", "-D", info.branch }, { cwd = info.repo_root, ignore_error = true })

M.worktrees[worktree_path] = nil
persist.remove_session(worktree_path)
if vim.fn.isdirectory(worktree_path) == 1 then vim.fn.delete(worktree_path, "rf") end

if remove_code ~= 0 then return false, "Failed to remove worktree: " .. (remove_err or "unknown error") end
vim.notify("[Vibe] Removed worktree: " .. worktree_path, vim.log.levels.INFO)
return true, nil
end

function M.discard_worktree(worktree_path) return M.remove_worktree(worktree_path) end
function M.get_worktree_info(worktree_path) return M.worktrees[worktree_path] end

function M.get_worktree_by_session(session_name)
for _, info in pairs(M.worktrees) do if info.name == session_name then return info end end
return nil
end

function M.has_worktrees_with_changes()
for _, info in pairs(M.worktrees) do
if #M.get_unresolved_files(info.worktree_path) > 0 then return true end
end
return false
end

function M.cleanup_all_worktrees()
for worktree_path, _ in pairs(M.worktrees) do M.remove_worktree(worktree_path) end
end

-- Legacy Compatibility
M.original_branch = nil
M.vibe_branch = nil
M.snapshot_commit = nil

function M.is_session_active() return M.vibe_branch ~= nil and M.snapshot_commit ~= nil end

function M.get_changed_files()
local info = M.get_worktree_by_session("default")
return info and M.get_worktree_changed_files(info.worktree_path) or {}
end

function M.accept_all()
local info = M.get_worktree_by_session("default")
if info then
local ok, err = M.accept_all_from_worktree(info.worktree_path)
if ok then M.remove_worktree(info.worktree_path); M:reset() end
return ok, err
end
return false, "No active session"
end

function M.reject_all()
local info = M.get_worktree_by_session("default")
if info then M.remove_worktree(info.worktree_path); M:reset(); return true, nil end
return false, "No active session"
end

function M.reject_file(filepath) return true, nil end
function M.accept_hunk(filepath, hunk, current_lines) return true end

function M.reject_hunk(filepath, hunk)
local info = M.get_worktree_by_session("default")
if not info then return false, "No active session" end
return modify_user_file(info.worktree_path, filepath, nil, function(lines)
local start = hunk.new_start - 1
if hunk.type == "add" then
for _=1, hunk.new_count do table.remove(lines, start + 1) end
elseif hunk.type == "delete" then
for i, l in ipairs(hunk.removed_lines) do table.insert(lines, start + i, l) end
else
for _=1, hunk.new_count do table.remove(lines, start + 1) end
for i, l in ipairs(hunk.removed_lines) do table.insert(lines, start + i, l) end
end
return true
end)
end

function M.cancel_session()
local info = M.get_worktree_by_session("default")
if info then M.remove_worktree(info.worktree_path); M:reset() end
return true, nil
end

function M:reset() self.original_branch = nil; self.vibe_branch = nil; self.snapshot_commit = nil end

return M
