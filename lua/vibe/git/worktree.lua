local M = {}

local persist = require("vibe.persist")
local config = require("vibe.config")
local git_cmd_mod = require("vibe.git.cmd")
local git_cmd = git_cmd_mod.git_cmd
local get_worktree_base_dir = git_cmd_mod.get_worktree_base_dir

---@type table<string, WorktreeInfo> worktree_path -> WorktreeInfo
M.worktrees = {}

---@type table<string, { job_id: integer|nil, worktree_path: string|nil, branch: string|nil, repo_root: string|nil, cancelled: boolean }>
M.pending_creations = {}

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
    if vim.fn.filereadable(vibeinclude_path) ~= 1 then
        return nil
    end

    local patterns = {}
    for line in io.lines(vibeinclude_path) do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            table.insert(patterns, line)
        end
    end
    return #patterns > 0 and patterns or nil
end

function M.matches_patterns(file, patterns)
    for _, pattern in ipairs(patterns) do
        -- Convert glob to Lua pattern:
        -- 1. Escape Lua magic chars except * and ? (they're glob wildcards)
        local lua_pat = pattern:gsub("([%(%)%.%%%+%-%[%]%^%$])", "%%%1")
        -- 2. Convert glob wildcards (order matters: ** before *)
        lua_pat = lua_pat
            :gsub("%*%*", "\001") -- temp placeholder for **
            :gsub("%*", "[^/]*") -- * = any non-slash chars
            :gsub("\001", ".*") -- ** = anything including slashes
            :gsub("%?", ".") -- ? = single char
        if file:match("^" .. lua_pat .. "$") then
            return true
        end
    end
    return false
end

--- Copy .gitignore from source repo to worktree (even if untracked)
---@param repo_root string
---@param worktree_path string
local function copy_gitignore_to_worktree(repo_root, worktree_path)
    local src = repo_root .. "/.gitignore"
    local dst = worktree_path .. "/.gitignore"
    if vim.fn.filereadable(src) == 1 then
        vim.fn.writefile(vim.fn.readfile(src, "b"), dst, "b")
    end
end

local function files_differ(path_a, path_b)
    local a_readable = vim.fn.filereadable(path_a) == 1
    local b_readable = vim.fn.filereadable(path_b) == 1
    if a_readable ~= b_readable then
        return true
    end
    if not a_readable then
        return false
    end
    local content_a = vim.fn.readfile(path_a, "b")
    local content_b = vim.fn.readfile(path_b, "b")
    if #content_a ~= #content_b then
        return true
    end
    for i = 1, #content_a do
        if content_a[i] ~= content_b[i] then
            return true
        end
    end
    return false
end


function M.is_git_repo(cwd)
    local _, exit_code, _ = git_cmd({ "rev-parse", "--is-inside-work-tree" }, { cwd = cwd, ignore_error = true })
    return exit_code == 0
end

function M.get_repo_root(cwd)
    local output, exit_code, _ = git_cmd({ "rev-parse", "--show-toplevel" }, { cwd = cwd, ignore_error = true })
    if exit_code ~= 0 or not output or output == "" then
        return nil
    end
    return output:gsub("^%s+", ""):gsub("%s+$", "")
end

function M.get_current_branch(cwd)
    local output, exit_code, _ = git_cmd({ "branch", "--show-current" }, { cwd = cwd, ignore_error = true })
    if exit_code ~= 0 or not output or output == "" then
        output, exit_code, _ = git_cmd({ "rev-parse", "--short", "HEAD" }, { cwd = cwd, ignore_error = true })
        if exit_code ~= 0 then
            return nil
        end
    end
    return output:gsub("^%s+", ""):gsub("%s+$", "")
end

local function init_repo(cwd)
    local _, exit_code, err = git_cmd({ "init" }, { cwd = cwd })
    if exit_code ~= 0 then
        return false, "git init failed: " .. (err or "unknown error")
    end
    return true, nil
end

local function cleanup_old_vibe_branches(repo_cwd)
    local output = git_cmd({ "branch", "--list", "vibe-" }, { cwd = repo_cwd, ignore_error = true })
    if output and output ~= "" then
        for branch in output:gmatch("[^\r\n]+") do
            branch = branch:gsub("^%s", ""):gsub("%s*$", ""):gsub("^%%s", "")
            if branch:match("^vibe%-") then
                git_cmd({ "branch", "-D", branch }, { cwd = repo_cwd, ignore_error = true })
            end
        end
    end

    local base_dir = get_worktree_base_dir()
    if vim.fn.isdirectory(base_dir) == 1 then
        for _, uuid in ipairs(vim.fn.readdir(base_dir) or {}) do
            local worktree_path = base_dir .. "/" .. uuid
            -- Skip non-directories (e.g., sessions.json)
            if vim.fn.isdirectory(worktree_path) == 1 then
                -- Check if this worktree belongs to the current repo
                local belongs_to_current_repo = false
                local git_file = worktree_path .. "/.git"
                if vim.fn.filereadable(git_file) == 1 then
                    local git_content = vim.fn.readfile(git_file)
                    if git_content and git_content[1] then
                        local gitdir = git_content[1]:gsub("^gitdir:%s*", "")
                        -- gitdir = /path/to/repo/.git/worktrees/<name>
                        -- repo root is 3 levels up
                        local linked_repo = vim.fn.fnamemodify(gitdir, ":h:h:h")
                        belongs_to_current_repo = (linked_repo == repo_cwd)
                    end
                else
                    -- No .git file = orphaned directory, safe to clean
                    belongs_to_current_repo = true
                end

                if belongs_to_current_repo then
                    local wt_list = git_cmd({ "worktree", "list" }, { cwd = repo_cwd, ignore_error = true })
                    local is_registered = false
                    if wt_list then
                        for line in wt_list:gmatch("[^\r\n]+") do
                            if line:match(vim.pesc(worktree_path)) then
                                is_registered = true
                                break
                            end
                        end
                    end
                    if not is_registered then
                        vim.fn.delete(worktree_path, "rf")
                    end
                end
            end
        end
    end
end

function M.create_worktree(session_name, repo_cwd)
    repo_cwd = repo_cwd or vim.fn.getcwd()

    if not M.is_git_repo(repo_cwd) then
        local choice = vim.fn.confirm(
            "[Vibe] This directory is not a git repository.\n"
                .. "Vibe needs to initialize git and commit all files.\n"
                .. "Continue?",
            "&Yes\n&No",
            2
        )
        if choice ~= 1 then
            return nil, "Please initialize the git repository before starting a new Vibe session."
        end
        local ok, err = init_repo(repo_cwd)
        if not ok then
            return nil, "Failed to initialize git repository: " .. (err or "unknown error")
        end
    end

    local repo_root = M.get_repo_root(repo_cwd)
    if not repo_root then
        return nil, "Failed to get repository root"
    end

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
        if commit_err then
            return nil, "Failed to create initial commit: " .. commit_err
        end
    end

    local _, worktree_code, worktree_err = git_cmd(
        { "worktree", "add", worktree_path, "-b", branch_name },
        { cwd = repo_cwd }
    )
    if worktree_code ~= 0 then
        for _ = 1, 3 do
            uuid, created_at = generate_timestamped_uuid()
            branch_name = "vibe-" .. uuid
            worktree_path = base_dir .. "/" .. uuid
            _, worktree_code, worktree_err = git_cmd(
                { "worktree", "add", worktree_path, "-b", branch_name },
                { cwd = repo_cwd }
            )
            if worktree_code == 0 then
                break
            end
        end
        if worktree_code ~= 0 then
            return nil, "Failed to create worktree: " .. (worktree_err or "unknown error")
        end
    end

    local changed_output = git_cmd({ "diff", "--name-only", "HEAD" }, { cwd = repo_cwd, ignore_error = true })
    local vibeinclude_patterns = get_vibeinclude_patterns(repo_root)
    local untracked_copied = 0

    local files_to_copy = {}
    for file in (changed_output or ""):gmatch("[^\r\n]+") do
        if file ~= "" then
            files_to_copy[file] = true
        end
    end

    if vibeinclude_patterns then
        -- Use git pathspec to filter: git ls-files --others -- pattern1 pattern2 ...
        -- No --exclude-standard: .vibeinclude overrides .gitignore (inclusion is explicit)
        local ls_args = { "ls-files", "--others", "--" }
        for _, pat in ipairs(vibeinclude_patterns) do
            table.insert(ls_args, pat)
        end
        local untracked_output = git_cmd(ls_args, { cwd = repo_root, ignore_error = true })

        for file in (untracked_output or ""):gmatch("[^\r\n]+") do
            if file ~= "" then
                files_to_copy[file] = true
                untracked_copied = untracked_copied + 1
            end
        end
    end

    if vibeinclude_patterns then
        if untracked_copied > 0 then
            vim.notify(
                string.format("[Vibe] .vibeinclude: copied %d untracked file(s)", untracked_copied),
                vim.log.levels.INFO
            )
        else
            vim.notify("[Vibe] .vibeinclude found but no untracked files matched", vim.log.levels.WARN)
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

    copy_gitignore_to_worktree(repo_root, worktree_path)

    git_cmd({ "add", "-A" }, { cwd = worktree_path })
    local _, commit_code, commit_err = git_cmd(
        { "commit", "-m", "Vibe snapshot", "--allow-empty" },
        { cwd = worktree_path }
    )
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
        name = session_name,
        worktree_path = worktree_path,
        branch = branch_name,
        snapshot_commit = commit_hash:gsub("^%s+", ""):gsub("%s+$", ""),
        original_branch = original_branch,
        repo_root = repo_root,
        uuid = uuid,
        created_at = created_at,
        addressed_hunks = {},
    }
    M.worktrees[worktree_path] = info

    persist.save_session(
        vim.tbl_extend("force", info, { cwd = repo_cwd, last_active = os.time(), has_terminal = true })
    )

    vim.notify("[Vibe] Created worktree: " .. worktree_path, vim.log.levels.INFO)
    return info, nil
