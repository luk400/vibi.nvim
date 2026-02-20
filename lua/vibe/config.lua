local M = {}

---@class VibeDiffKeymaps
---@field accept_hunk string Accept current hunk (use disk version)
---@field reject_hunk string Reject current hunk (keep buffer version)
---@field accept_all string Accept all hunks in buffer
---@field reject_all string Reject all hunks in buffer
---@field prev_hunk string Jump to previous hunk
---@field next_hunk string Jump to next hunk
---@field toggle_preview Toggle diff preview window

---@class VibeConflictPopupKeymaps
---@field accept_user string Keep user's version only
---@field accept_ai string Accept AI's version only
---@field accept_both string Keep both user + AI changes
---@field accept_none string Delete all changes in range
---@field close string Close popup

---@class VibeConflictPopupConfig
---@field enabled boolean Show popup for overlapping changes
---@field width number Popup width
---@field max_height number Maximum popup height
---@field keymaps VibeConflictPopupKeymaps

---@class VibeDiffConfig
---@field enabled boolean Enable diff display
---@field poll_interval number Poll interval in ms (0 = disabled)
---@field on_focus boolean Check on FocusGained
---@field on_enter boolean Check on BufEnter
---@field on_cursor_hold boolean Check on CursorHold/CursorHoldI
---@field on_write boolean Check after writing (to clear diff)
---@field max_lines number Max lines per hunk to display
---@field keymaps VibeDiffKeymaps
---@field review_user_additions boolean Whether to show user additions with +~ and require explicit accept/reject
---@field conflict_popup VibeConflictPopupConfig Conflict popup configuration
---@field raw_mode boolean Show raw git conflict markers instead of virtual lines (for debugging)

---@class VibeWorktreeConfig
---@field copy_untracked boolean|string[] Whether to copy untracked files to worktree (true = all, false = none, or list of glob patterns)
---@field use_vibeinclude boolean Use .vibeinclude file for untracked patterns (takes precedence if present)

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
  diff = {
    enabled = true,
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
    },
    conflict_popup = {
      enabled = true,           -- Show popup for overlapping changes
      width = 60,
      max_height = 20,
      keymaps = {
        accept_user = "u",      -- Keep user's version only
        accept_ai = "a",        -- Accept AI's version only
        accept_both = "b",      -- Keep both user + AI changes
        accept_none = "n",      -- Delete all changes in range
        close = "q",
      },
    },
  },
  worktree = {
    -- By default, don't copy untracked files to worktree
    -- Set to true to copy all, or provide a list of glob patterns
    copy_untracked = false,
    -- Use .vibeinclude file if present (takes precedence over copy_untracked patterns)
    use_vibeinclude = true,
  },
}

---@type VibeConfig
M.options = {}

---@param opts VibeConfig|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  return M.options
end

return M
