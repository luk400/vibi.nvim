-- test/unit/rename_spec.lua
local terminal = require("vibe.terminal")
local git = require("vibe.git")

describe("VibeRename", function()
	before_each(function()
		-- Register commands via setup
		require("vibe").setup({ quit_protection = false, keymap = false })
		terminal.sessions = {}
		terminal.current_session = nil
	end)

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
		-- vim.notify with ERROR level causes vim.cmd to throw, so wrap in pcall
		pcall(vim.cmd, "VibeRename a b")
		assert.is_not_nil(terminal.sessions["a"]) -- unchanged
		assert.is_not_nil(terminal.sessions["b"]) -- unchanged
	end)
end)
