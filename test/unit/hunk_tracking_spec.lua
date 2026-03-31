local git = require("vibe.git")
local persist = require("vibe.persist")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Hunk tracking", function()
    before_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
    end)

    after_each(function()
        helpers.cleanup_all()
    end)

    it("mark_hunk_addressed records the hunk", function()
        local repo_path = helpers.create_test_repo("track-mark", {
            ["test.txt"] = "line 1\nline 2\nline 3",
        })
        local info = git.create_worktree("track-mark-sess", repo_path)
        assert.is_not_nil(info)

        local hunk = {
            old_count = 1,
            new_count = 1,
            removed_lines = { "line 2" },
            added_lines = { "changed" },
        }

        git.mark_hunk_addressed(info.worktree_path, "test.txt", hunk, "accepted")

        local wt_info = git.worktrees[info.worktree_path]
        assert.is_not_nil(wt_info.addressed_hunks)
        eq(1, #wt_info.addressed_hunks)
        eq("test.txt", wt_info.addressed_hunks[1].filepath)
        eq("accepted", wt_info.addressed_hunks[1].action)
        eq(git.hunk_hash(hunk), wt_info.addressed_hunks[1].hunk_hash)
    end)

    it("is_file_fully_addressed returns false when hunks remain", function()
        local repo_path = helpers.create_test_repo("track-partial", {
            ["test.txt"] = "line 1\nline 2\nline 3\nline 4\nline 5",
        })
        local info = git.create_worktree("track-partial-sess", repo_path)
        assert.is_not_nil(info)

        -- AI makes two changes
        helpers.write_file(info.worktree_path .. "/test.txt", "changed 1\nline 2\nline 3\nline 4\nchanged 5")

        local user_file = info.repo_root .. "/test.txt"
        local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
        assert.is_true(#hunks >= 2, "Should have at least 2 hunks")

        -- Address only the first hunk
        git.mark_hunk_addressed(info.worktree_path, "test.txt", hunks[1], "accepted")

        local fully = git.is_file_fully_addressed(info.worktree_path, "test.txt")
        eq(false, fully, "File should not be fully addressed with remaining hunks")
    end)

    it("is_file_fully_addressed returns true when all addressed", function()
        local repo_path = helpers.create_test_repo("track-full", {
            ["test.txt"] = "line 1\nline 2\nline 3\nline 4\nline 5",
        })
        local info = git.create_worktree("track-full-sess", repo_path)
        assert.is_not_nil(info)

        -- AI makes two changes
        helpers.write_file(info.worktree_path .. "/test.txt", "changed 1\nline 2\nline 3\nline 4\nchanged 5")

        local user_file = info.repo_root .. "/test.txt"
        local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
        assert.is_true(#hunks >= 2)

        -- Address all hunks
        for _, hunk in ipairs(hunks) do
            git.mark_hunk_addressed(info.worktree_path, "test.txt", hunk, "accepted")
        end

        local fully = git.is_file_fully_addressed(info.worktree_path, "test.txt")
        eq(true, fully, "File should be fully addressed when all hunks marked")
    end)

    it("is_file_fully_addressed returns true when file has no diff", function()
        local repo_path = helpers.create_test_repo("track-nodiff", {
            ["test.txt"] = "line 1\nline 2",
        })
        local info = git.create_worktree("track-nodiff-sess", repo_path)
        assert.is_not_nil(info)

        -- Don't modify the worktree file - no diff
        local fully = git.is_file_fully_addressed(info.worktree_path, "test.txt")
        eq(true, fully, "File with no diff should be considered fully addressed")
    end)

    it("mark_hunk_addressed persists to disk", function()
        local repo_path = helpers.create_test_repo("track-persist", {
            ["test.txt"] = "line 1\nline 2",
        })
        local info = git.create_worktree("track-persist-sess", repo_path)
        assert.is_not_nil(info)

        local hunk = {
            old_count = 1,
            new_count = 1,
            removed_lines = { "line 2" },
            added_lines = { "changed" },
        }

        git.mark_hunk_addressed(info.worktree_path, "test.txt", hunk, "rejected")

        -- Load from disk
        local sessions = persist.load_sessions()
        local found_session = nil
        for _, s in ipairs(sessions) do
            if s.worktree_path == info.worktree_path then
                found_session = s
                break
            end
        end

        assert.is_not_nil(found_session, "Session should be persisted")
        assert.is_not_nil(found_session.addressed_hunks, "Addressed hunks should be persisted")
        eq(1, #found_session.addressed_hunks)
        eq("rejected", found_session.addressed_hunks[1].action)
    end)
end)
