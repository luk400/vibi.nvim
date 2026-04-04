local M = {}

---@class VibeDiffConfig
---@field mode "inline"|"split" Diff display mode

---@class VibeAgentGridConfig
---@field max_sessions integer Maximum sessions shown per grid page (default 9)
---@field maximize_keymap string|false Keybinding to toggle maximize in grid mode (default "<leader>m")

---@class VibeLargeFileConfig
---@field threshold integer Size in bytes above which a file is considered "large" (default 1048576 = 1MB)
---@field enabled boolean Enable large file detection dialog before review (default true)

---@class VibeWorktreeConfig
---@field worktree_dir string|nil Custom directory for worktrees (defaults to stdpath("cache") .. "/vibe-worktrees")

---@class VibeThemeColors
---@field suggestion_fg string Foreground for suggestion/user regions (default: "#FCC474" yellow)
---@field suggestion_bg string Background for suggestion regions (default: "#3a2a1a")
---@field convergent_fg string Foreground for convergent regions (default: "#69DB7C" green)
---@field convergent_bg string Background for convergent/auto-merged regions (default: "#1a3a1a")
---@field conflict_bg string Background for conflict regions (default: "#3a1a1a")
---@field delete_fg string Foreground for deleted content (default: "#FF6B6B" red)
---@field base_fg string Foreground for base/previous content (default: "#868E96" grey)
---@field ai_fg string Foreground for AI content in preview (default: "#69DB7C" green)
---@field change_bg string Background for modification indicators (default: "#3a3a1a")

---@class VibeHighlightConfig
---@field theme VibeThemeColors Semantic colors that drive all highlight groups
---@field overrides table<string, vim.api.keyset.highlight> Per-highlight-group overrides

---@class VibeConfig
---@field command string Command to run in the terminal
---@field position string Window position: "right", "left", "centered", "top", "bottom"
---@field window_mode "float"|"split" Window mode: "float" (floating window) or "split" (vim split)
---@field width number Width as fraction of screen (for left/right/centered)
---@field height number Height as fraction of screen (for top/bottom/centered)
---@field keymap string|false Keybinding to toggle vibe window
---@field border string Border style: "none", "single", "double", "rounded", "solid", "shadow"
---@field on_open "save_all"|"save_current"|"none" Action on open
---@field on_close "reload"|"none" Action on close
---@field quit_protection boolean Show dialog on quit when sessions exist (disable for testing)
---@field merge_mode "none"|"user"|"ai"|"both" Auto-merge mode for review
---@field diff VibeDiffConfig Diff display configuration
---@field highlights VibeHighlightConfig Highlight color configuration
---@field session_picker_keymap string|false Keybinding to open session picker in grid mode
---@field enable_agent_grid boolean Enable agent grid mode (show all sessions in a grid)
---@field agent_grid VibeAgentGridConfig Agent grid configuration
---@field auto_scroll boolean Auto-scroll terminal to bottom on new output when window is unfocused (default true)
---@field worktree VibeWorktreeConfig Worktree configuration
---@field large_files VibeLargeFileConfig Large file detection and handling configuration

---@type VibeConfig
M.defaults = {
    command = "claude",
    position = "right",
    window_mode = "float",
    width = 0.5,
    height = 0.8,
    keymap = "<leader>v",
    border = "rounded",
    on_open = "save_all",
    on_close = "reload",
    quit_protection = true,
    merge_mode = "user", -- "none", "user", "ai", "both"
    diff = {
        mode = "inline", -- "inline" (default) or "split" (side-by-side)
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
    highlights = {
        theme = {
            suggestion_fg = "#FCC474", -- Yellow (foreground for suggestion/user regions)
            suggestion_bg = "#3a2a1a", -- Dark yellow tint (background for suggestion regions)
            convergent_fg = "#69DB7C", -- Green (foreground for convergent regions)
            convergent_bg = "#1a3a1a", -- Dark green tint (background for convergent/auto-merged)
            conflict_bg   = "#3a1a1a", -- Dark red tint (background for conflict regions)
            delete_fg     = "#FF6B6B", -- Red (foreground for deleted content)
            base_fg       = "#868E96", -- Grey (foreground for base/previous content)
            ai_fg         = "#69DB7C", -- Green (foreground for AI content in preview)
            change_bg     = "#3a3a1a", -- Dark yellow-green (background for modifications)
        },
        overrides = {},
    },
    session_picker_keymap = "<leader>s",
    enable_agent_grid = false,
    agent_grid = {
        max_sessions = 9,
        maximize_keymap = "<leader>m",
    },
    auto_scroll = true,
    worktree = {
        -- Custom directory for worktrees (defaults to stdpath("cache") .. "/vibe-worktrees")
        worktree_dir = nil,
    },
    large_files = {
        threshold = 1048576, -- 1MB in bytes
        enabled = true,
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

    local valid_window_modes = { float = true, split = true }
    if options.window_mode and not valid_window_modes[options.window_mode] then
        vim.notify(
            string.format("[Vibe] Invalid window_mode '%s', falling back to 'float'", options.window_mode),
            vim.log.levels.WARN
        )
        options.window_mode = "float"
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

    if options.agent_grid and options.agent_grid.max_sessions then
        local ms = options.agent_grid.max_sessions
        if type(ms) ~= "number" or ms < 1 or math.floor(ms) ~= ms then
            vim.notify("[Vibe] Invalid agent_grid.max_sessions (must be positive integer), falling back to 9", vim.log.levels.WARN)
            options.agent_grid.max_sessions = 9
        end
    end

    if options.highlights and options.highlights.theme then
        local valid_theme_keys = {
            suggestion_fg = true, suggestion_bg = true,
            convergent_fg = true, convergent_bg = true,
            conflict_bg = true, delete_fg = true,
            base_fg = true, ai_fg = true, change_bg = true,
        }
        for key, val in pairs(options.highlights.theme) do
            if not valid_theme_keys[key] then
                vim.notify(
                    string.format("[Vibe] Unknown highlight theme key '%s', ignoring", key),
                    vim.log.levels.WARN
                )
                options.highlights.theme[key] = nil
            elseif type(val) ~= "string" or not val:match("^#%x%x%x%x%x%x$") then
                vim.notify(
                    string.format(
                        "[Vibe] Invalid color '%s' for highlights.theme.%s (expected #RRGGBB), using default",
                        tostring(val), key
                    ),
                    vim.log.levels.WARN
                )
                options.highlights.theme[key] = M.defaults.highlights.theme[key]
            end
        end
    end

    if options.highlights and options.highlights.overrides then
        if type(options.highlights.overrides) ~= "table" then
            vim.notify("[Vibe] highlights.overrides must be a table, ignoring", vim.log.levels.WARN)
            options.highlights.overrides = {}
        end
    end

end

---@param opts VibeConfig|nil
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
    validate_options(M.options)
    return M.options
end

return M
