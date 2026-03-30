-- test/unit/merge_accept_spec.lua
-- Tests for 3-way merge accept: ensures multi-session merges preserve changes from all sessions
local git = require("vibe.git")
local apply = require("vibe.git.apply")
local merge = require("vibe.review.merge")
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Merge accept", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		helpers.cleanup_all()
	end)

	-- Helper: create a repo, two worktrees, modify files in each
	local function setup_two_sessions(name, original_content, ai_a_content, ai_b_content)
		local repo_path = helpers.create_test_repo(name, {
			["shared.txt"] = original_content,
		})

		local info_a = git.create_worktree("sess-A", repo_path)
		assert.is_not_nil(info_a)

		local info_b = git.create_worktree("sess-B", repo_path)
		assert.is_not_nil(info_b)

		helpers.write_file(info_a.worktree_path .. "/shared.txt", ai_a_content)
		helpers.write_file(info_b.worktree_path .. "/shared.txt", ai_b_content)

		local user_file = repo_path .. "/shared.txt"
		return info_a, info_b, user_file, repo_path
	end

	describe("multi-session regression", function()
		it("merge_accept preserves session 1 changes when merging session 2", function()
			-- Original: lines 1-5
			-- Session A: modifies line 2
			-- Session B: modifies line 4
			local original = "line 1\nline 2\nline 3\nline 4\nline 5"
			local ai_a = "line 1\nA modified 2\nline 3\nline 4\nline 5"
			local ai_b = "line 1\nline 2\nline 3\nB modified 4\nline 5"

			local info_a, info_b, user_file = setup_two_sessions("merge-regression", original, ai_a, ai_b)

			-- Step 1: Accept session A (raw copy - simulates current behavior)
			git.accept_file_from_worktree(info_a.worktree_path, "shared.txt")
			local after_a = vim.fn.readfile(user_file)
			eq("A modified 2", after_a[2])
			eq("line 4", after_a[4])

			-- Step 2: Merge-accept session B (should preserve A's changes)
			local ok, err = git.merge_accept_file(info_b.worktree_path, "shared.txt", "both")
			assert.is_truthy(ok, "merge_accept_file should succeed: " .. (err or ""))

			local result = vim.fn.readfile(user_file)
			eq(5, #result)
			eq("line 1", result[1])
			eq("A modified 2", result[2]) -- Session A's change preserved
			eq("line 3", result[3])
			eq("B modified 4", result[4]) -- Session B's change applied
			eq("line 5", result[5])
		end)

		it("merge_accept_all preserves session 1 changes across all files", function()
			local repo_path = helpers.create_test_repo("merge-all-regression", {
				["file1.txt"] = "original 1\nline 2",
				["file2.txt"] = "original A\nline B",
			})

			local info_a = git.create_worktree("all-A", repo_path)
			local info_b = git.create_worktree("all-B", repo_path)

			-- Session A modifies file1
			helpers.write_file(info_a.worktree_path .. "/file1.txt", "A changed 1\nline 2")
			-- Session B modifies file2
			helpers.write_file(info_b.worktree_path .. "/file2.txt", "original A\nB changed B")

			-- Accept session A (raw copy)
			git.accept_file_from_worktree(info_a.worktree_path, "file1.txt")

			-- Merge-accept session B
			local result = git.merge_accept_all(info_b.worktree_path, "both")
			assert.is_truthy(result.all_ok)

			-- Verify session A's changes to file1 are preserved
			local f1 = vim.fn.readfile(repo_path .. "/file1.txt")
			eq("A changed 1", f1[1])

			-- Verify session B's changes to file2 are applied
			local f2 = vim.fn.readfile(repo_path .. "/file2.txt")
			eq("B changed B", f2[2])
		end)
	end)

	describe("merge_accept_file", function()
		it("detects conflicts and returns error", function()
			-- Both sessions modify the same line
			local original = "line 1\nline 2\nline 3"
			local ai_a = "line 1\nA changed\nline 3"
			local ai_b = "line 1\nB changed\nline 3"

			local info_a, info_b, user_file = setup_two_sessions("conflict-detect", original, ai_a, ai_b)

			-- Accept session A first
			git.accept_file_from_worktree(info_a.worktree_path, "shared.txt")

			-- Merge session B should detect conflict
			local ok, err, conflict_count = git.merge_accept_file(info_b.worktree_path, "shared.txt", "both")
			assert.is_falsy(ok)
			eq("conflicts", err)
			assert.is_true(conflict_count > 0)

			-- User file should be unchanged (still has A's version)
			local result = vim.fn.readfile(user_file)
			eq("A changed", result[2])
		end)

		it("handles AI deletion correctly", function()
			-- Session B deletes line 2
			local original = "line 1\nline 2\nline 3"
			local ai_b = "line 1\nline 3"

			local repo_path = helpers.create_test_repo("deletion", {
				["test.txt"] = original,
			})
			local info_b = git.create_worktree("del-B", repo_path)
			helpers.write_file(info_b.worktree_path .. "/test.txt", ai_b)

			local ok, err = git.merge_accept_file(info_b.worktree_path, "test.txt", "both")
			assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

			local result = vim.fn.readfile(repo_path .. "/test.txt")
			eq(2, #result)
			eq("line 1", result[1])
			eq("line 3", result[2])
		end)

		it("handles new AI file correctly", function()
			local repo_path = helpers.create_test_repo("new-file", {
				["existing.txt"] = "exists",
			})
			local info = git.create_worktree("new-ai", repo_path)
			helpers.write_file(info.worktree_path .. "/brand_new.txt", "new content\nline 2")

			local ok, err = git.merge_accept_file(info.worktree_path, "brand_new.txt", "both")
			assert.is_truthy(ok, "merge should succeed for new file: " .. (err or ""))

			local result = vim.fn.readfile(repo_path .. "/brand_new.txt")
			eq("new content", result[1])
			eq("line 2", result[2])
		end)
	end)

	describe("merge_accept_all", function()
		it("partial success: merges safe files, skips conflicting ones", function()
			local repo_path = helpers.create_test_repo("partial", {
				["safe.txt"] = "original safe",
				["conflict.txt"] = "original conflict",
			})

			local info_a = git.create_worktree("part-A", repo_path)
			local info_b = git.create_worktree("part-B", repo_path)

			-- Session A modifies both files
			helpers.write_file(info_a.worktree_path .. "/safe.txt", "A safe change")
			helpers.write_file(info_a.worktree_path .. "/conflict.txt", "A conflict change")

			-- Session B modifies conflict.txt at same line, safe.txt at different content
			helpers.write_file(info_b.worktree_path .. "/conflict.txt", "B conflict change")

			-- Accept session A
			git.accept_file_from_worktree(info_a.worktree_path, "safe.txt")
			git.accept_file_from_worktree(info_a.worktree_path, "conflict.txt")

			-- Merge session B
			local result = git.merge_accept_all(info_b.worktree_path, "both")
			assert.is_falsy(result.all_ok)
			assert.is_true(#result.skipped > 0, "Should have skipped files with conflicts")

			-- conflict.txt should still have A's version (not overwritten)
			local conflict_content = vim.fn.readfile(repo_path .. "/conflict.txt")
			eq("A conflict change", conflict_content[1])
		end)
	end)

	describe("build_resolved_content", function()
		it("returns snapshot copy when no regions", function()
			local snapshot = { "line 1", "line 2", "line 3" }
			local result = merge.build_resolved_content(snapshot, {})
			eq(3, #result)
			eq("line 1", result[1])
			eq("line 2", result[2])
			eq("line 3", result[3])
		end)

		it("applies AI_ONLY auto-resolved region", function()
			local base = { "line 1", "line 2", "line 3" }
			local regions = { {
				classification = types.AI_ONLY,
				auto_resolved = true,
				base_range = { 2, 2 },
				base_lines = { "line 2" },
				user_lines = { "line 2" },
				ai_lines = { "AI changed 2" },
			} }

			local result = merge.build_resolved_content(base, regions)
			eq(3, #result)
			eq("line 1", result[1])
			eq("AI changed 2", result[2])
			eq("line 3", result[3])
		end)

		it("keeps user_lines for USER_ONLY auto-resolved region", function()
			local base = { "line 1", "line 2", "line 3" }
			local regions = { {
				classification = types.USER_ONLY,
				auto_resolved = true,
				base_range = { 2, 2 },
				base_lines = { "line 2" },
				user_lines = { "user changed 2" },
				ai_lines = { "line 2" },
			} }

			local result = merge.build_resolved_content(base, regions)
			eq(3, #result)
			eq("user changed 2", result[2])
		end)

		it("keeps user_lines for non-auto-resolved CONFLICT region", function()
			local base = { "line 1", "line 2", "line 3" }
			local regions = { {
				classification = types.CONFLICT,
				auto_resolved = false,
				base_range = { 2, 2 },
				base_lines = { "line 2" },
				user_lines = { "user version" },
				ai_lines = { "ai version" },
			} }

			local result = merge.build_resolved_content(base, regions)
			eq(3, #result)
			eq("user version", result[2])
		end)

		it("handles deletion (empty replacement)", function()
			local base = { "line 1", "line 2", "line 3" }
			local regions = { {
				classification = types.AI_ONLY,
				auto_resolved = true,
				base_range = { 2, 2 },
				base_lines = { "line 2" },
				user_lines = { "line 2" },
				ai_lines = {},
			} }

			local result = merge.build_resolved_content(base, regions)
			eq(2, #result)
			eq("line 1", result[1])
			eq("line 3", result[2])
		end)

		it("handles pure insertion (empty base_lines)", function()
			local base = { "line 1", "line 2" }
			local regions = { {
				classification = types.AI_ONLY,
				auto_resolved = true,
				base_range = { 1, 1 },
				base_lines = {},
				user_lines = {},
				ai_lines = { "inserted line" },
			} }

			local result = merge.build_resolved_content(base, regions)
			eq(3, #result)
			eq("line 1", result[1])
			eq("inserted line", result[2])
			eq("line 2", result[3])
		end)

		it("handles mixed auto and non-auto regions", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local regions = {
				{
					classification = types.USER_ONLY,
					auto_resolved = true,
					base_range = { 2, 2 },
					base_lines = { "line 2" },
					user_lines = { "user changed 2" },
					ai_lines = { "line 2" },
				},
				{
					classification = types.AI_ONLY,
					auto_resolved = true,
					base_range = { 4, 4 },
					base_lines = { "line 4" },
					user_lines = { "line 4" },
					ai_lines = { "ai changed 4" },
				},
			}

			local result = merge.build_resolved_content(base, regions)
			eq(5, #result)
			eq("line 1", result[1])
			eq("user changed 2", result[2]) -- USER_ONLY preserved
			eq("line 3", result[3])
			eq("ai changed 4", result[4]) -- AI_ONLY applied
			eq("line 5", result[5])
		end)
	end)
end)
