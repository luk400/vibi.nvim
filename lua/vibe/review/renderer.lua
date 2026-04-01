--- Unified classification-aware review renderer
--- Single rendering path for all review modes, replacing collapsed_conflict.lua,
--- conflict_buffer.lua, conflict_popup.lua, and inline diff rendering from diff.lua
local git = require("vibe.git")
local resolve = require("vibe.resolve")
local review_keymaps = require("vibe.review.keymaps")
local engine = require("vibe.review.engine")
local types = require("vibe.review.types")
local util = require("vibe.util")
local config = require("vibe.config")
local kd = require("vibe.review.keymap_display")

local M = {}

M.ns = vim.api.nvim_create_namespace("vibe_review")
M.ns_auto = vim.api.nvim_create_namespace("vibe_auto_merged")

---@type table<integer, table> bufnr -> review state
M.buffer_state = {}

M.preview_winnr = nil
M.preview_bufnr = nil
M.hint_winnr = nil
M.hint_bufnr = nil

-- Highlights are now centralized in vibe.highlights

--- Find the main (non-floating) window showing a buffer
---@param bufnr integer
---@return integer|nil winid
local function find_buf_win(bufnr)
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(winid) == bufnr then
            local cfg = vim.api.nvim_win_get_config(winid)
            if cfg.relative == "" then
                return winid
            end
        end
    end
    return nil
end

--- Get the current extmark range for a review item
--- Returns (start_row, end_row) where end_row is exclusive (0-indexed)
local function get_current_range(bufnr, idx)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, idx * 1000, { details = true })
    if mark and #mark > 0 then
        local start_row = mark[1]
        local end_row = (mark[3] and mark[3].end_row) or (start_row + 1)
        return start_row, end_row
    end
    return nil, nil
end

--- Get highlight group for inline display
local function get_inline_hl(classification)
    if classification == types.CONFLICT then
        return "VibeConflictInline"
    elseif classification == types.CONVERGENT then
        return "VibeConvergentInline"
    else
        return "VibeSuggestionInline"
    end
end

--- Get sign name for a classification
local function get_sign_name(classification)
    if classification == types.CONFLICT then
        return "VibeReviewConflict"
    elseif classification == types.CONVERGENT then
        return "VibeReviewConvergent"
    else
        return "VibeReviewSuggestion"
    end
end

--- Show file with unified classification-aware review
function M.show_file(worktree_path, filepath, hunks, merge_mode)
    merge_mode = merge_mode or config.options.merge_mode or "user"

    local info = git.get_worktree_info(worktree_path)
    if not info then
        return
    end

    local user_file_path = info.repo_root .. "/" .. filepath
    local user_exists = vim.fn.filereadable(user_file_path) == 1

    local user_lines = {}
    if user_exists then
        local bufnr = vim.fn.bufnr(user_file_path)
        if bufnr ~= -1 then
            user_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        else
            user_lines = vim.fn.readfile(user_file_path)
        end
    end

    local result = engine.prepare_review(user_lines, worktree_path, filepath, info.name, merge_mode)
    local classified_file = result.classified_file
    local merged_lines = result.merged_lines
    local summary = result.summary

    -- Ensure directory exists
    local dir = vim.fn.fnamemodify(user_file_path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))
    local bufnr = vim.api.nvim_get_current_buf()

    -- Start with user's file content as the base buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, user_lines)

    -- Separate regions into review items and auto-resolved items
    local review_items = {}
    local auto_items = {}
    for _, region in ipairs(classified_file.regions) do
        if region.auto_resolved then
            table.insert(auto_items, region)
        else
            table.insert(review_items, region)
        end
    end

    M.buffer_state[bufnr] = {
        worktree_path = worktree_path,
        filepath = filepath,
        session_name = info.name,
        classified_file = classified_file,
        merge_mode = merge_mode,
        review_items = review_items,
        auto_items = auto_items,
        item_contents = {},
        auto_item_contents = {},
        resolved_count = 0,
        original_lines = vim.deepcopy(user_lines),
        merged_lines = merged_lines,
    }

    -- When there are auto_items, rebuild buffer content so AI_ONLY regions
    -- get ai_lines instead of user_lines (fixes bug where AI changes were lost on finalize)
    if #auto_items > 0 then
        local resolved_lines = M._build_resolved_content(M.buffer_state[bufnr])
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, resolved_lines)
    end

    M.setup_keymaps(bufnr)
    M.highlight_auto_merged(bufnr)
    M.setup_inline_review_items(bufnr)
    M.setup_tracking(bufnr)

    -- Show hint whenever there are auto_items
    if #auto_items > 0 then
        M.show_hint(bufnr)
    end

    if #review_items > 0 then
        local first_start = get_current_range(bufnr, 1)
        local first_line = first_start or 0
        vim.api.nvim_win_set_cursor(0, { first_line + 1, 0 })
        vim.defer_fn(function()
            M.show_preview()
        end, 50)

        local parts = {}
        if summary.conflict_count > 0 then
            table.insert(parts, summary.conflict_count .. " conflict(s)")
        end
        if summary.review_count > 0 then
            table.insert(parts, summary.review_count .. " suggestion(s)")
        end
        if summary.auto_count > 0 then
            table.insert(parts, summary.auto_count .. " auto-merged")
        end
        vim.notify(
            string.format("[Vibe] %s to review. %s", #review_items .. " item(s)", table.concat(parts, ", ")),
            vim.log.levels.INFO
        )
    else
        -- All auto-merged: show buffer with highlights, let user inspect/edit
        -- Jump to first auto-merged change
        local state = M.buffer_state[bufnr]
        local first_aic = state.auto_item_contents[1]
        if first_aic then
            vim.api.nvim_win_set_cursor(0, { first_aic.buf_start_0 + 1, 0 })
            vim.defer_fn(function()
                M.show_preview()
            end, 50)
        end

        local k_done = kd.get_key_or_fallback(bufnr, kd.DESC_DONE, "<leader>c")
        vim.notify(
            string.format(
                "[Vibe] All %d change(s) auto-merged. Edit freely, then %s to accept.",
                #auto_items,
                k_done
            ),
            vim.log.levels.INFO
        )
    end
end

--- Apply auto-merged regions to the buffer content and finalize
function M.apply_auto_merged_and_finalize(bufnr)
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end

    -- Build the resolved file content by applying all auto-resolved regions
    -- For auto-resolved: accept the change (user_lines for USER_ONLY, ai_lines for AI_ONLY, etc.)
    local resolved_lines = M._build_resolved_content(state)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, resolved_lines)

    -- Mark all auto items as addressed
    for _, region in ipairs(state.auto_items) do
        local action = resolve.resolution_to_action_v2(region.classification, "accept")
        M._mark_region_addressed(state, region, action)
    end

    M.finalize_file(bufnr)
