--- Merge engine: performs 3-way merge and classification
local git = require("vibe.git")
local classifier = require("vibe.review.classifier")
local config = require("vibe.config")

local M = {}

--- Prepare a full review for a file, returning classified regions and merge output
---@param user_lines string[] Current user file lines
---@param worktree_path string Path to worktree
---@param filepath string Relative file path
---@param session_name string Session name
---@param merge_mode string "none"|"user"|"ai"|"both"
---@return table {classified_file, merged_lines, summary}
function M.prepare_review(user_lines, worktree_path, filepath, session_name, merge_mode)
    merge_mode = merge_mode or config.options.merge_mode or "user"

    local info = git.get_worktree_info(worktree_path)
    local repo_root = info and info.repo_root or ""

    -- Classify the file
    local classified_file = classifier.classify_file(worktree_path, filepath, repo_root)

    -- Apply merge mode to determine auto-resolution
    local summary = classifier.apply_merge_mode(classified_file.regions, merge_mode)

    -- New AI files have no user content to merge with — always auto-resolve
    local types = require("vibe.review.types")
    if classified_file.file_status == types.FILE_NEW_AI then
        for _, region in ipairs(classified_file.regions) do
            if not region.auto_resolved then
                region.auto_resolved = true
                summary.auto_count = summary.auto_count + 1
                if summary.review_count > 0 then
                    summary.review_count = summary.review_count - 1
                end
            end
        end
    end

    -- Also produce git merge-file output for "edit manually" fallback
    local merged_lines = M._run_merge_file(user_lines, worktree_path, filepath, session_name)

    return {
        classified_file = classified_file,
        merged_lines = merged_lines,
        summary = summary,
    }
end

--- Run git merge-file to produce merged output (used for edit-manually fallback)
---@param user_lines string[]
---@param worktree_path string
---@param filepath string
---@param session_name string
---@return string[]
function M._run_merge_file(user_lines, worktree_path, filepath, session_name)
    local base_lines = git.get_worktree_snapshot_lines(worktree_path, filepath)

    local agent_file_path = worktree_path .. "/" .. filepath
    local agent_lines = {}
    if vim.fn.filereadable(agent_file_path) == 1 then
        agent_lines = vim.fn.readfile(agent_file_path)
    end

    local t_local = vim.fn.tempname()
    local t_base = vim.fn.tempname()
    local t_agent = vim.fn.tempname()
    vim.fn.writefile(user_lines, t_local)
    vim.fn.writefile(base_lines, t_base)
    vim.fn.writefile(agent_lines, t_agent)

    local cmd = string.format(
        "git merge-file -p -q -L HEAD -L Base -L vibe-%s %s %s %s",
        vim.fn.shellescape(session_name),
        vim.fn.shellescape(t_local),
        vim.fn.shellescape(t_base),
        vim.fn.shellescape(t_agent)
    )

    local merged_output = vim.fn.systemlist(cmd)

    vim.fn.delete(t_local)
    vim.fn.delete(t_base)
    vim.fn.delete(t_agent)

    return merged_output or {}
end

return M
