-- test/unit/conflict_buffer_spec.lua
local conflict_buffer = require("vibe.conflict_buffer")
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true
local is_false = assert.is_false

local function contains(str, pattern)
	return str:find(pattern, 1, true) ~= nil or str:find(pattern) ~= nil
end

describe("Conflict Buffer & Merging", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	local original_content = "line 1\nline 2\nline 3\n"

	it("auto-merges clean additions smoothly in 'auto' review mode", function()
		local repo = helpers.create_test_repo("merge-clean", { ["test.txt"] = original_content })
		local info = git.create_worktree("clean-sess", repo)

		-- AI modifies the END of the file
		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nline 2\nline 3\nline 4 (AI)\n")
		-- User modifies the START of the file
		helpers.write_file(repo .. "/test.txt", "line 1 (User)\nline 2\nline 3\n")

		local user_lines = vim.fn.readfile(repo .. "/test.txt")

		local lines, conflicts, auto_merged =
			conflict_buffer.insert_conflict_markers(user_lines, info.worktree_path, "test.txt", info.name, "auto")

		-- Since changes do not overlap, there should be NO conflicts
		eq(0, #conflicts, "Changes are distinct, should auto-merge safely")
		eq(1, #auto_merged, "Should track the clean AI addition")

		local result_str = table.concat(lines, "\n")
		is_true(contains(result_str, "line 1 %(User%)"))
		is_true(contains(result_str, "line 4 %(AI%)"))
	end)

	it("generates strict git conflict markers for overlapping edits", function()
		local repo = helpers.create_test_repo("merge-conflict", { ["test.txt"] = original_content })
		local info = git.create_worktree("conflict-sess", repo)

		-- AI edits line 2
		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nline 2 edited by AI\nline 3\n")
		-- User edits line 2
		helpers.write_file(repo .. "/test.txt", "line 1\nline 2 edited by User\nline 3\n")

		local user_lines = vim.fn.readfile(repo .. "/test.txt")

		local lines, conflicts, _ =
			conflict_buffer.insert_conflict_markers(user_lines, info.worktree_path, "test.txt", info.name, "auto")

		eq(1, #conflicts, "Should detect 1 overlapping conflict")
		local result_str = table.concat(lines, "\n")

		is_true(contains(result_str, "<<<<<<< HEAD"))
		is_true(contains(result_str, "line 2 edited by User"))
		is_true(contains(result_str, "======="))
		is_true(contains(result_str, "line 2 edited by AI"))
		is_true(contains(result_str, ">>>>>>> vibe%-conflict%-sess"))
	end)

	it("resolves a conflict buffer state successfully keeping ours", function()
		local repo = helpers.create_test_repo("merge-resolve", { ["test.txt"] = original_content })
		local info = git.create_worktree("resolve-sess", repo)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nAI\nline 3\n")
		helpers.write_file(repo .. "/test.txt", "line 1\nUSER\nline 3\n")

		-- Load up the file into the plugin's conflict buffer state
		conflict_buffer.show_file_with_conflicts(info.worktree_path, "test.txt", nil, "auto")
		local bufnr = vim.api.nvim_get_current_buf()

		-- Buffer is initialized, cursor is at conflict. Resolve using "ours" (USER)
		conflict_buffer.keep_ours()

		local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local result_str = table.concat(final_lines, "\n")

		is_false(contains(result_str, "<<<<<<< HEAD"))
		is_false(contains(result_str, "AI"))
		is_true(contains(result_str, "USER"), "User string should be preserved")
	end)
end)
