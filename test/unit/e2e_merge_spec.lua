--- True end-to-end tests for the VibeReview merge system
--- Exercises the full pipeline: git repo → worktree → AI edits → classification →
--- interactive resolution (with real keypresses) → finalize → verify file on disk
local e2e = require("test.helpers.e2e_helpers")
local renderer = require("vibe.review.renderer")

vim.g.mapleader = " "

describe("E2E merge review", function()
    after_each(function()
        e2e.cleanup()
    end)

    -- ──────────────────────────────────────────────
    -- Group 1: Single-file review-all mode
    -- ──────────────────────────────────────────────

    describe("review-all mode", function()
        it("accepts all AI suggestions", function()
            local sc = e2e.setup_scenario({
                name = "e2e-accept-all",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "AI line 1\nline 2\nline 3\nline 4\nAI line 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            assert.are.equal(2, e2e.count_remaining(bufnr))

            renderer.resolve_item("accept", bufnr)
            vim.wait(60, function() return false end)

            if renderer.buffer_state[bufnr] then
                renderer.resolve_item("accept", bufnr)
                vim.wait(60, function() return false end)
            end

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "AI line 1", "line 2", "line 3", "line 4", "AI line 5",
            })
        end)

        it("accepts some, rejects others", function()
            local sc = e2e.setup_scenario({
                name = "e2e-mixed-resolve",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "AI line 1\nline 2\nAI line 3\nline 4\nAI line 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            assert.are.equal(3, e2e.count_remaining(bufnr))

            renderer.resolve_item("accept", bufnr)
            vim.wait(60, function() return false end)

            if renderer.buffer_state[bufnr] then
                renderer.resolve_item("reject", bufnr)
                vim.wait(60, function() return false end)
            end

            if renderer.buffer_state[bufnr] then
                renderer.resolve_item("accept", bufnr)
                vim.wait(60, function() return false end)
            end

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "AI line 1", "line 2", "line 3", "line 4", "AI line 5",
            })
        end)

        it("rejects all AI suggestions", function()
            local sc = e2e.setup_scenario({
                name = "e2e-reject-all",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "AI line 1\nline 2\nAI line 3\nline 4\nAI line 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            assert.are.equal(3, e2e.count_remaining(bufnr))

            for _ = 1, 3 do
                if not renderer.buffer_state[bufnr] then break end
                renderer.resolve_item("reject", bufnr)
                vim.wait(60, function() return false end)
            end

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "line 3", "line 4", "line 5",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 2: Auto-merge mode
    -- ──────────────────────────────────────────────

    describe("auto-merge mode", function()
        it("auto-merges non-overlapping user+AI changes", function()
            local sc = e2e.setup_scenario({
                name = "e2e-auto-both",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                user_edits = { ["test.lua"] = "USER line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nAI line 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            local state = e2e.get_state(bufnr)
            assert.are.equal(0, #state.review_items, "No review items expected")
            assert.is_true(#state.auto_items >= 2, "Should have at least 2 auto items")

            renderer.finalize_file(bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "USER line 1", "line 2", "line 3", "line 4", "AI line 5",
            })
        end)

        it("auto-merge with conflict requiring resolution", function()
            local sc = e2e.setup_scenario({
                name = "e2e-auto-conflict",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                user_edits = { ["test.lua"] = "line 1\nline 2\nUSER line 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 2\nAI line 3\nline 4\nAI line 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            local state = e2e.get_state(bufnr)
            assert.are.equal(1, #state.review_items, "Should have 1 conflict")
            assert.are.equal("conflict", state.review_items[1].classification)

            renderer.resolve_item("keep_user", bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "USER line 3", "line 4", "AI line 5",
            })
        end)

        it("keep_ai for conflict", function()
            local sc = e2e.setup_scenario({
                name = "e2e-keep-ai",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                user_edits = { ["test.lua"] = "line 1\nline 2\nUSER line 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 2\nAI line 3\nline 4\nAI line 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            renderer.resolve_item("keep_ai", bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "AI line 3", "line 4", "AI line 5",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 3: Mixed regions
    -- ──────────────────────────────────────────────

    describe("mixed regions", function()
        it("handles USER_ONLY, AI_ONLY, and CONFLICT in one file", function()
            local sc = e2e.setup_scenario({
                name = "e2e-mixed",
                base_files = {
                    ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8",
                },
                user_edits = {
                    ["test.lua"] = "USER 1\nline 2\nline 3\nline 4\nline 5\nline 6\nUSER 7\nline 8",
                },
                ai_edits = {
                    ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nAI 5\nline 6\nAI 7\nline 8",
                },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            local state = e2e.get_state(bufnr)
            assert.are.equal(3, #state.review_items, "Should have 3 review items\n" .. e2e.debug_dump(bufnr))

            -- Item 1: USER_ONLY → accept
            renderer.resolve_item("accept", bufnr)
            vim.wait(60, function() return false end)

            -- Item 2: AI_ONLY → reject
            if renderer.buffer_state[bufnr] then
                renderer.resolve_item("reject", bufnr)
                vim.wait(60, function() return false end)
            end

            -- Item 3: CONFLICT → keep_user
            if renderer.buffer_state[bufnr] then
                renderer.resolve_item("keep_user", bufnr)
                vim.wait(60, function() return false end)
            end

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "USER 1", "line 2", "line 3", "line 4", "line 5", "line 6", "USER 7", "line 8",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 4: Keypress simulation (feedkeys)
    -- ──────────────────────────────────────────────

    describe("keypress simulation", function()
        it("leader-a accepts AI suggestion via feedkeys", function()
            local sc = e2e.setup_scenario({
                name = "e2e-feedkeys-accept",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3" },
                ai_edits = { ["test.lua"] = "AI line 1\nline 2\nline 3" },
            })

            e2e.open_review(sc, "test.lua", "none")
            e2e.feed("<leader>a")
            vim.wait(100, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "AI line 1", "line 2", "line 3",
            })
        end)

        it("leader-r rejects AI suggestion via feedkeys", function()
            local sc = e2e.setup_scenario({
                name = "e2e-feedkeys-reject",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3" },
                ai_edits = { ["test.lua"] = "AI line 1\nline 2\nline 3" },
            })

            e2e.open_review(sc, "test.lua", "none")
            e2e.feed("<leader>r")
            vim.wait(100, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "line 3",
            })
        end)

        it("leader-k keeps user version for conflict via feedkeys", function()
            local sc = e2e.setup_scenario({
                name = "e2e-feedkeys-keep",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3" },
                user_edits = { ["test.lua"] = "USER line 1\nline 2\nline 3" },
                ai_edits = { ["test.lua"] = "AI line 1\nline 2\nline 3" },
            })

            e2e.open_review(sc, "test.lua", "both")
            e2e.feed("<leader>k")
            vim.wait(100, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "USER line 1", "line 2", "line 3",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 5: Navigation
    -- ──────────────────────────────────────────────

    describe("navigation", function()
        it("navigates between review items", function()
            local sc = e2e.setup_scenario({
                name = "e2e-nav",
                base_files = {
                    ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7",
                },
                ai_edits = {
                    ["test.lua"] = "AI 1\nline 2\nline 3\nAI 4\nline 5\nline 6\nAI 7",
                },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            assert.are.equal(3, e2e.count_remaining(bufnr))

            local pos1 = vim.api.nvim_win_get_cursor(0)[1]

            renderer.next_item(bufnr)
            local pos2 = vim.api.nvim_win_get_cursor(0)[1]
            assert.is_true(pos2 > pos1, "Next should move cursor forward")

            renderer.next_item(bufnr)
            local pos3 = vim.api.nvim_win_get_cursor(0)[1]
            assert.is_true(pos3 > pos2, "Next should move cursor further forward")

            renderer.prev_item(bufnr)
            local pos4 = vim.api.nvim_win_get_cursor(0)[1]
            assert.are.equal(pos2, pos4, "Prev should go back to second item")

            renderer.next_item(bufnr)
            renderer.next_item(bufnr)
            local pos5 = vim.api.nvim_win_get_cursor(0)[1]
            assert.are.equal(pos1, pos5, "Should wrap to first item")

            renderer.buffer_state[bufnr] = nil
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 6: Deletion handling
    -- ──────────────────────────────────────────────

    describe("deletion handling", function()
        it("accepting AI deletion removes lines from file", function()
            local sc = e2e.setup_scenario({
                name = "e2e-del-accept",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 4\nline 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            assert.are.equal(1, e2e.count_remaining(bufnr))

            renderer.resolve_item("accept", bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 4", "line 5",
            })
        end)

        it("rejecting AI deletion restores original lines", function()
            local sc = e2e.setup_scenario({
                name = "e2e-del-reject",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 4\nline 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "none")
            assert.are.equal(1, e2e.count_remaining(bufnr))

            renderer.resolve_item("reject", bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "line 3", "line 4", "line 5",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 7: Auto-merge deletion recovery
    -- ──────────────────────────────────────────────

    describe("auto-merge deletion", function()
        it("recovers auto-deleted lines", function()
            local sc = e2e.setup_scenario({
                name = "e2e-auto-del-recover",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 4\nline 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            local state = e2e.get_state(bufnr)
            assert.are.equal(0, #state.review_items, "No review items in auto-merge")

            local sentinel_idx = nil
            for i, aic in pairs(state.auto_item_contents) do
                if aic.is_sentinel then
                    sentinel_idx = i
                    break
                end
            end
            assert.is_not_nil(sentinel_idx, "Should have a deletion sentinel")

            renderer.recover_auto_deletion(bufnr, sentinel_idx)
            vim.wait(60, function() return false end)

            renderer.finalize_file(bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "line 3", "line 4", "line 5",
            })
        end)

        it("dismiss auto-deletion removes sentinel", function()
            local sc = e2e.setup_scenario({
                name = "e2e-auto-del-dismiss",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 4\nline 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            local state = e2e.get_state(bufnr)

            local sentinel_idx = nil
            for i, aic in pairs(state.auto_item_contents) do
                if aic.is_sentinel then
                    sentinel_idx = i
                    break
                end
            end
            assert.is_not_nil(sentinel_idx, "Should have a deletion sentinel")

            renderer.dismiss_auto_deletion(bufnr, sentinel_idx)
            vim.wait(60, function() return false end)

            renderer.finalize_file(bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 4", "line 5",
            })
        end)

        it("uninteracted sentinels are cleaned on finalize", function()
            local sc = e2e.setup_scenario({
                name = "e2e-auto-del-finalize",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 4\nline 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            renderer.finalize_file(bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 4", "line 5",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 8: Multi-file review (through real dialog)
    -- ──────────────────────────────────────────────

    describe("multi-file review", function()
        it("resolves two files sequentially via dialog", function()
            local sc = e2e.setup_scenario({
                name = "e2e-multi",
                base_files = {
                    ["a.lua"] = "a line 1\na line 2\na line 3",
                    ["b.lua"] = "b line 1\nb line 2\nb line 3",
                },
                ai_edits = {
                    ["a.lua"] = "AI a1\na line 2\na line 3",
                    ["b.lua"] = "b line 1\nAI b2\nb line 3",
                },
            })

            local bufnr = e2e.open_review(sc, "a.lua", "none")
            assert.are.equal(1, e2e.count_remaining(bufnr))

            renderer.resolve_item("accept", bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/a.lua", {
                "AI a1", "a line 2", "a line 3",
            })

            local dialog_opened = e2e.wait_for_dialog(1000)
            assert.is_true(dialog_opened, "Dialog should open with remaining file b.lua")

            e2e.feed("<CR>")
            vim.wait(100, function() return false end)

            -- Find the new review buffer for b.lua
            bufnr = vim.api.nvim_get_current_buf()
            if renderer.buffer_state[bufnr] then
                renderer.resolve_item("accept", bufnr)
                vim.wait(60, function() return false end)
            end

            e2e.assert_file_contents(sc.info.repo_root .. "/b.lua", {
                "b line 1", "AI b2", "b line 3",
            })
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 9: Auto-merge revert
    -- ──────────────────────────────────────────────

    describe("auto-merge revert", function()
        it("reverts auto-merged modification", function()
            local sc = e2e.setup_scenario({
                name = "e2e-auto-revert",
                base_files = { ["test.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
                ai_edits = { ["test.lua"] = "line 1\nline 2\nAI line 3\nline 4\nline 5" },
            })

            local bufnr = e2e.open_review(sc, "test.lua", "both")
            local state = e2e.get_state(bufnr)
            assert.are.equal(0, #state.review_items, "No review items in auto-merge")

            local mod_idx = nil
            for i, aic in pairs(state.auto_item_contents) do
                if not aic.is_sentinel then
                    mod_idx = i
                    break
                end
            end
            assert.is_not_nil(mod_idx, "Should have a modification auto item")

            renderer.reject_auto_item(bufnr, mod_idx)
            vim.wait(60, function() return false end)

            renderer.finalize_file(bufnr)
            vim.wait(60, function() return false end)

            e2e.assert_file_contents(sc.info.repo_root .. "/test.lua", {
                "line 1", "line 2", "line 3", "line 4", "line 5",
            })
        end)
    end)
end)
