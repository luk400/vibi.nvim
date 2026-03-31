-- test/unit/statusline_spec.lua
local vibe = require("vibe")
local terminal = require("vibe.terminal")

describe("statusline", function()
    before_each(function()
        terminal.sessions = {}
    end)

    it("returns empty string with no sessions", function()
        assert.equals("", vibe.statusline())
    end)

    it("returns formatted string with sessions", function()
        terminal.sessions["foo"] = { bufnr = -1, name = "foo" }
        local result = vibe.statusline()
        assert.truthy(result:match("Vibe"))
        assert.truthy(result:match("1"))
    end)

    it("shows active/total counts", function()
        terminal.sessions["a"] = { bufnr = -1, name = "a" }
        terminal.sessions["b"] = { bufnr = -1, name = "b" }
        local result = vibe.statusline()
        assert.truthy(result:match("%d/%d"))
    end)
end)
