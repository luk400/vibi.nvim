local M = {}

---@class VibeDiffKeymaps
---@field accept_hunk string Accept current hunk (use disk version)
---@field reject_hunk string Reject current hunk (keep buffer version)
---@field accept_all string Accept all hunks in buffer
---@field reject_all string Reject all hunks in buffer
---@field prev_hunk string Jump to previous hunk
---@field next_hunk string Jump to next hunk
---@field toggle_preview Toggle diff preview window

---@class VibeDiffConfig
---@field enabled boolean Enable diff display
---@field poll_interval number Poll interval in ms (0 = disabled)
---@field on_focus boolean Check on FocusGained
---@field on_enter boolean Check on BufEnter
---@field on_cursor_hold boolean Check on CursorHold/CursorHoldI
---@field on_write boolean Check after writing (to clear diff)
---@field max_lines number Max lines per hunk to display
---@field keymaps VibeDiffKeymaps
---@field review_user_additions boolean (deprecated) Use merge_mode instead
---@field raw_mode boolean (deprecated) No longer used

---@class VibeWorktreeConfig
---@field worktree_dir string|nil Custom directory for worktrees (defaults to stdpath("cache") .. "/vibe-worktrees")

---@class VibeConfig
---@field command string Command to run in the terminal
---@field position string Window position: "right", "left", "centered", "top", "bottom"
---@field width number Width as fraction of screen (for left/right/centered)
---@field height number Height as fraction of screen (for top/bottom/centered)
---@field keymap string|false Keybinding to toggle vibe window
---@field border string Border style: "none", "single", "double", "rounded", "solid", "shadow"
---@field on_open "save_all"|"save_current"|"none" Action on open
---@field on_close "reload"|"none" Action on close
---@field quit_protection boolean Show dialog on quit when sessions exist (disable for testing)
---@field merge_mode "none"|"user"|"ai"|"both" Auto-merge mode for review
---@field diff VibeDiffConfig Diff display configuration
---@field worktree VibeWorktreeConfig Worktree configuration

---@type VibeConfig
M.defaults = {
    command = "claude",
    position = "right",
    width = 0.5,
    height = 0.8,
    keymap = "<leader>v",
    border = "rounded",
    on_open = "save_all",
    on_close = "reload",
    quit_protection = true,
    merge_mode = "user", -- "none", "user", "ai", "both"
    diff = {
        enabled = true,
        mode = "inline", -- "inline" (default) or "split" (side-by-side)
        poll_interval = 500, -- ms, 0 to disable
        on_focus = true,
        on_enter = true,
        on_cursor_hold = true,
        on_write = true,
        max_lines = 100,
        review_user_additions = true, -- If false, auto-accept user additions
        raw_mode = false, -- Show raw git conflict markers instead of virtual lines
        keymaps = {
            accept_hunk = "<leader>da",
            reject_hunk = "<leader>dr",
            accept_all = "<leader>dA",
            reject_all = "<leader>dR",
            prev_hunk = "[d",
            next_hunk = "]d",
            toggle_preview = "<leader>dp",
            keep_ours = "<leader>du",
            keep_both = "<leader>db",
            keep_none = "<leader>dn",
        },
        conflict_popup = {
            enabled = true, -- Show popup for overlapping changes
            width = 60,
            max_height = 20,
            keymaps = {
                accept_user = "u", -- Keep user's version only
                accept_ai = "a", -- Accept AI's version only
                accept_both = "b", -- Keep both user + AI changes
                accept_none = "n", -- Delete all changes in range
                close = "q",
            },
        },
        conflict_buffer = {
            keymaps = {
                keep_ours = "<leader>du",
                keep_theirs = "<leader>da",
                keep_both = "<leader>db",
                keep_none = "<leader>dn",
                accept_all = "<leader>dA",
                reject_all = "<leader>dR",
                next_conflict = "]c",
                prev_conflict = "[c",
                quit = "q",
            },
        },
    },
    history = {
        enabled = true, -- Record session history
        max_entries = 50, -- Maximum history entries to keep
    },
    log = {
        enabled = true, -- Log terminal scrollback on exit
        max_size_mb = 50, -- Max total log directory size
        max_files = 20, -- Max number of log files
    },
    auto_review = {
        enabled = true, -- Show review dialog automatically when AI finishes
        timeout = 2000, -- Time in ms to wait before showing review
    },
    worktree = {
        -- Custom directory for worktrees (defaults to stdpath("cache") .. "/vibe-worktrees")
        worktree_dir = nil,
    },
}

---@type VibeConfig
M.options = {}

local function validate_options(options)
    local valid_positions = { right = true, left = true, centered = true, top = true, bottom = true }
    if options.position and not valid_positions[options.position] then
        vim.notify(
            string.format("[Vibe] Invalid position '%s', falling back to 'right'", options.position),
            vim.log.levels.WARN
        )
        options.position = "right"
    end

    if options.width and (type(options.width) ~= "number" or options.width <= 0 or options.width > 1) then
        vim.notify("[Vibe] Invalid width (must be 0-1), falling back to 0.5", vim.log.levels.WARN)
        options.width = 0.5
    end

    if options.height and (type(options.height) ~= "number" or options.height <= 0 or options.height > 1) then
        vim.notify("[Vibe] Invalid height (must be 0-1), falling back to 0.8", vim.log.levels.WARN)
        options.height = 0.8
    end

    local valid_borders = { none = true, single = true, double = true, rounded = true, solid = true, shadow = true }
    if options.border and type(options.border) == "string" and not valid_borders[options.border] then
        vim.notify(
            string.format("[Vibe] Invalid border '%s', falling back to 'rounded'", options.border),
            vim.log.levels.WARN
        )
        options.border = "rounded"
    end

    local valid_merge_modes = { none = true, user = true, ai = true, both = true }
    if options.merge_mode and not valid_merge_modes[options.merge_mode] then
        vim.notify(
            string.format("[Vibe] Invalid merge_mode '%s', falling back to 'user'", options.merge_mode),
            vim.log.levels.WARN
        )
        options.merge_mode = "user"
    end

    if options.diff and options.diff.review_user_additions == false then
        vim.notify(
            "[Vibe] 'review_user_additions = false' is deprecated. Use merge_mode = 'user' or 'both' instead.",
            vim.log.levels.WARN
        )
    end
end

---@param opts VibeConfig|nil
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
    validate_options(M.options)
    return M.options
end

return M
