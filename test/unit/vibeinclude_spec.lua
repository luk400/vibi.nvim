-- test/unit/vibeinclude_spec.lua
-- Tests for .vibeinclude functionality
local file_picker = require("vibe.file_picker")
local eq = assert.are.equal
local is_true = assert.is_true

describe("vibeinclude", function()
    describe("build_vibeinclude_entries", function()
        it("converts directory selections to dir/** patterns", function()
            local selected = { "src/main.js", "src/util.js" }
            local dirs = { src = true }
            local entries = file_picker.build_vibeinclude_entries(selected, dirs)
            eq(1, #entries)
            eq("src/**", entries[1])
        end)

        it("adds exact paths for files not under a selected directory", function()
            local selected = { "config.json", "data/file.csv" }
            local dirs = {}
            local entries = file_picker.build_vibeinclude_entries(selected, dirs)
            eq(2, #entries)
            is_true(vim.tbl_contains(entries, "config.json"))
            is_true(vim.tbl_contains(entries, "data/file.csv"))
        end)

        it("handles mixed directories and individual files", function()
            local selected = { "src/main.js", "src/lib.js", "config.json" }
            local dirs = { src = true }
            local entries = file_picker.build_vibeinclude_entries(selected, dirs)
            eq(2, #entries)
            is_true(vim.tbl_contains(entries, "src/**"))
            is_true(vim.tbl_contains(entries, "config.json"))
        end)

        it("returns empty list for empty selections", function()
            local entries = file_picker.build_vibeinclude_entries({}, {})
            eq(0, #entries)
        end)

        it("handles nil dir_selections", function()
            local selected = { "file.txt" }
            local entries = file_picker.build_vibeinclude_entries(selected, nil)
            eq(1, #entries)
            eq("file.txt", entries[1])
        end)
    end)
end)
