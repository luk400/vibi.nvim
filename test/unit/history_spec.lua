-- test/unit/history_spec.lua
local history = require("vibe.history")
local config = require("vibe.config")

describe("history", function()
    local original_stdpath
    local temp_dir

    before_each(function()
        temp_dir = vim.fn.tempname() .. "-vibe-history-test"
        vim.fn.mkdir(temp_dir, "p")

        original_stdpath = vim.fn.stdpath
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.stdpath = function(what)
            if what == "data" then
                return temp_dir
            end
            return original_stdpath(what)
        end

        -- Ensure history is enabled by default
        config.setup({ history = { enabled = true, max_entries = 50 } })
    end)

    after_each(function()
        vim.fn.stdpath = original_stdpath
        vim.fn.delete(temp_dir, "rf")
    end)

    it("records and lists entries", function()
        history.record({ name = "test1", repo_root = "/tmp/repo" })
        local entries = history.list()
        assert.equals(1, #entries)
        assert.equals("test1", entries[1].name)
    end)

    it("returns entries newest-first", function()
        history.record({ name = "old", repo_root = "/r" })
        -- os.time() has second resolution; wait briefly to ensure different timestamps
        vim.wait(1100, function() return false end)
        history.record({ name = "new", repo_root = "/r" })
        local entries = history.list()
        assert.equals("new", entries[1].name)
    end)

    it("enforces max_entries cleanup", function()
        config.setup({ history = { enabled = true, max_entries = 3 } })
        for i = 1, 5 do
            -- Use unique timestamps via the filename format
            local orig_time = os.time
            ---@diagnostic disable-next-line: duplicate-set-field
            os.time = function() return orig_time() + i end
            history.record({ name = "s" .. i, repo_root = "/r" })
            os.time = orig_time
        end
        local entries = history.list()
        assert.is_true(#entries <= 3)
    end)

    it("does nothing when disabled", function()
        config.setup({ history = { enabled = false } })
        history.record({ name = "nope", repo_root = "/r" })
        local entries = history.list()
        assert.equals(0, #entries)
    end)
end)
