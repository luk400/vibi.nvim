--- Re-exports for backward compatibility
--- All consumers can continue using require("vibe.git").function_name()
local worktree = require("vibe.git.worktree")
local git_diff = require("vibe.git.diff")
local apply = require("vibe.git.apply")
local git_cmd_mod = require("vibe.git.cmd")
local persist = require("vibe.persist")

local M = {}

-- Shared worktree state (single source of truth)
M.worktrees = worktree.worktrees

-- git/cmd.lua
M.git_cmd = git_cmd_mod.git_cmd
M.with_temp_files = git_cmd_mod.with_temp_files

-- git/worktree.lua
M.is_git_repo = worktree.is_git_repo
M.get_repo_root = worktree.get_repo_root
M.get_current_branch = worktree.get_current_branch
M.create_worktree = worktree.create_worktree
M.create_worktree_async = worktree.create_worktree_async
M.scan_for_vibe_worktrees = worktree.scan_for_vibe_worktrees
M.remove_worktree = worktree.remove_worktree
M.discard_worktree = worktree.discard_worktree
M.get_worktree_info = worktree.get_worktree_info
M.get_worktree_by_session = worktree.get_worktree_by_session
M.cleanup_all_worktrees = worktree.cleanup_all_worktrees
M.matches_patterns = worktree.matches_patterns
M.parse_gitignore = worktree.parse_gitignore
M.matches_gitignore = worktree.matches_gitignore
M.pending_creations = worktree.pending_creations
M.cancel_creation = worktree.cancel_creation
M.cancel_all_creations = worktree.cancel_all_creations
M.copy_files_to_active_worktree = worktree.copy_files_to_active_worktree
M.sync_local_to_worktree = worktree.sync_local_to_worktree

-- git/diff.lua
M.hunk_hash = git_diff.hunk_hash
M.read_file_at_commit = git_diff.read_file_at_commit
M.get_worktree_file_hunks = git_diff.get_worktree_file_hunks

function M.get_worktree_snapshot_lines(worktree_path, filepath)
    return git_diff.get_worktree_snapshot_lines(M.worktrees, worktree_path, filepath)
end

function M.get_user_added_lines(worktree_path, filepath, user_file_path)
    return git_diff.get_user_added_lines(M.worktrees, worktree_path, filepath, user_file_path)
end

-- git/apply.lua (adapt to pass worktrees implicitly)
function M.apply_classified_resolution(worktree_path, filepath, resolved_lines, user_file_path)
    return apply.apply_classified_resolution(M.worktrees, worktree_path, filepath, resolved_lines, user_file_path)
end

function M.sync_resolved_file(worktree_path, filepath, user_file_path)
    return apply.sync_resolved_file(M.worktrees, worktree_path, filepath, user_file_path)
end

function M.accept_file_from_worktree(worktree_path, filepath, repo_root)
    return apply.accept_file_from_worktree(M.worktrees, worktree_path, filepath, repo_root)
end

function M.accept_all_from_worktree(worktree_path)
    return apply.accept_all_from_worktree(M.worktrees, worktree_path, M.get_worktree_changed_files)
end

function M.merge_accept_file(worktree_path, filepath, merge_mode, repo_root)
    return apply.merge_accept_file(M.worktrees, worktree_path, filepath, merge_mode, repo_root)
end

function M.merge_accept_all(worktree_path, merge_mode)
    return apply.merge_accept_all(M.worktrees, worktree_path, M.get_unresolved_files, merge_mode)
end

function M.mark_hunk_addressed(worktree_path, filepath, hunk, action)
    return apply.mark_hunk_addressed(M.worktrees, worktree_path, filepath, hunk, action)
end

function M.is_file_fully_addressed(worktree_path, filepath)
    return apply.is_file_fully_addressed(M.worktrees, worktree_path, filepath, M.get_worktree_file_hunks)
end

