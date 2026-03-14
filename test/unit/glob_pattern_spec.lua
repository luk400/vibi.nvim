-- test/unit/glob_pattern_spec.lua
local worktree = require("vibe.git.worktree")
local eq = assert.are.equal
local is_true = assert.is_true
local is_false = assert.is_false

describe("Glob Pattern Matching", function()
	it("matches simple wildcard *.js", function()
		is_true(worktree.matches_patterns("app.js", { "*.js" }))
		is_true(worktree.matches_patterns("index.js", { "*.js" }))
		is_false(worktree.matches_patterns("app.ts", { "*.js" }))
	end)

	it("matches double-star recursive glob src/**/*.ts", function()
		is_true(worktree.matches_patterns("src/components/Button.ts", { "src/**/*.ts" }))
		is_true(worktree.matches_patterns("src/deep/nested/file.ts", { "src/**/*.ts" }))
		is_false(worktree.matches_patterns("lib/file.ts", { "src/**/*.ts" }))
	end)

	it("matches question mark single char ?.lua", function()
		is_true(worktree.matches_patterns("a.lua", { "?.lua" }))
		is_false(worktree.matches_patterns("ab.lua", { "?.lua" }))
	end)

	it("matches literal dots in patterns", function()
		is_true(worktree.matches_patterns("package.json", { "package.json" }))
		is_false(worktree.matches_patterns("packageXjson", { "package.json" }))
	end)

	it("returns false when no patterns match", function()
		is_false(worktree.matches_patterns("README.md", { "*.js", "*.ts" }))
	end)

	it("handles multiple patterns", function()
		is_true(worktree.matches_patterns("app.js", { "*.ts", "*.js", "*.lua" }))
		is_true(worktree.matches_patterns("init.lua", { "*.ts", "*.js", "*.lua" }))
	end)

	it("matches star without double-star for single directory level", function()
		is_true(worktree.matches_patterns("src/file.ts", { "src/*.ts" }))
		-- Single * should not cross directory boundaries
		is_false(worktree.matches_patterns("src/deep/file.ts", { "src/*.ts" }))
	end)
end)
