--- Tests for visual indicators on auto-merged changes in :VibeReview
local renderer = require("vibe.review.renderer")
local types = require("vibe.review.types")
local kd = require("vibe.review.keymap_display")

local eq = assert.are.equal

--- Helper: create a minimal buffer state with auto_items for testing
local function setup_test_buffer(auto_items, review_items)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(bufnr)

	renderer.buffer_state[bufnr] = {
		worktree_path = "/tmp/test-wt",
		filepath = "test.lua",
		session_name = "test",
		classified_file = { regions = {} },
		merge_mode = "both",
		review_items = review_items or {},
		auto_items = auto_items or {},
		item_contents = {},
		resolved_count = 0,
		original_lines = { "line1", "line2", "line3", "line4", "line5" },
		merged_lines = {},
	}

	return bufnr
end

--- Helper: count extmarks in a namespace
local function count_extmarks(bufnr, ns)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
	return #marks
end

--- Helper: get extmarks with details
local function get_extmarks_detail(bufnr, ns)
	return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

describe("Auto-merge visual indicators", function()
	after_each(function()
		-- Clean up all test buffers
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if renderer.buffer_state[bufnr] then
				renderer.buffer_state[bufnr] = nil
				pcall(vim.api.nvim_buf_clear_namespace, bufnr, renderer.ns_auto, 0, -1)
			end
		end
		renderer.close_hint()
	end)

	describe("namespace and highlight groups", function()
		it("creates separate namespace for auto-merged extmarks", function()
			assert.is_truthy(renderer.ns_auto)
			assert.are_not.equal(renderer.ns, renderer.ns_auto)
		end)

		it("defines auto-merged highlight groups", function()
			renderer.setup_highlights()
			-- Verify highlight groups exist by checking they don't error
			local ok_add = pcall(vim.api.nvim_get_hl_by_name, "VibeAutoMergedAdd", true)
			local ok_del = pcall(vim.api.nvim_get_hl_by_name, "VibeAutoMergedDelete", true)
			local ok_chg = pcall(vim.api.nvim_get_hl_by_name, "VibeAutoMergedChange", true)
			assert.is_true(ok_add)
			assert.is_true(ok_del)
			assert.is_true(ok_chg)
		end)
	end)

	describe("highlight_auto_merged", function()
		it("places extmarks for added lines with VibeAutoMergedAdd", function()
			local auto_items = {
				{
					classification = types.AI_ONLY,
					auto_resolved = true,
					base_range = { 2, 1 }, -- insertion at line 2 (empty base range)
					base_lines = {},
					user_lines = {},
					ai_lines = { "new_line_a", "new_line_b" },
				},
			}
			local bufnr = setup_test_buffer(auto_items)
			-- Set buffer to content that includes the added lines
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "new_line_a", "new_line_b", "line2", "line3" })

			-- Mock git.get_worktree_snapshot_lines to return base content
			local git = require("vibe.git")
			local orig_fn = git.get_worktree_snapshot_lines
			git.get_worktree_snapshot_lines = function()
				return { "line1", "line2", "line3" }
			end

			renderer.highlight_auto_merged(bufnr)

			git.get_worktree_snapshot_lines = orig_fn

			local marks = get_extmarks_detail(bufnr, renderer.ns_auto)
			assert.is_true(#marks > 0)

			-- Check that at least one mark uses VibeAutoMergedAdd
			local found_add = false
			for _, mark in ipairs(marks) do
				if mark[4] and mark[4].hl_group == "VibeAutoMergedAdd" then
					found_add = true
					break
				end
			end
			assert.is_true(found_add)
		end)

		it("places virtual lines for deleted content with VibeAutoMergedDelete", function()
			local auto_items = {
				{
					classification = types.USER_ONLY,
					auto_resolved = true,
					base_range = { 2, 2 }, -- line 2 deleted
					base_lines = { "deleted_line" },
					user_lines = {},
					ai_lines = {},
				},
			}
			local bufnr = setup_test_buffer(auto_items)
			-- Buffer without the deleted line
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line3", "line4", "line5" })

			local git = require("vibe.git")
			local orig_fn = git.get_worktree_snapshot_lines
			git.get_worktree_snapshot_lines = function()
				return { "line1", "deleted_line", "line3", "line4", "line5" }
			end

			renderer.highlight_auto_merged(bufnr)

			git.get_worktree_snapshot_lines = orig_fn

			local marks = get_extmarks_detail(bufnr, renderer.ns_auto)
			assert.is_true(#marks > 0)

			-- Check for virt_lines
			local found_virt = false
			for _, mark in ipairs(marks) do
				if mark[4] and mark[4].virt_lines then
					found_virt = true
					-- Verify the virtual line text matches the deleted content
					local virt = mark[4].virt_lines[1]
					eq("deleted_line", virt[1][1])
					eq("VibeAutoMergedDelete", virt[1][2])
				end
			end
			assert.is_true(found_virt)
		end)

		it("places extmarks for modified lines with VibeAutoMergedChange", function()
			local auto_items = {
				{
					classification = types.USER_ONLY,
					auto_resolved = true,
					base_range = { 2, 2 }, -- line 2 modified
					base_lines = { "old_line2" },
					user_lines = { "new_line2" },
					ai_lines = {},
				},
			}
			local bufnr = setup_test_buffer(auto_items)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "new_line2", "line3", "line4", "line5" })

			local git = require("vibe.git")
			local orig_fn = git.get_worktree_snapshot_lines
			git.get_worktree_snapshot_lines = function()
				return { "line1", "old_line2", "line3", "line4", "line5" }
			end

			renderer.highlight_auto_merged(bufnr)

			git.get_worktree_snapshot_lines = orig_fn

			local marks = get_extmarks_detail(bufnr, renderer.ns_auto)
			assert.is_true(#marks > 0)

			local found_change = false
			for _, mark in ipairs(marks) do
				if mark[4] and mark[4].hl_group == "VibeAutoMergedChange" then
					found_change = true
					break
				end
			end
			assert.is_true(found_change)
		end)

		it("does not place extmarks when content is unchanged", function()
			local auto_items = {
				{
					classification = types.USER_ONLY,
					auto_resolved = true,
					base_range = { 2, 2 },
					base_lines = { "same_line" },
					user_lines = { "same_line" },
					ai_lines = {},
				},
			}
			local bufnr = setup_test_buffer(auto_items)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "same_line", "line3" })

			local git = require("vibe.git")
			local orig_fn = git.get_worktree_snapshot_lines
			git.get_worktree_snapshot_lines = function()
				return { "line1", "same_line", "line3" }
			end

			renderer.highlight_auto_merged(bufnr)

			git.get_worktree_snapshot_lines = orig_fn

			local marks = count_extmarks(bufnr, renderer.ns_auto)
			eq(0, marks)
		end)

		it("uses ai_lines for AI_ONLY classification", function()
			local auto_items = {
				{
					classification = types.AI_ONLY,
					auto_resolved = true,
					base_range = { 2, 2 },
					base_lines = { "old_line" },
					user_lines = { "old_line" }, -- user didn't change it
					ai_lines = { "ai_modified_line" },
				},
			}
			local bufnr = setup_test_buffer(auto_items)
			vim.api.nvim_buf_set_lines(
				bufnr,
				0,
				-1,
				false,
				{ "line1", "ai_modified_line", "line3", "line4", "line5" }
			)

			local git = require("vibe.git")
			local orig_fn = git.get_worktree_snapshot_lines
			git.get_worktree_snapshot_lines = function()
				return { "line1", "old_line", "line3", "line4", "line5" }
			end

			renderer.highlight_auto_merged(bufnr)

			git.get_worktree_snapshot_lines = orig_fn

			-- Should have a change extmark (ai_lines differs from base_lines)
			local marks = get_extmarks_detail(bufnr, renderer.ns_auto)
			assert.is_true(#marks > 0)

			local found_change = false
			for _, mark in ipairs(marks) do
				if mark[4] and mark[4].hl_group == "VibeAutoMergedChange" then
					found_change = true
					break
				end
			end
			assert.is_true(found_change)
		end)
	end)

	describe("_build_resolved_content", function()
		it("applies AI_ONLY auto-merged content to buffer", function()
			local git = require("vibe.git")
			local orig_fn = git.get_worktree_snapshot_lines
			git.get_worktree_snapshot_lines = function()
				return { "base1", "base2", "base3" }
			end

			local state = {
				worktree_path = "/tmp/test-wt",
				filepath = "test.lua",
				original_lines = { "base1", "base2", "base3" },
				classified_file = {
					regions = {
						{
							classification = types.AI_ONLY,
							auto_resolved = true,
							base_range = { 2, 2 },
							base_lines = { "base2" },
							user_lines = { "base2" },
							ai_lines = { "ai_replacement" },
						},
					},
				},
			}

			local result = renderer._build_resolved_content(state)

			git.get_worktree_snapshot_lines = orig_fn

			eq(3, #result)
			eq("base1", result[1])
			eq("ai_replacement", result[2])
			eq("base3", result[3])
		end)
	end)

	describe("namespace cleanup", function()
		it("clears ns_auto on finalize_file", function()
			local auto_items = {
				{
					classification = types.USER_ONLY,
					auto_resolved = true,
					base_range = { 2, 2 },
					base_lines = { "old" },
					user_lines = { "new" },
					ai_lines = {},
				},
			}
			local bufnr = setup_test_buffer(auto_items)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "new", "line3" })

			-- Place a test extmark
			vim.api.nvim_buf_set_extmark(bufnr, renderer.ns_auto, 1, 0, {
				hl_group = "VibeAutoMergedChange",
				hl_eol = true,
			})
			eq(1, count_extmarks(bufnr, renderer.ns_auto))

			-- Mock dependencies for finalize
			local git = require("vibe.git")
			local orig_sync = git.sync_resolved_file
			local orig_mark = git.mark_hunk_addressed
			git.sync_resolved_file = function() end
			git.mark_hunk_addressed = function() end

			local util = require("vibe.util")
			local orig_check = util.check_remaining_files
			util.check_remaining_files = function() end

			-- Set buffer name and clear buftype so :write works
			local tmpfile = vim.fn.tempname()
			vim.api.nvim_buf_set_name(bufnr, tmpfile)
			vim.bo[bufnr].buftype = ""

			renderer.finalize_file(bufnr)

			-- Restore
			git.sync_resolved_file = orig_sync
			git.mark_hunk_addressed = orig_mark
			util.check_remaining_files = orig_check
			pcall(os.remove, tmpfile)

			eq(0, count_extmarks(bufnr, renderer.ns_auto))
		end)

		it("clears ns_auto on quit", function()
			local bufnr = setup_test_buffer({})
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2" })

			-- Place a test extmark
			vim.api.nvim_buf_set_extmark(bufnr, renderer.ns_auto, 0, 0, {
				hl_group = "VibeAutoMergedAdd",
				hl_eol = true,
			})
			eq(1, count_extmarks(bufnr, renderer.ns_auto))

			-- Set buffer name and clear buftype so :write works
			local tmpfile = vim.fn.tempname()
			vim.api.nvim_buf_set_name(bufnr, tmpfile)
			vim.bo[bufnr].buftype = ""

			-- Mock confirm to say "yes, quit"
			local orig_confirm = vim.fn.confirm
			vim.fn.confirm = function()
				return 1
			end

			-- Mock dialog.show
			local dialog = require("vibe.dialog")
			local orig_show = dialog.show
			dialog.show = function() end

			renderer.quit(bufnr)

			-- Restore
			vim.fn.confirm = orig_confirm
			dialog.show = orig_show
			pcall(os.remove, tmpfile)

			eq(0, count_extmarks(bufnr, renderer.ns_auto))
		end)

		it("clears ns_auto on clear", function()
			local bufnr = setup_test_buffer({})
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1" })

			vim.api.nvim_buf_set_extmark(bufnr, renderer.ns_auto, 0, 0, {
				hl_group = "VibeAutoMergedAdd",
				hl_eol = true,
			})
			eq(1, count_extmarks(bufnr, renderer.ns_auto))

			renderer.clear(bufnr)

			eq(0, count_extmarks(bufnr, renderer.ns_auto))
		end)
	end)

	describe("DESC_DONE constant", function()
		it("is defined in keymap_display", function()
			assert.is_truthy(kd.DESC_DONE)
			eq("Accept file and continue", kd.DESC_DONE)
		end)
	end)

	describe("hint window", function()
		it("show_hint creates a floating window", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_set_current_buf(bufnr)
			-- Set up a minimal keymap so get_key_or_fallback works
			renderer.show_hint(bufnr)

			assert.is_truthy(renderer.hint_winnr)
			assert.is_true(vim.api.nvim_win_is_valid(renderer.hint_winnr))

			renderer.close_hint()
		end)

		it("close_hint closes the window", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_set_current_buf(bufnr)
			renderer.show_hint(bufnr)

			assert.is_truthy(renderer.hint_winnr)
			renderer.close_hint()

			assert.is_nil(renderer.hint_winnr)
			assert.is_nil(renderer.hint_bufnr)
		end)

		it("close_hint is safe to call when no hint is open", function()
			renderer.hint_winnr = nil
			renderer.hint_bufnr = nil
			-- Should not error
			renderer.close_hint()
			assert.is_nil(renderer.hint_winnr)
		end)
	end)

	describe("done keybind", function()
		it("is registered via keymaps.setup when done handler is provided", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			local keymaps = require("vibe.review.keymaps")

			local done_called = false
			keymaps.setup(bufnr, {
				get_item_at_cursor = function()
					return nil
				end,
				resolve = function() end,
				next_item = function() end,
				prev_item = function() end,
				done = function()
					done_called = true
				end,
				quit = function() end,
			})

			-- Check the keymap was registered
			local key = kd.get_key_for_desc(bufnr, kd.DESC_DONE)
			assert.is_truthy(key)
		end)
	end)
end)