-- Composite functions that use multiple submodules
function M.get_worktree_changed_files(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info then
        return {}
    end

    local snapshot_commit = info.snapshot_commit
    if not snapshot_commit or snapshot_commit == "" then
        local first_commit = git_cmd_mod.git_cmd(
            { "rev-list", "--max-parents=0", "HEAD" },
            { cwd = worktree_path, ignore_error = true }
        )
        if first_commit and first_commit ~= "" then
            snapshot_commit = first_commit:gsub("^%s+", ""):gsub("%s+$", "")
        else
            snapshot_commit = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        end
    end

    local output = git_cmd_mod.git_cmd(
        { "diff", "--name-only", snapshot_commit },
        { cwd = worktree_path, ignore_error = true }
    )
    local untracked_output = git_cmd_mod.git_cmd(
        { "ls-files", "--others", "--exclude-standard" },
        { cwd = worktree_path, ignore_error = true }
    )

    local files, seen = {}, {}
    local function process_output(out)
        for file in (out or ""):gmatch("[^\r\n]+") do
            if file ~= "" and not seen[file] then
                seen[file] = true
                table.insert(files, file)
            end
        end
    end

    process_output(output)
    process_output(untracked_output)

    local gitignore_patterns = worktree.parse_gitignore(info.repo_root)
    local ignored_count = 0
    if gitignore_patterns then
        local filtered = {}
        for _, file in ipairs(files) do
            if worktree.matches_gitignore(file, gitignore_patterns) then
                ignored_count = ignored_count + 1
            else
                table.insert(filtered, file)
            end
        end
        files = filtered
    end
    return files, ignored_count
end

function M.get_worktree_commit_messages(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info or not info.snapshot_commit then
        return {}
    end

    local output = git_cmd_mod.git_cmd(
        { "log", info.snapshot_commit .. "..HEAD", "--format=%s" },
        { cwd = worktree_path, ignore_error = true }
    )

    local messages = {}
    for msg in (output or ""):gmatch("[^\r\n]+") do
        if
            msg ~= ""
            and msg ~= "Vibe snapshot"
            and msg ~= "Vibe snapshot (accepted)"
            and msg ~= "Vibe snapshot (file sync)"
        then
            table.insert(messages, msg)
        end
    end
    return messages
end

function M.get_unresolved_files(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info then
        return {}
    end

    local changed_files, ignored_count = M.get_worktree_changed_files(worktree_path)
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
                        if worktree_lines[i] ~= user_lines[i] then
                            table.insert(unresolved, filepath)
                            break
                        end
                    end
                end
            end
        end
    end

    return unresolved, ignored_count or 0
end

function M.get_worktrees_with_changes()
    M.scan_for_vibe_worktrees()
    local result = {}
    for _, info in pairs(M.worktrees) do
        if #M.get_worktree_changed_files(info.worktree_path) > 0 then
            table.insert(result, info)
        end
    end
    return result
end

function M.get_worktrees_with_unresolved_files()
    M.scan_for_vibe_worktrees()
    local result = {}
    for _, info in pairs(M.worktrees) do
        if #M.get_unresolved_files(info.worktree_path) > 0 then
            table.insert(result, info)
        elseif #M.get_worktree_changed_files(info.worktree_path) > 0 then
            M.update_snapshot(info.worktree_path)
        end
    end
    return result
end

function M.has_worktrees_with_changes()
    for _, info in pairs(M.worktrees) do
        if #M.get_unresolved_files(info.worktree_path) > 0 then
            return true
        end
    end
    return false
end

--- Update the snapshot commit after all changes have been accepted/resolved.
--- This resets the baseline so that future reviews only show new changes.
---@param worktree_path string
---@return boolean ok
---@return string|nil error
function M.update_snapshot(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info then
        return false, "Worktree not found"
    end

    -- Stage all current worktree state
    git_cmd_mod.git_cmd({ "add", "-A" }, { cwd = worktree_path })

    -- Create new snapshot commit
    local _, commit_code, commit_err = git_cmd_mod.git_cmd(
        { "commit", "-m", "Vibe snapshot (accepted)", "--allow-empty" },
        { cwd = worktree_path }
    )
    if commit_code ~= 0 then
        return false, "Failed to update snapshot: " .. (commit_err or "unknown")
    end

    -- Get new commit hash
    local commit_hash = git_cmd_mod.git_cmd({ "rev-parse", "HEAD" }, { cwd = worktree_path })
    if not commit_hash or commit_hash == "" then
        return false, "Failed to get commit hash"
    end

    -- Update in-memory state
    info.snapshot_commit = commit_hash:gsub("^%s+", ""):gsub("%s+$", "")
    info.addressed_hunks = {}
    info.manually_modified_files = {}

    -- Persist to disk
    local persisted = persist.load_sessions()
    for _, s in ipairs(persisted) do
        if s.worktree_path == worktree_path then
            s.snapshot_commit = info.snapshot_commit
            s.addressed_hunks = {}
            break
        end
    end
    persist.save_sessions(persisted)

    -- If this is a merge session, auto-clean its source sessions
    if info.source_worktrees and #info.source_worktrees > 0 then
        M.finalize_merge_sources(worktree_path)
    end

    return true
end

--- After a merge session's review is completed, sync and clean its source sessions.
--- This prevents source worktrees from appearing dirty in :VibeReview.
---@param worktree_path string The merge worktree that was just accepted
---@return integer cleaned_count Number of source sessions cleaned
function M.finalize_merge_sources(worktree_path)
    local info = M.worktrees[worktree_path]
    if not info or not info.source_worktrees or #info.source_worktrees == 0 then
        return 0
    end

    -- Copy and clear source list FIRST to prevent any recursion
    local source_paths = info.source_worktrees
    info.source_worktrees = nil

    -- Persist the cleared field immediately
    local persisted_sessions = persist.load_sessions()
    for _, s in ipairs(persisted_sessions) do
        if s.worktree_path == worktree_path then
            s.source_worktrees = nil
            break
        end
    end
    persist.save_sessions(persisted_sessions)

    -- Ensure all worktrees are discovered
    M.scan_for_vibe_worktrees()

    local cleaned = 0
    local cleaned_names = {}

    for _, source_path in ipairs(source_paths) do
        local source_info = M.worktrees[source_path]
        if source_info then
            -- Sync local state to source worktree (as if user ran :VibeSync)
            M.sync_local_to_worktree(source_path)

            -- Update snapshot to mark as clean
            local ok = M.update_snapshot(source_path)
            if ok then
                cleaned = cleaned + 1
                table.insert(cleaned_names, source_info.name)
            end
        end
    end

    if cleaned > 0 then
        vim.notify(
            string.format(
                "[Vibe] Auto-cleaned %d source session(s): %s",
                cleaned,
                table.concat(cleaned_names, ", ")
            ),
            vim.log.levels.INFO
        )
    end

    return cleaned
end

-- Legacy Compatibility
M.original_branch = nil
M.vibe_branch = nil
M.snapshot_commit = nil

function M.get_changed_files()
    local info = M.get_worktree_by_session("default")
    return info and M.get_worktree_changed_files(info.worktree_path) or {}
end

function M.accept_all()
    local info = M.get_worktree_by_session("default")
    if info then
        local ok, err = M.accept_all_from_worktree(info.worktree_path)
        if ok then
            M.remove_worktree(info.worktree_path)
            M:reset()
        end
        return ok, err
    end
    return false, "No active session"
end

function M.reject_all()
    local info = M.get_worktree_by_session("default")
    if info then
        M.remove_worktree(info.worktree_path)
        M:reset()
        return true, nil
    end
    return false, "No active session"
end

function M.reject_file(filepath)
    return true, nil
end

function M.accept_hunk(filepath, hunk, current_lines)
    return true
end

function M.reject_hunk(filepath, hunk)
    local info = M.get_worktree_by_session("default")
    if not info then
        return false, "No active session"
    end
    -- Legacy: uses internal modify_user_file pattern
    local user_file_path = info.repo_root .. "/" .. filepath
    local bufnr = vim.fn.bufnr(user_file_path)
    local lines
    if bufnr ~= -1 then
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    else
        lines = vim.fn.filereadable(user_file_path) == 1 and vim.fn.readfile(user_file_path) or {}
    end

    local start = hunk.new_start - 1
    if hunk.type == "add" then
        for _ = 1, hunk.new_count do
            table.remove(lines, start + 1)
        end
    elseif hunk.type == "delete" then
        for i, l in ipairs(hunk.removed_lines) do
            table.insert(lines, start + i, l)
        end
    else
        for _ = 1, hunk.new_count do
            table.remove(lines, start + 1)
        end
        for i, l in ipairs(hunk.removed_lines) do
            table.insert(lines, start + i, l)
        end
    end

    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("write")
        end)
    else
        vim.fn.writefile(lines, user_file_path)
    end
    return true
end

function M.cancel_session()
    local info = M.get_worktree_by_session("default")
    if info then
        M.remove_worktree(info.worktree_path)
        M:reset()
    end
    return true, nil
end

function M:reset()
    self.original_branch = nil
    self.vibe_branch = nil
    self.snapshot_commit = nil
end

return M
