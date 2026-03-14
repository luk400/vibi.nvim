-- test/unit/hunk_application_spec.lua
local apply = require("vibe.git.apply")
local eq = assert.are.equal

-- Helper to create a mock worktrees table with a file
local function mock_worktrees(worktree_path, repo_root, file_content)
	local worktrees = {}
	worktrees[worktree_path] = {
		name = "test",
		worktree_path = worktree_path,
		repo_root = repo_root,
		addressed_hunks = {},
	}
	return worktrees
end

describe("Hunk Application", function()
	local test_dir, worktree_path, repo_root

	before_each(function()
		test_dir = vim.fn.tempname() .. "-hunk-test"
		repo_root = test_dir .. "/repo"
		worktree_path = test_dir .. "/worktree"
		vim.fn.mkdir(repo_root, "p")
		vim.fn.mkdir(worktree_path, "p")
	end)

	after_each(function()
		vim.fn.delete(test_dir, "rf")
	end)

	describe("accept_hunk_from_worktree", function()
		it("adds lines at line 0 without wiping existing content", function()
			-- Write a user file with existing content
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "existing line 1", "existing line 2" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "add",
				old_start = 0,
				old_count = 0,
				new_start = 1,
				new_count = 2,
				added_lines = { "new line A", "new line B" },
				removed_lines = {},
				user_added_indices = {},
			}

			local ok, err = apply.accept_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			-- New lines should be prepended, existing lines preserved
			eq(4, #lines)
			eq("new line A", lines[1])
			eq("new line B", lines[2])
			eq("existing line 1", lines[3])
			eq("existing line 2", lines[4])
		end)

		it("inserts lines at a specific position", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "line 1", "line 2", "line 3" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "add",
				old_start = 2,
				old_count = 0,
				new_start = 3,
				new_count = 1,
				added_lines = { "inserted line" },
				removed_lines = {},
				user_added_indices = {},
			}

			local ok = apply.accept_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(4, #lines)
			eq("line 1", lines[1])
			eq("line 2", lines[2])
			eq("inserted line", lines[3])
			eq("line 3", lines[4])
		end)

		it("skips hunk when all removed lines are user-added", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "user line 1", "user line 2" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "change",
				old_start = 1,
				old_count = 2,
				new_start = 1,
				new_count = 0,
				added_lines = {},
				removed_lines = { "user line 1", "user line 2" },
				user_added_indices = { 1, 2 },
			}

			local ok = apply.accept_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			-- Lines should be preserved (skipped)
			local lines = vim.fn.readfile(user_file)
			eq(2, #lines)
			eq("user line 1", lines[1])
			eq("user line 2", lines[2])
		end)

		it("handles nil user_added_indices gracefully", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "line 1" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "change",
				old_start = 1,
				old_count = 1,
				new_start = 1,
				new_count = 1,
				added_lines = { "replaced line" },
				removed_lines = { "line 1" },
				-- Intentionally omit user_added_indices to test nil safety
			}

			local ok = apply.accept_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(1, #lines)
			eq("replaced line", lines[1])
		end)

		it("deletes lines while preserving user-added ones", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "keep me", "delete me", "also keep" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "delete",
				old_start = 1,
				old_count = 3,
				new_start = 1,
				new_count = 0,
				added_lines = {},
				removed_lines = { "keep me", "delete me", "also keep" },
				user_added_indices = { 1, 3 }, -- Lines 1 and 3 are user-added
			}

			local ok = apply.accept_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(2, #lines)
			eq("keep me", lines[1])
			eq("also keep", lines[2])
		end)

		it("handles change with mixed user and AI lines", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "old line 1", "user added", "old line 3" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "change",
				old_start = 1,
				old_count = 3,
				new_start = 1,
				new_count = 2,
				added_lines = { "new line A", "new line B" },
				removed_lines = { "old line 1", "user added", "old line 3" },
				user_added_indices = { 2 }, -- Line 2 is user-added
			}

			local ok = apply.accept_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			-- Should remove non-user lines, keep user-added, and add new lines
			eq(3, #lines)
			eq("new line A", lines[1])
			eq("new line B", lines[2])
			eq("user added", lines[3])
		end)
	end)

	describe("reject_hunk_from_worktree", function()
		it("removes user-added lines on reject", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "original", "user addition", "more original" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "change",
				old_start = 1,
				old_count = 3,
				new_start = 1,
				new_count = 1,
				added_lines = { "ai change" },
				removed_lines = { "original", "user addition", "more original" },
				user_added_indices = { 2 },
			}

			local ok = apply.reject_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(2, #lines)
			eq("original", lines[1])
			eq("more original", lines[2])
		end)

		it("does nothing when no user-added lines", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "line 1", "line 2" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "change",
				old_start = 1,
				old_count = 2,
				new_start = 1,
				new_count = 2,
				added_lines = { "ai 1", "ai 2" },
				removed_lines = { "line 1", "line 2" },
				user_added_indices = {},
			}

			local ok = apply.reject_hunk_from_worktree(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(2, #lines)
			eq("line 1", lines[1])
			eq("line 2", lines[2])
		end)
	end)

	describe("keep_both_hunk", function()
		it("prepends at line 0 without wiping existing content", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "existing" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				type = "add",
				old_start = 0,
				old_count = 0,
				new_start = 1,
				new_count = 1,
				added_lines = { "new line" },
				removed_lines = {},
				user_added_indices = {},
			}

			local ok = apply.keep_both_hunk(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(2, #lines)
			eq("new line", lines[1])
			eq("existing", lines[2])
		end)
	end)

	describe("delete_hunk_range", function()
		it("deletes lines within range", function()
			local user_file = repo_root .. "/test.txt"
			vim.fn.writefile({ "keep", "delete1", "delete2", "also keep" }, user_file)

			local worktrees = mock_worktrees(worktree_path, repo_root)
			local hunk = {
				old_start = 2,
				old_count = 2,
				removed_lines = { "delete1", "delete2" },
			}

			local ok = apply.delete_hunk_range(worktrees, worktree_path, "test.txt", hunk, user_file)
			assert.is_true(ok)

			local lines = vim.fn.readfile(user_file)
			eq(2, #lines)
			eq("keep", lines[1])
			eq("also keep", lines[2])
		end)
	end)
end)
