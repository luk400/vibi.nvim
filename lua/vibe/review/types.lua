--- Pure data module: classifications, merge modes, and decision table
local M = {}

-- Region classifications
M.UNCHANGED = "unchanged"
M.USER_ONLY = "user_only"
M.AI_ONLY = "ai_only"
M.CONVERGENT = "convergent"
M.CONFLICT = "conflict"

-- Conflict sub-types
M.MOD_VS_MOD = "mod_vs_mod"
M.MOD_VS_DEL = "mod_vs_del"
M.DEL_VS_MOD = "del_vs_mod"

-- Merge modes
M.MODE_NONE = "none"
M.MODE_USER = "user"
M.MODE_AI = "ai"
M.MODE_BOTH = "both"

-- File statuses
M.FILE_MODIFIED = "modified"
M.FILE_NEW_USER = "new_user"
M.FILE_NEW_AI = "new_ai"
M.FILE_NEW_BOTH_SAME = "new_both_same"
M.FILE_NEW_BOTH_DIFF = "new_both_diff"
M.FILE_DELETED_USER = "deleted_user"
M.FILE_DELETED_AI = "deleted_ai"
M.FILE_DELETED_BOTH = "deleted_both"
M.FILE_DELETE_CONFLICT_USER_MOD = "delete_conflict_user_mod"
M.FILE_DELETE_CONFLICT_AI_MOD = "delete_conflict_ai_mod"

--- Decision table: should a region be auto-resolved given its classification and merge mode?
--- CONFLICT is never auto-resolved. UNCHANGED is always skipped (not a review item).
---@param classification string One of the classification constants
---@param merge_mode string One of the merge mode constants
---@return boolean
function M.should_auto_resolve(classification, merge_mode)
    if classification == M.CONFLICT then
        return false
    end
    if classification == M.UNCHANGED then
        return true
    end

    -- Decision table:
    --              none    user    ai      both
    -- USER_ONLY    false   true    false   true
    -- AI_ONLY      false   false   true    true
    -- CONVERGENT   false   true    true    true
    local table_lookup = {
        [M.USER_ONLY] = {
            [M.MODE_NONE] = false,
            [M.MODE_USER] = true,
            [M.MODE_AI] = false,
            [M.MODE_BOTH] = true,
        },
        [M.AI_ONLY] = {
            [M.MODE_NONE] = false,
            [M.MODE_USER] = false,
            [M.MODE_AI] = true,
            [M.MODE_BOTH] = true,
        },
        [M.CONVERGENT] = {
            [M.MODE_NONE] = false,
            [M.MODE_USER] = true,
            [M.MODE_AI] = true,
            [M.MODE_BOTH] = true,
        },
    }

    local row = table_lookup[classification]
    if row then
        return row[merge_mode] or false
    end
    return false
end

--- Mode display labels for UI
M.mode_labels = {
    [M.MODE_BOTH] = "Auto-Merge All",
    [M.MODE_USER] = "Auto-Merge User",
    [M.MODE_AI] = "Auto-Merge AI",
    [M.MODE_NONE] = "Review All",
}

--- Classification display info for UI
M.classification_info = {
    [M.USER_ONLY] = { label = "Your change", short = "yours", color = "VibeRegionSuggestion" },
    [M.AI_ONLY] = { label = "AI suggestion", short = "AI", color = "VibeRegionSuggestion" },
    [M.CONVERGENT] = { label = "Both agree", short = "agreed", color = "VibeRegionConvergent" },
    [M.CONFLICT] = { label = "Conflict", short = "conflict", color = "VibeRegionConflict" },
}

return M
