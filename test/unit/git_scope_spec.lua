-- test/unit/git_scope_spec.lua
-- Tests for directory scoping in worktree creation (Bug 1)
-- When a subdirectory is selected, only files under that path should be copied
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true

describe("Worktree directory scoping", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	--- Helper to log test details
	local function log_test_state(test_name, state)
		print("\n[TEST] ========== " .. test_name .. " ==========")
		print(string.format("[TEST] repo_root: %s", state.repo_root or "NIL"))
		print(string.format("[TEST] repo_cwd (selected): %s", state.repo_cwd or "NIL"))
		print(string.format("[TEST] worktree_path: %s", state.worktree_path or "NIL"))
		print(string.format("[TEST] snapshot_commit: %s", state.snapshot_commit or "NIL"))
		print(string.format("[TEST] files_in_worktree: %s", vim.inspect(state.files_in_worktree or {})))
		print("[TEST] ==========================================\n")
	end

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
		-- Create a repo with files in multiple directories
		local repo_path = helpers.create_test_repo("scope-root", {
			["root.txt"] = "root file",
			["src/main.js"] = "main content",
			["src/lib/util.js"] = "util content",
			["docs/readme.md"] = "docs content",
		})

		-- Select the repo root as the cwd
		local info, err = git.create_worktree("scope-root-test", repo_path)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		log_test_state("Repo root selection", {
			repo_root = info.repo_root,
			repo_cwd = repo_path,
			worktree_path = info.worktree_path,
			snapshot_commit = info.snapshot_commit,
			files_in_worktree = files,
		})

		-- When repo root is selected, all committed files should be in worktree
		is_true(vim.tbl_contains(files, "root.txt"), "root.txt should be in worktree")
		is_true(vim.tbl_contains(files, "src/main.js"), "src/main.js should be in worktree")
		is_true(vim.tbl_contains(files, "src/lib/util.js"), "src/lib/util.js should be in worktree")
		is_true(vim.tbl_contains(files, "docs/readme.md"), "docs/readme.md should be in worktree")
	end)

	it("only copies files under selected subdirectory", function()
		-- Create a repo with files in multiple directories
		local repo_path = helpers.create_test_repo("scope-subdir", {
			["root.txt"] = "root file",
			["src/main.js"] = "main content",
			["src/lib/util.js"] = "util content",
			["docs/readme.md"] = "docs content",
		})

		-- Select src/ as the working directory
		local src_cwd = repo_path .. "/src"

		-- Make src have uncommitted changes
		helpers.write_file(src_cwd .. "/new.js", "new file in src")

		local info, err = git.create_worktree("scope-src-test", src_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		log_test_state("Subdirectory src/ selection", {
			repo_root = info.repo_root,
			repo_cwd = src_cwd,
			worktree_path = info.worktree_path,
			snapshot_commit = info.snapshot_commit,
			files_in_worktree = files,
		})

		-- BUG DETECTION: Only files under src/ should be copied
		-- Currently this test FAILS because files outside src/ are also copied

		-- Files under src/ should be present
		is_true(vim.tbl_contains(files, "src/main.js"), "src/main.js should be in worktree")
		is_true(vim.tbl_contains(files, "src/lib/util.js"), "src/lib/util.js should be in worktree")
		is_true(vim.tbl_contains(files, "src/new.js"), "src/new.js should be in worktree (uncommitted)")

		-- Files OUTSIDE src/ should NOT be copied (THIS IS THE BUG)
		local has_root_txt = vim.tbl_contains(files, "root.txt")
		local has_docs_readme = vim.tbl_contains(files, "docs/readme.md")

		if has_root_txt or has_docs_readme then
			print("[TEST] BUG DETECTED: Files outside selected directory were copied!")
			print(string.format("[TEST]   root.txt present: %s", tostring(has_root_txt)))
			print(string.format("[TEST]   docs/readme.md present: %s", tostring(has_docs_readme)))
		end

		eq(false, has_root_txt, "root.txt should NOT be in worktree (outside src/)")
		eq(false, has_docs_readme, "docs/readme.md should NOT be in worktree (outside src/)")
	end)

	it("handles nested subdirectory selection", function()
		-- Create a repo with deeply nested files
		local repo_path = helpers.create_test_repo("scope-nested", {
			["root.txt"] = "root file",
			["src/main.js"] = "main content",
			["src/lib/util.js"] = "util content",
			["src/lib/helpers/format.js"] = "format helper",
			["docs/readme.md"] = "docs content",
		})

		-- Select src/lib/ as the working directory
		local lib_cwd = repo_path .. "/src/lib"

		-- Add uncommitted change in lib
		helpers.write_file(lib_cwd .. "/newlib.js", "new lib file")

		local info, err = git.create_worktree("scope-lib-test", lib_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		log_test_state("Nested subdirectory src/lib/ selection", {
			repo_root = info.repo_root,
			repo_cwd = lib_cwd,
			worktree_path = info.worktree_path,
			snapshot_commit = info.snapshot_commit,
			files_in_worktree = files,
		})

		-- Files under src/lib/ should be present
		is_true(
			vim.tbl_contains(files, "src/lib/util.js"),
			"src/lib/util.js should be in worktree"
		)
		is_true(
			vim.tbl_contains(files, "src/lib/helpers/format.js"),
			"src/lib/helpers/format.js should be in worktree"
		)
		is_true(
			vim.tbl_contains(files, "src/lib/newlib.js"),
			"src/lib/newlib.js should be in worktree (uncommitted)"
		)

		-- Files OUTSIDE src/lib/ should NOT be copied
		eq(false, vim.tbl_contains(files, "root.txt"), "root.txt should NOT be in worktree")
		eq(false, vim.tbl_contains(files, "src/main.js"), "src/main.js should NOT be in worktree")
		eq(false, vim.tbl_contains(files, "docs/readme.md"), "docs/readme.md should NOT be in worktree")
	end)

	it("handles untracked files correctly when scoped", function()
		-- Create repo with untracked files in different directories
		local repo_path = helpers.create_test_repo("scope-untracked", {
			["committed.txt"] = "committed file",
		})

		-- Create untracked files in different directories
		helpers.write_file(repo_path .. "/src/untracked_src.txt", "untracked in src")
		helpers.write_file(repo_path .. "/docs/untracked_docs.txt", "untracked in docs")

		-- Configure to copy all untracked files
		require("vibe.config").setup({
			quit_protection = false,
			worktree = {
				copy_untracked = true,
			},
		})

		-- Select src/ directory
		local src_cwd = repo_path .. "/src"
		local info, err = git.create_worktree("scope-untracked-test", src_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		log_test_state("Untracked files with src/ scope", {
			repo_root = info.repo_root,
			repo_cwd = src_cwd,
			worktree_path = info.worktree_path,
			snapshot_commit = info.snapshot_commit,
			files_in_worktree = files,
		})

		-- Untracked file in src/ should be copied
		is_true(
			vim.tbl_contains(files, "src/untracked_src.txt"),
			"src/untracked_src.txt should be in worktree"
		)

		-- Untracked file in docs/ should NOT be copied
		eq(
			false,
			vim.tbl_contains(files, "docs/untracked_docs.txt"),
			"docs/untracked_docs.txt should NOT be in worktree"
		)

		-- Reset config
		require("vibe.config").setup({})
	end)

	it("handles changed files correctly when scoped", function()
		-- Create repo with committed files
		local repo_path = helpers.create_test_repo("scope-changed", {
			["src/changed.js"] = "original content",
			["src/unchanged.js"] = "unchanged content",
			["other/changed.js"] = "other original",
		})

		-- Modify files
		helpers.write_file(repo_path .. "/src/changed.js", "modified content")
		helpers.write_file(repo_path .. "/other/changed.js", "other modified")

		-- Select src/ directory
		local src_cwd = repo_path .. "/src"
		local info, err = git.create_worktree("scope-changed-test", src_cwd)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		local files = list_files_in_dir(info.worktree_path)

		log_test_state("Changed files with src/ scope", {
			repo_root = info.repo_root,
			repo_cwd = src_cwd,
			worktree_path = info.worktree_path,
			snapshot_commit = info.snapshot_commit,
			files_in_worktree = files,
		})

		-- Changed file in src/ should have modified content
		is_true(vim.tbl_contains(files, "src/changed.js"), "src/changed.js should be in worktree")
		local content = table.concat(vim.fn.readfile(info.worktree_path .. "/src/changed.js"), "\n")
		eq("modified content", content, "src/changed.js should have modified content")

		-- Changed file outside src/ should NOT be copied
		eq(
			false,
			vim.tbl_contains(files, "other/changed.js"),
			"other/changed.js should NOT be in worktree"
		)
	end)
end)
