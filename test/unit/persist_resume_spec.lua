local git = require("vibe.git")
local worktree = require("vibe.git.worktree")
local persist = require("vibe.persist")
local config = require("vibe.config")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Persist and resume cycle", function()
    local custom_dir

    before_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end

        custom_dir = vim.fn.tempname() .. "-persist-resume"
        vim.fn.mkdir(custom_dir, "p")
        config.setup({
            quit_protection = false,
            worktree = {
                worktree_dir = custom_dir,
            },
        })
    end)

    after_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
        if vim.fn.isdirectory(custom_dir) == 1 then
            vim.fn.delete(custom_dir, "rf")
        end
        config.setup({})
        helpers.cleanup_all()
    end)

    it("full persist/resume cycle preserves addressed hunks", function()
        local repo_path = helpers.create_test_repo("persist-cycle", {
            ["test.txt"] = "line 1\nline 2\nline 3",
        })

        -- Step 1: create worktree, AI modifies
        local info = git.create_worktree("persist-cycle-sess", repo_path)
        assert.is_not_nil(info)

        helpers.write_file(info.worktree_path .. "/test.txt", "AI line 1\nline 2\nAI line 3")

        -- Step 2: accept file, mark hunk addressed
        local user_file = info.repo_root .. "/test.txt"
        local hunks = git.get_worktree_file_hunks(info.worktree_path, "test.txt", user_file)
        assert.is_true(#hunks >= 1)

        git.accept_file_from_worktree(info.worktree_path, "test.txt")
        git.mark_hunk_addressed(info.worktree_path, "test.txt", hunks[1], "accepted")

        local worktree_path = info.worktree_path

        -- Step 3: verify persistence happened
        local sessions = persist.load_sessions()
        local found = false
        for _, s in ipairs(sessions) do
            if s.worktree_path == worktree_path then
                found = true
                assert.is_not_nil(s.addressed_hunks, "Addressed hunks should be persisted")
                assert.is_true(#s.addressed_hunks >= 1, "Should have at least 1 addressed hunk")
                break
            end
        end
        assert.is_true(found, "Session should be found in persisted data")

        -- Step 4: clear in-memory state (simulate restart)
        for k in pairs(worktree.worktrees) do worktree.worktrees[k] = nil end

        -- Step 5: load sessions and verify
        local loaded = persist.load_sessions()
        local loaded_session = nil
        for _, s in ipairs(loaded) do
            if s.worktree_path == worktree_path then
                loaded_session = s
                break
            end
        end
        assert.is_not_nil(loaded_session)
        assert.is_not_nil(loaded_session.addressed_hunks)
        assert.is_true(#loaded_session.addressed_hunks >= 1)

        -- Step 6: scan for worktrees (rediscovery)
        git.scan_for_vibe_worktrees()
        local restored = git.worktrees[worktree_path]
        assert.is_not_nil(restored, "Worktree should be rediscovered after scan")

        -- Step 7: addressed hunks should be restored
        assert.is_not_nil(restored.addressed_hunks)
        assert.is_true(#restored.addressed_hunks >= 1, "Addressed hunks should be restored from persistence")
    end)
end)
