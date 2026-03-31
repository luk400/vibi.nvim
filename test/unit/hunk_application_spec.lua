-- test/unit/hunk_application_spec.lua
local apply = require("vibe.git.apply")
local eq = assert.are.equal

-- Helper to create a mock worktrees table
local function mock_worktrees(worktree_path, repo_root)
    local worktrees = {}
    worktrees[worktree_path] = {
        name = "test",
        worktree_path = worktree_path,
        repo_root = repo_root,
        addressed_hunks = {},
    }
    return worktrees
end

describe("Classified Resolution Application", function()
    local test_dir, worktree_path, repo_root

    before_each(function()
        test_dir = vim.fn.tempname() .. "-hunk-test"
        repo_root = test_dir .. "/repo"
        worktree_path = test_dir .. "/worktree"
        vim.fn.mkdir(repo_root, "p")
        vim.fn.mkdir(worktree_path, "p")
    end)

    after_each(function()
        vim.fn.delete(test_dir, "rf")
    end)

    describe("apply_classified_resolution", function()
        it("writes resolved lines to user file", function()
            local user_file = repo_root .. "/test.txt"
            vim.fn.writefile({ "old line 1", "old line 2" }, user_file)

            -- Also write worktree file so sync works
            vim.fn.writefile({ "old line 1", "old line 2" }, worktree_path .. "/test.txt")

            local worktrees = mock_worktrees(worktree_path, repo_root)
            local resolved_lines = { "new line 1", "new line 2", "new line 3" }

            local ok = apply.apply_classified_resolution(worktrees, worktree_path, "test.txt", resolved_lines, user_file)
            assert.is_true(ok)

            local lines = vim.fn.readfile(user_file)
            eq(3, #lines)
            eq("new line 1", lines[1])
            eq("new line 2", lines[2])
            eq("new line 3", lines[3])
        end)

        it("creates parent directory if needed", function()
            local user_file = repo_root .. "/sub/dir/test.txt"
            vim.fn.mkdir(worktree_path .. "/sub/dir", "p")
            vim.fn.writefile({ "" }, worktree_path .. "/sub/dir/test.txt")

            local worktrees = mock_worktrees(worktree_path, repo_root)
            local resolved_lines = { "content" }

            local ok = apply.apply_classified_resolution(worktrees, worktree_path, "sub/dir/test.txt", resolved_lines, user_file)
            assert.is_true(ok)

            local lines = vim.fn.readfile(user_file)
            eq(1, #lines)
            eq("content", lines[1])
        end)

        it("syncs resolved file to worktree", function()
            local user_file = repo_root .. "/test.txt"
            vim.fn.writefile({ "original" }, user_file)
            vim.fn.writefile({ "original" }, worktree_path .. "/test.txt")

            local worktrees = mock_worktrees(worktree_path, repo_root)
            local resolved_lines = { "resolved content" }

            local ok = apply.apply_classified_resolution(worktrees, worktree_path, "test.txt", resolved_lines, user_file)
            assert.is_true(ok)

            -- Worktree file should now match user file
            local wt_lines = vim.fn.readfile(worktree_path .. "/test.txt")
            eq(1, #wt_lines)
            eq("resolved content", wt_lines[1])
        end)
    end)

    describe("sync_resolved_file", function()
        it("copies user file content to worktree", function()
            local user_file = repo_root .. "/test.txt"
            vim.fn.writefile({ "user content" }, user_file)
            vim.fn.writefile({ "old worktree" }, worktree_path .. "/test.txt")

            local worktrees = mock_worktrees(worktree_path, repo_root)
            apply.sync_resolved_file(worktrees, worktree_path, "test.txt", user_file)

            local wt_lines = vim.fn.readfile(worktree_path .. "/test.txt")
            eq(1, #wt_lines)
            eq("user content", wt_lines[1])
        end)

        it("tracks manually modified files", function()
            local user_file = repo_root .. "/test.txt"
            vim.fn.writefile({ "modified by user" }, user_file)
            vim.fn.writefile({ "original worktree content" }, worktree_path .. "/test.txt")

            local worktrees = mock_worktrees(worktree_path, repo_root)
            apply.sync_resolved_file(worktrees, worktree_path, "test.txt", user_file)

            local info = worktrees[worktree_path]
            assert.is_not_nil(info.manually_modified_files)
            assert.is_true(info.manually_modified_files["test.txt"] or false)
        end)
    end)

    describe("accept_file_from_worktree", function()
        it("copies worktree file to user repo", function()
            vim.fn.writefile({ "AI content" }, worktree_path .. "/test.txt")

            local worktrees = mock_worktrees(worktree_path, repo_root)
            local ok = apply.accept_file_from_worktree(worktrees, worktree_path, "test.txt", repo_root)
            assert.is_true(ok)

            local lines = vim.fn.readfile(repo_root .. "/test.txt")
            eq(1, #lines)
            eq("AI content", lines[1])
        end)
    end)
end)
