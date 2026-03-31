-- test/unit/sync_spec.lua
-- Tests for sync_local_to_worktree
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal
local is_true = assert.is_true

describe("sync_local_to_worktree", function()
    before_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
    end)

    after_each(function()
        helpers.cleanup_all()
        require("vibe.config").setup({})
    end)

    it("syncs modified tracked file", function()
        local repo_path = helpers.create_test_repo("sync-modified", {
            ["app.js"] = "original content",
        })

        local info = git.create_worktree("sync-mod-test", repo_path)
        assert.is_not_nil(info)

        -- Modify file locally after worktree creation
        helpers.write_file(repo_path .. "/app.js", "updated content")

        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok, "sync should succeed")
        assert.is_nil(err)
        eq(1, count, "should sync 1 file")

        local wt_content = table.concat(vim.fn.readfile(info.worktree_path .. "/app.js"), "\n")
        eq("updated content", wt_content, "worktree should have updated content")
    end)

    it("syncs new tracked file not in worktree", function()
        local repo_path = helpers.create_test_repo("sync-new-tracked", {
            ["existing.txt"] = "existing",
        })

        local info = git.create_worktree("sync-new-test", repo_path)
        assert.is_not_nil(info)

        -- Add and commit a new file in the repo root
        helpers.write_file(repo_path .. "/new_file.txt", "new file content")
        helpers.git_cmd({ "add", "new_file.txt" }, { cwd = repo_path })
        helpers.git_cmd({ "commit", "-m", "add new file" }, { cwd = repo_path })

        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok, "sync should succeed")
        assert.is_nil(err)
        eq(1, count, "should sync 1 file")

        eq(1, vim.fn.filereadable(info.worktree_path .. "/new_file.txt"), "new file should exist in worktree")
        local content = table.concat(vim.fn.readfile(info.worktree_path .. "/new_file.txt"), "\n")
        eq("new file content", content)
    end)

    it("skips identical files", function()
        local repo_path = helpers.create_test_repo("sync-identical", {
            ["app.js"] = "same content",
            ["lib.js"] = "lib content",
        })

        local info = git.create_worktree("sync-identical-test", repo_path)
        assert.is_not_nil(info)

        local original_snapshot = info.snapshot_commit

        -- No local changes
        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok, "sync should succeed")
        assert.is_nil(err)
        eq(0, count, "should sync 0 files")

        -- Snapshot should be unchanged
        eq(original_snapshot, info.snapshot_commit, "snapshot_commit should not change")
    end)

    it("syncs untracked file already in worktree", function()
        local repo_path = helpers.create_test_repo("sync-untracked-present", {
            ["tracked.txt"] = "tracked",
        })

        local info = git.create_worktree("sync-untracked-test", repo_path)
        assert.is_not_nil(info)

        -- Write untracked file to both repo and worktree (simulating prior VibeCopyFiles)
        helpers.write_file(repo_path .. "/data.json", "original data")
        helpers.write_file(info.worktree_path .. "/data.json", "original data")

        -- Now modify local copy
        helpers.write_file(repo_path .. "/data.json", "updated data")

        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok, "sync should succeed")
        assert.is_nil(err)
        eq(1, count, "should sync 1 file")

        local wt_content = table.concat(vim.fn.readfile(info.worktree_path .. "/data.json"), "\n")
        eq("updated data", wt_content, "worktree should have updated untracked content")
    end)

    it("skips untracked file not yet in worktree", function()
        local repo_path = helpers.create_test_repo("sync-untracked-absent", {
            ["tracked.txt"] = "tracked",
        })

        local info = git.create_worktree("sync-untracked-new-test", repo_path)
        assert.is_not_nil(info)

        -- Add untracked file locally only (not in worktree)
        helpers.write_file(repo_path .. "/local_only.txt", "local only content")

        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok, "sync should succeed")
        assert.is_nil(err)
        eq(0, count, "should sync 0 files")

        eq(0, vim.fn.filereadable(info.worktree_path .. "/local_only.txt"),
            "untracked file should NOT appear in worktree")
    end)

    it("skips gitignored untracked file", function()
        local repo_path = helpers.create_test_repo("sync-gitignored", {
            ["tracked.txt"] = "tracked",
            [".gitignore"] = "*.log\nbuild/\n",
        })

        local info = git.create_worktree("sync-gitignored-test", repo_path)
        assert.is_not_nil(info)

        -- Add gitignored files locally
        helpers.write_file(repo_path .. "/debug.log", "log output")
        vim.fn.mkdir(repo_path .. "/build", "p")
        helpers.write_file(repo_path .. "/build/output.js", "built code")

        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok, "sync should succeed")
        assert.is_nil(err)
        eq(0, count, "should sync 0 files")

        eq(0, vim.fn.filereadable(info.worktree_path .. "/debug.log"), "gitignored file should NOT appear in worktree")
        eq(0, vim.fn.filereadable(info.worktree_path .. "/build/output.js"), "gitignored dir should NOT appear in worktree")
    end)

    it("updates snapshot_commit", function()
        local repo_path = helpers.create_test_repo("sync-snapshot", {
            ["app.js"] = "original",
        })

        local info = git.create_worktree("sync-snapshot-test", repo_path)
        assert.is_not_nil(info)

        local original_snapshot = info.snapshot_commit

        -- Modify file locally
        helpers.write_file(repo_path .. "/app.js", "changed")

        local ok = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok)

        assert.are_not.equal(original_snapshot, info.snapshot_commit, "snapshot_commit should differ after sync")
    end)

    it("clears addressed hunks for synced files only", function()
        local repo_path = helpers.create_test_repo("sync-hunks", {
            ["file_a.js"] = "a content",
            ["file_b.js"] = "b content",
        })

        local info = git.create_worktree("sync-hunks-test", repo_path)
        assert.is_not_nil(info)

        -- Pre-populate addressed hunks for both files
        info.addressed_hunks = {
            { filepath = "file_a.js", hash = "aaa" },
            { filepath = "file_b.js", hash = "bbb" },
        }

        -- Only modify file_a locally
        helpers.write_file(repo_path .. "/file_a.js", "a updated")

        local ok = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok)

        -- file_a hunks should be cleared, file_b hunks preserved
        local remaining = {}
        for _, h in ipairs(info.addressed_hunks) do
            table.insert(remaining, h.filepath)
        end
        eq(false, vim.tbl_contains(remaining, "file_a.js"), "file_a.js hunks should be cleared")
        is_true(vim.tbl_contains(remaining, "file_b.js"), "file_b.js hunks should be preserved")
    end)

    it("no-op returns success", function()
        local repo_path = helpers.create_test_repo("sync-noop", {
            ["app.js"] = "content",
        })

        local info = git.create_worktree("sync-noop-test", repo_path)
        assert.is_not_nil(info)

        local ok, err, count = git.sync_local_to_worktree(info.worktree_path)
        is_true(ok)
        assert.is_nil(err)
        eq(0, count)
    end)
end)
