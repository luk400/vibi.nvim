-- test/unit/git_scope_spec.lua
-- Tests for worktree file copying behavior
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true

describe("Worktree file copying", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		helpers.cleanup_all()
		require("vibe.config").setup({})
	end)

	--- Helper to list files in worktree (recursively)
	local function list_files_in_dir(dir, prefix, result)
		result = result or {}
		prefix = prefix or ""
		if vim.fn.isdirectory(dir) == 0 then
			return result
		end
		for _, name in ipairs(vim.fn.readdir(dir) or {}) do
			if name ~= ".git" then
				local full_path = dir .. "/" .. name
				local rel_path = prefix ~= "" and (prefix .. "/" .. name) or name
				if vim.fn.isdirectory(full_path) == 1 then
					list_files_in_dir(full_path, rel_path, result)
				else
					table.insert(result, rel_path)
				end
			end
		end
		return result
	end

	it("copies all files when repo root is selected", function()
		local repo_path = helpers.create_test_repo("scope-root", {
			["root.txt"] = "root file",
			["src/main.js"] = "main content",
			["src/lib/util.js"] = "util content",
			["docs/readme.md"] = "docs content",
		})

		local info, err = git.create_worktree("scope-root-test", repo_path)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		is_true(vim.tbl_contains(files, "root.txt"), "root.txt should be in worktree")
		is_true(vim.tbl_contains(files, "src/main.js"), "src/main.js should be in worktree")
		is_true(vim.tbl_contains(files, "src/lib/util.js"), "src/lib/util.js should be in worktree")
		is_true(vim.tbl_contains(files, "docs/readme.md"), "docs/readme.md should be in worktree")
	end)

	it("copies all untracked files when copy_untracked is true regardless of cwd", function()
		local repo_path = helpers.create_test_repo("scope-untracked", {
			["committed.txt"] = "committed file",
		})

		helpers.write_file(repo_path .. "/src/untracked_src.txt", "untracked in src")
		helpers.write_file(repo_path .. "/docs/untracked_docs.txt", "untracked in docs")

		require("vibe.config").setup({
			quit_protection = false,
			worktree = {
				copy_untracked = true,
			},
		})

		local src_cwd = repo_path .. "/src"
		local info, err = git.create_worktree("scope-untracked-test", src_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		-- Both untracked files should be copied (no subdirectory scoping)
		is_true(
			vim.tbl_contains(files, "src/untracked_src.txt"),
			"src/untracked_src.txt should be in worktree"
		)
		is_true(
			vim.tbl_contains(files, "docs/untracked_docs.txt"),
			"docs/untracked_docs.txt should be in worktree"
		)

		-- Committed file should also be present
		is_true(
			vim.tbl_contains(files, "committed.txt"),
			"committed.txt should be in worktree"
		)
	end)

	it("copies all tracked files with modifications regardless of cwd", function()
		local repo_path = helpers.create_test_repo("scope-changed", {
			["src/changed.js"] = "original content",
			["src/unchanged.js"] = "unchanged content",
			["other/changed.js"] = "other original",
		})

		helpers.write_file(repo_path .. "/src/changed.js", "modified content")
		helpers.write_file(repo_path .. "/other/changed.js", "other modified")

		local src_cwd = repo_path .. "/src"
		local info, err = git.create_worktree("scope-changed-test", src_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		-- ALL tracked files should be present regardless of cwd
		is_true(vim.tbl_contains(files, "src/changed.js"), "src/changed.js should be in worktree")
		is_true(vim.tbl_contains(files, "src/unchanged.js"), "src/unchanged.js should be in worktree")
		is_true(vim.tbl_contains(files, "other/changed.js"), "other/changed.js should be in worktree")

		-- Modified files should have their modified content
		local src_content = table.concat(vim.fn.readfile(info.worktree_path .. "/src/changed.js"), "\n")
		eq("modified content", src_content, "src/changed.js should have modified content")

		local other_content = table.concat(vim.fn.readfile(info.worktree_path .. "/other/changed.js"), "\n")
		eq("other modified", other_content, "other/changed.js should have modified content")
	end)

	it("copies only untracked files matching patterns when configured", function()
		local repo_path = helpers.create_test_repo("scope-patterns", {
			["main.js"] = "main content",
		})

		helpers.write_file(repo_path .. "/data.json", '{"key": "value"}')
		helpers.write_file(repo_path .. "/report.csv", "a,b,c")
		helpers.write_file(repo_path .. "/notes.txt", "some notes")

		require("vibe.config").setup({
			quit_protection = false,
			worktree = {
				copy_untracked = { "*.json" },
			},
		})

		local info, err = git.create_worktree("scope-patterns-test", repo_path)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		-- Only .json untracked file should be copied
		is_true(vim.tbl_contains(files, "data.json"), "data.json should be in worktree")
		eq(false, vim.tbl_contains(files, "report.csv"), "report.csv should NOT be in worktree")
		eq(false, vim.tbl_contains(files, "notes.txt"), "notes.txt should NOT be in worktree")

		-- Tracked file should always be present
		is_true(vim.tbl_contains(files, "main.js"), "main.js should be in worktree")
	end)

	it("does not copy untracked files by default", function()
		local repo_path = helpers.create_test_repo("scope-default", {
			["tracked.txt"] = "tracked content",
			["src/app.js"] = "app content",
		})

		helpers.write_file(repo_path .. "/untracked.txt", "untracked content")
		helpers.write_file(repo_path .. "/src/untracked.js", "untracked js")

		local info, err = git.create_worktree("scope-default-test", repo_path)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		-- Untracked files should NOT be present
		eq(false, vim.tbl_contains(files, "untracked.txt"), "untracked.txt should NOT be in worktree")
		eq(false, vim.tbl_contains(files, "src/untracked.js"), "src/untracked.js should NOT be in worktree")

		-- Tracked files should be present
		is_true(vim.tbl_contains(files, "tracked.txt"), "tracked.txt should be in worktree")
		is_true(vim.tbl_contains(files, "src/app.js"), "src/app.js should be in worktree")
	end)

	it("does not copy untracked files when copy_untracked is false", function()
		local repo_path = helpers.create_test_repo("scope-false", {
			["tracked.txt"] = "tracked content",
			["src/app.js"] = "app content",
			["lib/util.js"] = "util content",
		})

		helpers.write_file(repo_path .. "/untracked.txt", "untracked content")
		helpers.write_file(repo_path .. "/src/untracked.js", "untracked js")
		helpers.write_file(repo_path .. "/lib/untracked.lua", "untracked lua")

		require("vibe.config").setup({
			quit_protection = false,
			worktree = {
				copy_untracked = false,
			},
		})

		local src_cwd = repo_path .. "/src"
		local info, err = git.create_worktree("scope-false-test", src_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		-- No untracked files should be copied
		eq(false, vim.tbl_contains(files, "untracked.txt"), "untracked.txt should NOT be in worktree")
		eq(false, vim.tbl_contains(files, "src/untracked.js"), "src/untracked.js should NOT be in worktree")
		eq(false, vim.tbl_contains(files, "lib/untracked.lua"), "lib/untracked.lua should NOT be in worktree")

		-- ALL tracked files should be present regardless of cwd
		is_true(vim.tbl_contains(files, "tracked.txt"), "tracked.txt should be in worktree")
		is_true(vim.tbl_contains(files, "src/app.js"), "src/app.js should be in worktree")
		is_true(vim.tbl_contains(files, "lib/util.js"), "lib/util.js should be in worktree")
	end)
end)
