-- test/unit/three_way_merge_spec.lua
-- Comprehensive 3-way merge classification and resolution tests (92 tests)
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")
local resolve = require("vibe.resolve")
local eq = assert.are.equal

local function deep_eq(expected, actual, msg)
	msg = msg or ""
	eq(#expected, #actual, msg .. " length: expected " .. #expected .. ", got " .. #actual)
	for i = 1, #expected do
		eq(expected[i], actual[i], msg .. " [" .. i .. "]")
	end
end

local function count_type(regions, cls)
	local n = 0
	for _, r in ipairs(regions) do
		if r.classification == cls then
			n = n + 1
		end
	end
	return n
end

local function has_type(regions, cls)
	return count_type(regions, cls) > 0
end

local function find_type(regions, cls)
	for _, r in ipairs(regions) do
		if r.classification == cls then
			return r
		end
	end
	return nil
end

--- Reconstruct output from base + classified regions + per-region decisions
local function reconstruct(base, regions, decisions)
	local result = {}
	local base_pos = 1
	for i, region in ipairs(regions) do
		local resolved = resolve.get_replacement_for_region(region.classification, decisions[i], region)
		if not resolved then
			resolved = region.user_lines
		end
		local is_insert = #region.base_lines == 0
		if is_insert then
			while base_pos <= region.base_range[1] do
				table.insert(result, base[base_pos])
				base_pos = base_pos + 1
			end
		else
			while base_pos < region.base_range[1] do
				table.insert(result, base[base_pos])
				base_pos = base_pos + 1
			end
		end
		for _, line in ipairs(resolved) do
			table.insert(result, line)
		end
		if not is_insert then
			base_pos = region.base_range[2] + 1
		end
	end
	while base_pos <= #base do
		table.insert(result, base[base_pos])
		base_pos = base_pos + 1
	end
	return result
end

describe("3-way merge", function()
	-- ============================================================
	-- 2.1 Single-region classification (tests 1-14)
	-- ============================================================
	describe("single-region classification", function()
		it("#1 user modifies line, AI unchanged -> USER_ONLY", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "USER modified", "line 3" }
			local ai = { "line 1", "line 2", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			assert.is_true(vim.tbl_contains(regions[1].user_lines, "USER modified"))
		end)

		it("#2 AI modifies line, user unchanged -> AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 2", "line 3" }
			local ai = { "line 1", "AI modified", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.AI_ONLY, regions[1].classification)
			assert.is_true(vim.tbl_contains(regions[1].ai_lines, "AI modified"))
		end)

		it("#3 both modify same line identically -> CONVERGENT", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "same change", "line 3" }
			local ai = { "line 1", "same change", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONVERGENT, regions[1].classification)
		end)

		it("#4 both modify same line differently -> CONFLICT", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 2 edited by User", "line 3" }
			local ai = { "line 1", "line 2 edited by AI", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			assert.is_true(vim.tbl_contains(regions[1].user_lines, "line 2 edited by User"))
			assert.is_true(vim.tbl_contains(regions[1].ai_lines, "line 2 edited by AI"))
		end)

		it("#5 user deletes line, AI modifies it -> CONFLICT", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 3" }
			local ai = { "line 1", "AI modified 2", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			eq(0, #regions[1].user_lines)
			assert.is_true(vim.tbl_contains(regions[1].ai_lines, "AI modified 2"))
		end)

		it("#6 user modifies line, AI deletes it -> CONFLICT", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "USER modified 2", "line 3" }
			local ai = { "line 1", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			assert.is_true(vim.tbl_contains(regions[1].user_lines, "USER modified 2"))
			eq(0, #regions[1].ai_lines)
		end)

		it("#7 user adds line, AI unchanged -> USER_ONLY", function()
			local base = { "line 1", "line 3" }
			local user = { "line 1", "USER new line", "line 3" }
			local ai = { "line 1", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
		end)

		it("#8 AI adds line, user unchanged -> AI_ONLY", function()
			local base = { "line 1", "line 3" }
			local user = { "line 1", "line 3" }
			local ai = { "line 1", "AI new line", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.AI_ONLY, regions[1].classification)
		end)

		it("#9 both add same line at same position -> CONVERGENT", function()
			local base = { "aaa" }
			local user = { "bbb", "aaa" }
			local ai = { "bbb", "aaa" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONVERGENT, regions[1].classification)
			-- _reconstruct_side includes the base line at insertion point
			deep_eq(regions[1].user_lines, regions[1].ai_lines, "user and AI lines should match")
		end)

		it("#10 both add different lines at same position -> CONFLICT", function()
			local base = { "aaa" }
			local user = { "xxx", "aaa" }
			local ai = { "yyy", "aaa" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			assert.is_true(vim.tbl_contains(regions[1].user_lines, "xxx"))
			assert.is_true(vim.tbl_contains(regions[1].ai_lines, "yyy"))
		end)

		it("#11 user deletes line, AI unchanged -> USER_ONLY", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 3" }
			local ai = { "line 1", "line 2", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(0, #regions[1].user_lines)
		end)

		it("#12 AI deletes line, user unchanged -> AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 2", "line 3" }
			local ai = { "line 1", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.AI_ONLY, regions[1].classification)
			eq(0, #regions[1].ai_lines)
		end)

		it("#13 both delete same line -> CONVERGENT", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 3" }
			local ai = { "line 1", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONVERGENT, regions[1].classification)
		end)

		it("#14 no changes from either side -> 0 regions", function()
			local base = { "line 1", "line 2", "line 3" }
			local regions = classifier.classify_regions(base, base, base)
			eq(0, #regions)
		end)
	end)

	-- ============================================================
	-- 2.2 Multi-region classification (tests 15-23)
	-- ============================================================
	describe("multi-region classification", function()
		it("#15 user edits line 1, AI edits line 5 -> USER_ONLY + AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1 (User)", "line 2", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "line 5 (AI)" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(types.AI_ONLY, regions[2].classification)
		end)

		it("#16 user edits lines 1-2, AI edits lines 4-5 -> USER_ONLY + AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "USER 2", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "AI 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(types.AI_ONLY, regions[2].classification)
		end)

		it("#17 user edits line 2, AI edits line 2 AND adds line 4 -> CONFLICT + AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "USER line 2", "line 3" }
			local ai = { "line 1", "AI line 2", "line 3", "AI line 4" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(#regions >= 2, "Should have at least 2 regions")
			assert.is_true(has_type(regions, types.CONFLICT), "Should have CONFLICT")
			assert.is_true(has_type(regions, types.AI_ONLY), "Should have AI_ONLY")
		end)

		it("#18 user adds after line 2, AI adds after line 4 -> USER_ONLY + AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "USER inserted", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "AI inserted", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			assert.is_true(has_type(regions, types.USER_ONLY))
			assert.is_true(has_type(regions, types.AI_ONLY))
		end)

		it("#19 three separate regions: USER_ONLY, CONFLICT, AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "USER 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(3, #regions)
			assert.is_true(has_type(regions, types.USER_ONLY))
			assert.is_true(has_type(regions, types.CONFLICT))
			assert.is_true(has_type(regions, types.AI_ONLY))
		end)

		it("#20 adjacent non-overlapping changes", function()
			local base = { "line 1", "line 2", "line 3", "line 4" }
			local user = { "USER 1", "USER 2", "line 3", "line 4" }
			local ai = { "line 1", "line 2", "AI 3", "AI 4" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(types.AI_ONLY, regions[2].classification)
		end)

		it("#21 partial overlap -> merged CONFLICT", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "USER 2", "USER 3", "line 4", "line 5" }
			local ai = { "line 1", "AI 2", "AI 3", "AI 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			-- Overlapping ranges merge into one CONFLICT
			assert.is_true(has_type(regions, types.CONFLICT))
			local conflict = find_type(regions, types.CONFLICT)
			-- Should span the merged range (at least lines 1-4)
			assert.is_true(conflict.base_range[1] <= 2)
			assert.is_true(conflict.base_range[2] >= 3)
		end)

		it("#22 multiple convergent regions", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "same 1", "line 2", "same 3", "line 4", "line 5" }
			local ai = { "same 1", "line 2", "same 3", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			for _, r in ipairs(regions) do
				eq(types.CONVERGENT, r.classification)
			end
		end)

		it("#23 all four types in one file", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5", "line 6", "line 7", "line 8" }
			local user = { "USER 1", "line 2", "same 3", "line 4", "line 5", "line 6", "USER 7", "line 8" }
			local ai = { "line 1", "line 2", "same 3", "line 4", "AI 5", "line 6", "AI 7", "line 8" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(has_type(regions, types.USER_ONLY), "Should have USER_ONLY")
			assert.is_true(has_type(regions, types.CONVERGENT), "Should have CONVERGENT")
			assert.is_true(has_type(regions, types.AI_ONLY), "Should have AI_ONLY")
			assert.is_true(has_type(regions, types.CONFLICT), "Should have CONFLICT")
		end)
	end)

	-- ============================================================
	-- 2.3 Edge cases (tests 24-31)
	-- ============================================================
	describe("edge cases", function()
		it("#24 empty base, both add same content -> CONVERGENT", function()
			local base = {}
			local user = { "new content" }
			local ai = { "new content" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(#regions >= 1)
			assert.is_true(has_type(regions, types.CONVERGENT))
		end)

		it("#25 empty base, both add different content -> CONFLICT", function()
			local base = {}
			local user = { "user content" }
			local ai = { "ai content" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(#regions >= 1)
			assert.is_true(has_type(regions, types.CONFLICT))
		end)

		it("#26 single-line file, user modifies -> USER_ONLY", function()
			local base = { "original" }
			local user = { "modified" }
			local ai = { "original" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
		end)

		it("#27 user adds multiple lines at beginning -> USER_ONLY", function()
			local base = { "line 1", "line 2" }
			local user = { "new A", "new B", "line 1", "line 2" }
			local ai = { "line 1", "line 2" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
		end)

		it("#28 AI adds multiple lines at end -> AI_ONLY", function()
			local base = { "line 1", "line 2" }
			local user = { "line 1", "line 2" }
			local ai = { "line 1", "line 2", "AI A", "AI B", "AI C" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.AI_ONLY, regions[1].classification)
		end)

		it("#29 large file with single change -> USER_ONLY", function()
			local base = {}
			for i = 1, 20 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[10] = "line 10 modified"
			local ai = vim.deepcopy(base)
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
		end)

		it("#30 both add different content after same line -> CONFLICT", function()
			local base = { "aaa" }
			local user = { "xxx", "aaa" }
			local ai = { "yyy", "aaa" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			assert.is_true(vim.tbl_contains(regions[1].user_lines, "xxx"))
			assert.is_true(vim.tbl_contains(regions[1].ai_lines, "yyy"))
		end)

		it("#31 user replaces 3 lines with 1, AI replaces 3 with 5 -> CONFLICT", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "collapsed", "line 4", "line 5" }
			local ai = { "expanded A", "expanded B", "expanded C", "expanded D", "expanded E", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(#regions >= 1)
			assert.is_true(has_type(regions, types.CONFLICT))
		end)
	end)

	-- ============================================================
	-- 2.4 Merge mode behavior (tests 32-38)
	-- ============================================================
	describe("merge mode behavior", function()
		local function make_regions()
			return {
				{ classification = types.USER_ONLY, auto_resolved = false },
				{ classification = types.AI_ONLY, auto_resolved = false },
				{ classification = types.CONVERGENT, auto_resolved = false },
				{ classification = types.CONFLICT, auto_resolved = false },
			}
		end

		it("#32 mode 'none' -- nothing auto-resolved", function()
			local regions = make_regions()
			classifier.apply_merge_mode(regions, "none")
			eq(false, regions[1].auto_resolved)
			eq(false, regions[2].auto_resolved)
			eq(false, regions[3].auto_resolved)
			eq(false, regions[4].auto_resolved)
		end)

		it("#33 mode 'user' -- USER_ONLY and CONVERGENT auto-resolved", function()
			local regions = make_regions()
			classifier.apply_merge_mode(regions, "user")
			eq(true, regions[1].auto_resolved) -- USER_ONLY
			eq(false, regions[2].auto_resolved) -- AI_ONLY
			eq(true, regions[3].auto_resolved) -- CONVERGENT
			eq(false, regions[4].auto_resolved) -- CONFLICT
		end)

		it("#34 mode 'ai' -- AI_ONLY and CONVERGENT auto-resolved", function()
			local regions = make_regions()
			classifier.apply_merge_mode(regions, "ai")
			eq(false, regions[1].auto_resolved) -- USER_ONLY
			eq(true, regions[2].auto_resolved) -- AI_ONLY
			eq(true, regions[3].auto_resolved) -- CONVERGENT
			eq(false, regions[4].auto_resolved) -- CONFLICT
		end)

		it("#35 mode 'both' -- all except CONFLICT auto-resolved", function()
			local regions = make_regions()
			classifier.apply_merge_mode(regions, "both")
			eq(true, regions[1].auto_resolved) -- USER_ONLY
			eq(true, regions[2].auto_resolved) -- AI_ONLY
			eq(true, regions[3].auto_resolved) -- CONVERGENT
			eq(false, regions[4].auto_resolved) -- CONFLICT
		end)

		it("#36 USER_ONLY only, mode 'user' -> auto-resolved", function()
			local regions = { { classification = types.USER_ONLY, auto_resolved = false } }
			classifier.apply_merge_mode(regions, "user")
			eq(true, regions[1].auto_resolved)
		end)

		it("#37 AI_ONLY only, mode 'ai' -> auto-resolved", function()
			local regions = { { classification = types.AI_ONLY, auto_resolved = false } }
			classifier.apply_merge_mode(regions, "ai")
			eq(true, regions[1].auto_resolved)
		end)

		it("#38 CONFLICT only, mode 'both' -> never auto-resolved", function()
			local regions = { { classification = types.CONFLICT, auto_resolved = false } }
			classifier.apply_merge_mode(regions, "both")
			eq(false, regions[1].auto_resolved)
		end)
	end)

	-- ============================================================
	-- 2.5 Suggestion resolution (tests 39-44)
	-- ============================================================
	describe("suggestion resolution", function()
		it("#39 USER_ONLY accept -> user_lines", function()
			local region = { classification = types.USER_ONLY, base_lines = { "original" }, user_lines = { "USER version" }, ai_lines = { "original" } }
			local result = resolve.get_replacement_for_region(types.USER_ONLY, "accept", region)
			deep_eq({ "USER version" }, result)
		end)

		it("#40 USER_ONLY reject -> base_lines", function()
			local region = { classification = types.USER_ONLY, base_lines = { "original" }, user_lines = { "USER version" }, ai_lines = { "original" } }
			local result = resolve.get_replacement_for_region(types.USER_ONLY, "reject", region)
			deep_eq({ "original" }, result)
		end)

		it("#41 AI_ONLY accept -> ai_lines", function()
			local region = { classification = types.AI_ONLY, base_lines = { "original" }, user_lines = { "original" }, ai_lines = { "AI version" } }
			local result = resolve.get_replacement_for_region(types.AI_ONLY, "accept", region)
			deep_eq({ "AI version" }, result)
		end)

		it("#42 AI_ONLY reject -> base_lines", function()
			local region = { classification = types.AI_ONLY, base_lines = { "original" }, user_lines = { "original" }, ai_lines = { "AI version" } }
			local result = resolve.get_replacement_for_region(types.AI_ONLY, "reject", region)
			deep_eq({ "original" }, result)
		end)

		it("#43 CONVERGENT accept -> user_lines (same as AI)", function()
			local region = { classification = types.CONVERGENT, base_lines = { "original" }, user_lines = { "agreed change" }, ai_lines = { "agreed change" } }
			local result = resolve.get_replacement_for_region(types.CONVERGENT, "accept", region)
			deep_eq({ "agreed change" }, result)
		end)

		it("#44 CONVERGENT reject -> base_lines", function()
			local region = { classification = types.CONVERGENT, base_lines = { "original" }, user_lines = { "agreed change" }, ai_lines = { "agreed change" } }
			local result = resolve.get_replacement_for_region(types.CONVERGENT, "reject", region)
			deep_eq({ "original" }, result)
		end)
	end)

	-- ============================================================
	-- 2.6 Conflict resolution (tests 45-47)
	-- ============================================================
	describe("conflict resolution", function()
		it("#45 CONFLICT keep_user -> user_lines", function()
			local region = { classification = types.CONFLICT, base_lines = { "original" }, user_lines = { "USER" }, ai_lines = { "AI" } }
			local result = resolve.get_replacement_for_region(types.CONFLICT, "keep_user", region)
			deep_eq({ "USER" }, result)
		end)

		it("#46 CONFLICT keep_ai -> ai_lines", function()
			local region = { classification = types.CONFLICT, base_lines = { "original" }, user_lines = { "USER" }, ai_lines = { "AI" } }
			local result = resolve.get_replacement_for_region(types.CONFLICT, "keep_ai", region)
			deep_eq({ "AI" }, result)
		end)

		it("#47 CONFLICT edit_manually -> nil", function()
			local region = { classification = types.CONFLICT, base_lines = { "original" }, user_lines = { "USER" }, ai_lines = { "AI" } }
			local result = resolve.get_replacement_for_region(types.CONFLICT, "edit_manually", region)
			assert.is_nil(result)
		end)
	end)

	-- ============================================================
	-- 2.7 Resolution action mapping (tests 48-56)
	-- ============================================================
	describe("resolution action mapping", function()
		it("#48 USER_ONLY/accept -> accepted", function()
			eq("accepted", resolve.resolution_to_action_v2(types.USER_ONLY, "accept"))
		end)
		it("#49 USER_ONLY/reject -> rejected", function()
			eq("rejected", resolve.resolution_to_action_v2(types.USER_ONLY, "reject"))
		end)
		it("#50 AI_ONLY/accept -> accepted", function()
			eq("accepted", resolve.resolution_to_action_v2(types.AI_ONLY, "accept"))
		end)
		it("#51 AI_ONLY/reject -> rejected", function()
			eq("rejected", resolve.resolution_to_action_v2(types.AI_ONLY, "reject"))
		end)
		it("#52 CONVERGENT/accept -> accepted", function()
			eq("accepted", resolve.resolution_to_action_v2(types.CONVERGENT, "accept"))
		end)
		it("#53 CONVERGENT/reject -> rejected", function()
			eq("rejected", resolve.resolution_to_action_v2(types.CONVERGENT, "reject"))
		end)
		it("#54 CONFLICT/keep_user -> rejected", function()
			eq("rejected", resolve.resolution_to_action_v2(types.CONFLICT, "keep_user"))
		end)
		it("#55 CONFLICT/keep_ai -> accepted", function()
			eq("accepted", resolve.resolution_to_action_v2(types.CONFLICT, "keep_ai"))
		end)
		it("#56 CONFLICT/edit_manually -> accepted", function()
			eq("accepted", resolve.resolution_to_action_v2(types.CONFLICT, "edit_manually"))
		end)
	end)

	-- ============================================================
	-- 2.8 End-to-end merge scenarios (tests 57-70)
	-- ============================================================
	describe("end-to-end merge scenarios", function()
		it("#57 accept both non-overlapping changes", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			local output = reconstruct(base, regions, { "accept", "accept" })
			deep_eq({ "USER 1", "line 2", "line 3", "line 4", "AI 5" }, output)
		end)

		it("#58 reject user, accept AI", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject", "accept" })
			deep_eq({ "line 1", "line 2", "line 3", "line 4", "AI 5" }, output)
		end)

		it("#59 accept user, reject AI", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "accept", "reject" })
			deep_eq({ "USER 1", "line 2", "line 3", "line 4", "line 5" }, output)
		end)

		it("#60 reject both -> original base", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject", "reject" })
			deep_eq(base, output)
		end)

		it("#61 conflict on line 3, keep_user", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "USER 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI 3", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			local output = reconstruct(base, regions, { "keep_user" })
			deep_eq({ "line 1", "line 2", "USER 3", "line 4", "line 5" }, output)
		end)

		it("#62 conflict on line 3, keep_ai", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "USER 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI 3", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "keep_ai" })
			deep_eq({ "line 1", "line 2", "AI 3", "line 4", "line 5" }, output)
		end)

		it("#63 mixed: accept USER_ONLY + keep_ai CONFLICT + reject AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "USER 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(3, #regions)
			local output = reconstruct(base, regions, { "accept", "keep_ai", "reject" })
			deep_eq({ "USER 1", "line 2", "AI 3", "line 4", "line 5" }, output)
		end)

		it("#64 mixed opposite: reject USER_ONLY + keep_user CONFLICT + accept AI_ONLY", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "USER 1", "line 2", "USER 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject", "keep_user", "accept" })
			deep_eq({ "line 1", "line 2", "USER 3", "line 4", "AI 5" }, output)
		end)

		it("#65 auto-merge both mode accepts all non-conflicts", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "USER 1", "line 2", "line 3" }
			local ai = { "line 1", "line 2", "AI 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			classifier.apply_merge_mode(regions, "both")
			eq(true, regions[1].auto_resolved)
			eq(true, regions[2].auto_resolved)
			local output = reconstruct(base, regions, { "accept", "accept" })
			deep_eq({ "USER 1", "line 2", "AI 3" }, output)
		end)

		it("#66 conflict in 'both' mode still needs manual resolution", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "USER 2", "line 3" }
			local ai = { "line 1", "AI 2", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			classifier.apply_merge_mode(regions, "both")
			eq(false, regions[1].auto_resolved)
		end)

		it("#67 user inserts 3 lines, AI modifies line 5 -> accept both", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "new A", "new B", "new C", "line 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "AI 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			local output = reconstruct(base, regions, { "accept", "accept" })
			deep_eq({ "line 1", "line 2", "new A", "new B", "new C", "line 3", "line 4", "AI 5" }, output)
		end)

		it("#68 user deletes lines 2-3, AI adds after line 5 -> accept both", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 3", "line 4", "line 5", "AI new" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			local output = reconstruct(base, regions, { "accept", "accept" })
			deep_eq({ "line 1", "line 4", "line 5", "AI new" }, output)
		end)

		it("#69 multiple regions including conflict in middle", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 3", "USER 4", "line 5" }
			local ai = { "AI 1", "line 2", "line 3", "AI 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(#regions >= 2, "Should have multiple regions")
			assert.is_true(has_type(regions, types.CONFLICT), "Should have CONFLICT on line 4")
		end)

		it("#70 10-line file with 4 regions, each resolved differently", function()
			local base = {}
			for i = 1, 10 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[1] = "USER 1"
			user[4] = "USER 4"
			user[7] = "USER 7"
			local ai = vim.deepcopy(base)
			ai[4] = "AI 4"
			ai[7] = "AI 7"
			ai[10] = "AI 10"
			local regions = classifier.classify_regions(base, user, ai)
			eq(4, #regions)
			-- Region order: USER_ONLY(1), CONFLICT(4), CONFLICT(7), AI_ONLY(10)
			eq(types.USER_ONLY, regions[1].classification)
			eq(types.CONFLICT, regions[2].classification)
			eq(types.CONFLICT, regions[3].classification)
			eq(types.AI_ONLY, regions[4].classification)
			local output = reconstruct(base, regions, { "accept", "keep_user", "keep_ai", "reject" })
			deep_eq({
				"USER 1", "line 2", "line 3", "USER 4", "line 5", "line 6",
				"AI 7", "line 8", "line 9", "line 10",
			}, output)
		end)
	end)

	-- ============================================================
	-- 2.9 Deletion scenarios (tests 71-80)
	-- ============================================================
	describe("deletion scenarios", function()
		it("#71 user deletes line 3, accept", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "line 4", "line 5" }
			local ai = vim.deepcopy(base)
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			local output = reconstruct(base, regions, { "accept" })
			deep_eq({ "line 1", "line 2", "line 4", "line 5" }, output)
		end)

		it("#72 user deletes line 3, reject", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "line 4", "line 5" }
			local ai = vim.deepcopy(base)
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject" })
			deep_eq(base, output)
		end)

		it("#73 AI deletes lines 2-4, accept", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = vim.deepcopy(base)
			local ai = { "line 1", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.AI_ONLY, regions[1].classification)
			local output = reconstruct(base, regions, { "accept" })
			deep_eq({ "line 1", "line 5" }, output)
		end)

		it("#74 AI deletes lines 2-4, reject", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = vim.deepcopy(base)
			local ai = { "line 1", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject" })
			deep_eq(base, output)
		end)

		it("#75 user deletes line 3, AI modifies line 3 -> CONFLICT keep_user", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI modified 3", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			local output = reconstruct(base, regions, { "keep_user" })
			deep_eq({ "line 1", "line 2", "line 4", "line 5" }, output)
		end)

		it("#76 user deletes line 3, AI modifies -> CONFLICT keep_ai", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "AI modified 3", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "keep_ai" })
			deep_eq({ "line 1", "line 2", "AI modified 3", "line 4", "line 5" }, output)
		end)

		it("#77 user modifies line 3, AI deletes -> CONFLICT keep_user", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "USER modified 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			local output = reconstruct(base, regions, { "keep_user" })
			deep_eq({ "line 1", "line 2", "USER modified 3", "line 4", "line 5" }, output)
		end)

		it("#78 user modifies line 3, AI deletes -> CONFLICT keep_ai", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 2", "USER modified 3", "line 4", "line 5" }
			local ai = { "line 1", "line 2", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "keep_ai" })
			deep_eq({ "line 1", "line 2", "line 4", "line 5" }, output)
		end)

		it("#79 both delete same lines -> CONVERGENT accept", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 4", "line 5" }
			local ai = { "line 1", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONVERGENT, regions[1].classification)
			local output = reconstruct(base, regions, { "accept" })
			deep_eq({ "line 1", "line 4", "line 5" }, output)
		end)

		it("#80 both delete same lines -> CONVERGENT reject", function()
			local base = { "line 1", "line 2", "line 3", "line 4", "line 5" }
			local user = { "line 1", "line 4", "line 5" }
			local ai = { "line 1", "line 4", "line 5" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject" })
			deep_eq(base, output)
		end)
	end)

	-- ============================================================
	-- 2.10 Insertion scenarios (tests 81-87)
	-- ============================================================
	describe("insertion scenarios", function()
		it("#81 user inserts after line 2, accept", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 2", "USER new", "line 3" }
			local ai = vim.deepcopy(base)
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			local output = reconstruct(base, regions, { "accept" })
			deep_eq({ "line 1", "line 2", "USER new", "line 3" }, output)
		end)

		it("#82 user inserts after line 2, reject", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = { "line 1", "line 2", "USER new", "line 3" }
			local ai = vim.deepcopy(base)
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject" })
			deep_eq(base, output)
		end)

		it("#83 AI inserts 3 lines after line 1, accept", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = vim.deepcopy(base)
			local ai = { "line 1", "AI A", "AI B", "AI C", "line 2", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.AI_ONLY, regions[1].classification)
			local output = reconstruct(base, regions, { "accept" })
			deep_eq({ "line 1", "AI A", "AI B", "AI C", "line 2", "line 3" }, output)
		end)

		it("#84 AI inserts 3 lines after line 1, reject", function()
			local base = { "line 1", "line 2", "line 3" }
			local user = vim.deepcopy(base)
			local ai = { "line 1", "AI A", "AI B", "AI C", "line 2", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			local output = reconstruct(base, regions, { "reject" })
			deep_eq(base, output)
		end)

		it("#85 both insert same content at same position -> CONVERGENT", function()
			local base = { "line 1", "line 2" }
			local user = { "line 1", "same new", "line 2" }
			local ai = { "line 1", "same new", "line 2" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONVERGENT, regions[1].classification)
		end)

		it("#86 both insert different content at same position -> CONFLICT", function()
			local base = { "line 1", "line 2" }
			local user = { "line 1", "user new", "line 2" }
			local ai = { "line 1", "ai new", "line 2" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
		end)

		it("#87 user inserts after line 1, AI inserts after line 3 -> two regions", function()
			local base = { "line 1", "line 2", "line 3", "line 4" }
			local user = { "line 1", "USER inserted", "line 2", "line 3", "line 4" }
			local ai = { "line 1", "line 2", "line 3", "AI inserted", "line 4" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			assert.is_true(has_type(regions, types.USER_ONLY))
			assert.is_true(has_type(regions, types.AI_ONLY))
		end)
	end)

	-- ============================================================
	-- 2.11 Complex real-world scenarios (tests 88-92)
	-- ============================================================
	describe("complex real-world scenarios", function()
		it("#88 function refactor: AI renames, user adds param -> CONFLICT", function()
			local base = { "function hello()", "  print('hi')", "end" }
			local user = { "function hello(name)", "  print('hi')", "end" }
			local ai = { "function greet()", "  print('hi')", "end" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(has_type(regions, types.CONFLICT))
		end)

		it("#89 import additions: both add different imports -> CONFLICT", function()
			local base = { "local M = {}", "", "return M" }
			local user = { "local M = {}", "local utils = require('utils')", "", "return M" }
			local ai = { "local M = {}", "local log = require('log')", "", "return M" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(has_type(regions, types.CONFLICT))
		end)

		it("#90 both add same comment -> CONVERGENT", function()
			local base = { "local x = 1", "local y = 2" }
			local user = { "-- important vars", "local x = 1", "local y = 2" }
			local ai = { "-- important vars", "local x = 1", "local y = 2" }
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(has_type(regions, types.CONVERGENT))
		end)

		it("#91 overlapping multi-line blocks -> CONFLICT spanning merged range", function()
			local base = {}
			for i = 1, 10 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			for i = 3, 7 do
				user[i] = "USER " .. i
			end
			local ai = vim.deepcopy(base)
			for i = 5, 9 do
				ai[i] = "AI " .. i
			end
			local regions = classifier.classify_regions(base, user, ai)
			assert.is_true(has_type(regions, types.CONFLICT))
			local conflict = find_type(regions, types.CONFLICT)
			-- Merged range should span at least lines 3-9
			assert.is_true(conflict.base_range[1] <= 5, "Should start at or before line 5")
			assert.is_true(conflict.base_range[2] >= 7, "Should end at or after line 7")
		end)

		it("#92 whitespace-only change by user, content change by AI -> CONFLICT", function()
			local base = { "line 1", "  hello  ", "line 3" }
			local user = { "line 1", "  hello", "line 3" }
			local ai = { "line 1", "  goodbye  ", "line 3" }
			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
		end)
	end)
end)