end

--- Build resolved content from user lines + applying auto-resolved changes
function M._build_resolved_content(state)
    local base_lines = state.original_lines
    local regions = state.classified_file.regions

    -- If no regions with changes, return original
    if #regions == 0 then
        return vim.deepcopy(base_lines)
    end

    -- For auto-resolved regions, we need to figure out what the "accepted" version looks like
    -- The simplest approach: start from user's content and apply AI-only changes
    -- But we need a proper reconstruction. Let's compute the "desired" output.
    --
    -- The user_lines in each region tell us what the user's version looks like,
    -- and ai_lines tell us AI's version. base_lines tells us the original.
    --
    -- For auto-resolved:
    -- - USER_ONLY: keep user's version (already in the file)
    -- - AI_ONLY: use AI's version
    -- - CONVERGENT: use either (they're the same)
    --
    -- For review items (not auto): keep user's version (they'll be handled interactively)

    -- Since we're starting from the user's file content, USER_ONLY changes are already there.
    -- We only need to apply AI_ONLY and CONVERGENT (auto-resolved) changes.
    -- This requires mapping base ranges to user file positions.

    -- Actually, the safest approach is to reconstruct from base + all accepted changes.
    -- Let's use the classified regions to build the output.

    -- Get base (snapshot) lines
    local snapshot_lines = git.get_worktree_snapshot_lines(state.worktree_path, state.filepath)

    -- Build output by walking through base lines and applying changes
    local result = {}
    local base_pos = 1

    -- Sort regions by base_range start
    local sorted_regions = {}
    for _, r in ipairs(regions) do
        table.insert(sorted_regions, r)
    end
    table.sort(sorted_regions, function(a, b)
        return a.base_range[1] < b.base_range[1]
    end)

    for _, region in ipairs(sorted_regions) do
        local rstart = region.base_range[1]
        local rend = region.base_range[2]
        local is_pure_insert = #(region.base_lines or {}) == 0

        -- Add unchanged lines before this region
        if is_pure_insert then
            -- Include the anchor line BEFORE inserting new content
            while base_pos <= rstart and base_pos <= #snapshot_lines do
                table.insert(result, snapshot_lines[base_pos])
                base_pos = base_pos + 1
            end
        else
            while base_pos < rstart and base_pos <= #snapshot_lines do
                table.insert(result, snapshot_lines[base_pos])
                base_pos = base_pos + 1
            end
        end

        -- Determine what lines to use for this region
        local replacement
        if region.auto_resolved then
            -- Use the accepted version
            if region.classification == types.USER_ONLY or region.classification == types.CONVERGENT then
                replacement = region.user_lines
            elseif region.classification == types.AI_ONLY then
                replacement = region.ai_lines
            else
                replacement = region.user_lines
            end
            -- For auto-resolved deletions, insert a sentinel line
            if #(replacement or {}) == 0 and #(region.base_lines or {}) > 0 then
                replacement = { "" }
                region._has_sentinel = true
            end
        else
            -- Not auto-resolved: keep user's version for now (will be handled interactively)
            replacement = region.user_lines
        end

        for _, line in ipairs(replacement or {}) do
            table.insert(result, line)
        end

        -- Skip the base lines covered by this region (NOT for pure insertions)
        if not is_pure_insert and rstart <= rend then
            base_pos = rend + 1
        end
    end

    -- Add remaining base lines
    while base_pos <= #snapshot_lines do
        table.insert(result, snapshot_lines[base_pos] or "")
        base_pos = base_pos + 1
    end

    return result
end

