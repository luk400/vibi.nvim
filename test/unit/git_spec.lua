-- test/unit/git_spec.lua
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true

describe("Git Worktree Management", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("creates a worktree correctly from a base repo", function()
		local repo_path = helpers.create_test_repo("git-core", {
			["app.js"] = "console.log('hello');",
		})

		local info, err = git.create_worktree("test-sess", repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)
		eq("test-sess", info.name)
		eq(repo_path, info.repo_root)
		is_true(vim.fn.isdirectory(info.worktree_path) == 1, "Worktree directory should exist")

		-- Verify the file exists in the worktree
		is_true(vim.fn.filereadable(info.worktree_path .. "/app.js") == 1, "File should be copied to worktree")
	end)

	it("detects unresolved changes when AI modifies the worktree", function()
		local repo_path = helpers.create_test_repo("git-changes", {
			["app.js"] = "console.log('hello');",
		})

		local info = git.create_worktree("change-sess", repo_path)

		-- AI modifies the file in the worktree
		helpers.write_file(info.worktree_path .. "/app.js", "console.log('hello world');")

		local changed_files = git.get_worktree_changed_files(info.worktree_path)
		eq(1, #changed_files)
		eq("app.js", changed_files[1])

		local unresolved = git.get_unresolved_files(info.worktree_path)
		eq(1, #unresolved)
	end)

	it("considers file resolved when user syncs it", function()
		local repo_path = helpers.create_test_repo("git-resolve", {
			["app.js"] = "console.log('hello');",
		})

		local info = git.create_worktree("resolve-sess", repo_path)

		-- AI changes worktree
		helpers.write_file(info.worktree_path .. "/app.js", "console.log('AI');")
		-- User accepts/syncs change to main repo
		helpers.write_file(repo_path .. "/app.js", "console.log('AI');")

		local unresolved = git.get_unresolved_files(info.worktree_path)
		eq(0, #unresolved, "File should be resolved since contents are identical")
	end)
end)
