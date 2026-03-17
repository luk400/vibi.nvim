local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Hunk parsing", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("parses single addition hunk", function()
		local repo_path = helpers.create_test_repo("parse-add", {
			["test.txt"] = "line 1\nline 2\nline 3",
		})
		local info = git.create_worktree("parse-add-sess", repo_path)
		assert.is_not_nil(info)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nline 2\nnew line\nline 3")

		local user_file = info.repo_root .. "/test.txt"
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)

		eq(1, #hunks, "Should have exactly 1 hunk")
		eq("add", hunks[1].type, "Hunk type should be 'add'")
		eq(1, #hunks[1].added_lines, "Should have 1 added line")
		eq("new line", hunks[1].added_lines[1])
	end)

	it("parses single deletion hunk", function()
		local repo_path = helpers.create_test_repo("parse-del", {
			["test.txt"] = "line 1\nline 2\nline 3",
		})
		local info = git.create_worktree("parse-del-sess", repo_path)
		assert.is_not_nil(info)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nline 3")

		local user_file = info.repo_root .. "/test.txt"
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)

		eq(1, #hunks, "Should have exactly 1 hunk")
		eq("delete", hunks[1].type, "Hunk type should be 'delete'")
		eq(1, #hunks[1].removed_lines, "Should have 1 removed line")
		eq("line 2", hunks[1].removed_lines[1])
	end)

	it("parses single change hunk", function()
		local repo_path = helpers.create_test_repo("parse-change", {
			["test.txt"] = "line 1\nline 2\nline 3",
		})
		local info = git.create_worktree("parse-change-sess", repo_path)
		assert.is_not_nil(info)

		helpers.write_file(info.worktree_path .. "/test.txt", "line 1\nmodified line 2\nline 3")

		local user_file = info.repo_root .. "/test.txt"
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)

		eq(1, #hunks, "Should have exactly 1 hunk")
		eq("change", hunks[1].type, "Hunk type should be 'change'")
		eq(1, #hunks[1].removed_lines)
		eq("line 2", hunks[1].removed_lines[1])
		eq(1, #hunks[1].added_lines)
		eq("modified line 2", hunks[1].added_lines[1])
	end)

	it("parses multiple hunks in one file", function()
		local repo_path = helpers.create_test_repo("parse-multi", {
			["test.txt"] = "line 1\nline 2\nline 3\nline 4\nline 5",
		})
		local info = git.create_worktree("parse-multi-sess", repo_path)
		assert.is_not_nil(info)

		helpers.write_file(info.worktree_path .. "/test.txt", "changed 1\nline 2\nline 3\nline 4\nchanged 5")

		local user_file = info.repo_root .. "/test.txt"
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)

		assert.is_true(#hunks >= 2, "Should have at least 2 hunks for changes at lines 1 and 5")
	end)

	it("returns empty for identical files", function()
		local repo_path = helpers.create_test_repo("parse-same", {
			["test.txt"] = "line 1\nline 2\nline 3",
		})
		local info = git.create_worktree("parse-same-sess", repo_path)
		assert.is_not_nil(info)

		-- Don't modify the worktree file
		local user_file = info.repo_root .. "/test.txt"
		local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)

		eq(0, #hunks, "Identical files should produce no hunks")
	end)
end)