end

function M.create_worktree_async(session_name, repo_cwd, callback)
    repo_cwd = repo_cwd or vim.fn.getcwd()

    -- Phase 1 (sync, fast): validate, cleanup, prepare
    if not M.is_git_repo(repo_cwd) then
        local choice = vim.fn.confirm(
            "[Vibe] This directory is not a git repository.\n"
                .. "Vibe needs to initialize git and commit all files.\n"
                .. "Continue?",
            "&Yes\n&No",
            2
        )
        if choice ~= 1 then
            callback(nil, "Please initialize the git repository before starting a new Vibe session.")
            return
        end
        local _, exit_code, init_err = git_cmd({ "init" }, { cwd = repo_cwd })
        if exit_code ~= 0 then
            callback(nil, "Failed to initialize git repository: " .. (init_err or "unknown error"))
            return
        end
    end

    local repo_root = M.get_repo_root(repo_cwd)
    if not repo_root then
        callback(nil, "Failed to get repository root")
        return
    end

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
        if commit_err then
            callback(nil, "Failed to create initial commit: " .. commit_err)
            return
        end
    end

    -- Register pending creation for cancellation support
    local pending = {
        job_id = nil,
        worktree_path = worktree_path,
        branch = branch_name,
        repo_root = repo_root,
        cancelled = false,
    }
    M.pending_creations[session_name] = pending

    -- Phase 2 (async, slow): git worktree add
    local retry_count = 0
    local function try_worktree_add()
        local job_id = git_cmd_mod.git_cmd_async(
            { "worktree", "add", worktree_path, "-b", branch_name },
            { cwd = repo_cwd },
            function(_, exit_code, worktree_err)
                if pending.cancelled then
                    M.pending_creations[session_name] = nil
                    return
                end

                if exit_code ~= 0 then
                    if retry_count < 3 then
                        retry_count = retry_count + 1
                        uuid, created_at = generate_timestamped_uuid()
                        branch_name = "vibe-" .. uuid
                        worktree_path = base_dir .. "/" .. uuid
                        pending.worktree_path = worktree_path
                        pending.branch = branch_name
                        try_worktree_add()
                        return
                    end
                    M.pending_creations[session_name] = nil
                    callback(nil, "Failed to create worktree: " .. (worktree_err or "unknown error"))
                    return
                end

                -- Phase 3 (sync in callback, fast): copy files, snapshot commit
                local changed_output = git_cmd({ "diff", "--name-only", "HEAD" }, { cwd = repo_cwd, ignore_error = true })
                local vibeinclude_patterns = get_vibeinclude_patterns(repo_root)
                local untracked_copied = 0

                local files_to_copy = {}
                for file in (changed_output or ""):gmatch("[^\r\n]+") do
                    if file ~= "" then
                        files_to_copy[file] = true
                    end
                end

                if vibeinclude_patterns then
                    local ls_args = { "ls-files", "--others", "--" }
                    for _, pat in ipairs(vibeinclude_patterns) do
                        table.insert(ls_args, pat)
                    end
                    local untracked_output = git_cmd(ls_args, { cwd = repo_root, ignore_error = true })

                    for file in (untracked_output or ""):gmatch("[^\r\n]+") do
                        if file ~= "" then
                            files_to_copy[file] = true
                            untracked_copied = untracked_copied + 1
                        end
                    end
                end

                if vibeinclude_patterns then
                    if untracked_copied > 0 then
                        vim.notify(
                            string.format("[Vibe] .vibeinclude: copied %d untracked file(s)", untracked_copied),
                            vim.log.levels.INFO
                        )
                    else
                        vim.notify("[Vibe] .vibeinclude found but no untracked files matched", vim.log.levels.WARN)
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

                copy_gitignore_to_worktree(repo_root, worktree_path)

                git_cmd({ "add", "-A" }, { cwd = worktree_path })
                local _, commit_code, commit_err = git_cmd(
                    { "commit", "-m", "Vibe snapshot", "--allow-empty" },
                    { cwd = worktree_path }
                )
                if commit_code ~= 0 then
                    git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = repo_cwd, ignore_error = true })
                    callback(nil, "Failed to create snapshot commit: " .. (commit_err or "unknown error"))
                    return
                end

                local commit_hash, _, hash_err = git_cmd({ "rev-parse", "HEAD" }, { cwd = worktree_path })
                if not commit_hash or commit_hash == "" then
                    git_cmd({ "worktree", "remove", "--force", worktree_path }, { cwd = repo_cwd, ignore_error = true })
                    callback(nil, "Failed to get commit hash: " .. (hash_err or "unknown error"))
                    return
                end

                local info = {
                    name = session_name,
                    worktree_path = worktree_path,
                    branch = branch_name,
                    snapshot_commit = commit_hash:gsub("^%s+", ""):gsub("%s+$", ""),
                    original_branch = original_branch,
                    repo_root = repo_root,
                    uuid = uuid,
                    created_at = created_at,
                    addressed_hunks = {},
                }
                M.worktrees[worktree_path] = info

                persist.save_session(
                    vim.tbl_extend("force", info, { cwd = repo_cwd, last_active = os.time(), has_terminal = true })
                )

                vim.notify("[Vibe] Created worktree: " .. worktree_path, vim.log.levels.INFO)
                M.pending_creations[session_name] = nil
                callback(info, nil)
            end
        )
        pending.job_id = job_id
    end

    try_worktree_add()
