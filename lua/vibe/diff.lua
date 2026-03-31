--- Thin routing layer for diff/review display
--- Routes to the unified classification-aware renderer or split view
local config = require("vibe.config")
local git = require("vibe.git")
local dialog = require("vibe.dialog")
local util = require("vibe.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_diff")

function M.show_split_view(worktree_path, filepath)
    local info = git.get_worktree_info(worktree_path)
    if not info then
        return
    end

    local user_file_path = info.repo_root .. "/" .. filepath
    local worktree_file_path = worktree_path .. "/" .. filepath

    if vim.fn.filereadable(worktree_file_path) ~= 1 then
        vim.notify("[Vibe] Worktree file not found: " .. filepath, vim.log.levels.ERROR)
        return
    end

    vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))
    vim.cmd("diffthis")

    vim.cmd("vsplit " .. vim.fn.fnameescape(worktree_file_path))
    local split_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[split_bufnr].readonly = true
    vim.bo[split_bufnr].modifiable = false
    vim.bo[split_bufnr].buftype = "nofile"
    vim.cmd("diffthis")

    vim.keymap.set("n", "q", function()
        vim.cmd("diffoff!")
        vim.cmd("close")
        if worktree_path then
            require("vibe.dialog").show(worktree_path)
        end
    end, { buffer = split_bufnr, silent = true, desc = "Close split diff" })
end

function M.show_for_file(worktree_path, filepath, review_mode)
    review_mode = review_mode or config.options.merge_mode or "user"

    if config.options.diff.mode == "split" then
        M.show_split_view(worktree_path, filepath)
        return
    end

    -- Route to the unified classification-aware renderer
    require("vibe.review.renderer").show_file(worktree_path, filepath, nil, review_mode)
end

function M.show_for_current_file()
    local worktree_path = dialog.get_current_worktree()
    if not worktree_path then
        local worktrees = git.get_worktrees_with_changes()
        if #worktrees == 0 then
            vim.notify("[Vibe] No sessions with changes", vim.log.levels.INFO)
            return
        end
        worktree_path = worktrees[1].worktree_path
    end

    local info = git.get_worktree_info(worktree_path)
    if not info then
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local full_path = vim.api.nvim_buf_get_name(bufnr)
    local filepath = full_path:gsub("^" .. vim.pesc(info.repo_root) .. "/", "")

    if filepath == full_path then
        vim.notify("[Vibe] File not in repository", vim.log.levels.WARN)
        return
    end
    M.show_for_file(worktree_path, filepath, config.options.merge_mode or "user")
end

function M.clear(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    vim.fn.sign_unplace("vibe_diff", { buffer = bufnr })
end

function M.setup()
    vim.fn.sign_define("VibeDiffHunk", { text = "│", texthl = "WarningMsg" })
    vim.fn.sign_define("VibeDiffConflict", { text = "!", texthl = "ErrorMsg" })
    vim.api.nvim_set_hl(0, "VibeUserAddition", { link = "DiagnosticInfo", default = true })
    vim.api.nvim_set_hl(0, "VibeConflictCollapsed", { link = "DiagnosticError", default = true })

    dialog.setup_highlights()
    require("vibe.review.renderer").setup()
end

return M
