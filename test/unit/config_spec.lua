-- test/unit/config_spec.lua
local config = require("vibe.config")

describe("config validation", function()
    it("falls back to 'right' for invalid position", function()
        config.setup({ position = "diagonal" })
        assert.equals("right", config.options.position)
    end)

    it("falls back to 0.5 for invalid width", function()
        config.setup({ width = 5 })
        assert.equals(0.5, config.options.width)
    end)

    it("falls back to 0.8 for invalid height", function()
        config.setup({ height = -1 })
        assert.equals(0.8, config.options.height)
    end)

    it("falls back to 'rounded' for invalid border", function()
        config.setup({ border = "zigzag" })
        assert.equals("rounded", config.options.border)
    end)

    it("accepts valid position values", function()
        for _, pos in ipairs({ "right", "left", "centered", "top", "bottom" }) do
            config.setup({ position = pos })
            assert.equals(pos, config.options.position)
        end
    end)

    it("deep-merges diff sub-tables", function()
        config.setup({ diff = { poll_interval = 1000 } })
        assert.equals(1000, config.options.diff.poll_interval)
        assert.equals(true, config.options.diff.enabled) -- default preserved
    end)
end)
