-- test/unit/conflict_buffer_spec.lua
-- Tests for the classification engine which replaces the old conflict_buffer module
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true

describe("Classification Engine", function()
	before_each(function()
		for path, _ in pairs(git.worktrees) do
			git.remove_worktree(path)
		end
	end)

	after_each(function()
		helpers.cleanup_all()
	end)

	it("classifies non-overlapping user and AI changes correctly", function()
		local base = { "line 1", "line 2", "line 3" }
		local user = { "line 1 (User)", "line 2", "line 3" }
		local ai = { "line 1", "line 2", "line 3", "line 4 (AI)" }

		local regions = classifier.classify_regions(base, user, ai)

		-- Should have 2 non-overlapping regions: USER_ONLY and AI_ONLY
		eq(2, #regions)

		local user_only_found = false
		local ai_only_found = false
		for _, r in ipairs(regions) do
			if r.classification == types.USER_ONLY then
				user_only_found = true
			end
			if r.classification == types.AI_ONLY then
				ai_only_found = true
			end
		end
		is_true(user_only_found, "Should have a USER_ONLY region")
		is_true(ai_only_found, "Should have an AI_ONLY region")
	end)

	it("classifies overlapping edits as CONFLICT", function()
		local base = { "line 1", "line 2", "line 3" }
		local user = { "line 1", "line 2 edited by User", "line 3" }
		local ai = { "line 1", "line 2 edited by AI", "line 3" }

		local regions = classifier.classify_regions(base, user, ai)

		eq(1, #regions)
		eq(types.CONFLICT, regions[1].classification)
	end)

	it("classifies identical changes as CONVERGENT", function()
		local base = { "line 1", "line 2", "line 3" }
		local user = { "line 1", "same change", "line 3" }
		local ai = { "line 1", "same change", "line 3" }

		local regions = classifier.classify_regions(base, user, ai)

		eq(1, #regions)
		eq(types.CONVERGENT, regions[1].classification)
	end)

	it("applies merge modes correctly", function()
		local regions = {
			{ classification = types.USER_ONLY, auto_resolved = false },
			{ classification = types.AI_ONLY, auto_resolved = false },
			{ classification = types.CONFLICT, auto_resolved = false },
		}

		local summary = classifier.apply_merge_mode(regions, "user")
		is_true(regions[1].auto_resolved, "USER_ONLY should be auto-resolved in 'user' mode")
		eq(false, regions[2].auto_resolved, "AI_ONLY should NOT be auto-resolved in 'user' mode")
		eq(false, regions[3].auto_resolved, "CONFLICT should never be auto-resolved")
		eq(1, summary.auto_count)
		eq(1, summary.review_count)
		eq(1, summary.conflict_count)
	end)
end)
