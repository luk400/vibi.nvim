local git = require("vibe.git")
local config = require("vibe.config")
local util = require("vibe.util")

local M = {}

---@type integer|nil
M.dialog_bufnr = nil

---@type integer|nil
M.dialog_winid = nil

---@type string[] Changed files
M.changed_files = {}

---@type integer Current selection index
M.selected_idx = 1

---@type string|nil Current worktree path being reviewed
M.current_worktree_path = nil

---@type string|nil Current session name being reviewed
M.current_session_name = nil

---@type string "none"|"user"|"ai"|"both"
M.review_mode = "user"

---@type integer Number of gitignored files omitted from review
M.ignored_count = 0

---@type table<string, {added: integer, removed: integer}> Per-file hunk stats cache
M.hunk_cache = {}

---@type table<string, table> Per-file classification cache
M.file_status_cache = {}

--- Open the modified files dialog for a worktree
---@param worktree_path string|nil The worktree to review (uses first available if nil)
---@param worktree_info table|nil Optional worktree info (avoids lookup)
---@param review_mode string|nil Mode for reviewing ("auto" or "manual")
function M.show(worktree_path, worktree_info, review_mode)
    M.close()

    -- Full state reset before any early returns
    M.changed_files = {}
    M.selected_idx = 1
    M.review_mode = review_mode or config.options.merge_mode or "user"
    M.current_worktree_path = nil
    M.current_session_name = nil
    M.file_status_cache = {}
    M.ignored_count = 0

    if not worktree_path then
        local worktrees = git.get_worktrees_with_changes()
        if #worktrees == 0 then
            vim.notify("[Vibe] No sessions with changes to review", vim.log.levels.INFO)
            return
        end
        worktree_path = worktrees[1].worktree_path
        worktree_info = worktrees[1]
    end

    local info = worktree_info or git.get_worktree_info(worktree_path)
    if not info then
        vim.notify("[Vibe] Worktree info lost, scanning...", vim.log.levels.WARN)
        git.scan_for_vibe_worktrees()
        info = git.get_worktree_info(worktree_path)
        if not info then
            vim.notify("[Vibe] Worktree not found: " .. tostring(worktree_path), vim.log.levels.ERROR)
            return
        end
    end

    M.current_worktree_path = worktree_path
    M.current_session_name = info.name
    local unresolved, ignored_count = git.get_unresolved_files(worktree_path)
    M.changed_files = unresolved
    M.ignored_count = ignored_count or 0
    M.hunk_cache = {}
    M.file_status_cache = {}
    local classifier = require("vibe.review.classifier")
    local review_types = require("vibe.review.types")
    for _, file in ipairs(M.changed_files) do
        local user_file_path = info.repo_root .. "/" .. file
        local ok, hunks = pcall(git.get_worktree_file_hunks, worktree_path, file, user_file_path)
        if ok and hunks then
            local added, removed = 0, 0
            for _, hunk in ipairs(hunks) do
                added = added + #(hunk.added_lines or {})
                removed = removed + #(hunk.removed_lines or {})
            end
            M.hunk_cache[file] = { added = added, removed = removed }
        end
        -- Classify file for badges
        local cls_ok, classified = pcall(classifier.classify_file, worktree_path, file, info.repo_root)
        if cls_ok and classified then
            local conflict_count = 0
            local total_regions = #classified.regions
            for _, region in ipairs(classified.regions) do
                if region.classification == review_types.CONFLICT then
                    conflict_count = conflict_count + 1
                end
            end
            -- Check if all regions would be auto-merged
            local all_auto = true
            for _, region in ipairs(classified.regions) do
                if not review_types.should_auto_resolve(region.classification, M.review_mode) then
                    all_auto = false
                    break
                end
            end
            M.file_status_cache[file] = {
                file_status = classified.file_status,
                conflict_count = conflict_count,
                region_count = total_regions,
                all_auto = all_auto and total_regions > 0,
            }
        end
    end

    if #M.changed_files == 0 then
        git.update_snapshot(worktree_path)
        vim.notify("[Vibe] No unresolved files in this session", vim.log.levels.INFO)
        M.current_worktree_path = nil
        M.current_session_name = nil
        return
    end

    local target_height = math.min(20, #M.changed_files + 6)

    local bufnr, winid, close = util.create_centered_float({
        filetype = "vibe_dialog",
        min_width = math.max(74, math.floor(vim.o.columns * 0.5)),
        height = target_height,
        title = "Vibe: Modified Files (" .. info.name .. ")",
        cursorline = true,
        zindex = 200,
        no_default_keymaps = true,
    })

    M.dialog_bufnr = bufnr
    M.dialog_winid = winid
    M.selected_idx = 1
    vim.wo[winid].wrap = false

    M.render()
    M.setup_keymaps()
    M.detect_overlapping_sessions()
end

function M.close()
    if M.dialog_winid and vim.api.nvim_win_is_valid(M.dialog_winid) then
        vim.api.nvim_win_close(M.dialog_winid, true)
    end
    M.dialog_winid = nil
    M.dialog_bufnr = nil
    M.selected_idx = 1
    M.current_worktree_path = nil
    M.current_session_name = nil
    M.ignored_count = 0
end

function M.is_open()
    return M.dialog_winid ~= nil and vim.api.nvim_win_is_valid(M.dialog_winid)
end

function M.render()
    if not M.dialog_bufnr then
        return
    end

    local review_types = require("vibe.review.types")
    local lines = {}
    local mode_label = review_types.mode_labels[M.review_mode] or ""
    if mode_label ~= "" then
        mode_label = " (" .. mode_label .. ")"
    end
    table.insert(lines, "Files to review" .. mode_label .. ":")
    table.insert(lines, "")

    for i, file in ipairs(M.changed_files) do
        local prefix = i == M.selected_idx and "▶ " or "  "
        local stats = M.hunk_cache[file]
        local file_info = M.file_status_cache[file]

        local parts = { prefix .. file }

        -- File status badge
        if file_info then
            local fs = file_info.file_status
            if fs == review_types.FILE_NEW_AI then
                table.insert(parts, " [new: AI]")
            elseif fs == review_types.FILE_NEW_USER then
                table.insert(parts, " [new: yours]")
            elseif fs == review_types.FILE_DELETED_AI then
                table.insert(parts, " [deleted: AI]")
            elseif fs == review_types.FILE_DELETED_USER then
                table.insert(parts, " [deleted: yours]")
            elseif fs == review_types.FILE_DELETE_CONFLICT_AI_MOD then
                table.insert(parts, " [delete conflict]")
            elseif fs == review_types.FILE_MODIFIED then
                table.insert(parts, " [modified]")
            end
        end

        -- Stats
        if stats then
            table.insert(parts, string.format("  +%d -%d", stats.added, stats.removed))
        end

        -- Conflict count
        if file_info and file_info.conflict_count > 0 then
            table.insert(parts, string.format("  %d conflict(s)", file_info.conflict_count))
        end

        -- Auto-merged indicator
        if file_info and file_info.all_auto then
            table.insert(parts, "  auto-merged")
        end

        table.insert(lines, table.concat(parts))
    end

    if M.ignored_count > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format(
            "  (%d file%s matching .gitignore omitted)",
            M.ignored_count,
            M.ignored_count == 1 and "" or "s"
        ))
    end

    table.insert(lines, "")
    table.insert(
        lines,
        "────────────────────────────────────────"
    )
    local function dialog_key(desc, fallback)
        local maps = vim.api.nvim_buf_get_keymap(M.dialog_bufnr, "n")
        for _, map in ipairs(maps) do
            if map.desc == desc then
                local kd = require("vibe.review.keymap_display")
                return kd.format_key_display(map.lhs)
            end
        end
        return fallback
    end
    local k_accept = dialog_key("Accept file", "<leader>a")
    local k_reject = dialog_key("Reject file", "<leader>r")
    table.insert(lines, string.format("<CR> view  |  %s accept  |  %s reject  |  A accept all  |  q back", k_accept, k_reject))

    vim.bo[M.dialog_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(M.dialog_bufnr, 0, -1, false, lines)
    vim.bo[M.dialog_bufnr].modifiable = false

    for i, file in ipairs(M.changed_files) do
        local line_idx = i + 1
        local file_info = M.file_status_cache[file]
        if i == M.selected_idx then
            vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogSelected", line_idx, 0, -1)
        elseif file_info and file_info.all_auto then
            vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "Comment", line_idx, 0, -1)
        else
            vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogFile", line_idx, 0, -1)
        end
    end

    vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogHeader", 0, 0, -1)
    local extra_lines = M.ignored_count > 0 and 2 or 0
    local footer_start = #M.changed_files + 3 + extra_lines
    if M.ignored_count > 0 then
        local hint_line_idx = #M.changed_files + 3
        vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "Comment", hint_line_idx, 0, -1)
    end
    vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogFooter", footer_start, 0, -1)
    vim.api.nvim_buf_add_highlight(M.dialog_bufnr, -1, "VibeDialogFooter", footer_start + 1, 0, -1)

    -- Move cursor to selected line so the window scrolls to keep it visible
    if M.dialog_winid and vim.api.nvim_win_is_valid(M.dialog_winid) then
        vim.api.nvim_win_set_cursor(M.dialog_winid, { M.selected_idx + 2, 0 })
    end