--- Set up inline review items in the buffer (replaces collapsed single-line summaries)
--- Shows full content inline with highlights instead of collapsed lines
function M.setup_inline_review_items(bufnr)
    local state = M.buffer_state[bufnr]
    if not state or #state.review_items == 0 then
        return
    end

    -- Map base line numbers to current buffer positions
    local snapshot_lines = git.get_worktree_snapshot_lines(state.worktree_path, state.filepath)
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local base_to_user = M._build_line_map(snapshot_lines, current_lines)

    local total_shift = 0

    for i, region in ipairs(state.review_items) do
        local rstart = region.base_range[1]
        local user_line_count = #(region.user_lines or {})

        -- Map base range to buffer position
        local user_start = (base_to_user[rstart] or rstart) + total_shift

        -- Determine display_lines and stored_lines based on classification
        local display_lines, stored_lines
        local cls = region.classification
        if cls == types.CONFLICT then
            display_lines = vim.deepcopy(region.ai_lines or {})
            stored_lines = vim.deepcopy(region.user_lines or {})
        elseif cls == types.USER_ONLY then
            display_lines = vim.deepcopy(region.user_lines or {})
            stored_lines = vim.deepcopy(region.base_lines or {})
        elseif cls == types.AI_ONLY then
            display_lines = vim.deepcopy(region.ai_lines or {})
            stored_lines = vim.deepcopy(region.base_lines or {})
        else -- CONVERGENT
            display_lines = vim.deepcopy(region.user_lines or {})
            stored_lines = vim.deepcopy(region.base_lines or {})
        end

        -- Handle empty display_lines (deletion): use sentinel line as hover target
        local is_deletion = #display_lines == 0
        if is_deletion then
            display_lines = { "" } -- sentinel: empty real line
        end

        -- Replace buffer lines at the mapped position
        local is_pure_insert = #(region.base_lines or {}) == 0 and user_line_count == 0
        local api_start
        if is_pure_insert then
            api_start = user_start -- insert AFTER anchor (user_start is 1-indexed = correct 0-indexed position after anchor)
        else
            api_start = user_start - 1 -- convert to 0-indexed
        end
        local api_end
        if user_line_count > 0 then
            api_end = api_start + user_line_count
        else
            api_end = api_start -- insertion point
        end

        local line_count = vim.api.nvim_buf_line_count(bufnr)
        api_start = math.max(0, math.min(api_start, line_count))
        api_end = math.max(api_start, math.min(api_end, line_count))

        vim.api.nvim_buf_set_lines(bufnr, api_start, api_end, false, display_lines)

        -- Update total_shift
        total_shift = total_shift + (#display_lines - user_line_count)

        -- Place ranged extmark spanning all display lines
        local sign_id = i * 1000
        local hl_group = is_deletion and "VibeDeleteSentinel" or get_inline_hl(region.classification)
        local sign_name = get_sign_name(region.classification)
        pcall(vim.fn.sign_place, sign_id, "vibe_review", sign_name, bufnr, { lnum = api_start + 1 })

        line_count = vim.api.nvim_buf_line_count(bufnr)
        local extmark_start = math.max(0, math.min(api_start, line_count - 1))
        local extmark_end = math.max(extmark_start + 1, math.min(api_start + #display_lines, line_count))

        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, extmark_start, 0, {
            id = sign_id,
            end_row = extmark_end,
            hl_group = hl_group,
            hl_eol = true,
            priority = 200,
        })

        -- For non-CONFLICT deletion sentinels, add virtual lines showing deleted content
        if is_deletion and cls ~= types.CONFLICT then
            local virt_lines = {}
            for _, line in ipairs(stored_lines) do
                table.insert(virt_lines, { { line, "VibeAutoMergedDelete" } })
            end
            if #virt_lines > 0 then
                pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, extmark_start, 0, {
                    id = sign_id + 1,
                    virt_lines = virt_lines,
                    virt_lines_above = true,
                })
            end
        end

        -- Store item contents
        state.item_contents[i] = {
            display_lines = display_lines,
            stored_lines = stored_lines,
            region = region,
            buffer_start = user_start, -- 1-indexed
            buffer_line_count = #display_lines,
            is_deletion_sentinel = is_deletion,
        }

        region._extmark_idx = i
        region._resolved = false
    end
end

--- Build a mapping from base line numbers to user file line numbers
function M._build_line_map(base_lines, user_lines)
    local base_str = table.concat(base_lines, "\n") .. (#base_lines > 0 and "\n" or "")
    local user_str = table.concat(user_lines, "\n") .. (#user_lines > 0 and "\n" or "")

    local hunks = vim.diff(base_str, user_str, { result_type = "indices" }) or {}

    -- Build the map by walking through hunks
    local map = {}
    local base_pos = 1
    local user_pos = 1

    for _, hunk in ipairs(hunks) do
        local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

        -- Map unchanged lines before this hunk
        while base_pos < start_a do
            map[base_pos] = user_pos
            base_pos = base_pos + 1
            user_pos = user_pos + 1
        end

        -- Map the hunk: base lines start_a..start_a+count_a-1 -> user lines start_b
        if count_a > 0 then
            map[start_a] = (count_b > 0) and start_b or start_b
            for j = 1, count_a - 1 do
                map[start_a + j] = start_b + math.min(j, math.max(0, count_b - 1))
            end
        elseif count_a == 0 then
            -- Insertion: base line start_a maps to user line start_b
            map[start_a] = start_b
        end

        base_pos = (count_a > 0) and (start_a + count_a) or (start_a + 1)
        user_pos = (count_b > 0) and (start_b + count_b) or start_b
    end

    -- Map remaining lines
    while base_pos <= #base_lines do
        map[base_pos] = user_pos
        base_pos = base_pos + 1
        user_pos = user_pos + 1
    end

    return map
end

--- Highlight auto-merged regions in the buffer
function M.highlight_auto_merged(bufnr)
    local state = M.buffer_state[bufnr]
    if not state or #state.auto_items == 0 then
        return
    end

    local snapshot_lines = git.get_worktree_snapshot_lines(state.worktree_path, state.filepath)
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local base_to_buf = M._build_line_map(snapshot_lines, current_lines)

    for auto_idx, region in ipairs(state.auto_items) do
        local base_lines = region.base_lines or {}
        local resolved_lines
        if region.classification == types.AI_ONLY then
            resolved_lines = region.ai_lines or {}
        else
            resolved_lines = region.user_lines or {}
        end

        local rstart = region.base_range[1]
        local buf_start = base_to_buf[rstart] or rstart

        if #base_lines > 0 and #(resolved_lines or {}) == 0 then
            -- Deletion with sentinel (sentinel line was inserted by _build_resolved_content)
            local sentinel_row = buf_start - 1 -- 0-indexed
            sentinel_row = math.max(0, math.min(sentinel_row, #current_lines - 1))
            -- Highlight sentinel line
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_auto, sentinel_row, 0, {
                id = auto_idx * 1000 + 500,
                end_row = sentinel_row + 1,
                hl_group = "VibeDeleteSentinel",
                hl_eol = true,
            })
            -- Virtual lines above sentinel showing deleted content
            local virt_lines = {}
            for _, line in ipairs(base_lines) do
                table.insert(virt_lines, { { line, "VibeAutoMergedDelete" } })
            end
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_auto, sentinel_row, 0, {
                virt_lines = virt_lines,
                virt_lines_above = true,
            })
            state.auto_item_contents[auto_idx] = {
                region = region,
                buf_start_0 = sentinel_row,
                line_count = 1,
                is_deletion = true,
                is_sentinel = true,
                extmark_id = auto_idx * 1000 + 500,
            }
        elseif #base_lines == 0 and #resolved_lines > 0 then
            -- Pure addition: highlight each added line
            for j = 0, #resolved_lines - 1 do
                local line_idx = buf_start - 1 + j
                if line_idx >= 0 and line_idx < #current_lines then
                    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_auto, line_idx, 0, {
                        hl_group = "VibeAutoMergedAdd",
                        hl_eol = true,
                        end_row = line_idx + 1,
                    })
                end
            end
            -- Track for hover
            local start_0 = buf_start - 1
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_auto, start_0, 0, {
                id = auto_idx * 1000 + 500,
                end_row = start_0 + #resolved_lines,
            })
            state.auto_item_contents[auto_idx] = {
                region = region,
                buf_start_0 = start_0,
                line_count = #resolved_lines,
                is_deletion = false,
                is_sentinel = false,
                extmark_id = auto_idx * 1000 + 500,
            }
        else
            -- Modification: check if content actually differs
            local differs = #base_lines ~= #resolved_lines
            if not differs then
                for k = 1, #base_lines do
                    if base_lines[k] ~= resolved_lines[k] then
                        differs = true
                        break
                    end
                end
            end
            if differs then
                for j = 0, #resolved_lines - 1 do
                    local line_idx = buf_start - 1 + j
                    if line_idx >= 0 and line_idx < #current_lines then
                        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_auto, line_idx, 0, {
                            hl_group = "VibeAutoMergedChange",
                            hl_eol = true,
                            end_row = line_idx + 1,
                        })
                    end
                end
                -- Track for hover
                local start_0 = buf_start - 1
                pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_auto, start_0, 0, {
                    id = auto_idx * 1000 + 500,
                    end_row = start_0 + #resolved_lines,
                })
                state.auto_item_contents[auto_idx] = {
                    region = region,
                    buf_start_0 = start_0,
                    line_count = #resolved_lines,
                    is_deletion = false,
                    is_sentinel = false,
                    extmark_id = auto_idx * 1000 + 500,
                }
            end
        end
    end
