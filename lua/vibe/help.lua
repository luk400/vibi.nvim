local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

--- Determine the current UI context and the associated buffer
---@return string context, integer|nil bufnr
local function get_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype

    if ft == "vibe" then
        return "terminal", bufnr
    end

    local renderer = require("vibe.review.renderer")
    if renderer.buffer_state[bufnr] then
        return "review", bufnr
    end

    if ft == "vibe_dialog" then
        return "dialog", bufnr
    end

    return "normal", bufnr
end

local function get_help_lines(context, bufnr)
    local lines = { " Vibe Help", " " .. string.rep("─", 50), "" }

    if context == "terminal" then
        table.insert(lines, " Terminal Mode:")
        table.insert(lines, "  <Esc><Esc>    Exit terminal mode")
        table.insert(lines, "  <C-n>         Next session")
        table.insert(lines, "  <C-p>         Previous session")
        table.insert(lines, "  q / <Esc>     Close window (normal mode)")
        table.insert(lines, "  <M-h/j/k/l>  Navigate windows")
    elseif context == "review" then
        local kd = require("vibe.review.keymap_display")
        local function k(desc, fb)
            return kd.get_key_or_fallback(bufnr, desc, fb)
        end

        table.insert(lines, " Review Mode:")
        table.insert(lines, "")
        table.insert(lines, " Suggestions (your change / AI suggestion / both agree):")
        table.insert(lines, string.format("  %-14s Accept change", k(kd.DESC_ACCEPT, "<leader>a")))
        table.insert(lines, string.format("  %-14s Reject change (keep base)", k(kd.DESC_REJECT, "<leader>r")))
        table.insert(lines, "")
        table.insert(lines, " Conflicts:")
        table.insert(lines, string.format("  %-14s Keep your version", k(kd.DESC_KEEP_YOURS, "<leader>k")))
        table.insert(lines, string.format("  %-14s Keep AI version", k(kd.DESC_ACCEPT, "<leader>a")))
        table.insert(lines, string.format("  %-14s Edit manually", k(kd.DESC_EDIT, "<leader>e")))
        table.insert(lines, "")
        table.insert(lines, " Navigation:")
        table.insert(lines, string.format("  %-14s Next item", k(kd.DESC_NEXT, "]c")))
        table.insert(lines, string.format("  %-14s Previous item", k(kd.DESC_PREV, "[c")))
        table.insert(lines, string.format("  %-14s Scroll preview down", k(kd.DESC_SCROLL_DOWN, "<leader>d")))
        table.insert(lines, string.format("  %-14s Scroll preview up", k(kd.DESC_SCROLL_UP, "<leader>u")))
        table.insert(lines, string.format("  %-14s Quit review", k(kd.DESC_QUIT, "q")))
        table.insert(lines, "  :VibeAcceptAll  Accept all items")
    elseif context == "dialog" then
        table.insert(lines, " File Dialog:")
        table.insert(lines, "  <CR>          View file (granular review)")
        table.insert(lines, "  a             Accept file (use AI version)")
        table.insert(lines, "  r             Reject file (keep yours)")
        table.insert(lines, "  A             Accept all files")
        table.insert(lines, "  j/k           Navigate")
        table.insert(lines, "  q/<Esc>       Back to review list")
    else
        table.insert(lines, " Commands:")
        table.insert(lines, "  :Vibe [name]     Toggle terminal (smart)")
        table.insert(lines, "  :VibeList        List sessions")
        table.insert(lines, "  :VibeKill [name] Kill session")
        table.insert(lines, "  :VibeReview      Review AI changes")
        table.insert(lines, "  :VibeResume      Resume paused session")
        table.insert(lines, "  :VibeStatus      Show status summary")
        table.insert(lines, "  :VibeDiff        Diff current file")
        table.insert(lines, "  :VibeRename [new] Rename current session (or :VibeRename old new)")
        table.insert(lines, "  :VibeHistory     Session history")
        table.insert(lines, "  :VibeLog [name]  View terminal logs")
        table.insert(lines, "  :VibeHelp        This help")
        table.insert(lines, "")
        table.insert(lines, " Merge Modes (set via config or review picker):")
        table.insert(lines, "  none    Review everything")
        table.insert(lines, "  user    Auto-merge user changes (default)")
        table.insert(lines, "  ai      Auto-merge AI changes")
        table.insert(lines, "  both    Auto-merge all safe changes")
    end

    table.insert(lines, "")
    table.insert(lines, " q close")
    return lines
end

function M.show()
    local context, bufnr = get_context()
    local lines = get_help_lines(context, bufnr)

    local help_bufnr, _, _ = util.create_centered_float({
        lines = lines,
        filetype = "vibe_help",
        min_width = 60,
        title = "Vibe Help",
    })
    vim.api.nvim_buf_add_highlight(help_bufnr, -1, "Title", 0, 0, -1)
end

return M
