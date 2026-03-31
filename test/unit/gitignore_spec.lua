-- test/unit/gitignore_spec.lua
local worktree = require("vibe.git.worktree")
local is_true = assert.is_true
local is_false = assert.is_false

describe("Gitignore", function()
    local tmpdir

    before_each(function()
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
    end)

    after_each(function()
        vim.fn.delete(tmpdir, "rf")
    end)

    describe("parse_gitignore", function()
        it("returns patterns from a valid .gitignore", function()
            vim.fn.writefile({ "target", "*.o", "build/" }, tmpdir .. "/.gitignore")
            local patterns = worktree.parse_gitignore(tmpdir)
            assert.is_not_nil(patterns)
            assert.are.equal(3, #patterns)
            assert.are.equal("target", patterns[1])
            assert.are.equal("*.o", patterns[2])
            assert.are.equal("build/", patterns[3])
        end)

        it("skips comments and blank lines", function()
            vim.fn.writefile({ "# a comment", "", "target", "  ", "*.o" }, tmpdir .. "/.gitignore")
            local patterns = worktree.parse_gitignore(tmpdir)
            assert.is_not_nil(patterns)
            assert.are.equal(2, #patterns)
            assert.are.equal("target", patterns[1])
            assert.are.equal("*.o", patterns[2])
        end)

        it("skips negation patterns", function()
            vim.fn.writefile({ "target", "!important.txt", "*.o" }, tmpdir .. "/.gitignore")
            local patterns = worktree.parse_gitignore(tmpdir)
            assert.is_not_nil(patterns)
            assert.are.equal(2, #patterns)
            assert.are.equal("target", patterns[1])
            assert.are.equal("*.o", patterns[2])
        end)

        it("returns nil for missing file", function()
            local patterns = worktree.parse_gitignore(tmpdir .. "/nonexistent")
            assert.is_nil(patterns)
        end)

        it("returns nil for empty .gitignore", function()
            vim.fn.writefile({ "", "# only comments", "  " }, tmpdir .. "/.gitignore")
            local patterns = worktree.parse_gitignore(tmpdir)
            assert.is_nil(patterns)
        end)
    end)

    describe("matches_gitignore", function()
        it("handles unanchored simple names", function()
            local patterns = { "target" }
            is_true(worktree.matches_gitignore("target/debug/app", patterns))
            is_true(worktree.matches_gitignore("rust/target/debug/app", patterns))
            is_true(worktree.matches_gitignore("target", patterns))
        end)

        it("handles unanchored globs", function()
            local patterns = { "*.o" }
            is_true(worktree.matches_gitignore("build/foo.o", patterns))
            is_true(worktree.matches_gitignore("src/bar.o", patterns))
            is_true(worktree.matches_gitignore("foo.o", patterns))
            is_false(worktree.matches_gitignore("foo.obj", patterns))
        end)

        it("handles anchored patterns with /", function()
            local patterns = { "rust/target" }
            is_true(worktree.matches_gitignore("rust/target/debug/app", patterns))
            is_false(worktree.matches_gitignore("other/rust/target/app", patterns))
        end)

        it("handles trailing slash (directory marker)", function()
            local patterns = { "target/" }
            is_true(worktree.matches_gitignore("target/debug/app", patterns))
            is_true(worktree.matches_gitignore("rust/target/debug/app", patterns))
        end)

        it("does not match partial names", function()
            local patterns = { "tar" }
            is_false(worktree.matches_gitignore("target/foo", patterns))
            is_true(worktree.matches_gitignore("tar/foo", patterns))
            is_true(worktree.matches_gitignore("tar", patterns))
        end)

        it("handles ** patterns", function()
            local patterns = { "**/build" }
            is_true(worktree.matches_gitignore("deep/nested/build", patterns))
            is_true(worktree.matches_gitignore("build", patterns))
        end)

        it("returns false when no patterns match", function()
            local patterns = { "target", "*.o" }
            is_false(worktree.matches_gitignore("src/main.rs", patterns))
            is_false(worktree.matches_gitignore("README.md", patterns))
        end)

        it("handles multiple patterns", function()
            local patterns = { "target", "*.o", "build/" }
            is_true(worktree.matches_gitignore("target/debug/app", patterns))
            is_true(worktree.matches_gitignore("src/foo.o", patterns))
            is_true(worktree.matches_gitignore("build/output.bin", patterns))
            is_false(worktree.matches_gitignore("src/main.rs", patterns))
        end)
    end)
end)