end

--- Get the review item at cursor position
function M.get_item_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return nil, nil
    end

    -- Use the window showing the review buffer, not necessarily window 0
    local win = find_buf_win(bufnr) or 0
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
    for i, region in ipairs(state.review_items) do
        if not region._resolved then
            local start_row, end_row = get_current_range(bufnr, i)
            if start_row and cursor_line >= start_row and cursor_line < end_row then
                return region, i
            end
        end
    end
    return nil, nil
end

--- Get the auto-merged item at cursor position
function M.get_auto_item_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return nil, nil
    end

    local win = find_buf_win(bufnr) or 0
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
    for i, region in ipairs(state.auto_items) do
        if not region._rejected and not region._dismissed then
            local aic = state.auto_item_contents[i]
            if aic then
                local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_auto, aic.extmark_id, { details = true })
                if mark and #mark > 0 then
                    local s = mark[1]
                    local e = (mark[3] and mark[3].end_row) or (s + 1)
                    if cursor_line >= s and cursor_line < e then
                        return region, i
                    end
                end
            end
        end
    end
    return nil, nil
end

function M.is_preview_visible()
    return M.preview_winnr ~= nil and vim.api.nvim_win_is_valid(M.preview_winnr)
end

function M.close_preview()
    if M.preview_winnr and vim.api.nvim_win_is_valid(M.preview_winnr) then
        vim.api.nvim_win_close(M.preview_winnr, true)
    end
    M.preview_winnr, M.preview_bufnr = nil, nil
end

