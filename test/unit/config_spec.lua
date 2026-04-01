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

    it("falls back to 'float' for invalid window_mode", function()
        config.setup({ window_mode = "popup" })
        assert.equals("float", config.options.window_mode)
    end)

    it("accepts valid window_mode values", function()
        for _, mode in ipairs({ "float", "split" }) do
            config.setup({ window_mode = mode })
            assert.equals(mode, config.options.window_mode)
        end
    end)

    it("deep-merges diff sub-tables", function()
        config.setup({ diff = { poll_interval = 1000 } })
        assert.equals(1000, config.options.diff.poll_interval)
        assert.equals(true, config.options.diff.enabled) -- default preserved
    end)

    it("deep-merges highlights.theme sub-tables", function()
        config.setup({ highlights = { theme = { suggestion_fg = "#ff0000" } } })
        assert.equals("#ff0000", config.options.highlights.theme.suggestion_fg)
        assert.equals("#69DB7C", config.options.highlights.theme.convergent_fg) -- default preserved
    end)

    it("validates hex color format in theme", function()
        config.setup({ highlights = { theme = { suggestion_fg = "red" } } })
        assert.equals("#FCC474", config.options.highlights.theme.suggestion_fg) -- falls back to default
    end)

    it("warns on unknown theme key", function()
        config.setup({ highlights = { theme = { foobar = "#123456" } } })
        assert.is_nil(config.options.highlights.theme.foobar)
    end)

    it("accepts valid overrides table", function()
        config.setup({ highlights = { overrides = { VibeRegionSuggestion = { fg = "#abcdef" } } } })
        assert.is_not_nil(config.options.highlights.overrides.VibeRegionSuggestion)
    end)

    it("default suggestion_fg is yellow", function()
        config.setup({})
        assert.equals("#FCC474", config.options.highlights.theme.suggestion_fg)
    end)
end)