end

--- Cancel a pending worktree creation
---@param session_name string
function M.cancel_creation(session_name)
    local pending = M.pending_creations[session_name]
    if not pending then
        return
    end

    pending.cancelled = true

    -- Stop the running job
    if pending.job_id then
        pcall(vim.fn.jobstop, pending.job_id)
    end

    -- Clean up partial worktree and branch
    if pending.worktree_path and pending.repo_root then
        git_cmd({ "worktree", "remove", "--force", pending.worktree_path }, { cwd = pending.repo_root, ignore_error = true })
        if pending.branch then
            git_cmd({ "branch", "-D", pending.branch }, { cwd = pending.repo_root, ignore_error = true })
        end
        if vim.fn.isdirectory(pending.worktree_path) == 1 then
            vim.fn.delete(pending.worktree_path, "rf")
        end
    end

    M.pending_creations[session_name] = nil
end

--- Cancel all pending worktree creations
function M.cancel_all_creations()
    local names = {}
    for session_name, _ in pairs(M.pending_creations) do
        table.insert(names, session_name)
    end
    for _, session_name in ipairs(names) do
        M.cancel_creation(session_name)
    end
end

function M.scan_for_vibe_worktrees()
    local base_dir = get_worktree_base_dir()
    if vim.fn.isdirectory(base_dir) == 0 then
        return
    end

    local persisted = persist.get_valid_persisted_sessions()
    local persisted_by_path = {}
    for _, s in ipairs(persisted) do
        persisted_by_path[s.worktree_path] = s
    end

    for _, uuid in ipairs(vim.fn.readdir(base_dir) or {}) do
        local worktree_path = base_dir .. "/" .. uuid
        if vim.fn.isdirectory(worktree_path) == 1 and not M.worktrees[worktree_path] then
            local branch = M.get_current_branch(worktree_path)
            if branch and branch:match("^vibe%-") then
                local main_repo_root = nil
                local wt_list = git_cmd({ "worktree", "list" }, { cwd = worktree_path, ignore_error = true })
                if wt_list then
                    local first_line = wt_list:match("[^\r\n]+")
                    if first_line then
                        main_repo_root = first_line:match("^%S+")
                    end
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
                    local persisted_info = persisted_by_path[worktree_path]
                    local snapshot_commit = persisted_info and persisted_info.snapshot_commit or nil

                    if not snapshot_commit or snapshot_commit == "" then
                        local log_output = git_cmd(
                            { "log", "--reverse", "--format=%H", "-n", "1" },
                            { cwd = worktree_path, ignore_error = true }
                        )
                        snapshot_commit = log_output and log_output:gsub("^%s+", ""):gsub("%s+$", "") or nil
                    end

                    if not snapshot_commit or snapshot_commit == "" then
                        local first_commit = git_cmd(
                            { "rev-list", "--max-parents=0", "HEAD" },
                            { cwd = worktree_path, ignore_error = true }
                        )
                        if first_commit and first_commit ~= "" then
                            snapshot_commit = first_commit:gsub("^%s+", ""):gsub("%s+$", "")
                        end
                    end

                    local created_at = persisted_info and persisted_info.created_at or os.time()

                    if not persisted_info then
                        local ts_part = uuid:match("^(%d+%-?%d+)%-")
                        if ts_part then
                            local year, month, day, hour, min, sec =
                                ts_part:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
                            if year then
                                created_at = os.time({
                                    year = tonumber(year),
                                    month = tonumber(month),
                                    day = tonumber(day),
                                    hour = tonumber(hour),
                                    min = tonumber(min),
                                    sec = tonumber(sec),
                                }) or os.time()
                            end
                        end
                    end

                    M.worktrees[worktree_path] = {
                        name = persisted_info and persisted_info.name or uuid:sub(1, 8),
                        worktree_path = worktree_path,
                        branch = branch,
                        snapshot_commit = snapshot_commit,
                        original_branch = persisted_info and persisted_info.original_branch or "main",
                        repo_root = main_repo_root,
                        uuid = uuid,
                        created_at = created_at,
                        addressed_hunks = persisted_info and persisted_info.addressed_hunks or {},
                        manually_modified_files = persisted_info and persisted_info.manually_modified_files or {},
                    }
                end
            end
        end
    end
