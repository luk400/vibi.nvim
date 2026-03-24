--- E2E tests for sequential multi-session merge workflows.
--- Simulates: session 1 already merged into local, then session 2 is reviewed.
--- Uses setup_scenario with user_edits = post-session-1-merge state.
local e2e = require("test.helpers.e2e_helpers")
local renderer = require("vibe.review.renderer")
local types = require("vibe.review.types")

vim.g.mapleader = " "

describe("Sequential multi-session E2E merge", function()
	after_each(function()
		e2e.cleanup()
	end)

	-- ──────────────────────────────────────────────
	-- A: Non-overlapping changes auto-merge cleanly
	-- ──────────────────────────────────────────────
	describe("non-overlapping sequential merge", function()
		it("auto-merges session 1 (user) and session 2 (ai) changes in both mode", function()
			local sc = e2e.setup_scenario({
				name = "seq-non-overlap",
				base_files = { ["app.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
				-- Session 1 changed line 1 (already merged into local)
				user_edits = { ["app.lua"] = "S1 line 1\nline 2\nline 3\nline 4\nline 5" },
				-- Session 2 changed line 5
				ai_edits = { ["app.lua"] = "line 1\nline 2\nline 3\nline 4\nS2 line 5" },
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			local state = e2e.get_state(bufnr)
			assert.are.equal(0, #state.review_items, "No conflicts expected\n" .. e2e.debug_dump(bufnr))
			assert.is_true(#state.auto_items >= 2, "Should have auto items for both changes")

			renderer.finalize_file(bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/app.lua", {
				"S1 line 1", "line 2", "line 3", "line 4", "S2 line 5",
			})
		end)
	end)

	-- ──────────────────────────────────────────────
	-- B: Conflicting edits at same line — keep_user
	-- ──────────────────────────────────────────────
	describe("conflicting sequential merge", function()
		it("detects conflict and keep_user preserves session 1 change", function()
			local sc = e2e.setup_scenario({
				name = "seq-conflict-keep-user",
				base_files = { ["app.lua"] = "line 1\nline 2\nline 3" },
				user_edits = { ["app.lua"] = "line 1\nS1 edit\nline 3" },
				ai_edits = { ["app.lua"] = "line 1\nS2 edit\nline 3" },
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			local state = e2e.get_state(bufnr)
			assert.are.equal(1, #state.review_items, "Should have 1 conflict")
			assert.are.equal(types.CONFLICT, state.review_items[1].classification)

			renderer.resolve_item("keep_user", bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/app.lua", {
				"line 1", "S1 edit", "line 3",
			})
		end)

		it("detects conflict and keep_ai applies session 2 change", function()
			local sc = e2e.setup_scenario({
				name = "seq-conflict-keep-ai",
				base_files = { ["app.lua"] = "line 1\nline 2\nline 3" },
				user_edits = { ["app.lua"] = "line 1\nS1 edit\nline 3" },
				ai_edits = { ["app.lua"] = "line 1\nS2 edit\nline 3" },
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			renderer.resolve_item("keep_ai", bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/app.lua", {
				"line 1", "S2 edit", "line 3",
			})
		end)
	end)

	-- ──────────────────────────────────────────────
	-- C: Mixed — conflict + auto-merged regions
	-- ──────────────────────────────────────────────
	describe("mixed conflict and auto-merge", function()
		it("auto-merges non-overlapping, requires review for conflict", function()
			local sc = e2e.setup_scenario({
				name = "seq-mixed",
				base_files = {
					["app.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8",
				},
				-- Session 1 changed lines 1 and 4
				user_edits = {
					["app.lua"] = "S1 line 1\nline 2\nline 3\nS1 line 4\nline 5\nline 6\nline 7\nline 8",
				},
				-- Session 2 changed lines 4 and 8
				ai_edits = {
					["app.lua"] = "line 1\nline 2\nline 3\nS2 line 4\nline 5\nline 6\nline 7\nS2 line 8",
				},
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			local state = e2e.get_state(bufnr)

			-- Line 1: USER_ONLY (auto), Line 4: CONFLICT (review), Line 8: AI_ONLY (auto)
			assert.are.equal(1, #state.review_items, "Should have 1 conflict at line 4\n" .. e2e.debug_dump(bufnr))
			assert.are.equal(types.CONFLICT, state.review_items[1].classification)
			assert.is_true(#state.auto_items >= 2, "Should auto-merge line 1 and line 8")

			renderer.resolve_item("keep_user", bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/app.lua", {
				"S1 line 1", "line 2", "line 3", "S1 line 4",
				"line 5", "line 6", "line 7", "S2 line 8",
			})
		end)
	end)

	-- ──────────────────────────────────────────────
	-- D: Convergent — both sessions made same change
	-- ──────────────────────────────────────────────
	describe("convergent sequential merge", function()
		it("auto-resolves when both sessions made identical change", function()
			local sc = e2e.setup_scenario({
				name = "seq-convergent",
				base_files = { ["app.lua"] = "line 1\nline 2\nline 3" },
				user_edits = { ["app.lua"] = "line 1\nFIXED line 2\nline 3" },
				ai_edits = { ["app.lua"] = "line 1\nFIXED line 2\nline 3" },
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			local state = e2e.get_state(bufnr)
			assert.are.equal(0, #state.review_items, "Convergent should auto-resolve\n" .. e2e.debug_dump(bufnr))

			renderer.finalize_file(bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/app.lua", {
				"line 1", "FIXED line 2", "line 3",
			})
		end)
	end)

	-- ──────────────────────────────────────────────
	-- E: Multi-file — conflict in one, clean merge in another
	-- ──────────────────────────────────────────────
	describe("multi-file sequential merge", function()
		it("handles conflict in a.lua and clean AI_ONLY in b.lua", function()
			local sc = e2e.setup_scenario({
				name = "seq-multifile",
				base_files = {
					["a.lua"] = "a1\na2\na3",
					["b.lua"] = "b1\nb2\nb3",
				},
				-- Session 1 changed line 1 of a.lua
				user_edits = {
					["a.lua"] = "S1-a1\na2\na3",
				},
				-- Session 2 changed line 1 of a.lua (conflict) and line 2 of b.lua (clean)
				ai_edits = {
					["a.lua"] = "S2-a1\na2\na3",
					["b.lua"] = "b1\nS2-b2\nb3",
				},
			})

			-- Review a.lua first
			local bufnr = e2e.open_review(sc, "a.lua", "both")
			local state = e2e.get_state(bufnr)
			assert.are.equal(1, #state.review_items, "a.lua should have 1 conflict")
			assert.are.equal(types.CONFLICT, state.review_items[1].classification)

			renderer.resolve_item("keep_user", bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/a.lua", {
				"S1-a1", "a2", "a3",
			})

			-- Review b.lua — AI_ONLY should auto-merge in "both" mode
			bufnr = e2e.open_review(sc, "b.lua", "both")
			state = e2e.get_state(bufnr)
			assert.are.equal(0, #state.review_items, "b.lua should have no conflicts")

			renderer.finalize_file(bufnr)
			vim.wait(60, function() return false end)

			e2e.assert_file_contents(sc.info.repo_root .. "/b.lua", {
				"b1", "S2-b2", "b3",
			})
		end)
	end)

	-- ──────────────────────────────────────────────
	-- F: Deletion conflict — session 1 deleted lines, session 2 edited them
	-- ──────────────────────────────────────────────
	describe("deletion conflict in sequential merge", function()
		it("detects del_vs_mod conflict when session 1 deleted lines session 2 edited", function()
			local sc = e2e.setup_scenario({
				name = "seq-del-conflict",
				base_files = { ["app.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5" },
				-- Session 1 deleted lines 2-3
				user_edits = { ["app.lua"] = "line 1\nline 4\nline 5" },
				-- Session 2 modified line 2
				ai_edits = { ["app.lua"] = "line 1\nMODIFIED line 2\nline 3\nline 4\nline 5" },
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			local state = e2e.get_state(bufnr)

			-- Should detect conflict between user's deletion and AI's modification
			local has_conflict = false
			for _, item in ipairs(state.review_items) do
				if item.classification == types.CONFLICT then
					has_conflict = true
					break
				end
			end
			assert.is_true(has_conflict, "Should detect conflict for deleted-then-edited region\n" .. e2e.debug_dump(bufnr))
		end)
	end)

	-- ──────────────────────────────────────────────
	-- G: Realistic code scenario — function rename vs parameter addition
	-- ──────────────────────────────────────────────
	describe("realistic code sequential merge", function()
		it("handles function rename (S1) conflicting with param add (S2), preserving other changes", function()
			local base_code = table.concat({
				"local M = {}",
				"",
				"function M.calculate(a, b)",
				"  return a + b",
				"end",
				"",
				"function M.format(value)",
				"  return tostring(value)",
				"end",
				"",
				"return M",
			}, "\n")

			local s1_merged = table.concat({
				"local M = {}",
				"",
				"function M.sum(x, y)",       -- S1 renamed calculate→sum, a,b→x,y
				"  return x + y",              -- S1 changed body
				"end",
				"",
				"function M.format(value)",
				"  return tostring(value)",
				"end",
				"",
				"return M",
			}, "\n")

			local s2_worktree = table.concat({
				"local M = {}",
				"",
				"function M.calculate(a, b, precision)",  -- S2 added param
				"  return a + b",
				"end",
				"",
				"function M.format(value)",
				"  return string.format('%.2f', value)",  -- S2 also changed format
				"end",
				"",
				"return M",
			}, "\n")

			local sc = e2e.setup_scenario({
				name = "seq-realistic",
				base_files = { ["calc.lua"] = base_code },
				user_edits = { ["calc.lua"] = s1_merged },
				ai_edits = { ["calc.lua"] = s2_worktree },
			})

			local bufnr = e2e.open_review(sc, "calc.lua", "both")
			local state = e2e.get_state(bufnr)

			-- Should have conflict at calculate/sum function (both edited lines 3-4)
			local conflicts = {}
			local other = {}
			for _, item in ipairs(state.review_items) do
				if item.classification == types.CONFLICT then
					table.insert(conflicts, item)
				else
					table.insert(other, item)
				end
			end
			assert.is_true(#conflicts >= 1, "Should have conflict at renamed function\n" .. e2e.debug_dump(bufnr))

			-- The format function change (S2 only) should be auto-merged as AI_ONLY
			assert.is_true(#state.auto_items >= 1, "format() change should be auto-merged")
		end)
	end)

	-- ──────────────────────────────────────────────
	-- H: Session 2 old state doesn't overwrite session 1's merged changes
	-- ──────────────────────────────────────────────
	describe("old state preservation", function()
		it("session 2 base state does not overwrite session 1 merged changes in untouched regions", function()
			local sc = e2e.setup_scenario({
				name = "seq-preserve",
				base_files = {
					["app.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6",
				},
				-- Session 1 changed lines 1, 3, 5 (now in local)
				user_edits = {
					["app.lua"] = "S1-1\nline 2\nS1-3\nline 4\nS1-5\nline 6",
				},
				-- Session 2 only changed line 6 (didn't touch lines 1,3,5)
				ai_edits = {
					["app.lua"] = "line 1\nline 2\nline 3\nline 4\nline 5\nS2-6",
				},
			})

			local bufnr = e2e.open_review(sc, "app.lua", "both")
			local state = e2e.get_state(bufnr)

			-- All of S1's changes should be USER_ONLY (auto-kept)
			-- S2's change at line 6 should be AI_ONLY (auto-merged)
			-- No conflicts!
			assert.are.equal(0, #state.review_items,
				"No conflicts expected — S2 didn't touch S1's regions\n" .. e2e.debug_dump(bufnr))

			renderer.finalize_file(bufnr)
			vim.wait(60, function() return false end)

			-- Critical: S1's changes at lines 1,3,5 must be preserved
			-- S2's change at line 6 must be merged in
			e2e.assert_file_contents(sc.info.repo_root .. "/app.lua", {
				"S1-1", "line 2", "S1-3", "line 4", "S1-5", "S2-6",
			})
		end)
	end)
end)
