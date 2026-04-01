-- test/unit/rename_spec.lua
local terminal = require("vibe.terminal")
local git = require("vibe.git")
local status = require("vibe.status")

describe("VibeRename", function()
    before_each(function()
        -- Register commands via setup
        require("vibe").setup({ quit_protection = false, keymap = false })
        terminal.sessions = {}
        terminal.current_session = nil
        git.worktrees = {}
        status.last_activity = {}
    end)

    -- Backward-compatible 2-arg tests
    it("moves session from old key to new key", function()
        terminal.sessions["old"] = { name = "old", bufnr = -1 }
        vim.cmd("VibeRename old new")
        assert.is_nil(terminal.sessions["old"])
        assert.is_not_nil(terminal.sessions["new"])
    end)

    it("updates the name field on the session object", function()
        terminal.sessions["old"] = { name = "old", bufnr = -1 }
        vim.cmd("VibeRename old new")
        assert.equals("new", terminal.sessions["new"].name)
    end)

    it("updates current_session if it was the renamed one", function()
        terminal.sessions["old"] = { name = "old", bufnr = -1 }
        terminal.current_session = "old"
        vim.cmd("VibeRename old new")
        assert.equals("new", terminal.current_session)
    end)

    it("rejects rename to existing session name", function()
        terminal.sessions["a"] = { name = "a", bufnr = -1 }
        terminal.sessions["b"] = { name = "b", bufnr = -1 }
        pcall(vim.cmd, "VibeRename a b")
        assert.is_not_nil(terminal.sessions["a"]) -- unchanged
        assert.is_not_nil(terminal.sessions["b"]) -- unchanged
    end)

    -- 1-arg: rename current session
    it("renames current session with single arg", function()
        terminal.sessions["current"] = { name = "current", bufnr = -1 }
        terminal.current_session = "current"
        vim.cmd("VibeRename newname")
        assert.is_nil(terminal.sessions["current"])
        assert.is_not_nil(terminal.sessions["newname"])
        assert.equals("newname", terminal.sessions["newname"].name)
        assert.equals("newname", terminal.current_session)
    end)

    it("errors with single arg when no current session", function()
        local ok = pcall(vim.cmd, "VibeRename newname")
        -- Should error (no current session), not create anything
        assert.is_nil(terminal.sessions["newname"])
    end)

    -- terminal.rename() direct tests
    describe("terminal.rename()", function()
        it("returns false for non-existent session", function()
            local ok, err = terminal.rename("nonexistent", "new")
            assert.is_false(ok)
            assert.matches("not found", err)
        end)

        it("returns false for name collision", function()
            terminal.sessions["a"] = { name = "a", bufnr = -1 }
            terminal.sessions["b"] = { name = "b", bufnr = -1 }
            local ok, err = terminal.rename("a", "b")
            assert.is_false(ok)
            assert.matches("already exists", err)
        end)

        it("migrates status activity tracking", function()
            terminal.sessions["old"] = { name = "old", bufnr = -1 }
            status.last_activity["old"] = 12345
            local ok = terminal.rename("old", "new")
            assert.is_true(ok)
            assert.is_nil(status.last_activity["old"])
            assert.equals(12345, status.last_activity["new"])
        end)

        it("updates git worktree name", function()
            local wt_path = "/tmp/test-worktree"
            terminal.sessions["old"] = { name = "old", bufnr = -1, worktree_path = wt_path }
            git.worktrees[wt_path] = { name = "old" }
            local ok = terminal.rename("old", "new")
            assert.is_true(ok)
            assert.equals("new", git.worktrees[wt_path].name)
        end)

        it("does not touch current_session if not the renamed one", function()
            terminal.sessions["a"] = { name = "a", bufnr = -1 }
            terminal.sessions["b"] = { name = "b", bufnr = -2 }
            terminal.current_session = "b"
            local ok = terminal.rename("a", "c")
            assert.is_true(ok)
            assert.equals("b", terminal.current_session)
        end)
    end)
end)