--- Show preview popup for the item at cursor
function M.show_preview()
    local bufnr = vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end

    -- Check review items first, then auto items
    local region, idx = M.get_item_at_cursor(bufnr)
    local is_auto = false
    local auto_aic = nil
    if not region or region._resolved then
        region, idx = M.get_auto_item_at_cursor(bufnr)
        if region then
            is_auto = true
            auto_aic = state.auto_item_contents[idx]
        end
    end
    if not region then
        M.close_preview()
        return
    end

    -- Avoid re-opening preview when cursor moves within the same region
    local preview_key = is_auto and ("auto_" .. idx) or idx
    if state._last_preview_idx == preview_key and M.is_preview_visible() then
        return
    end
    state._last_preview_idx = preview_key

    M.close_preview()

    local cls = region.classification
    local info = types.classification_info[cls] or { label = "Region" }

    -- Build preview content
    local preview_lines = {}
    local hl_ranges = {} -- {line_idx, hl_group}
    local has_old_content = false

    local k_keep = kd.get_key_or_fallback(bufnr, kd.DESC_KEEP_YOURS, "<leader>k")
    local k_accept = kd.get_key_or_fallback(bufnr, kd.DESC_ACCEPT, "<leader>a")
    local k_reject = kd.get_key_or_fallback(bufnr, kd.DESC_REJECT, "<leader>r")
    local k_edit = kd.get_key_or_fallback(bufnr, kd.DESC_EDIT, "<leader>e")
    local k_quit = kd.get_key_or_fallback(bufnr, kd.DESC_QUIT, "q")

    if is_auto then
        -- Auto-merged item preview
        local is_sentinel = auto_aic and auto_aic.is_sentinel
        if is_sentinel then
            -- Deletion sentinel: show deleted lines + recover/dismiss
            local header =
                string.format("── [%s] recover  [%s] dismiss  [%s] close ──", k_accept, k_reject, k_quit)
            table.insert(preview_lines, header)
            table.insert(hl_ranges, { #preview_lines, "VibePreviewKeymap" })
            table.insert(preview_lines, "")
            table.insert(preview_lines, "━━━━━━━━━ Deleted lines ━━━━━━━━━")
            table.insert(hl_ranges, { #preview_lines, "VibeAutoMergedDelete" })
            for _, line in ipairs(region.base_lines or {}) do
                table.insert(preview_lines, line)
                table.insert(hl_ranges, { #preview_lines, "VibeAutoMergedDelete" })
            end
            has_old_content = true
        else
            -- Auto-merged modification/addition: show old version + revert option
            local header = string.format("── [%s] revert  [%s] close ──", k_reject, k_quit)
            table.insert(preview_lines, header)
            table.insert(hl_ranges, { #preview_lines, "VibePreviewKeymap" })
            if #(region.base_lines or {}) > 0 then
                has_old_content = true
                table.insert(preview_lines, "")
                table.insert(preview_lines, "━━━━━━━━━ Previous version ━━━━━━━━━")
                table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
                for _, line in ipairs(region.base_lines) do
                    table.insert(preview_lines, line)
                    table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
                end
            end
        end
        info = { label = is_sentinel and "Auto-merged deletion" or "Auto-merged" }
    elseif cls == types.CONFLICT then
        -- Conflict: show keybinds + user's version (AI content is already in buffer)
        has_old_content = true
        local header =
            string.format("── [%s] yours  [%s] AI  [%s] edit  [%s] close ──", k_keep, k_accept, k_edit, k_quit)
        table.insert(preview_lines, header)
        table.insert(hl_ranges, { #preview_lines, "VibePreviewKeymap" })
        table.insert(preview_lines, "")

        table.insert(preview_lines, "━━━━━━━━━ Your version ━━━━━━━━━")
        table.insert(hl_ranges, { #preview_lines, "VibePreviewUser" })
        local user_lines = state.item_contents[idx] and state.item_contents[idx].stored_lines or region.user_lines or {}
        if #user_lines > 0 then
            for _, line in ipairs(user_lines) do
                table.insert(preview_lines, line)
                table.insert(hl_ranges, { #preview_lines, "VibePreviewUser" })
            end
        else
            table.insert(preview_lines, "(empty / deleted)")
            table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
        end
    else
        -- Suggestions: keybinds + optional old version
        local header = string.format("── [%s] accept  [%s] reject  [%s] close ──", k_accept, k_reject, k_quit)
        table.insert(preview_lines, header)
        table.insert(hl_ranges, { #preview_lines, "VibePreviewKeymap" })

        -- Check for deletion sentinel
        local ic = state.item_contents[idx]
        if ic and ic.is_deletion_sentinel then
            has_old_content = true
            table.insert(preview_lines, "")
            table.insert(preview_lines, "━━━━━━━━━ Deleted lines ━━━━━━━━━")
            table.insert(hl_ranges, { #preview_lines, "VibeAutoMergedDelete" })
            for _, line in ipairs(ic.stored_lines or {}) do
                table.insert(preview_lines, line)
                table.insert(hl_ranges, { #preview_lines, "VibeAutoMergedDelete" })
            end
        else
            -- Show previous version for modifications (not pure additions)
            local old_lines = ic and ic.stored_lines or {}
            if #old_lines > 0 then
                has_old_content = true
                table.insert(preview_lines, "")
                table.insert(preview_lines, "━━━━━━━━━ Previous version ━━━━━━━━━")
                table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
                for _, line in ipairs(old_lines) do
                    table.insert(preview_lines, line)
                    table.insert(hl_ranges, { #preview_lines, "VibePreviewBase" })
                end
            end
        end
    end

    -- Create preview buffer
    M.preview_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(M.preview_bufnr, 0, -1, false, preview_lines)
    vim.bo[M.preview_bufnr].bufhidden = "wipe"
    vim.bo[M.preview_bufnr].modifiable = false

    local win_width = vim.api.nvim_win_get_width(0)
    local win_height = vim.api.nvim_win_get_height(0)

    -- Compute content-aware width from all preview lines
    local content_width = 60
    for _, line in ipairs(preview_lines) do
        content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
    end

    local width, height, needs_scroll
    if has_old_content then
        -- Use the larger of 80% window width or content width, capped to window
        width = math.max(math.floor(win_width * 0.8), content_width + 2)
        width = math.min(width, win_width - 4)
        height = math.min(#preview_lines + 2, math.max(20, math.floor(win_height * 0.7)))
        needs_scroll = height < #preview_lines + 2
    else
        -- Keybind-only: size to content
        width = math.max(60, math.min(content_width + 4, win_width - 4))
        height = math.min(#preview_lines + 2, 5)
        needs_scroll = false
    end

    local row = math.max(0, math.floor((win_height - height) / 2))
    local col = math.max(0, math.floor((win_width - width) / 2))

    local title = " " .. info.label .. " "

    M.preview_winnr = vim.api.nvim_open_win(M.preview_bufnr, false, {
        relative = "win",
        win = 0,
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
        zindex = 100,
    })

    -- If content overflows, update header with scroll hint
    if needs_scroll then
        local k_sd = kd.get_key_or_fallback(bufnr, kd.DESC_SCROLL_DOWN, "<leader>d")
        local k_su = kd.get_key_or_fallback(bufnr, kd.DESC_SCROLL_UP, "<leader>u")
        local scroll_hint = string.format("  [%s/%s scroll]", k_sd, k_su)
        local updated_header = preview_lines[1] .. scroll_hint
        vim.bo[M.preview_bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(M.preview_bufnr, 0, 1, false, { updated_header })
        vim.bo[M.preview_bufnr].modifiable = false
        preview_lines[1] = updated_header
    end

    -- Apply highlights
    local ns_preview = vim.api.nvim_create_namespace("vibe_preview_hl")
    for _, hl in ipairs(hl_ranges) do
        pcall(vim.api.nvim_buf_add_highlight, M.preview_bufnr, ns_preview, hl[2], hl[1] - 1, 0, -1)
    end

    -- Preview keymaps
    if is_auto then
        local is_sentinel = auto_aic and auto_aic.is_sentinel
        review_keymaps.setup_preview(M.preview_bufnr, {
            accept = is_sentinel and function()
                M.close_preview()
                M.recover_auto_deletion(bufnr, idx)
            end or nil,
            reject = function()
                M.close_preview()
                if is_sentinel then
                    M.dismiss_auto_deletion(bufnr, idx)
                else
                    M.reject_auto_item(bufnr, idx)
                end
            end,
            close = M.close_preview,
        }, nil)
    elseif cls == types.CONFLICT then
        review_keymaps.setup_preview(M.preview_bufnr, {
            keep_user = function()
                M.close_preview()
                M.resolve_item("keep_user")
            end,
            keep_ai = function()
                M.close_preview()
                M.resolve_item("keep_ai")
            end,
            edit_manually = function()
                M.close_preview()
                M.resolve_item("edit_manually")
            end,
            close = M.close_preview,
        }, cls)
    else
        review_keymaps.setup_preview(M.preview_bufnr, {
            accept = function()
                M.close_preview()
                M.resolve_item("accept")
            end,
            reject = function()
                M.close_preview()
                M.resolve_item("reject")
            end,
            close = M.close_preview,
        }, cls)
    end
end

--- Resolve the review item at cursor
function M.resolve_item(resolution, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return false
    end

    local region, idx = M.get_item_at_cursor(bufnr)
    if not region then
        return false
    end

    -- For "edit_manually", insert conflict markers inline
    if resolution == "edit_manually" then
        M.open_edit_inline(bufnr, region, idx)
        return true
    end

    local start_row, end_row = get_current_range(bufnr, idx)
    if not start_row then
        return false
    end

    pcall(vim.cmd, "undojoin")

    -- Remove extmark and sign
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000)
    pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = idx * 1000 })

    local is_accept = (resolution == "keep_ai" or resolution == "accept")

    if is_accept then
        -- For deletion sentinels, remove the sentinel line from the buffer
        local ic = state.item_contents[idx]
        if ic and ic.is_deletion_sentinel then
            vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, {})
        end
        -- Clean up virtual line extmark if present
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000 + 1)
    else
        -- Replace displayed range with stored_lines (keep_user / reject)
        local stored_lines = state.item_contents[idx] and state.item_contents[idx].stored_lines or {}
        vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, stored_lines)
        -- Clean up virtual line extmark if present
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000 + 1)
    end

    region._resolved = true
    state._last_preview_idx = nil

    -- Mark as addressed
    local action = resolve.resolution_to_action_v2(region.classification, resolution)
    M._mark_region_addressed(state, region, action)

    local remaining = M.count_remaining(bufnr)
    if remaining == 0 then
        M.finalize_file(bufnr)
    else
        M.next_item(bufnr)
        vim.defer_fn(M.show_preview, 50)
        vim.notify(string.format("[Vibe] Resolved. %d remaining", remaining), vim.log.levels.INFO)
    end
    return true
end

--- Insert conflict markers inline for manual editing
function M.open_edit_inline(bufnr, region, idx)
    M.close_preview()

    local start_row, end_row = get_current_range(bufnr, idx)
    if not start_row then
        return
    end

    -- Build conflict marker lines
    local edit_lines = {}
    table.insert(edit_lines, "<<<<<<< YOURS")
    for _, line in ipairs(region.user_lines or {}) do
        table.insert(edit_lines, line)
    end
    table.insert(edit_lines, "=======")
    for _, line in ipairs(region.ai_lines or {}) do
        table.insert(edit_lines, line)
    end
    table.insert(edit_lines, ">>>>>>> AI")

    pcall(vim.cmd, "undojoin")

    -- Remove extmark and sign
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, idx * 1000)
    pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = idx * 1000 })

    -- Replace the region in-buffer with conflict markers
    vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, edit_lines)

    -- Mark as resolved immediately (user edits at their leisure)
    local state = M.buffer_state[bufnr]
    if state then
        region._resolved = true
        state.resolved_count = state.resolved_count + 1
        state._last_preview_idx = nil
        M._mark_region_addressed(state, region, "accepted")

        local remaining = M.count_remaining(bufnr)
        local hint_label = remaining > 0 and "continue reviewing" or nil
        M.show_hint(bufnr, hint_label)
        local k_done = kd.get_key_or_fallback(bufnr, kd.DESC_DONE, "<leader>c")
        vim.notify(
            string.format(
                "[Vibe] Conflict markers inserted. Edit freely, then %s to continue.",
                k_done
            ),
            vim.log.levels.INFO
        )
    end

    -- Navigate cursor to the conflict markers
    vim.api.nvim_win_set_cursor(0, { start_row + 1, 0 })
end

--- Mark a region as addressed in the hunk tracking system
function M._mark_region_addressed(state, region, action)
    -- Create a dummy hunk for the tracking system
    local dummy_hunk = {
        old_start = region.base_range[1],
        old_count = region.base_range[2] - region.base_range[1] + 1,
        new_start = region.base_range[1],
        new_count = #(region.ai_lines or {}),
        removed_lines = region.base_lines or {},
        added_lines = region.ai_lines or {},
        type = "change",
    }
    pcall(git.mark_hunk_addressed, state.worktree_path, state.filepath, dummy_hunk, action)
end

--- Reject an auto-merged modification/addition (revert to base)
function M.reject_auto_item(bufnr, auto_idx)
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end
    local region = state.auto_items[auto_idx]
    local aic = state.auto_item_contents[auto_idx]
    if not region or not aic then
        return
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_auto, aic.extmark_id, { details = true })
    if not mark or #mark == 0 then
        return
    end
    local start_row = mark[1]
    local end_row = (mark[3] and mark[3].end_row) or (start_row + 1)

    pcall(vim.cmd, "undojoin")
    vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, region.base_lines or {})

    -- Clean up extmarks in affected range
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_auto, aic.extmark_id)
    local new_end = start_row + #(region.base_lines or {})
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns_auto, { start_row, 0 }, { new_end, 0 }, {})
    for _, m in ipairs(marks) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_auto, m[1])
    end

    region._rejected = true
    state._last_preview_idx = nil
    M._mark_region_addressed(state, region, "rejected")
end

--- Recover auto-merged deleted lines (replace sentinel with original content)
function M.recover_auto_deletion(bufnr, auto_idx)
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end
    local region = state.auto_items[auto_idx]
    local aic = state.auto_item_contents[auto_idx]
    if not region or not aic or not aic.is_sentinel then
        return
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_auto, aic.extmark_id, { details = true })
    if not mark or #mark == 0 then
        return
    end
    local sentinel_row = mark[1]

    pcall(vim.cmd, "undojoin")
    -- Replace sentinel with recovered lines
    vim.api.nvim_buf_set_lines(bufnr, sentinel_row, sentinel_row + 1, false, region.base_lines or {})

    -- Clean up extmarks
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_auto, aic.extmark_id)
    local new_end = sentinel_row + #(region.base_lines or {})
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns_auto, { sentinel_row, 0 }, { new_end, 0 }, {})
    for _, m in ipairs(marks) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_auto, m[1])
    end

    region._rejected = true -- "rejected" the deletion = recovered original
    state._last_preview_idx = nil
    M._mark_region_addressed(state, region, "rejected")
end

--- Dismiss auto-merged deletion (confirm deletion, remove sentinel)
function M.dismiss_auto_deletion(bufnr, auto_idx)
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end
    local region = state.auto_items[auto_idx]
    local aic = state.auto_item_contents[auto_idx]
    if not region or not aic or not aic.is_sentinel then
        return
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_auto, aic.extmark_id, { details = true })
    if not mark or #mark == 0 then
        return
    end

    pcall(vim.cmd, "undojoin")
    -- Remove sentinel entirely
    vim.api.nvim_buf_set_lines(bufnr, mark[1], mark[1] + 1, false, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_auto, aic.extmark_id)

    region._dismissed = true
    state._last_preview_idx = nil
    M._mark_region_addressed(state, region, "accepted")
end

function M.count_remaining(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    local count = 0
    if state then
        for _, region in ipairs(state.review_items) do
            if not region._resolved then
                count = count + 1
            end
        end
    end
    return count
end

--- Collect all navigable target positions (review items + auto items)
local function collect_nav_targets(bufnr, state)
    local targets = {}
    for i, region in ipairs(state.review_items) do
        if not region._resolved then
            local start_row = get_current_range(bufnr, i)
            if start_row then
                table.insert(targets, start_row)
            end
        end
    end
    for i, region in ipairs(state.auto_items) do
        if not region._rejected and not region._dismissed then
            local aic = state.auto_item_contents[i]
            if aic then
                local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_auto, aic.extmark_id, { details = true })
                if mark and #mark > 0 then
                    table.insert(targets, mark[1])
                end
            end
        end
    end
    table.sort(targets)
    return targets
end

function M.next_item(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end
    local win = find_buf_win(bufnr) or 0
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1
    local targets = collect_nav_targets(bufnr, state)

    for _, pos in ipairs(targets) do
        if pos > cursor_line then
            vim.api.nvim_win_set_cursor(win, { pos + 1, 0 })
            return
        end
    end
    -- Wrap around
    if #targets > 0 then
        vim.api.nvim_win_set_cursor(win, { targets[1] + 1, 0 })
    end
end

function M.prev_item(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end
    local win = find_buf_win(bufnr) or 0
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1
    local targets = collect_nav_targets(bufnr, state)

    for i = #targets, 1, -1 do
        if targets[i] < cursor_line then
            vim.api.nvim_win_set_cursor(win, { targets[i] + 1, 0 })
            return
        end
    end
    -- Wrap around
    if #targets > 0 then
        vim.api.nvim_win_set_cursor(win, { targets[#targets] + 1, 0 })
    end
end

function M.accept_all(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end

    local remaining = M.count_remaining(bufnr)
    if remaining == 0 then
        M.finalize_file(bufnr)
        return
    end

    -- Accept all = keep what's in the buffer. Just remove extmarks/signs.
    -- Process in reverse to maintain stable positions for sentinel removal.
    for i = #state.review_items, 1, -1 do
        local region = state.review_items[i]
        if not region._resolved then
            local start_row, end_row = get_current_range(bufnr, i)
            pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, i * 1000)
            pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, i * 1000 + 1)
            pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr, id = i * 1000 })

            -- Remove sentinel lines for deletions
            local ic = state.item_contents[i]
            if ic and ic.is_deletion_sentinel and start_row then
                vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, {})
            end

            region._resolved = true
            state.resolved_count = state.resolved_count + 1

            local resolution = region.classification == types.CONFLICT and "keep_ai" or "accept"
            local action = resolve.resolution_to_action_v2(region.classification, resolution)
            M._mark_region_addressed(state, region, action)
        end
    end

    vim.notify("[Vibe] All items accepted", vim.log.levels.INFO)
    M.finalize_file(bufnr)
end

function M.quit(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    local remaining = M.count_remaining(bufnr)

    if remaining > 0 and vim.fn.confirm("Unresolved item(s). Quit anyway?", "&Yes\n&No", 2) ~= 1 then
        return
    end

    M.close_preview()
    M.close_hint()
    if state then
        -- Restore original content (reject auto-merge changes)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, state.original_lines)
        vim.cmd("write")
        M.buffer_state[bufnr] = nil
        vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, M.ns_auto, 0, -1)
        vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
    end
    if state and state.worktree_path then
        require("vibe.dialog").show(state.worktree_path)
    end
end

function M.finalize_file(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = M.buffer_state[bufnr]
    if not state then
        return
    end

    -- Mark auto-merged items as addressed (skip already rejected/dismissed)
    for _, region in ipairs(state.auto_items) do
        if not region._rejected and not region._dismissed then
            local action = resolve.resolution_to_action_v2(region.classification, "accept")
            M._mark_region_addressed(state, region, action)
        end
    end

    -- Remove remaining sentinel lines (user didn't interact with them)
    -- Process in reverse to maintain stable positions
    for i = #state.auto_items, 1, -1 do
        local aic = state.auto_item_contents[i]
        local region = state.auto_items[i]
        if aic and aic.is_sentinel and not region._rejected and not region._dismissed then
            local mark =
                vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_auto, aic.extmark_id, { details = true })
            if mark and #mark > 0 then
                pcall(vim.api.nvim_buf_set_lines, bufnr, mark[1], mark[1] + 1, false, {})
            end
        end
    end

    local user_file_path = vim.api.nvim_buf_get_name(bufnr)
    vim.fn.mkdir(vim.fn.fnamemodify(user_file_path, ":h"), "p")
    -- Ensure we write the review buffer, not whatever floating window might be current
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("write")
    end)
    git.sync_resolved_file(state.worktree_path, state.filepath, user_file_path)

    M.buffer_state[bufnr] = nil
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns_auto, 0, -1)
    vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
    M.close_preview()
    M.close_hint()
    util.check_remaining_files(state.worktree_path, state.merge_mode)
end

function M.setup_tracking(bufnr)
    local group = vim.api.nvim_create_augroup("Vibe_review_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = bufnr,
        callback = function()
            local state = M.buffer_state[bufnr]
            if not state then
                return
            end
            -- Check review items first, then auto items
            local region, idx = M.get_item_at_cursor(bufnr)
            local is_auto = false
            if not region or region._resolved then
                region, idx = M.get_auto_item_at_cursor(bufnr)
                is_auto = true
            end
            if region and (is_auto or not region._resolved) then
                local preview_key = is_auto and ("auto_" .. idx) or idx
                if state._last_preview_idx == preview_key and M.is_preview_visible() then
                    -- Same region, preview already open: do nothing
                else
                    M.show_preview()
                end
            else
                state._last_preview_idx = nil
                M.close_preview()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = bufnr, callback = M.close_preview })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = bufnr,
        callback = function()
            M.buffer_state[bufnr] = nil
            M.close_preview()
        end,
    })
end

function M.setup_keymaps(bufnr)
    review_keymaps.setup(bufnr, {
        get_item_at_cursor = function()
            local region, _ = M.get_item_at_cursor(bufnr)
            return region
        end,
        resolve = function(resolution)
            M.close_preview()
            M.resolve_item(resolution, bufnr)
        end,
        next_item = function()
            M.next_item(bufnr)
        end,
        prev_item = function()
            M.prev_item(bufnr)
        end,
        done = function()
            local remaining = M.count_remaining(bufnr)
            if remaining > 0 then
                M.close_hint()
                M.next_item(bufnr)
                vim.defer_fn(M.show_preview, 50)
                vim.notify(string.format("[Vibe] %d item(s) remaining", remaining), vim.log.levels.INFO)
            else
                M.finalize_file(bufnr)
            end
        end,
        quit = function()
            M.quit(bufnr)
        end,
    })

    -- Accept all via command
    vim.api.nvim_buf_create_user_command(bufnr, "VibeAcceptAll", function()
        M.accept_all(bufnr)
    end, { desc = "Accept all review items" })
end

function M.setup()
    -- Highlights are now handled by vibe.highlights.setup()
end

--- Show floating hint window for accept-file keybind
function M.show_hint(bufnr, label)
    M.close_hint()

    local k_done = kd.get_key_or_fallback(bufnr, kd.DESC_DONE, "<leader>c")
    local hint_text = " " .. k_done .. "  " .. (label or "accept file and continue") .. " "

    M.hint_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(M.hint_bufnr, 0, -1, false, { hint_text })
    vim.bo[M.hint_bufnr].bufhidden = "wipe"
    vim.bo[M.hint_bufnr].modifiable = false

    -- Apply highlights: keybind in blue, description in Comment
    local ns_hint = vim.api.nvim_create_namespace("vibe_hint_hl")
    local key_end = #(" " .. k_done)
    pcall(vim.api.nvim_buf_add_highlight, M.hint_bufnr, ns_hint, "VibePreviewKeymap", 0, 0, key_end)
    pcall(vim.api.nvim_buf_add_highlight, M.hint_bufnr, ns_hint, "Comment", 0, key_end, -1)

    local win_height = vim.api.nvim_win_get_height(0)
    local win_width = vim.api.nvim_win_get_width(0)
    local hint_width = math.min(vim.fn.strdisplaywidth(hint_text), win_width - 4)
    local row = math.max(0, win_height - 3)
    local col = 1

    M.hint_winnr = vim.api.nvim_open_win(M.hint_bufnr, false, {
        relative = "win",
        win = 0,
        row = row,
        col = col,
        width = hint_width,
        height = 1,
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 50,
    })

    if M.hint_winnr and vim.api.nvim_win_is_valid(M.hint_winnr) then
        pcall(vim.api.nvim_win_set_option, M.hint_winnr, "winblend", 20)
    end
end

--- Close the floating hint window
function M.close_hint()
    if M.hint_winnr and vim.api.nvim_win_is_valid(M.hint_winnr) then
        vim.api.nvim_win_close(M.hint_winnr, true)
    end
    M.hint_winnr, M.hint_bufnr = nil, nil
end

function M.clear(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    M.buffer_state[bufnr] = nil
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns_auto, 0, -1)
    vim.fn.sign_unplace("vibe_review", { buffer = bufnr })
    M.close_preview()
    M.close_hint()
end

function M.is_review_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    return M.buffer_state[bufnr] ~= nil
end

return M
