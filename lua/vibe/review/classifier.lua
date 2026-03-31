--- Classification engine: takes base/user/AI lines, produces classified regions
local types = require("vibe.review.types")

local M = {}

--- Convert vim.diff indices hunk to a base-coordinate range
--- vim.diff returns {start_a, count_a, start_b, count_b}
---@param hunk table {start_a, count_a, start_b, count_b}
---@return table {base_start, base_end, side_start, side_end, is_insert}
local function hunk_to_range(hunk)
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    local base_start, base_end
    if count_a == 0 then
        -- Pure insertion: zero-width range at start_a
        base_start = start_a
        base_end = start_a -- zero-width: between start_a and start_a+1
    else
        base_start = start_a
        base_end = start_a + count_a - 1
    end
    return {
        base_start = base_start,
        base_end = base_end,
        count_a = count_a,
        side_start = start_b,
        side_count = count_b,
        is_insert = count_a == 0,
    }
end

--- Check if two ranges overlap (including adjacency for insertions at same point)
local function ranges_overlap(r1, r2)
    if r1.is_insert and r2.is_insert then
        return r1.base_start == r2.base_start
    end
    if r1.is_insert then
        return r1.base_start >= r2.base_start and r1.base_start <= r2.base_end
    end
    if r2.is_insert then
        return r2.base_start >= r1.base_start and r2.base_start <= r1.base_end
    end
    return r1.base_start <= r2.base_end and r2.base_start <= r1.base_end
end

--- Extract lines from a side (user or AI) for a given range
local function extract_side_lines(side_lines, range)
    local lines = {}
    for i = range.side_start, range.side_start + range.side_count - 1 do
        table.insert(lines, side_lines[i] or "")
    end
    return lines
end

--- Extract base lines for a given range
local function extract_base_lines(base_lines, base_start, base_end)
    local lines = {}
    if base_start > base_end then
        return lines
    end
    for i = base_start, base_end do
        table.insert(lines, base_lines[i] or "")
    end
    return lines
end

