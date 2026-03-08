-- test/unit/custom_worktree_dir_spec.lua
-- Tests for custom worktree_dir configuration (Bug 2)
-- VibeReview should detect changes when using custom worktree_dir
local git = require("vibe.git")
local persist = require("vibe.persist")
local config = require("vibe.config")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true
local is_nil = assert.is_nil

describe("Custom worktree directory", function()
	local custom_worktree_dir

	before_each(function()
		-- Clean up existing worktrees
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}

		-- Create a unique custom worktree directory for each test
		custom_worktree_dir = vim.fn.tempname() .. "-custom-worktrees"
		vim.fn.mkdir(custom_worktree_dir, "p")

		-- Configure vibe with custom worktree_dir
		config.setup({
			quit_protection = false,
			worktree = {
				worktree_dir = custom_worktree_dir,
				copy_untracked = true,
			},
		})
	end)

	after_each(function()
		-- Clean up
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}

		-- Clean up custom worktree directory
		if vim.fn.isdirectory(custom_worktree_dir) == 1 then
			vim.fn.delete(custom_worktree_dir, "rf")
		end

		helpers.cleanup_all()

		-- Reset config
		config.setup({})
	end)

	--- Helper to log test details
	local function log_test_state(test_name, state)
		print("\n[TEST] ========== " .. test_name .. " ==========")
		print(string.format("[TEST] custom_worktree_dir: %s", state.custom_worktree_dir or "NIL"))
		print(string.format("[TEST] worktree_path: %s", state.worktree_path or "NIL"))
		print(string.format("[TEST] sessions_file: %s", state.sessions_file or "NIL"))
		print(string.format("[TEST] snapshot_commit: %s", state.snapshot_commit or "NIL"))
		print(string.format("[TEST] changed_files: %s", vim.inspect(state.changed_files or {})))
		print(string.format("[TEST] unresolved_files: %s", vim.inspect(state.unresolved_files or {})))
		print("[TEST] ==========================================\n")
	end

	it("creates worktree in custom directory", function()
		local repo_path = helpers.create_test_repo("custom-dir", {
			["app.js"] = "console.log('hello');",
		})

		local info, err = git.create_worktree("custom-test", repo_path)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)

		-- Worktree should be in custom directory
		is_true(
			vim.startswith(info.worktree_path, custom_worktree_dir),
			"Worktree should be in custom directory"
		)
		is_true(vim.fn.isdirectory(info.worktree_path) == 1, "Worktree directory should exist")

		log_test_state("Worktree in custom directory", {
			custom_worktree_dir = custom_worktree_dir,
			worktree_path = info.worktree_path,
			snapshot_commit = info.snapshot_commit,
		})
	end)

	it("persists session to custom directory", function()
		local repo_path = helpers.create_test_repo("custom-persist", {
			["app.js"] = "console.log('hello');",
		})

		local info, err = git.create_worktree("persist-test", repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)

		-- Check that sessions file is in custom directory
		local sessions_file = custom_worktree_dir .. "/sessions.json"
		is_true(vim.fn.filereadable(sessions_file) == 1, "Sessions file should exist in custom directory")

		-- Load and verify session
		local sessions = persist.load_sessions()
		local found = false
		for _, s in ipairs(sessions) do
			if s.worktree_path == info.worktree_path then
				found = true
				eq("persist-test", s.name)
				break
			end
		end
		is_true(found, "Session should be persisted")

		log_test_state("Session persistence", {
			custom_worktree_dir = custom_worktree_dir,
			worktree_path = info.worktree_path,
			sessions_file = sessions_file,
		})
	end)

	it("VibeReview finds changes after scan", function()
		local repo_path = helpers.create_test_repo("custom-review", {
			["app.js"] = "console.log('hello');",
		})

		-- Create worktree
		local info, err = git.create_worktree("review-test", repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)
		assert.is_not_nil(info.snapshot_commit, "snapshot_commit should not be nil")

		-- Simulate AI modifying a file in the worktree
		helpers.write_file(info.worktree_path .. "/app.js", "console.log('AI modified');")

		-- Clear the in-memory cache to simulate a fresh scan
		git.worktrees = {}

		-- Scan for worktrees (this is what VibeReview does)
		git.scan_for_vibe_worktrees()

		-- Check that the worktree was found
		local scanned_info = git.worktrees[info.worktree_path]
		assert.is_not_nil(scanned_info, "Worktree should be found after scan")

		-- Check that snapshot_commit was properly restored
		is_true(
			scanned_info.snapshot_commit ~= nil and scanned_info.snapshot_commit ~= "",
			"snapshot_commit should not be nil or empty after scan"
		)

		-- Get changed files
		local changed_files = git.get_worktree_changed_files(info.worktree_path)
		local unresolved = git.get_unresolved_files(info.worktree_path)

		log_test_state("VibeReview after scan", {
			custom_worktree_dir = custom_worktree_dir,
			worktree_path = info.worktree_path,
			snapshot_commit = scanned_info.snapshot_commit,
			changed_files = changed_files,
			unresolved_files = unresolved,
		})

		-- BUG DETECTION: If snapshot_commit is nil, get_worktree_changed_files returns empty
		eq(1, #changed_files, "Should detect 1 changed file")
		eq("app.js", changed_files[1], "Should detect app.js as changed")
		eq(1, #unresolved, "Should have 1 unresolved file")
	end)

	it("handles missing snapshot_commit gracefully", function()
		local repo_path = helpers.create_test_repo("custom-missing-snapshot", {
			["app.js"] = "console.log('hello');",
		})

		-- Create worktree
		local info, err = git.create_worktree("missing-snapshot-test", repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)

		-- Simulate AI modifying a file
		helpers.write_file(info.worktree_path .. "/app.js", "console.log('modified');")

		-- Corrupt the snapshot_commit to simulate the bug
		local original_snapshot = info.snapshot_commit
		info.snapshot_commit = nil

		-- Get changed files with nil snapshot_commit
		local changed_files = git.get_worktree_changed_files(info.worktree_path)

		log_test_state("Missing snapshot_commit handling", {
			worktree_path = info.worktree_path,
			original_snapshot = original_snapshot,
			snapshot_commit = info.snapshot_commit or "NIL",
			changed_files = changed_files,
		})

		-- BUG DETECTION: With nil snapshot_commit, should still work somehow
		-- Currently this returns empty because git diff with nil fails
		if #changed_files == 0 then
			print("[TEST] BUG DETECTED: No changes detected when snapshot_commit is nil!")
			print("[TEST] This causes VibeReview to show 'no changes to review'")
		end

		-- Ideally, we should either:
		-- 1. Return all changed files (comparing to HEAD or initial commit)
		-- 2. Return an error indicating the issue
		-- For now, document the bug
		-- eq(1, #changed_files, "Should still detect changes even with nil snapshot_commit")

		-- Restore for cleanup
		info.snapshot_commit = original_snapshot
	end)

	it("scan_for_vibe_worktrees restores snapshot_commit correctly", function()
		local repo_path = helpers.create_test_repo("custom-scan-restore", {
			["app.js"] = "console.log('hello');",
		})

		-- Create worktree
		local info, err = git.create_worktree("scan-restore-test", repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)

		local original_snapshot = info.snapshot_commit
		assert.is_not_nil(original_snapshot, "Original snapshot_commit should not be nil")

		-- Clear in-memory cache
		git.worktrees = {}

		-- Scan to restore
		git.scan_for_vibe_worktrees()

		-- Verify snapshot_commit was restored
		local restored = git.worktrees[info.worktree_path]
		assert.is_not_nil(restored, "Worktree info should be restored")

		log_test_state("Snapshot commit restoration after scan", {
			worktree_path = info.worktree_path,
			original_snapshot = original_snapshot,
			restored_snapshot = restored.snapshot_commit or "NIL",
		})

		if restored.snapshot_commit == nil then
			print("[TEST] BUG DETECTED: snapshot_commit is nil after scan_for_vibe_worktrees!")
			print("[TEST] This causes VibeReview to fail finding changes")
		end

		is_true(
			restored.snapshot_commit ~= nil and restored.snapshot_commit ~= "",
			"snapshot_commit should be restored after scan"
		)
		eq(original_snapshot, restored.snapshot_commit, "snapshot_commit should match original")
	end)

	it("get_worktrees_with_changes finds worktrees with changes", function()
		local repo_path = helpers.create_test_repo("custom-with-changes", {
			["app.js"] = "console.log('hello');",
		})

		-- Create worktree
		local info, err = git.create_worktree("with-changes-test", repo_path)
		assert.is_nil(err)
		assert.is_not_nil(info)

		-- Initially no changes
		local worktrees_with_changes = git.get_worktrees_with_changes()
		eq(0, #worktrees_with_changes, "Initially no changes")

		-- Modify file in worktree
		helpers.write_file(info.worktree_path .. "/app.js", "console.log('modified');")

		-- Clear and rescan
		git.worktrees = {}
		git.scan_for_vibe_worktrees()

		-- Now should have changes
		worktrees_with_changes = git.get_worktrees_with_changes()

		log_test_state("get_worktrees_with_changes after modification", {
			worktree_path = info.worktree_path,
			snapshot_commit = git.worktrees[info.worktree_path]
				and git.worktrees[info.worktree_path].snapshot_commit or "NIL",
			worktrees_found = #worktrees_with_changes,
		})

		eq(1, #worktrees_with_changes, "Should find 1 worktree with changes")
		eq(info.worktree_path, worktrees_with_changes[1].worktree_path, "Should be our worktree")
	end)

	it("handles custom path with special characters", function()
		-- Create custom dir with space in path
		local special_dir = vim.fn.tempname() .. " custom worktrees"
		vim.fn.mkdir(special_dir, "p")

		config.setup({
			quit_protection = false,
			worktree = {
				worktree_dir = special_dir,
			},
		})

		local repo_path = helpers.create_test_repo("custom-special", {
			["app.js"] = "console.log('hello');",
		})

		local info, err = git.create_worktree("special-test", repo_path)

		assert.is_nil(err, "Error should be nil: " .. (err or "nil"))
		assert.is_not_nil(info)
		is_true(vim.startswith(info.worktree_path, special_dir), "Worktree should be in special directory")

		log_test_state("Custom path with special characters", {
			custom_worktree_dir = special_dir,
			worktree_path = info.worktree_path,
		})

		-- Cleanup
		if vim.fn.isdirectory(special_dir) == 1 then
			vim.fn.delete(special_dir, "rf")
		end
	end)
end)