end

function M.setup_keymaps()
    local opts = { buffer = M.dialog_bufnr, silent = true, noremap = true }

    vim.keymap.set("n", "j", function()
        if M.selected_idx < #M.changed_files then
            M.selected_idx = M.selected_idx + 1
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "k", function()
        if M.selected_idx > 1 then
            M.selected_idx = M.selected_idx - 1
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "<Down>", function()
        if M.selected_idx < #M.changed_files then
            M.selected_idx = M.selected_idx + 1
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "<Up>", function()
        if M.selected_idx > 1 then
            M.selected_idx = M.selected_idx - 1
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "<CR>", M.jump_to_file, opts)
    vim.keymap.set("n", "A", M.accept_all, opts)

    -- File-level accept: 3-way merge (preserves changes from other sessions)
    vim.keymap.set("n", "<leader>a", function()
        if #M.changed_files == 0 then
            return
        end
        local file = M.changed_files[M.selected_idx]
        if not file or not M.current_worktree_path then
            return
        end
        local ok, err, conflict_count = git.merge_accept_file(
            M.current_worktree_path, file, M.review_mode
        )
        if ok then
            vim.notify("[Vibe] File accepted (merged): " .. file, vim.log.levels.INFO)
            M.refresh()
        elseif err == "conflicts" then
            vim.notify(
                string.format("[Vibe] %s has %d conflict(s) - opening review", file, conflict_count),
                vim.log.levels.WARN
            )
            local worktree_path = M.current_worktree_path
            local review_mode = M.review_mode
            M.close()
            local info = git.get_worktree_info(worktree_path)
            if info then
                local user_file_path = info.repo_root .. "/" .. file
                local dir = vim.fn.fnamemodify(user_file_path, ":h")
                if vim.fn.isdirectory(dir) == 0 then
                    vim.fn.mkdir(dir, "p")
                end
                vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))
                require("vibe.diff").show_for_file(worktree_path, file, review_mode)
            end
        else
            vim.notify("[Vibe] Failed to accept: " .. (err or ""), vim.log.levels.ERROR)
        end
    end, vim.tbl_extend("force", opts, { desc = "Accept file" }))

    -- File-level reject: keep user version, mark all hunks addressed
    vim.keymap.set("n", "<leader>r", function()
        if #M.changed_files == 0 then
            return
        end
        local file = M.changed_files[M.selected_idx]
        if not file or not M.current_worktree_path then
            return
        end
        local info = git.get_worktree_info(M.current_worktree_path)
        if info then
            local hunks = git.get_worktree_file_hunks(M.current_worktree_path, file, info.repo_root .. "/" .. file)
            for _, hunk in ipairs(hunks or {}) do
                git.mark_hunk_addressed(M.current_worktree_path, file, hunk, "rejected")
            end
        end
        git.sync_resolved_file(M.current_worktree_path, file, (info and info.repo_root or "") .. "/" .. file)
        vim.notify("[Vibe] File rejected: " .. file, vim.log.levels.INFO)
        M.refresh()
    end, vim.tbl_extend("force", opts, { desc = "Reject file" }))

    local function back_to_review()
        M.close()
        require("vibe.session").show_review_list()
    end
    vim.keymap.set("n", "q", back_to_review, opts)
    vim.keymap.set("n", "<Esc>", back_to_review, opts)
