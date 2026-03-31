--- Tests for inline display of conflicts and suggestions in :VibeReview
local renderer = require("vibe.review.renderer")
local types = require("vibe.review.types")

local eq = assert.are.equal

--- Helper: create a minimal buffer state with review items for testing
local function setup_test_buffer(review_items, buf_lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines or { "line1", "line2", "line3", "line4", "line5" })

    renderer.buffer_state[bufnr] = {
        worktree_path = "/tmp/test-wt",
        filepath = "test.lua",
        session_name = "test",
        classified_file = { regions = {} },
        merge_mode = "user",
        review_items = review_items or {},
        auto_items = {},
        item_contents = {},
        auto_item_contents = {},
        resolved_count = 0,
        original_lines = vim.deepcopy(buf_lines or { "line1", "line2", "line3", "line4", "line5" }),
        merged_lines = {},
    }

    return bufnr
end

--- Helper: count extmarks in a namespace
local function count_extmarks(bufnr, ns)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    return #marks
end

--- Helper: get extmarks with details
local function get_extmarks_detail(bufnr, ns)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

--- Helper: mock git.get_worktree_snapshot_lines
local function mock_snapshot(snapshot_lines)
    local git = require("vibe.git")
    local orig = git.get_worktree_snapshot_lines
    git.get_worktree_snapshot_lines = function()
        return snapshot_lines
    end
    return function()
        git.get_worktree_snapshot_lines = orig
    end
end

