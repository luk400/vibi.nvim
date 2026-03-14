local persist = require("vibe.persist")
local config = require("vibe.config")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Persist extra coverage", function()
	local custom_dir

	before_each(function()
		custom_dir = vim.fn.tempname() .. "-persist-extra"
		vim.fn.mkdir(custom_dir, "p")
		config.setup({
			quit_protection = false,
			worktree = {
				worktree_dir = custom_dir,
			},
		})
	end)

	after_each(function()
		if vim.fn.isdirectory(custom_dir) == 1 then
			vim.fn.delete(custom_dir, "rf")
		end
		config.setup({})
		helpers.cleanup_all()
	end)

	it("remove_session deletes by worktree_path", function()
		local session_a = {
			name = "sess-a",
			worktree_path = "/tmp/fake-wt-a",
			branch = "vibe-a",
			snapshot_commit = "abc123",
			original_branch = "main",
			repo_root = "/tmp/repo",
			cwd = "/tmp/repo",
			created_at = os.time(),
			last_active = os.time(),
			has_terminal = false,
		}
		local session_b = {
			name = "sess-b",
			worktree_path = "/tmp/fake-wt-b",
			branch = "vibe-b",
			snapshot_commit = "def456",
			original_branch = "main",
			repo_root = "/tmp/repo",
			cwd = "/tmp/repo",
			created_at = os.time(),
			last_active = os.time(),
			has_terminal = false,
		}

		persist.save_session(session_a)
		persist.save_session(session_b)

		local before = persist.load_sessions()
		eq(2, #before, "Should have 2 sessions before removal")

		persist.remove_session("/tmp/fake-wt-a")

		local after = persist.load_sessions()
		eq(1, #after, "Should have 1 session after removal")
		eq("/tmp/fake-wt-b", after[1].worktree_path)
	end)

	it("mark_all_sessions_paused sets has_terminal=false", function()
		local session = {
			name = "active-sess",
			worktree_path = "/tmp/fake-wt-active",
			branch = "vibe-active",
			snapshot_commit = "abc123",
			original_branch = "main",
			repo_root = "/tmp/repo",
			cwd = "/tmp/repo",
			created_at = os.time(),
			last_active = os.time(),
			has_terminal = true,
		}

		persist.save_session(session)

		-- Verify it's active
		local before = persist.load_sessions()
		eq(true, before[1].has_terminal, "Should be active before pausing")

		persist.mark_all_sessions_paused()

		local after = persist.load_sessions()
		eq(false, after[1].has_terminal, "Should be paused after mark_all_sessions_paused")
	end)

	it("format_timestamp returns human-readable strings", function()
		local now = os.time()

		eq("just now", persist.format_timestamp(now), "Current time should be 'just now'")
		eq("just now", persist.format_timestamp(now - 30), "30 seconds ago should be 'just now'")

		local mins_result = persist.format_timestamp(now - 120)
		assert.is_truthy(mins_result:find("min"), "2 minutes ago should contain 'min'")

		local hours_result = persist.format_timestamp(now - 7200)
		assert.is_truthy(hours_result:find("hour"), "2 hours ago should contain 'hour'")

		local days_result = persist.format_timestamp(now - 172800)
		assert.is_truthy(days_result:find("day"), "2 days ago should contain 'day'")

		eq("unknown", persist.format_timestamp(nil), "nil timestamp should return 'unknown'")
	end)
end)