end

function M.remove_worktree(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info then
        return false, "Worktree not found"
    end

    local _, remove_code, remove_err = git_cmd(
        { "worktree", "remove", "--force", worktree_path },
        { cwd = info.repo_root, ignore_error = true }
    )
    git_cmd({ "branch", "-D", info.branch }, { cwd = info.repo_root, ignore_error = true })

    M.worktrees[worktree_path] = nil
    persist.remove_session(worktree_path)
    if vim.fn.isdirectory(worktree_path) == 1 then
        vim.fn.delete(worktree_path, "rf")
    end

    if remove_code ~= 0 then
        return false, "Failed to remove worktree: " .. (remove_err or "unknown error")
    end
    vim.notify("[Vibe] Removed worktree: " .. worktree_path, vim.log.levels.INFO)
    return true, nil
end

function M.discard_worktree(worktree_path)
    return M.remove_worktree(worktree_path)
end

function M.get_worktree_info(worktree_path)
    return M.worktrees[worktree_path]
end

function M.get_worktree_by_session(session_name)
    for _, info in pairs(M.worktrees) do
        if info.name == session_name then
            return info
        end
    end
    return nil
end

function M.cleanup_all_worktrees()
    local paths = {}
    for worktree_path, _ in pairs(M.worktrees) do
        table.insert(paths, worktree_path)
    end
    for _, worktree_path in ipairs(paths) do
        M.remove_worktree(worktree_path)
    end
end

--- Recursively enumerate all files in a directory
---@param dir_path string Absolute path to directory
---@param repo_root string Root for computing relative paths
---@return string[] List of relative file paths
local function enumerate_files_recursive(dir_path, repo_root)
    local files = {}
    local handle = vim.uv.fs_scandir(dir_path)
    if not handle then
        return files
    end
    while true do
        local name, ftype = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if name ~= ".git" then
            local full = dir_path .. "/" .. name
            if ftype == "directory" then
                vim.list_extend(files, enumerate_files_recursive(full, repo_root))
            else
                table.insert(files, full:sub(#repo_root + 2))
            end
        end
    end
    return files
end

--- Copy local files to an active worktree and update the snapshot commit.
--- After copying, creates a new snapshot so the review system sees proper
--- per-hunk diffs instead of treating copied files as entirely new.
---@param worktree_path string Path to the active worktree
---@param relative_paths string[] Relative file or directory paths to copy
---@return boolean ok
---@return string|nil error message
---@return integer copied_count Number of files actually copied
function M.copy_files_to_active_worktree(worktree_path, relative_paths)
    local info = M.worktrees[worktree_path]
    if not info then
        return false, "Worktree not found", 0
    end

    local repo_root = info.repo_root
    local copied_files = {}

    -- Copy files, expanding directories to individual files
    for _, rel_path in ipairs(relative_paths) do
        local src = repo_root .. "/" .. rel_path
        if vim.fn.isdirectory(src) == 1 then
            local sub_files = enumerate_files_recursive(src, repo_root)
            for _, sub_file in ipairs(sub_files) do
                local sub_src = repo_root .. "/" .. sub_file
                local sub_dst = worktree_path .. "/" .. sub_file
                if vim.fn.filereadable(sub_src) == 1 then
                    vim.fn.mkdir(vim.fn.fnamemodify(sub_dst, ":h"), "p")
                    vim.fn.writefile(vim.fn.readfile(sub_src, "b"), sub_dst, "b")
                    table.insert(copied_files, sub_file)
                end
            end
        elseif vim.fn.filereadable(src) == 1 then
            local dst = worktree_path .. "/" .. rel_path
            vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
            vim.fn.writefile(vim.fn.readfile(src, "b"), dst, "b")
            table.insert(copied_files, rel_path)
        end
    end

    if #copied_files == 0 then
        return false, "No files were copied", 0
    end

    -- Unstage any AI-staged changes to prevent them leaking into snapshot
    git_cmd({ "reset", "HEAD", "--quiet" }, { cwd = worktree_path, ignore_error = true })

    -- Stage only the copied files
    local add_args = { "add", "--" }
    for _, f in ipairs(copied_files) do
        table.insert(add_args, f)
    end
    git_cmd(add_args, { cwd = worktree_path })

    -- Create new snapshot commit
    local _, commit_code, commit_err = git_cmd(
        { "commit", "-m", "Vibe snapshot (file sync)", "--allow-empty" },
        { cwd = worktree_path }
    )
    if commit_code ~= 0 then
        return false, "Failed to update snapshot: " .. (commit_err or "unknown"), #copied_files
    end

    -- Get new commit hash
    local new_hash = git_cmd({ "rev-parse", "HEAD" }, { cwd = worktree_path })
    if not new_hash or new_hash == "" then
        return false, "Failed to get new commit hash", #copied_files
    end

    -- Update in-memory state
    info.snapshot_commit = new_hash:gsub("^%s+", ""):gsub("%s+$", "")

    -- Clear addressed hunks for copied files (base changed, old hashes invalid)
    if info.addressed_hunks then
        local copied_set = {}
        for _, f in ipairs(copied_files) do
            copied_set[f] = true
        end
        local new_hunks = {}
        for _, hunk in ipairs(info.addressed_hunks) do
            if not copied_set[hunk.filepath] then
                table.insert(new_hunks, hunk)
            end
        end
        info.addressed_hunks = new_hunks
    end

    -- Clear manually_modified_files entries for copied files
    if info.manually_modified_files then
        for _, f in ipairs(copied_files) do
            info.manually_modified_files[f] = nil
        end
    end

    -- Persist to disk
    local persisted = persist.load_sessions()
    for _, s in ipairs(persisted) do
        if s.worktree_path == worktree_path then
            s.snapshot_commit = info.snapshot_commit
            s.addressed_hunks = info.addressed_hunks
            break
        end
    end
    persist.save_sessions(persisted)

    return true, nil, #copied_files
end

---@param worktree_path string
---@return boolean ok
---@return string|nil error
---@return integer synced_count
function M.sync_local_to_worktree(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info then
        return false, "Worktree not found", 0
    end

    local repo_root = info.repo_root
    local sync_list = {}

    -- Tracked files: sync if local content differs from worktree content
    local tracked_output = git_cmd({ "ls-files" }, { cwd = repo_root, ignore_error = true })
    for file in (tracked_output or ""):gmatch("[^\r\n]+") do
        if file ~= "" then
            local local_path = repo_root .. "/" .. file
            local wt_path = worktree_path .. "/" .. file
            if vim.fn.filereadable(local_path) == 1 and files_differ(local_path, wt_path) then
                table.insert(sync_list, file)
            end
        end
    end

    -- Untracked files: sync only if already in worktree and content differs
    local untracked_output = git_cmd(
        { "ls-files", "--others", "--exclude-standard" },
        { cwd = repo_root, ignore_error = true }
    )
    for file in (untracked_output or ""):gmatch("[^\r\n]+") do
        if file ~= "" then
            local local_path = repo_root .. "/" .. file
            local wt_path = worktree_path .. "/" .. file
            if files_differ(local_path, wt_path) then
                table.insert(sync_list, file)
            end
        end
    end

    if #sync_list == 0 then
        return true, nil, 0
    end

    return M.copy_files_to_active_worktree(worktree_path, sync_list)
end

--- Parse .gitignore and return patterns (excluding comments, blanks, negations)
---@param repo_root string
---@return string[]|nil
function M.parse_gitignore(repo_root)
    local gitignore_path = repo_root .. "/.gitignore"
    if vim.fn.filereadable(gitignore_path) ~= 1 then
        return nil
    end
    local patterns = {}
    for line in io.lines(gitignore_path) do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") and not line:match("^!") then
            table.insert(patterns, line)
        end
    end
    return #patterns > 0 and patterns or nil
end

--- Check if a filepath matches any gitignore pattern
---@param filepath string
---@param patterns string[]
---@return boolean
function M.matches_gitignore(filepath, patterns)
    for _, pattern in ipairs(patterns) do
        local pat = pattern:gsub("/$", "") -- strip trailing /
        if pat:find("/") then
            -- Anchored pattern: match against full path
            pat = pat:gsub("^/", "")
            if
                M.matches_patterns(filepath, { pat })
                or M.matches_patterns(filepath, { pat .. "/**" })
            then
                return true
            end
            -- **/ prefix means "at any depth, including root" — also try bare suffix
            local bare = pat:match("^%*%*/(.*)")
            if bare then
                if
                    M.matches_patterns(filepath, { bare })
                    or M.matches_patterns(filepath, { bare .. "/**" })
                then
                    return true
                end
            end
        else
            -- Unanchored: match if any path segment matches, or as prefix
            if
                M.matches_patterns(filepath, { pat })
                or M.matches_patterns(filepath, { pat .. "/**" })
                or M.matches_patterns(filepath, { "**/" .. pat })
                or M.matches_patterns(filepath, { "**/" .. pat .. "/**" })
            then
                return true
            end
        end
    end
    return false
end

return M