describe("Inline review display", function()
    after_each(function()
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if renderer.buffer_state[bufnr] then
                renderer.buffer_state[bufnr] = nil
                pcall(vim.api.nvim_buf_clear_namespace, bufnr, renderer.ns, 0, -1)
                pcall(vim.fn.sign_unplace, "vibe_review", { buffer = bufnr })
            end
        end
        renderer.close_preview()
    end)

    describe("setup_inline_review_items for conflicts", function()
        it("shows AI lines in buffer and stores user lines", function()
            -- Base: line1, old_line, line3
            -- User: line1, user_line, line3
            -- AI: line1, ai_line, line3
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 2 },
                    base_lines = { "old_line" },
                    user_lines = { "user_line" },
                    ai_lines = { "ai_line" },
                },
            }
            -- Buffer starts with user content
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Buffer should now have AI lines
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(3, #lines)
            eq("line1", lines[1])
            eq("ai_line", lines[2])
            eq("line3", lines[3])

            -- Extmark should span the AI line
            local marks = get_extmarks_detail(bufnr, renderer.ns)
            assert.is_true(#marks > 0)
            local mark = marks[1]
            eq(1, mark[2]) -- start_row (0-indexed, line 2)
            assert.is_truthy(mark[4].end_row)
            assert.is_truthy(mark[4].hl_group)

            -- Stored lines should be user_lines
            local state = renderer.buffer_state[bufnr]
            assert.is_truthy(state.item_contents[1])
            eq("ai_line", state.item_contents[1].display_lines[1])
            eq("user_line", state.item_contents[1].stored_lines[1])
        end)

        it("handles multi-line conflicts", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 3 },
                    base_lines = { "old2", "old3" },
                    user_lines = { "user2", "user3" },
                    ai_lines = { "ai2", "ai3", "ai_extra" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user2", "user3", "line4" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old2", "old3", "line4" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(5, #lines) -- 1 + 3 AI lines + 1
            eq("line1", lines[1])
            eq("ai2", lines[2])
            eq("ai3", lines[3])
            eq("ai_extra", lines[4])
            eq("line4", lines[5])

            -- Extmark should span 3 lines
            local marks = get_extmarks_detail(bufnr, renderer.ns)
            assert.is_true(#marks > 0)
            local mark = marks[1]
            eq(1, mark[2]) -- start at row 1
            eq(4, mark[4].end_row) -- end at row 4 (exclusive)
        end)

        it("inserts sentinel line when AI deleted the section", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 2 },
                    base_lines = { "old_line" },
                    user_lines = { "user_line" },
                    ai_lines = {},
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(3, #lines)
            -- Should have empty sentinel line as hover target
            eq("", lines[2])
            -- Should be marked as deletion sentinel
            local ic = renderer.buffer_state[bufnr].item_contents[1]
            assert.is_truthy(ic.is_deletion_sentinel)
        end)
    end)

    describe("setup_inline_review_items for suggestions", function()
        it("shows user lines for USER_ONLY and stores base lines", function()
            local review_items = {
                {
                    classification = types.USER_ONLY,
                    base_range = { 2, 2 },
                    base_lines = { "base_line" },
                    user_lines = { "user_line" },
                    ai_lines = { "base_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "base_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Buffer should still have user_lines (no change)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("user_line", lines[2])

            -- Stored lines should be base_lines
            local state = renderer.buffer_state[bufnr]
            eq("user_line", state.item_contents[1].display_lines[1])
            eq("base_line", state.item_contents[1].stored_lines[1])
        end)

        it("shows AI lines for AI_ONLY and stores base lines", function()
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 2, 2 },
                    base_lines = { "base_line" },
                    user_lines = { "base_line" },
                    ai_lines = { "ai_line" },
                },
            }
            -- Buffer starts with user content (which equals base for AI_ONLY)
            local bufnr = setup_test_buffer(review_items, { "line1", "base_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "base_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Buffer should now have AI lines
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("ai_line", lines[2])

            -- Stored lines should be base_lines
            local state = renderer.buffer_state[bufnr]
            eq("ai_line", state.item_contents[1].display_lines[1])
            eq("base_line", state.item_contents[1].stored_lines[1])
        end)

        it("shows user lines for CONVERGENT and stores base lines", function()
            local review_items = {
                {
                    classification = types.CONVERGENT,
                    base_range = { 2, 2 },
                    base_lines = { "base_line" },
                    user_lines = { "agreed_line" },
                    ai_lines = { "agreed_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "agreed_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "base_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("agreed_line", lines[2])

            local state = renderer.buffer_state[bufnr]
            eq("agreed_line", state.item_contents[1].display_lines[1])
            eq("base_line", state.item_contents[1].stored_lines[1])
        end)

        it("places extmarks with correct highlight group", function()
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 2, 2 },
                    base_lines = { "base_line" },
                    user_lines = { "base_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "base_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "base_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local marks = get_extmarks_detail(bufnr, renderer.ns)
            assert.is_true(#marks > 0)
            eq("VibeSuggestionInline", marks[1][4].hl_group)
        end)
    end)

    describe("get_item_at_cursor with multi-line ranges", function()
        it("returns item when cursor is at start of range", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 3 },
                    base_lines = { "old2", "old3" },
                    user_lines = { "user2", "user3" },
                    ai_lines = { "ai2", "ai3", "ai_extra" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user2", "user3", "line4" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old2", "old3", "line4" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Cursor at first AI line (row 2, 1-indexed)
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            local region, idx = renderer.get_item_at_cursor(bufnr)
            assert.is_truthy(region)
            eq(1, idx)
        end)

        it("returns item when cursor is in middle of range", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 3 },
                    base_lines = { "old2", "old3" },
                    user_lines = { "user2", "user3" },
                    ai_lines = { "ai2", "ai3", "ai_extra" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user2", "user3", "line4" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old2", "old3", "line4" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Cursor at middle AI line (row 3, 1-indexed)
            vim.api.nvim_win_set_cursor(0, { 3, 0 })
            local region, idx = renderer.get_item_at_cursor(bufnr)
            assert.is_truthy(region)
            eq(1, idx)
        end)

        it("returns item when cursor is at last line of range", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 3 },
                    base_lines = { "old2", "old3" },
                    user_lines = { "user2", "user3" },
                    ai_lines = { "ai2", "ai3", "ai_extra" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user2", "user3", "line4" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old2", "old3", "line4" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Cursor at last AI line (row 4, 1-indexed)
            vim.api.nvim_win_set_cursor(0, { 4, 0 })
            local region, idx = renderer.get_item_at_cursor(bufnr)
            assert.is_truthy(region)
            eq(1, idx)
        end)

        it("returns nil when cursor is outside range", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 2 },
                    base_lines = { "old_line" },
                    user_lines = { "user_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Cursor on line1 (outside range)
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            local region = renderer.get_item_at_cursor(bufnr)
            assert.is_nil(region)

            -- Cursor on line3 (outside range)
            vim.api.nvim_win_set_cursor(0, { 3, 0 })
            region = renderer.get_item_at_cursor(bufnr)
            assert.is_nil(region)
        end)
    end)

    describe("resolve_item keep_ai for conflicts", function()
        it("only removes extmark, buffer lines unchanged", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 2 },
                    base_lines = { "old_line" },
                    user_lines = { "user_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Verify AI line is in buffer
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("ai_line", lines[2])

            -- Mock finalize dependencies
            local git = require("vibe.git")
            local orig_sync = git.sync_resolved_file
            local orig_mark = git.mark_hunk_addressed
            git.sync_resolved_file = function() end
            git.mark_hunk_addressed = function() end
            local util_mod = require("vibe.util")
            local orig_check = util_mod.check_remaining_files
            util_mod.check_remaining_files = function() end

            -- Set buffer name so finalize works
            local tmpfile = vim.fn.tempname()
            vim.api.nvim_buf_set_name(bufnr, tmpfile)
            vim.bo[bufnr].buftype = ""

            -- Position cursor on the AI line
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            -- Resolve: keep_ai
            renderer.resolve_item("keep_ai")

            -- Buffer should be unchanged (AI content stays)
            lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(3, #lines)
            eq("ai_line", lines[2])

            -- Extmark should be removed
            eq(0, count_extmarks(bufnr, renderer.ns))

            -- Restore
            git.sync_resolved_file = orig_sync
            git.mark_hunk_addressed = orig_mark
            util_mod.check_remaining_files = orig_check
            pcall(os.remove, tmpfile)
        end)
    end)

    describe("resolve_item keep_user for conflicts", function()
        it("replaces AI lines with user lines", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 2 },
                    base_lines = { "old_line" },
                    user_lines = { "user_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Buffer has AI line
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("ai_line", lines[2])

            -- Mock dependencies
            local git = require("vibe.git")
            local orig_sync = git.sync_resolved_file
            local orig_mark = git.mark_hunk_addressed
            git.sync_resolved_file = function() end
            git.mark_hunk_addressed = function() end
            local util_mod = require("vibe.util")
            local orig_check = util_mod.check_remaining_files
            util_mod.check_remaining_files = function() end

            local tmpfile = vim.fn.tempname()
            vim.api.nvim_buf_set_name(bufnr, tmpfile)
            vim.bo[bufnr].buftype = ""

            -- Position cursor on the AI line
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            -- Resolve: keep_user
            renderer.resolve_item("keep_user")

            -- Buffer should now have user lines
            lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(3, #lines)
            eq("user_line", lines[2])

            -- Extmark should be removed
            eq(0, count_extmarks(bufnr, renderer.ns))

            -- Restore
            git.sync_resolved_file = orig_sync
            git.mark_hunk_addressed = orig_mark
            util_mod.check_remaining_files = orig_check
            pcall(os.remove, tmpfile)
        end)
    end)

    describe("resolve_item edit_manually for conflicts", function()
        it("inserts conflict markers inline", function()
            local review_items = {
                {
                    classification = types.CONFLICT,
                    base_range = { 2, 2 },
                    base_lines = { "old_line" },
                    user_lines = { "user_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "user_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "old_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Mock dependencies
            local git = require("vibe.git")
            local orig_sync = git.sync_resolved_file
            local orig_mark = git.mark_hunk_addressed
            git.sync_resolved_file = function() end
            git.mark_hunk_addressed = function() end
            local util_mod = require("vibe.util")
            local orig_check = util_mod.check_remaining_files
            util_mod.check_remaining_files = function() end

            local tmpfile = vim.fn.tempname()
            vim.api.nvim_buf_set_name(bufnr, tmpfile)
            vim.bo[bufnr].buftype = ""

            -- Position cursor on the AI line
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            -- Resolve: edit_manually
            renderer.resolve_item("edit_manually")

            -- Buffer should have conflict markers
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            -- Expected: line1, <<<<<<< YOURS, user_line, =======, ai_line, >>>>>>> AI, line3
            assert.is_true(#lines >= 7)
            eq("line1", lines[1])
            eq("<<<<<<< YOURS", lines[2])
            eq("user_line", lines[3])
            eq("=======", lines[4])
            eq("ai_line", lines[5])
            eq(">>>>>>> AI", lines[6])
            eq("line3", lines[7])

            -- Extmark should be removed
            eq(0, count_extmarks(bufnr, renderer.ns))

            -- Region should be marked resolved
            assert.is_true(review_items[1]._resolved)

            -- Restore
            git.sync_resolved_file = orig_sync
            git.mark_hunk_addressed = orig_mark
            util_mod.check_remaining_files = orig_check
            pcall(os.remove, tmpfile)
        end)
    end)

    describe("resolve_item accept for suggestions", function()
        it("only removes extmark for AI_ONLY accept", function()
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 2, 2 },
                    base_lines = { "base_line" },
                    user_lines = { "base_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "base_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "base_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Buffer has AI line
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("ai_line", lines[2])

            -- Mock dependencies
            local git = require("vibe.git")
            local orig_sync = git.sync_resolved_file
            local orig_mark = git.mark_hunk_addressed
            git.sync_resolved_file = function() end
            git.mark_hunk_addressed = function() end
            local util_mod = require("vibe.util")
            local orig_check = util_mod.check_remaining_files
            util_mod.check_remaining_files = function() end

            local tmpfile = vim.fn.tempname()
            vim.api.nvim_buf_set_name(bufnr, tmpfile)
            vim.bo[bufnr].buftype = ""

            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            renderer.resolve_item("accept")

            -- Buffer unchanged
            lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(3, #lines)
            eq("ai_line", lines[2])
            eq(0, count_extmarks(bufnr, renderer.ns))

            -- Restore
            git.sync_resolved_file = orig_sync
            git.mark_hunk_addressed = orig_mark
            util_mod.check_remaining_files = orig_check
            pcall(os.remove, tmpfile)
        end)
    end)

    describe("setup_inline_review_items for pure insertions", function()
        it("places AI_ONLY pure insertion after anchor line", function()
            -- Base: A, B, C — AI inserts "X" after "B"
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 2, 2 },
                    base_lines = {},
                    user_lines = {},
                    ai_lines = { "X" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "A", "B", "C" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "A", "B", "C" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(4, #lines)
            eq("A", lines[1])
            eq("B", lines[2])
            eq("X", lines[3])
            eq("C", lines[4])

            -- Extmark should cover the inserted line (line 3, 0-indexed row 2)
            local marks = get_extmarks_detail(bufnr, renderer.ns)
            assert.is_true(#marks > 0)
            eq(2, marks[1][2]) -- start_row 0-indexed
        end)

        it("places AI_ONLY pure insertion at beginning of file", function()
            -- Base: A, B, C — AI inserts "HEADER" before everything
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 0, 0 },
                    base_lines = {},
                    user_lines = {},
                    ai_lines = { "HEADER" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "A", "B", "C" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "A", "B", "C" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(4, #lines)
            eq("HEADER", lines[1])
            eq("A", lines[2])
            eq("B", lines[3])
            eq("C", lines[4])
        end)

        it("handles multiple pure insertions at correct positions", function()
            -- Base: A, B, C — AI inserts "X" after A and "Y" after B
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 1, 1 },
                    base_lines = {},
                    user_lines = {},
                    ai_lines = { "X" },
                },
                {
                    classification = types.AI_ONLY,
                    base_range = { 2, 2 },
                    base_lines = {},
                    user_lines = {},
                    ai_lines = { "Y" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "A", "B", "C" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "A", "B", "C" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(5, #lines)
            eq("A", lines[1])
            eq("X", lines[2])
            eq("B", lines[3])
            eq("Y", lines[4])
            eq("C", lines[5])
        end)
    end)

    describe("_build_resolved_content for pure insertions", function()
        it("places auto-resolved AI_ONLY insertion after anchor line", function()
            local state = {
                worktree_path = "/tmp/test-wt",
                filepath = "test.lua",
                session_name = "test",
                classified_file = {
                    regions = {
                        {
                            classification = types.AI_ONLY,
                            auto_resolved = true,
                            base_range = { 2, 2 },
                            base_lines = {},
                            user_lines = {},
                            ai_lines = { "X" },
                        },
                    },
                },
                auto_items = { true }, -- non-empty to trigger the code path
                review_items = {},
            }

            local restore = mock_snapshot({ "A", "B", "C" })
            local result = renderer._build_resolved_content(state)
            restore()

            eq(4, #result)
            eq("A", result[1])
            eq("B", result[2])
            eq("X", result[3])
            eq("C", result[4])
        end)
    end)

    describe("resolve_item reject for suggestions", function()
        it("replaces displayed lines with base lines", function()
            local review_items = {
                {
                    classification = types.AI_ONLY,
                    base_range = { 2, 2 },
                    base_lines = { "base_line" },
                    user_lines = { "base_line" },
                    ai_lines = { "ai_line" },
                },
            }
            local bufnr = setup_test_buffer(review_items, { "line1", "base_line", "line3" })
            renderer.setup_highlights()

            local restore = mock_snapshot({ "line1", "base_line", "line3" })
            renderer.setup_inline_review_items(bufnr)
            restore()

            -- Buffer has AI line
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq("ai_line", lines[2])

            -- Mock dependencies
            local git = require("vibe.git")
            local orig_sync = git.sync_resolved_file
            local orig_mark = git.mark_hunk_addressed
            git.sync_resolved_file = function() end
            git.mark_hunk_addressed = function() end
            local util_mod = require("vibe.util")
            local orig_check = util_mod.check_remaining_files
            util_mod.check_remaining_files = function() end

            local tmpfile = vim.fn.tempname()
            vim.api.nvim_buf_set_name(bufnr, tmpfile)
            vim.bo[bufnr].buftype = ""

            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            renderer.resolve_item("reject")

            -- Buffer should now have base lines
            lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            eq(3, #lines)
            eq("base_line", lines[2])
            eq(0, count_extmarks(bufnr, renderer.ns))

            -- Restore
            git.sync_resolved_file = orig_sync
            git.mark_hunk_addressed = orig_mark
            util_mod.check_remaining_files = orig_check
            pcall(os.remove, tmpfile)
        end)
    end)
end)