end

function M.refresh()
    local wt = M.current_worktree_path
    local mode = M.review_mode
    if wt then
        M.show(wt, nil, mode)
    end
end

function M.jump_to_file()
    if #M.changed_files == 0 then
        return
    end
    local file = M.changed_files[M.selected_idx]
    if not file then
        return
    end

    local worktree_path = M.current_worktree_path
    local review_mode = M.review_mode
    local info = git.get_worktree_info(worktree_path)
    if not info then
        vim.notify("[Vibe] Worktree info lost", vim.log.levels.ERROR)
        return
    end

    M.close()

    local user_file_path = info.repo_root .. "/" .. file

    -- Create directory if the file is completely new to avoid errors
    local dir = vim.fn.fnamemodify(user_file_path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    vim.cmd("edit " .. vim.fn.fnameescape(user_file_path))

    local diff = require("vibe.diff")
    diff.show_for_file(worktree_path, file, review_mode)
end

function M.accept_all()
    if not M.current_worktree_path then
        return
    end
    local file_count = #M.changed_files
    if vim.fn.confirm(
        string.format("Merge ALL changes in %d file(s)? This cannot be undone.", file_count),
        "&Yes\n&No",
        2
    ) ~= 1 then
        return
    end

    local result = git.merge_accept_all(M.current_worktree_path, M.review_mode)

    if result.all_ok then
        git.update_snapshot(M.current_worktree_path)
        M.close()
        vim.notify(
            string.format("[Vibe] All %d file(s) merged successfully.", #result.accepted),
            vim.log.levels.INFO
        )
        local session = require("vibe.session")
        vim.defer_fn(function()
            session.show_review_list()
        end, 100)
    else
        local msg_parts = {}
        if #result.accepted > 0 then
            table.insert(msg_parts, string.format("%d file(s) merged", #result.accepted))
        end
        if #result.skipped > 0 then
            table.insert(msg_parts, string.format("%d file(s) have conflicts", #result.skipped))
        end
        if #result.errors > 0 then
            table.insert(msg_parts, string.format("%d file(s) failed", #result.errors))
        end
        vim.notify(
            "[Vibe] " .. table.concat(msg_parts, ", ") .. ". Review remaining files.",
            #result.errors > 0 and vim.log.levels.ERROR or vim.log.levels.WARN
        )
        M.refresh()
    end
end

function M.detect_overlapping_sessions()
    if not M.current_worktree_path or #M.changed_files == 0 then
        return
    end

    local all_worktrees = git.get_worktrees_with_changes()
    local overlapping = {}

    for _, wt_info in ipairs(all_worktrees) do
        if wt_info.worktree_path ~= M.current_worktree_path then
            local other_files = git.get_worktree_changed_files(wt_info.worktree_path)
            local other_set = {}
            for _, f in ipairs(other_files) do
                other_set[f] = true
            end
            local shared_count = 0
            for _, f in ipairs(M.changed_files) do
                if other_set[f] then
                    shared_count = shared_count + 1
                end
            end
            if shared_count > 0 then
                table.insert(overlapping, {
                    name = wt_info.name,
                    count = shared_count,
                })
            end
        end
    end

    if #overlapping > 0 then
        local parts = {}
        for _, ov in ipairs(overlapping) do
            table.insert(parts, string.format("'%s' (%d file(s))", ov.name, ov.count))
        end
        vim.defer_fn(function()
            vim.notify(
                "[Vibe] Overlapping files with session(s): "
                    .. table.concat(parts, ", ")
                    .. ". Use merge review (Enter) for safe merging.",
                vim.log.levels.WARN
            )
        end, 50)
    end
end

function M.get_current_worktree()
    return M.current_worktree_path
end

function M.setup_highlights()
    vim.api.nvim_set_hl(0, "VibeDialogHeader", { link = "Title" })
    vim.api.nvim_set_hl(0, "VibeDialogFile", { link = "Normal" })
    vim.api.nvim_set_hl(0, "VibeDialogSelected", { link = "Visual" })
    vim.api.nvim_set_hl(0, "VibeDialogFooter", { link = "Comment" })
end

return M
