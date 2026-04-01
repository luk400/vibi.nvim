-- test/unit/highlights_spec.lua
local config = require("vibe.config")
local highlights = require("vibe.highlights")

describe("highlights module", function()
    before_each(function()
        config.setup({})
    end)

    it("applies default highlights without error", function()
        assert.has_no.errors(function()
            highlights.apply()
        end)
    end)

    it("sets VibeRegionSuggestion with default yellow fg", function()
        highlights.apply()
        local hl = vim.api.nvim_get_hl(0, { name = "VibeRegionSuggestion" })
        -- #FCC474 = rgb(252, 196, 116) = 0xFCC474 = 16565364
        assert.equals(0xFCC474, hl.fg)
        assert.is_true(hl.bold)
    end)

    it("respects custom theme colors", function()
        config.setup({ highlights = { theme = { suggestion_fg = "#abcdef" } } })
        highlights.apply()
        local hl = vim.api.nvim_get_hl(0, { name = "VibeRegionSuggestion" })
        assert.equals(0xABCDEF, hl.fg)
    end)

    it("applies overrides over theme-derived values", function()
        config.setup({
            highlights = {
                overrides = {
                    VibeRegionSuggestion = { fg = "#112233", italic = true },
                },
            },
        })
        highlights.apply()
        local hl = vim.api.nvim_get_hl(0, { name = "VibeRegionSuggestion" })
        assert.equals(0x112233, hl.fg)
        assert.is_true(hl.italic)
    end)

    it("sets convergent highlight with default green fg", function()
        highlights.apply()
        local hl = vim.api.nvim_get_hl(0, { name = "VibeRegionConvergent" })
        assert.equals(0x69DB7C, hl.fg)
        assert.is_true(hl.bold)
    end)

    it("sets conflict bg highlight", function()
        highlights.apply()
        local hl = vim.api.nvim_get_hl(0, { name = "VibeRegionConflictBg" })
        assert.equals(0x3a1a1a, hl.bg)
    end)

    it("sets delete sentinel with conflict bg and delete fg", function()
        highlights.apply()
        local hl = vim.api.nvim_get_hl(0, { name = "VibeDeleteSentinel" })
        assert.equals(0xFF6B6B, hl.fg)
        assert.equals(0x3a1a1a, hl.bg)
    end)
end)
