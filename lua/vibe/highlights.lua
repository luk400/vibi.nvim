--- Centralized highlight definitions for all Vibe modules.
--- All highlight groups are driven by config.options.highlights.theme
--- and can be individually overridden via config.options.highlights.overrides.
local config = require("vibe.config")

local M = {}

--- Apply all highlight groups and sign definitions based on current config.
function M.apply()
    local theme = config.options.highlights.theme
    local overrides = config.options.highlights.overrides or {}

    -- Build highlight definitions from theme values
    local defs = {
        -- Review: suggestion regions
        VibeRegionSuggestion   = { fg = theme.suggestion_fg, bold = true, default = true },
        VibeRegionSuggestionBg = { bg = theme.suggestion_bg, default = true },

        -- Review: convergent regions
        VibeRegionConvergent   = { fg = theme.convergent_fg, bold = true, default = true },
        VibeRegionConvergentBg = { bg = theme.convergent_bg, default = true },

        -- Review: conflict regions
        VibeRegionConflictBg   = { bg = theme.conflict_bg, default = true },

        -- Auto-merged regions
        VibeRegionAutoMerged   = { bg = theme.convergent_bg, default = true },
        VibeAutoMergedAdd      = { bg = theme.convergent_bg, default = true },
        VibeAutoMergedDelete   = { bg = theme.conflict_bg, fg = theme.delete_fg, default = true },
        VibeAutoMergedChange   = { bg = theme.change_bg, default = true },
        VibeDeleteSentinel     = { bg = theme.conflict_bg, fg = theme.delete_fg, default = true },

        -- Preview sections
        VibePreviewUser        = { fg = theme.suggestion_fg, bold = true, default = true },
        VibePreviewAI          = { fg = theme.ai_fg, bold = true, default = true },
        VibePreviewBase        = { fg = theme.base_fg, default = true },
        VibePreviewKeymap      = { fg = theme.suggestion_fg, bold = true, default = true },

        -- Inline display highlights (background-only for code readability)
        VibeConflictInline     = { bg = theme.conflict_bg, default = true },
        VibeSuggestionInline   = { bg = theme.suggestion_bg, default = true },
        VibeConvergentInline   = { bg = theme.convergent_bg, default = true },

        -- Diff module highlights
        VibeUserAddition       = { link = "DiagnosticInfo", default = true },
        VibeConflictCollapsed  = { link = "DiagnosticError", default = true },

        -- Dialog highlights
        VibeDialogHeader       = { link = "Title" },
        VibeDialogFile         = { link = "Normal" },
        VibeDialogSelected     = { link = "Visual" },
        VibeDialogFooter       = { link = "Comment" },

        -- File picker highlights
        VibePickerUntracked    = { default = true, fg = "#a6e3a1", bold = true },
        VibePickerModified     = { default = true, fg = "#f9e2af" },
        VibePickerIgnored      = { default = true, fg = "#6c7086", italic = true },
        VibePickerNormal       = { default = true, link = "Normal" },
        VibePickerSelected     = { default = true, fg = "#a6e3a1", bold = true },
        VibePickerDir          = { default = true, fg = "#89b4fa", bold = true },
        VibePickerHeader       = { default = true, link = "Title" },
        VibePickerFooter       = { default = true, link = "Comment" },

        -- Large file dialog highlights
        VibeLargeFileIgnore    = { default = true, fg = "#6c7086", italic = true },
        VibeLargeFileCopyOver  = { default = true, fg = "#a6e3a1", bold = true },
        VibeLargeFileMerge     = { default = true, fg = "#f9e2af", bold = true },
        VibeLargeFileDir       = { default = true, fg = "#89b4fa", bold = true },
        VibeLargeFileSize      = { default = true, link = "Comment" },

        -- Status highlight
        VibeActive             = { link = "WarningMsg" },
    }

    -- Apply per-group overrides (replaces entire definition for that group)
    for group, hl_opts in pairs(overrides) do
        if type(hl_opts) == "table" then
            defs[group] = hl_opts
        end
    end

    -- Clear then set all highlight groups (clear first so default=true works on re-apply)
    for group, _ in pairs(defs) do
        vim.api.nvim_set_hl(0, group, {})
    end
    for group, opts in pairs(defs) do
        vim.api.nvim_set_hl(0, group, opts)
    end

    -- Sign definitions
    vim.fn.sign_define("VibeReviewConflict", { text = "!", texthl = "ErrorMsg" })
    vim.fn.sign_define("VibeReviewSuggestion", { text = "~", texthl = "WarningMsg" })
    vim.fn.sign_define("VibeReviewConvergent", { text = "=", texthl = "String" })
    vim.fn.sign_define("VibeDiffHunk", { text = "│", texthl = "WarningMsg" })
    vim.fn.sign_define("VibeDiffConflict", { text = "!", texthl = "ErrorMsg" })
end

--- Setup highlights and register ColorScheme autocmd to re-apply on theme change.
function M.setup()
    M.apply()

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("VibeHighlights", { clear = true }),
        callback = function()
            M.apply()
        end,
    })
end

return M
