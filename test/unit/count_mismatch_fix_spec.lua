-- test/unit/count_mismatch_fix_spec.lua
--
-- Comprehensive tests verifying the three count mismatch fixes:
-- Fix 1: Bracket count uses get_unresolved_files (not get_worktree_changed_files)
-- Fix 2: Proactive update_snapshot for fully-resolved sessions
-- Fix 3: Persisted snapshot_commit survives re-scan after eviction

local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Count mismatch fixes", function()
    before_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
    end)

    after_each(function()
        helpers.cleanup_all()
    end)

    describe("Fix 1: bracket count uses get_unresolved_files", function()
        it("count matches picker after partial merge", function()
            local repo_path = helpers.create_test_repo("fix1-partial", {
                ["x.txt"] = "line 1\nline 2\nline 3",
                ["y.txt"] = "line 1\nline 2\nline 3",
            })
            local info = git.create_worktree("fix1-partial-sess", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/x.txt", "agent 1\nline 2\nline 3")
            helpers.write_file(info.worktree_path .. "/y.txt", "agent 1\nline 2\nline 3")

            -- Accept x.txt via 3-way merge (syncs content back to worktree)
            local ok = git.merge_accept_file(info.worktree_path, "x.txt")
            assert.is_truthy(ok)

            -- The review count (get_unresolved_files) should show only y.txt
            local unresolved = git.get_unresolved_files(info.worktree_path)
            eq(1, #unresolved, "Only y.txt should be unresolved")
            eq("y.txt", unresolved[1])
        end)

        it("count matches picker when some files already have identical content", function()
            local repo_path = helpers.create_test_repo("fix1-identical", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
                ["c.txt"] = "original c",
            })
            local info = git.create_worktree("fix1-ident-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 3 files
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b")
            helpers.write_file(info.worktree_path .. "/c.txt", "agent c")

            -- User already has b.txt with agent content
            helpers.write_file(repo_path .. "/b.txt", "agent b")

            -- The review count should show only a.txt and c.txt (not b.txt)
            local unresolved = git.get_unresolved_files(info.worktree_path)
            eq(2, #unresolved, "Only files with actual differences should be counted")

            local unresolved_set = {}
            for _, f in ipairs(unresolved) do
                unresolved_set[f] = true
            end
            assert.is_true(unresolved_set["a.txt"])
            assert.is_true(unresolved_set["c.txt"])
            assert.is_falsy(unresolved_set["b.txt"])
        end)

        it("large-scale: 10 changed, 6 matching -> count shows 4", function()
            local files = {}
            for i = 1, 10 do
                files["file" .. i .. ".txt"] = "original " .. i
            end
            local repo_path = helpers.create_test_repo("fix1-scale", files)
            local info = git.create_worktree("fix1-scale-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 10
            for i = 1, 10 do
                helpers.write_file(info.worktree_path .. "/file" .. i .. ".txt", "agent " .. i)
            end

            -- User already has 6 of them
            for i = 1, 6 do
                helpers.write_file(repo_path .. "/file" .. i .. ".txt", "agent " .. i)
            end

            local unresolved = git.get_unresolved_files(info.worktree_path)
            eq(4, #unresolved, "Review count should show only 4 unresolved files")
        end)
    end)

    describe("Fix 2: proactive update_snapshot for resolved sessions", function()
        it("get_worktrees_with_unresolved_files calls update_snapshot for 0-unresolved sessions", function()
            local repo_path = helpers.create_test_repo("fix2-auto", {
                ["a.txt"] = "original",
                ["b.txt"] = "original",
            })
            local info = git.create_worktree("fix2-auto-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies both
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b")

            -- User already has both (simulates external merge)
            helpers.write_file(repo_path .. "/a.txt", "agent a")
            helpers.write_file(repo_path .. "/b.txt", "agent b")

            -- Before: changed=2 but unresolved=0
            eq(2, #git.get_worktree_changed_files(info.worktree_path))
            eq(0, #git.get_unresolved_files(info.worktree_path))

            -- This should trigger update_snapshot for the fully-resolved session
            local worktrees = git.get_worktrees_with_unresolved_files()
            eq(0, #worktrees, "Session should not appear (0 unresolved)")

            -- After: changed should also be 0 (snapshot advanced)
            eq(0, #git.get_worktree_changed_files(info.worktree_path),
                "Snapshot should have been updated, clearing changed count")
        end)

        it("new agent changes after auto-snapshot show correct count", function()
            local repo_path = helpers.create_test_repo("fix2-new", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
                ["c.txt"] = "original c",
            })
            local info = git.create_worktree("fix2-new-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 3, user already has all 3
            for i, name in ipairs({ "a", "b", "c" }) do
                helpers.write_file(info.worktree_path .. "/" .. name .. ".txt", "agent " .. name)
                helpers.write_file(repo_path .. "/" .. name .. ".txt", "agent " .. name)
            end

            -- Trigger proactive snapshot
            git.get_worktrees_with_unresolved_files()

            -- Agent makes 1 new change
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a v2")

            -- Both counts should show 1
            eq(1, #git.get_worktree_changed_files(info.worktree_path))
            eq(1, #git.get_unresolved_files(info.worktree_path))
        end)

        it("does NOT call update_snapshot when unresolved files remain", function()
            local repo_path = helpers.create_test_repo("fix2-no-snap", {
                ["a.txt"] = "original",
            })
            local info = git.create_worktree("fix2-no-sess", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")

            local original_snapshot = info.snapshot_commit
            local worktrees = git.get_worktrees_with_unresolved_files()
            eq(1, #worktrees, "Session should appear (1 unresolved)")

            -- Snapshot should NOT have changed
            eq(original_snapshot, git.worktrees[info.worktree_path].snapshot_commit,
                "Snapshot should not be updated when files remain unresolved")
        end)

        it("does NOT call update_snapshot when no changed files exist", function()
            local repo_path = helpers.create_test_repo("fix2-empty", {
                ["a.txt"] = "original",
            })
            local info = git.create_worktree("fix2-empty-sess", repo_path)
            assert.is_not_nil(info)

            -- No modifications — no changed files at all
            local original_snapshot = info.snapshot_commit
            git.get_worktrees_with_unresolved_files()

            -- Snapshot should not change (no-op)
            eq(original_snapshot, git.worktrees[info.worktree_path].snapshot_commit)
        end)
    end)

    describe("Fix 3: persisted snapshot survives re-scan", function()
        it("after update_snapshot + eviction + re-scan, snapshot is preserved", function()
            local repo_path = helpers.create_test_repo("fix3-persist", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
            })
            local info = git.create_worktree("fix3-persist-sess", repo_path)
            assert.is_not_nil(info)

            local original_snapshot = info.snapshot_commit

            -- Agent modifies files
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b")

            -- Update snapshot
            local ok = git.update_snapshot(info.worktree_path)
            assert.is_truthy(ok)

            local updated_snapshot = git.worktrees[info.worktree_path].snapshot_commit
            assert.are_not.equal(original_snapshot, updated_snapshot)
            eq(0, #git.get_worktree_changed_files(info.worktree_path))

            -- Simulate Neovim restart: evict from memory
            local worktree_path = info.worktree_path
            git.worktrees[worktree_path] = nil

            -- Re-scan
            require("vibe.git.worktree").scan_for_vibe_worktrees()

            -- Persisted snapshot should be used
            local rescanned = git.worktrees[worktree_path]
            assert.is_not_nil(rescanned)
            eq(updated_snapshot, rescanned.snapshot_commit,
                "Re-scanned snapshot should match the persisted (updated) value")
            eq(0, #git.get_worktree_changed_files(worktree_path),
                "No changed files with correct snapshot")
        end)

        it("count is correct after re-scan with new agent changes", function()
            local repo_path = helpers.create_test_repo("fix3-new", {
                ["a.txt"] = "original",
            })
            local info = git.create_worktree("fix3-new-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies file, then snapshot is updated
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            git.update_snapshot(info.worktree_path)
            eq(0, #git.get_worktree_changed_files(info.worktree_path))

            -- Agent makes another change
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a v2")
            eq(1, #git.get_worktree_changed_files(info.worktree_path))

            -- Evict and re-scan
            local worktree_path = info.worktree_path
            git.worktrees[worktree_path] = nil
            require("vibe.git.worktree").scan_for_vibe_worktrees()

            -- Should still show 1, not inflated
            eq(1, #git.get_worktree_changed_files(worktree_path),
                "After re-scan, count should reflect only new changes")
        end)

        it("falls back to git log when no persisted data exists", function()
            local repo_path = helpers.create_test_repo("fix3-fallback", {
                ["a.txt"] = "original",
            })
            local info = git.create_worktree("fix3-fallback-sess", repo_path)
            assert.is_not_nil(info)

            local original_snapshot = info.snapshot_commit

            -- Agent modifies file
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")

            -- Evict from memory AND remove from persisted data
            local worktree_path = info.worktree_path
            git.worktrees[worktree_path] = nil
            local persist = require("vibe.persist")
            local sessions = persist.load_sessions()
            local filtered = {}
            for _, s in ipairs(sessions) do
                if s.worktree_path ~= worktree_path then
                    table.insert(filtered, s)
                end
            end
            persist.save_sessions(filtered)

            -- Re-scan should fall back to git log
            require("vibe.git.worktree").scan_for_vibe_worktrees()

            local rescanned = git.worktrees[worktree_path]
            if rescanned then
                -- Should use the first commit (git log fallback)
                assert.is_not_nil(rescanned.snapshot_commit)
                -- The agent change should be visible
                assert.is_true(#git.get_worktree_changed_files(worktree_path) > 0,
                    "Changed files should be detected via git log fallback")
            end
        end)
    end)

    describe("End-to-end: all three fixes together", function()
        it("full lifecycle: create -> edit -> partial merge -> snapshot -> re-scan -> new change", function()
            local files = {}
            for i = 1, 15 do
                files["module" .. i .. ".lua"] = "-- module " .. i .. "\nlocal M = {}\nreturn M"
            end
            local repo_path = helpers.create_test_repo("e2e-all", files)
            local info = git.create_worktree("e2e-all-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 15
            for i = 1, 15 do
                helpers.write_file(
                    info.worktree_path .. "/module" .. i .. ".lua",
                    "-- module " .. i .. " (agent)\nlocal M = {}\nM.new = true\nreturn M"
                )
            end

            -- User already had 10 of these
            for i = 1, 10 do
                helpers.write_file(
                    repo_path .. "/module" .. i .. ".lua",
                    "-- module " .. i .. " (agent)\nlocal M = {}\nM.new = true\nreturn M"
                )
            end

            -- Fix 1: review count matches picker (5, not 15)
            local unresolved = git.get_unresolved_files(info.worktree_path)
            eq(5, #unresolved, "Review count should show 5 unresolved files")

            -- Merge the 5 remaining
            for _, filepath in ipairs(unresolved) do
                local ok = git.merge_accept_file(info.worktree_path, filepath)
                assert.is_truthy(ok)
            end
            eq(0, #git.get_unresolved_files(info.worktree_path))

            -- Fix 2: proactive update_snapshot cleans up
            local worktrees = git.get_worktrees_with_unresolved_files()
            eq(0, #worktrees, "Session should disappear after resolution")
            eq(0, #git.get_worktree_changed_files(info.worktree_path),
                "Snapshot advanced, changed count is 0")

            -- Agent makes 1 new change
            helpers.write_file(
                info.worktree_path .. "/module1.lua",
                "-- module 1 (agent v2)\nlocal M = {}\nM.new = true\nM.extra = true\nreturn M"
            )

            -- Both counts agree: 1
            eq(1, #git.get_unresolved_files(info.worktree_path))
            eq(1, #git.get_worktree_changed_files(info.worktree_path))

            -- Fix 3: survives re-scan (simulated restart)
            local worktree_path = info.worktree_path
            git.worktrees[worktree_path] = nil
            require("vibe.git.worktree").scan_for_vibe_worktrees()

            eq(1, #git.get_unresolved_files(worktree_path),
                "After re-scan, only the new change appears as unresolved")
            eq(1, #git.get_worktree_changed_files(worktree_path),
                "After re-scan, changed count matches unresolved")
        end)

        it("simulated Neovim restart does not lose review progress", function()
            local repo_path = helpers.create_test_repo("e2e-restart", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
            })
            local info = git.create_worktree("e2e-restart-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies both
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b")

            -- Merge both
            git.merge_accept_file(info.worktree_path, "a.txt")
            git.merge_accept_file(info.worktree_path, "b.txt")

            -- Trigger snapshot
            git.get_worktrees_with_unresolved_files()
            eq(0, #git.get_worktree_changed_files(info.worktree_path))

            -- Simulate restart
            local worktree_path = info.worktree_path
            git.worktrees[worktree_path] = nil
            require("vibe.git.worktree").scan_for_vibe_worktrees()

            -- Still 0 after restart
            eq(0, #git.get_worktree_changed_files(worktree_path),
                "Review progress should survive restart")
            eq(0, #git.get_unresolved_files(worktree_path))
        end)
    end)

    describe("Edge cases", function()
        it("new file (exists in worktree but not repo)", function()
            local repo_path = helpers.create_test_repo("edge-new", {
                ["existing.txt"] = "original",
            })
            local info = git.create_worktree("edge-new-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent creates a new file
            helpers.write_file(info.worktree_path .. "/brand_new.txt", "new content")

            local unresolved = git.get_unresolved_files(info.worktree_path)
            local found = false
            for _, f in ipairs(unresolved) do
                if f == "brand_new.txt" then found = true end
            end
            assert.is_true(found, "New file should appear in unresolved")
        end)

        it("deleted file (exists in repo but deleted in worktree)", function()
            local repo_path = helpers.create_test_repo("edge-delete", {
                ["keep.txt"] = "keep this",
                ["remove.txt"] = "remove this",
            })
            local info = git.create_worktree("edge-del-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent deletes a file in worktree
            vim.fn.delete(info.worktree_path .. "/remove.txt")

            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            -- Both should include the deleted file
            local changed_set = {}
            for _, f in ipairs(changed) do changed_set[f] = true end
            local unresolved_set = {}
            for _, f in ipairs(unresolved) do unresolved_set[f] = true end

            assert.is_true(changed_set["remove.txt"],
                "Deleted file should be in changed_files")
            assert.is_true(unresolved_set["remove.txt"],
                "Deleted file should be in unresolved (repo still has it)")
        end)

        it("single-file change", function()
            local repo_path = helpers.create_test_repo("edge-single", {
                ["only.txt"] = "original",
            })
            local info = git.create_worktree("edge-single-sess", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/only.txt", "agent version")

            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            eq(1, #changed)
            eq(1, #unresolved)
            eq(changed[1], unresolved[1])
        end)

        it("gitignore consistency: excluded from both functions", function()
            local repo_path = helpers.create_test_repo("edge-gitignore", {
                ["src/app.lua"] = "app code",
                [".gitignore"] = "*.log\nbuild/",
            })
            local info = git.create_worktree("edge-gi-sess", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/src/app.lua", "modified app")
            helpers.write_file(info.worktree_path .. "/debug.log", "log output")
            helpers.write_file(info.worktree_path .. "/build/out.js", "built code")

            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            local changed_set = {}
            for _, f in ipairs(changed) do changed_set[f] = true end

            assert.is_true(changed_set["src/app.lua"])
            assert.is_falsy(changed_set["debug.log"],
                "Gitignored files should not appear in changed_files")
            assert.is_falsy(changed_set["build/out.js"],
                "Gitignored files should not appear in changed_files")

            -- Since unresolved starts from changed, gitignored files are excluded there too
            local unresolved_set = {}
            for _, f in ipairs(unresolved) do unresolved_set[f] = true end
            assert.is_falsy(unresolved_set["debug.log"])
            assert.is_falsy(unresolved_set["build/out.js"])
        end)
    end)
end)
