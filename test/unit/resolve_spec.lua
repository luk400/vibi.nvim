-- test/unit/resolve_spec.lua
local resolve = require("vibe.resolve")
local eq = assert.are.equal

describe("Shared Resolve Module", function()
	describe("get_replacement_lines", function()
		local ours = { "user line 1", "user line 2" }
		local theirs = { "ai line 1", "ai line 2", "ai line 3" }

		it("returns ours lines for 'ours' resolution", function()
			local result = resolve.get_replacement_lines("ours", ours, theirs)
			eq(2, #result)
			eq("user line 1", result[1])
			eq("user line 2", result[2])
		end)

		it("returns theirs lines for 'theirs' resolution", function()
			local result = resolve.get_replacement_lines("theirs", ours, theirs)
			eq(3, #result)
			eq("ai line 1", result[1])
		end)

		it("returns combined lines for 'both' resolution", function()
			local result = resolve.get_replacement_lines("both", ours, theirs)
			eq(5, #result)
			eq("user line 1", result[1])
			eq("user line 2", result[2])
			eq("ai line 1", result[3])
		end)

		it("returns empty table for 'none' resolution", function()
			local result = resolve.get_replacement_lines("none", ours, theirs)
			eq(0, #result)
		end)

		it("handles empty ours", function()
			local result = resolve.get_replacement_lines("ours", {}, theirs)
			eq(0, #result)
		end)

		it("handles empty theirs", function()
			local result = resolve.get_replacement_lines("theirs", ours, {})
			eq(0, #result)
		end)

		it("handles both empty for 'both'", function()
			local result = resolve.get_replacement_lines("both", {}, {})
			eq(0, #result)
		end)
	end)

	describe("resolution_to_action", function()
		it("maps ours to rejected", function()
			eq("rejected", resolve.resolution_to_action("ours"))
		end)

		it("maps theirs to accepted", function()
			eq("accepted", resolve.resolution_to_action("theirs"))
		end)

		it("maps both to accepted", function()
			eq("accepted", resolve.resolution_to_action("both"))
		end)

		it("maps none to rejected", function()
			eq("rejected", resolve.resolution_to_action("none"))
		end)
	end)
end)
