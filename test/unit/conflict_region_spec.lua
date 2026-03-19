-- test/unit/conflict_region_spec.lua
-- Tests verifying that conflict regions contain only the correct lines
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")
local eq = assert.are.equal

describe("conflict region boundaries", function()
	describe("single-line conflict on large file", function()
		it("produces a region spanning only 1 line", function()
			local base = {}
			for i = 1, 100 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[50] = "USER changed line 50"
			local ai = vim.deepcopy(base)
			ai[50] = "AI changed line 50"

			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			eq(50, regions[1].base_range[1])
			eq(50, regions[1].base_range[2])
			eq(1, #regions[1].user_lines)
			eq(1, #regions[1].ai_lines)
		end)

		it("multi-line conflict stays bounded", function()
			local base = {}
			for i = 1, 100 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[30] = "USER 30"
			user[31] = "USER 31"
			local ai = vim.deepcopy(base)
			ai[30] = "AI 30"
			ai[31] = "AI 31"

			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			eq(30, regions[1].base_range[1])
			eq(31, regions[1].base_range[2])
			eq(2, #regions[1].user_lines)
			eq(2, #regions[1].ai_lines)
		end)

		it("conflict at end of large file is correctly bounded", function()
			local base = {}
			for i = 1, 100 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[100] = "USER last"
			local ai = vim.deepcopy(base)
			ai[100] = "AI last"

			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			eq(100, regions[1].base_range[1])
			eq(100, regions[1].base_range[2])
		end)

		it("conflict at start of large file is correctly bounded", function()
			local base = {}
			for i = 1, 100 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[1] = "USER first"
			local ai = vim.deepcopy(base)
			ai[1] = "AI first"

			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			eq(1, regions[1].base_range[1])
			eq(1, regions[1].base_range[2])
		end)
	end)

	describe("conflict user_lines contain only conflicting lines", function()
		it("50-line file single-line conflict has 1 user/ai line", function()
			local base = {}
			for i = 1, 50 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[25] = "USER 25"
			local ai = vim.deepcopy(base)
			ai[25] = "AI 25"

			local regions = classifier.classify_regions(base, user, ai)
			eq(1, #regions)
			eq(types.CONFLICT, regions[1].classification)
			eq(1, #regions[1].user_lines)
			eq(1, #regions[1].ai_lines)
			eq("USER 25", regions[1].user_lines[1])
			eq("AI 25", regions[1].ai_lines[1])
		end)

		it("non-overlapping changes produce separate regions", function()
			local base = {}
			for i = 1, 100 do
				base[i] = "line " .. i
			end
			local user = vim.deepcopy(base)
			user[10] = "USER 10"
			local ai = vim.deepcopy(base)
			ai[90] = "AI 90"

			local regions = classifier.classify_regions(base, user, ai)
			eq(2, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(types.AI_ONLY, regions[2].classification)
		end)
	end)

	describe("_build_line_map correctness via _reconstruct_side", function()
		it("maps unchanged lines 1:1", function()
			local base = { "a", "b", "c" }
			local user = { "a", "b", "c" }
			-- No changes: user_ranges is empty, so _reconstruct_side returns base lines in range
			local result = classifier._reconstruct_side(base, user, {}, {}, 1, 3)
			eq(3, #result)
			eq("a", result[1])
			eq("b", result[2])
			eq("c", result[3])
		end)

		it("handles single-line change", function()
			local base = { "a", "b", "c" }
			local user = { "a", "B", "c" }
			local regions = classifier.classify_regions(base, user, base)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(1, #regions[1].user_lines)
			eq("B", regions[1].user_lines[1])
		end)

		it("handles insertion shifting lines", function()
			local base = { "a", "b", "c" }
			local user = { "a", "INSERTED", "b", "c" }
			local regions = classifier.classify_regions(base, user, base)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			-- The inserted line should be in user_lines
			assert.is_true(vim.tbl_contains(regions[1].user_lines, "INSERTED"))
		end)

		it("handles deletion", function()
			local base = { "a", "b", "c" }
			local user = { "a", "c" }
			local regions = classifier.classify_regions(base, user, base)
			eq(1, #regions)
			eq(types.USER_ONLY, regions[1].classification)
			eq(0, #regions[1].user_lines)
		end)
	end)
end)
