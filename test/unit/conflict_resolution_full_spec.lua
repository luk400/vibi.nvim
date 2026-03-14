local conflict_buffer = require("vibe.conflict_buffer")
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true
local is_false = assert.is_false

local function contains(str, pattern)
	return str:find(pattern, 1, true) ~= nil or str:find(pattern) ~= nil
end

describe("Conflict resolution full coverage", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	local original_content = "line 1\nline 2\nline 3\n"

	it("keep_theirs resolves with AI version", function()
		local repo = helpers.create_test_repo("resolve-theirs", { ["test.txt"] = original_content })
		local info = git.create_worktree("theirs-sess", repo)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nAI\nline 3\n")
		helpers.write_file(repo .. "/test.txt", "line 1\nUSER\nline 3\n")

		conflict_buffer.show_file_with_conflicts(info.worktree_path, "test.txt", nil, "auto")
		local bufnr = vim.api.nvim_get_current_buf()

		conflict_buffer.keep_theirs()

		local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local result_str = table.concat(final_lines, "\n")

		is_false(contains(result_str, "<<<<<<< HEAD"))
		is_true(contains(result_str, "AI"), "AI version should be present after keep_theirs")
		is_false(contains(result_str, "USER"), "USER version should be removed after keep_theirs")
	end)

	it("keep_both preserves both versions", function()
		local repo = helpers.create_test_repo("resolve-both", { ["test.txt"] = original_content })
		local info = git.create_worktree("both-sess", repo)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nAI\nline 3\n")
		helpers.write_file(repo .. "/test.txt", "line 1\nUSER\nline 3\n")

		conflict_buffer.show_file_with_conflicts(info.worktree_path, "test.txt", nil, "auto")
		local bufnr = vim.api.nvim_get_current_buf()

		conflict_buffer.keep_both()

		local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local result_str = table.concat(final_lines, "\n")

		is_false(contains(result_str, "<<<<<<< HEAD"))
		is_true(contains(result_str, "USER"), "USER version should be present after keep_both")
		is_true(contains(result_str, "AI"), "AI version should be present after keep_both")
	end)

	it("keep_none removes both versions", function()
		local repo = helpers.create_test_repo("resolve-none", { ["test.txt"] = original_content })
		local info = git.create_worktree("none-sess", repo)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nAI\nline 3\n")
		helpers.write_file(repo .. "/test.txt", "line 1\nUSER\nline 3\n")

		conflict_buffer.show_file_with_conflicts(info.worktree_path, "test.txt", nil, "auto")
		local bufnr = vim.api.nvim_get_current_buf()

		conflict_buffer.keep_none()

		local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local result_str = table.concat(final_lines, "\n")

		is_false(contains(result_str, "<<<<<<< HEAD"))
		is_false(contains(result_str, "USER"), "USER version should be removed after keep_none")
		is_false(contains(result_str, "AI"), "AI version should be removed after keep_none")
	end)

	it("mixed: 1 auto-merged + 1 conflict", function()
		local repo = helpers.create_test_repo("resolve-mixed", { ["test.txt"] = original_content })
		local info = git.create_worktree("mixed-sess", repo)

		-- AI edits line 2 AND adds line 4 at end
		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nAI line 2\nline 3\nAI line 4\n")
		-- User edits line 2 (conflict) but doesn't touch line 4 area
		helpers.write_file(repo .. "/test.txt", "line 1\nUSER line 2\nline 3\n")

		local user_lines = vim.fn.readfile(repo .. "/test.txt")
		local lines, conflicts, auto_merged =
			conflict_buffer.insert_conflict_markers(user_lines, info.worktree_path, "test.txt", info.name, "auto")

		-- Should have 1 conflict (overlapping edit on line 2)
		eq(1, #conflicts, "Should have 1 conflict for overlapping edit")
		-- Should have 1 auto-merged region (AI line 4 addition)
		assert.is_true(#auto_merged >= 1, "Should have at least 1 auto-merged region")

		local result_str = table.concat(lines, "\n")
		is_true(contains(result_str, "AI line 4"), "Auto-merged AI addition should be present")
		is_true(contains(result_str, "<<<<<<< HEAD"), "Conflict markers should be present")
	end)
end)