--- Check if two sets of lines are identical
local function lines_equal(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--- Determine conflict sub-type
local function get_conflict_type(user_range, ai_range)
    local user_deletes = user_range.side_count == 0
    local ai_deletes = ai_range.side_count == 0
    if user_deletes and not ai_deletes then
        return types.DEL_VS_MOD
    elseif not user_deletes and ai_deletes then
        return types.MOD_VS_DEL
    else
        return types.MOD_VS_MOD
    end
end

--- Classify regions from base, user, and AI lines
---@param base_lines string[] Base (snapshot) file lines
---@param user_lines string[] User's current file lines
---@param ai_lines string[] AI's worktree file lines
---@return table[] regions Array of ClassifiedRegion
function M.classify_regions(base_lines, user_lines, ai_lines)
    local base_str = table.concat(base_lines, "\n") .. (#base_lines > 0 and "\n" or "")
    local user_str = table.concat(user_lines, "\n") .. (#user_lines > 0 and "\n" or "")
    local ai_str = table.concat(ai_lines, "\n") .. (#ai_lines > 0 and "\n" or "")

    -- Get diffs in indices form
    local user_hunks_raw = vim.diff(base_str, user_str, { result_type = "indices" }) or {}
    local ai_hunks_raw = vim.diff(base_str, ai_str, { result_type = "indices" }) or {}

    -- Convert to range objects
    local user_ranges = {}
    for _, h in ipairs(user_hunks_raw) do
        table.insert(user_ranges, hunk_to_range(h))
    end
    local ai_ranges = {}
    for _, h in ipairs(ai_hunks_raw) do
        table.insert(ai_ranges, hunk_to_range(h))
    end

    -- No changes at all
    if #user_ranges == 0 and #ai_ranges == 0 then
        return {}
    end

    -- Find overlapping groups using connected-component merging
    -- Build overlap graph between user and AI ranges
    local user_in_group = {} -- user_idx -> group_id
    local ai_in_group = {} -- ai_idx -> group_id
    local groups = {} -- group_id -> {user_indices=[], ai_indices=[]}
    local next_group = 1

    for ui, ur in ipairs(user_ranges) do
        for ai, ar in ipairs(ai_ranges) do
            if ranges_overlap(ur, ar) then
                local ug = user_in_group[ui]
                local ag = ai_in_group[ai]
                if ug and ag and ug ~= ag then
                    -- Merge groups
                    local keep, discard = ug, ag
                    for _, idx in ipairs(groups[discard].user_indices) do
                        table.insert(groups[keep].user_indices, idx)
                        user_in_group[idx] = keep
                    end
                    for _, idx in ipairs(groups[discard].ai_indices) do
                        table.insert(groups[keep].ai_indices, idx)
                        ai_in_group[idx] = keep
                    end
                    groups[discard] = nil
                elseif ug then
                    if not ai_in_group[ai] then
                        table.insert(groups[ug].ai_indices, ai)
                        ai_in_group[ai] = ug
                    end
                elseif ag then
                    if not user_in_group[ui] then
                        table.insert(groups[ag].user_indices, ui)
                        user_in_group[ui] = ag
                    end
                else
                    -- New group
                    groups[next_group] = { user_indices = { ui }, ai_indices = { ai } }
                    user_in_group[ui] = next_group
                    ai_in_group[ai] = next_group
                    next_group = next_group + 1
                end
            end
        end
    end

    local regions = {}

    -- Non-overlapping user-only changes
    for ui, ur in ipairs(user_ranges) do
        if not user_in_group[ui] then
            local bl = extract_base_lines(base_lines, ur.base_start, ur.is_insert and (ur.base_start - 1) or ur.base_end)
            local ul = extract_side_lines(user_lines, ur)
            table.insert(regions, {
                classification = types.USER_ONLY,
                base_range = { ur.base_start, ur.is_insert and ur.base_start or ur.base_end },
                base_lines = bl,
                user_lines = ul,
                ai_lines = bl, -- AI didn't change, so AI has base content
                auto_resolved = false,
            })
        end
    end

    -- Non-overlapping AI-only changes
    for ai, ar in ipairs(ai_ranges) do
        if not ai_in_group[ai] then
            local bl = extract_base_lines(base_lines, ar.base_start, ar.is_insert and (ar.base_start - 1) or ar.base_end)
            local al = extract_side_lines(ai_lines, ar)
            table.insert(regions, {
                classification = types.AI_ONLY,
                base_range = { ar.base_start, ar.is_insert and ar.base_start or ar.base_end },
                base_lines = bl,
                user_lines = bl, -- User didn't change, so user has base content
                ai_lines = al,
                auto_resolved = false,
            })
        end
    end

    -- Overlapping groups -> CONVERGENT or CONFLICT
    for _, group in pairs(groups) do
        -- Find the merged base range spanning all hunks in the group
        local min_base, max_base = math.huge, 0
        for _, ui in ipairs(group.user_indices) do
            local ur = user_ranges[ui]
            min_base = math.min(min_base, ur.base_start)
            max_base = math.max(max_base, ur.is_insert and ur.base_start or ur.base_end)
        end
        for _, ai in ipairs(group.ai_indices) do
            local ar = ai_ranges[ai]
            min_base = math.min(min_base, ar.base_start)
            max_base = math.max(max_base, ar.is_insert and ar.base_start or ar.base_end)
        end

        -- Find the user/AI line ranges that cover this region
        -- We need to map the merged base range to both sides
        local user_result_lines = {}
        local ai_result_lines = {}

        -- For user side: collect all lines from user hunks in this group,
        -- plus any unchanged base lines between them
        -- Simpler approach: use the base range to figure out what each side looks like
        local bl = extract_base_lines(base_lines, min_base, max_base)

        -- Reconstruct user's version of this base range
        -- by applying user hunks to base lines
        local ul = M._reconstruct_side(base_lines, user_lines, user_ranges, group.user_indices, min_base, max_base)
        local al = M._reconstruct_side(base_lines, ai_lines, ai_ranges, group.ai_indices, min_base, max_base)

        if lines_equal(ul, al) then
            table.insert(regions, {
                classification = types.CONVERGENT,
                base_range = { min_base, max_base },
                base_lines = bl,
                user_lines = ul,
                ai_lines = al,
                auto_resolved = false,
            })
        else
            -- Determine conflict sub-type from the group
            local conflict_type = types.MOD_VS_MOD
            if #group.user_indices == 1 and #group.ai_indices == 1 then
                conflict_type = get_conflict_type(user_ranges[group.user_indices[1]], ai_ranges[group.ai_indices[1]])
            end

            table.insert(regions, {
                classification = types.CONFLICT,
                conflict_type = conflict_type,
                base_range = { min_base, max_base },
                base_lines = bl,
                user_lines = ul,
                ai_lines = al,
                auto_resolved = false,
            })
        end
    end

    -- Sort regions by base position
    table.sort(regions, function(a, b)
        return a.base_range[1] < b.base_range[1]
    end)

    return regions
end

--- Reconstruct what a side looks like over a base range, given its hunks
---@param base_lines string[]
---@param side_lines string[]
---@param side_ranges table[]
---@param indices integer[] indices into side_ranges that belong to this group
---@param min_base integer start of base range
---@param max_base integer end of base range
---@return string[]
function M._reconstruct_side(base_lines, side_lines, side_ranges, indices, min_base, max_base)
    -- Sort the hunks by base position
    local sorted = {}
    for _, idx in ipairs(indices) do
        table.insert(sorted, side_ranges[idx])
    end
    table.sort(sorted, function(a, b)
        return a.base_start < b.base_start
    end)

    local result = {}
    local base_pos = min_base

    for _, r in ipairs(sorted) do
        -- Add unchanged base lines before this hunk
        local hunk_start = r.base_start
        if r.is_insert then
            -- For insertions, unchanged lines go up to (but not including) the insertion point
            while base_pos < hunk_start do
                table.insert(result, base_lines[base_pos] or "")
                base_pos = base_pos + 1
            end
        else
            while base_pos < hunk_start do
                table.insert(result, base_lines[base_pos] or "")
                base_pos = base_pos + 1
            end
        end

        -- Add the side's replacement lines
        for i = r.side_start, r.side_start + r.side_count - 1 do
            table.insert(result, side_lines[i] or "")
        end

        -- Skip the base lines that this hunk replaces
        if not r.is_insert then
            base_pos = r.base_end + 1
        end
    end

    -- Add remaining unchanged base lines
    while base_pos <= max_base do
        table.insert(result, base_lines[base_pos] or "")
        base_pos = base_pos + 1
    end

    return result
end

--- Classify a file considering file-level status (new, deleted, etc.)
---@param worktree_path string
---@param filepath string
---@param repo_root string
---@return table ClassifiedFile
function M.classify_file(worktree_path, filepath, repo_root)
    local git = require("vibe.git")

    local base_lines = git.get_worktree_snapshot_lines(worktree_path, filepath)
    local base_exists = #base_lines > 0 or (base_lines[1] ~= nil)

    -- Fallback: if worktree snapshot is unavailable, try reading from repo_root
    if not base_exists and repo_root ~= "" then
        local diff_mod = require("vibe.git.diff")
        -- Try the snapshot commit from the worktree info
        local worktree_info = git.worktrees[worktree_path]
        if worktree_info and worktree_info.snapshot_commit then
            base_lines = diff_mod.read_file_at_commit(repo_root, filepath, worktree_info.snapshot_commit)
        end
        -- If that fails, try HEAD
        if #base_lines == 0 then
            base_lines = diff_mod.read_file_at_commit(repo_root, filepath, "HEAD")
        end
        base_exists = #base_lines > 0 or (base_lines[1] ~= nil)
    end
    -- Handle the case where git show returns {""}  for an empty file vs {} for non-existent
    if #base_lines == 1 and base_lines[1] == "" then
        -- Could be empty file or non-existent, check via git
        local git_cmd = require("vibe.git.cmd")
        local result = git_cmd.git_cmd(
            { "cat-file", "-t", (git.worktrees[worktree_path] or {}).snapshot_commit .. ":" .. filepath },
            { cwd = worktree_path, ignore_error = true }
        )
        base_exists = result and result:match("blob") ~= nil
    end

    local user_file_path = repo_root .. "/" .. filepath
    local user_exists = vim.fn.filereadable(user_file_path) == 1
    local user_lines = {}
    if user_exists then
        local bufnr = vim.fn.bufnr(user_file_path)
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        else
            user_lines = vim.fn.readfile(user_file_path)
        end
    end

    local ai_file_path = worktree_path .. "/" .. filepath
    local ai_exists = vim.fn.filereadable(ai_file_path) == 1
    local ai_lines = {}
    if ai_exists then
        ai_lines = vim.fn.readfile(ai_file_path)
    end

    -- File-level triage
    if not base_exists then
        -- New file
        if user_exists and ai_exists then
            if lines_equal(user_lines, ai_lines) then
                return {
                    filepath = filepath,
                    file_status = types.FILE_NEW_BOTH_SAME,
                    regions = {},
                    auto_accept = true,
                }
            else
                return {
                    filepath = filepath,
                    file_status = types.FILE_NEW_BOTH_DIFF,
                    regions = { {
                        classification = types.CONFLICT,
                        conflict_type = types.MOD_VS_MOD,
                        base_range = { 1, 1 },
                        base_lines = {},
                        user_lines = user_lines,
                        ai_lines = ai_lines,
                        auto_resolved = false,
                    } },
                    auto_accept = false,
                }
            end
        elseif user_exists then
            return {
                filepath = filepath,
                file_status = types.FILE_NEW_USER,
                regions = {},
                auto_accept = true,
            }
        elseif ai_exists then
            return {
                filepath = filepath,
                file_status = types.FILE_NEW_AI,
                regions = { {
                    classification = types.AI_ONLY,
                    base_range = { 1, 1 },
                    base_lines = {},
                    user_lines = {},
                    ai_lines = ai_lines,
                    auto_resolved = false,
                } },
                auto_accept = false,
            }
        else
            return { filepath = filepath, file_status = types.FILE_DELETED_BOTH, regions = {}, auto_accept = true }
        end
    end

    -- Base exists
    if not user_exists and not ai_exists then
        return { filepath = filepath, file_status = types.FILE_DELETED_BOTH, regions = {}, auto_accept = true }
    elseif not user_exists and ai_exists then
        return {
            filepath = filepath,
            file_status = types.FILE_DELETED_USER,
            regions = { {
                classification = types.USER_ONLY,
                base_range = { 1, #base_lines },
                base_lines = base_lines,
                user_lines = {},
                ai_lines = ai_lines,
                auto_resolved = false,
            } },
            auto_accept = false,
        }
    elseif user_exists and not ai_exists then
        return {
            filepath = filepath,
            file_status = types.FILE_DELETE_CONFLICT_AI_MOD,
            regions = { {
                classification = types.CONFLICT,
                conflict_type = types.DEL_VS_MOD,
                base_range = { 1, #base_lines },
                base_lines = base_lines,
                user_lines = user_lines,
                ai_lines = {},
                auto_resolved = false,
            } },
            auto_accept = false,
        }
    end

    -- Both exist with base — do full region classification
    if not base_exists then
        base_lines = {}
    end
    local regions = M.classify_regions(base_lines, user_lines, ai_lines)
    return {
        filepath = filepath,
        file_status = types.FILE_MODIFIED,
        regions = regions,
        auto_accept = false,
    }
end

--- Apply merge mode to regions, setting auto_resolved flags
---@param regions table[] ClassifiedRegion array
---@param merge_mode string One of the merge mode constants
---@return table {auto_count, review_count, conflict_count}
function M.apply_merge_mode(regions, merge_mode)
    local auto_count, review_count, conflict_count = 0, 0, 0
    for _, region in ipairs(regions) do
        if types.should_auto_resolve(region.classification, merge_mode) then
            region.auto_resolved = true
            auto_count = auto_count + 1
        else
            region.auto_resolved = false
            if region.classification == types.CONFLICT then
                conflict_count = conflict_count + 1
            else
                review_count = review_count + 1
            end
        end
    end
    return { auto_count = auto_count, review_count = review_count, conflict_count = conflict_count }
end

return M
