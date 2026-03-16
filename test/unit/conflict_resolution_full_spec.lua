-- test/unit/conflict_resolution_full_spec.lua
-- Tests for the classification engine and resolution logic
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")
local resolve = require("vibe.resolve")
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true
local is_false = assert.is_false

describe("Classification and resolution", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
		git.worktrees = {}
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("resolve_suggestion with accept returns change lines", function()
		local change = { "AI version" }
		local base = { "original" }
		local result = resolve.resolve_suggestion("accept", change, base)
		eq(1, #result)
		eq("AI version", result[1])
	end)

	it("resolve_suggestion with reject returns base lines", function()
		local change = { "AI version" }
		local base = { "original" }
		local result = resolve.resolve_suggestion("reject", change, base)
		eq(1, #result)
		eq("original", result[1])
	end)

	it("resolve_conflict with keep_user returns user lines", function()
		local user = { "USER" }
		local ai = { "AI" }
		local result = resolve.resolve_conflict("keep_user", user, ai)
		eq(1, #result)
		eq("USER", result[1])
	end)

	it("resolve_conflict with keep_ai returns AI lines", function()
		local user = { "USER" }
		local ai = { "AI" }
		local result = resolve.resolve_conflict("keep_ai", user, ai)
		eq(1, #result)
		eq("AI", result[1])
	end)

	it("resolve_conflict with edit_manually returns nil", function()
		local result = resolve.resolve_conflict("edit_manually", { "USER" }, { "AI" })
		assert.is_nil(result)
	end)

	it("mixed: 1 auto-merged + 1 conflict via classifier", function()
		local base = { "line 1", "line 2", "line 3" }
		-- AI edits line 2 AND adds line 4 at end
		local ai = { "line 1", "AI line 2", "line 3", "AI line 4" }
		-- User edits line 2 (conflict) but doesn't touch line 4 area
		local user = { "line 1", "USER line 2", "line 3" }

		local regions = classifier.classify_regions(base, user, ai)

		-- Should have a CONFLICT (overlapping edit on line 2) and AI_ONLY (line 4 addition)
		local has_conflict = false
		local has_ai_only = false
		for _, r in ipairs(regions) do
			if r.classification == types.CONFLICT then
				has_conflict = true
			end
			if r.classification == types.AI_ONLY then
				has_ai_only = true
			end
		end
		is_true(has_conflict, "Should have a CONFLICT region for overlapping edit")
		is_true(has_ai_only, "Should have an AI_ONLY region for AI addition")
	end)

	it("resolution_to_action_v2 maps correctly", function()
		eq("accepted", resolve.resolution_to_action_v2(types.AI_ONLY, "accept"))
		eq("rejected", resolve.resolution_to_action_v2(types.AI_ONLY, "reject"))
		eq("rejected", resolve.resolution_to_action_v2(types.CONFLICT, "keep_user"))
		eq("accepted", resolve.resolution_to_action_v2(types.CONFLICT, "keep_ai"))
		eq("accepted", resolve.resolution_to_action_v2(types.CONFLICT, "edit_manually"))
	end)

	it("get_replacement_for_region works for suggestions", function()
		local region = {
			classification = types.AI_ONLY,
			base_lines = { "original" },
			user_lines = { "original" },
			ai_lines = { "AI version" },
		}
		local accepted = resolve.get_replacement_for_region(types.AI_ONLY, "accept", region)
		eq(1, #accepted)
		eq("AI version", accepted[1])

		local rejected = resolve.get_replacement_for_region(types.AI_ONLY, "reject", region)
		eq(1, #rejected)
		eq("original", rejected[1])
	end)

	it("get_replacement_for_region works for conflicts", function()
		local region = {
			classification = types.CONFLICT,
			base_lines = { "original" },
			user_lines = { "USER" },
			ai_lines = { "AI" },
		}
		local keep_user = resolve.get_replacement_for_region(types.CONFLICT, "keep_user", region)
		eq("USER", keep_user[1])

		local keep_ai = resolve.get_replacement_for_region(types.CONFLICT, "keep_ai", region)
		eq("AI", keep_ai[1])
	end)
end)
