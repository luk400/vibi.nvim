-- test/unit/count_mismatch_spec.lua
--
-- Hypothesis tests for the VibeReview count mismatch bug:
-- The bracket count in the session list (e.g., "40 files") doesn't match
-- the actual files shown in the file picker.
--
-- Root cause hypotheses:
-- H1: show_review_list uses get_worktree_changed_files() for count,
--     but the picker uses get_unresolved_files() — different functions.
-- H2: Files that exist in git diff but have identical content between
--     worktree and repo inflate the count but don't appear in picker.
-- H3: After update_snapshot(), the count resets correctly (within session).
-- H4: After scan_for_vibe_worktrees() re-discovers a worktree,
--     it ignores the persisted snapshot_commit and uses the first commit,
--     reverting any update_snapshot() advancement.
-- H5: Gitignore filtering is consistent between both functions.

local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Count mismatch investigation", function()
    before_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
    end)

    after_each(function()
        helpers.cleanup_all()
    end)

    -- H1: get_worktree_changed_files and get_unresolved_files return
    -- different results when files have been synced (identical content).
    describe("H1: count function vs picker function divergence", function()
        it("changed_files includes files where worktree == repo content", function()
            local repo_path = helpers.create_test_repo("h1-diverge", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
                ["c.txt"] = "original c",
            })
            local info = git.create_worktree("h1-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 3 files in worktree
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b")
            helpers.write_file(info.worktree_path .. "/c.txt", "agent c")

            -- Simulate: user already has file "b.txt" with agent's content
            -- (e.g., from a previous merge or manual edit)
            helpers.write_file(repo_path .. "/b.txt", "agent b")

            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            -- changed_files should include all 3 (they all differ from snapshot)
            assert.is_true(#changed >= 3,
                "get_worktree_changed_files should include all files changed since snapshot, got " .. #changed)

            -- unresolved should exclude b.txt (content matches between worktree and repo)
            -- It should only include a.txt and c.txt
            local unresolved_set = {}
            for _, f in ipairs(unresolved) do
                unresolved_set[f] = true
            end
            assert.is_true(unresolved_set["a.txt"],
                "a.txt should be unresolved (different content)")
            assert.is_true(unresolved_set["c.txt"],
                "c.txt should be unresolved (different content)")
            assert.is_falsy(unresolved_set["b.txt"],
                "b.txt should NOT be unresolved (content matches repo)")

            -- THIS IS THE BUG: count would show 3, picker would show 2
            assert.is_true(#changed > #unresolved,
                "changed_files count should be larger than unresolved count")
        end)

        it("after merge_accept_file, file disappears from unresolved but stays in changed", function()
            local repo_path = helpers.create_test_repo("h1-post-merge", {
                ["x.txt"] = "line 1\nline 2\nline 3",
                ["y.txt"] = "line 1\nline 2\nline 3",
            })
            local info = git.create_worktree("h1-merge-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies both files
            helpers.write_file(info.worktree_path .. "/x.txt", "agent 1\nline 2\nline 3")
            helpers.write_file(info.worktree_path .. "/y.txt", "agent 1\nline 2\nline 3")

            -- Both should be in changed and unresolved
            local changed_before = git.get_worktree_changed_files(info.worktree_path)
            local unresolved_before = git.get_unresolved_files(info.worktree_path)
            eq(#changed_before, #unresolved_before,
                "Before merge, counts should match")

            -- Accept file x.txt (3-way merge)
            local ok = git.merge_accept_file(info.worktree_path, "x.txt")
            assert.is_truthy(ok)

            -- After merge: x.txt content is synced (worktree = repo),
            -- but git diff still shows it as changed from snapshot
            local changed_after = git.get_worktree_changed_files(info.worktree_path)
            local unresolved_after = git.get_unresolved_files(info.worktree_path)

            -- changed_files still includes x.txt (git diff from snapshot)
            local changed_set = {}
            for _, f in ipairs(changed_after) do
                changed_set[f] = true
            end
            assert.is_true(changed_set["x.txt"],
                "x.txt should still be in changed_files after merge (git history)")

            -- unresolved should NOT include x.txt (content now matches)
            local unresolved_set = {}
            for _, f in ipairs(unresolved_after) do
                unresolved_set[f] = true
            end
            assert.is_falsy(unresolved_set["x.txt"],
                "x.txt should NOT be in unresolved after merge (content synced)")

            -- Divergence between count and picker
            assert.is_true(#changed_after > #unresolved_after,
                "After merge, changed_files > unresolved — this is the count mismatch")
        end)
    end)

    -- H2: Large-scale reproduction of the user's scenario
    -- (40 files in count, fewer in picker)
    describe("H2: large-scale count inflation", function()
        it("many changed files where some already match repo", function()
            -- Create repo with 10 files
            local files = {}
            for i = 1, 10 do
                files["file" .. i .. ".txt"] = "original " .. i
            end
            local repo_path = helpers.create_test_repo("h2-scale", files)
            local info = git.create_worktree("h2-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 10 files
            for i = 1, 10 do
                helpers.write_file(
                    info.worktree_path .. "/file" .. i .. ".txt",
                    "agent version " .. i
                )
            end

            -- User already has 6 of the 10 files with agent content
            -- (simulating previous partial merge or manual edits)
            for i = 1, 6 do
                helpers.write_file(
                    repo_path .. "/file" .. i .. ".txt",
                    "agent version " .. i
                )
            end

            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            -- Count shows 10, picker shows 4
            eq(10, #changed, "All 10 files changed since snapshot")
            eq(4, #unresolved, "Only 4 files actually differ between worktree and repo")
        end)
    end)

    -- H3: After update_snapshot, the count resets correctly
    describe("H3: update_snapshot resets count", function()
        it("count drops to 0 after update_snapshot with no pending changes", function()
            local repo_path = helpers.create_test_repo("h3-snapshot", {
                ["test.txt"] = "original",
            })
            local info = git.create_worktree("h3-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies file
            helpers.write_file(info.worktree_path .. "/test.txt", "agent version")

            local changed_before = git.get_worktree_changed_files(info.worktree_path)
            assert.is_true(#changed_before > 0, "Should have changed files")

            -- Update snapshot (advances baseline to current state)
            local ok = git.update_snapshot(info.worktree_path)
            assert.is_truthy(ok)

            -- After snapshot update, no files should be changed
            local changed_after = git.get_worktree_changed_files(info.worktree_path)
            eq(0, #changed_after,
                "After update_snapshot, changed_files should be empty")
        end)

        it("count shows only new changes after update_snapshot + new agent edit", function()
            local repo_path = helpers.create_test_repo("h3-new-change", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
                ["c.txt"] = "original c",
            })
            local info = git.create_worktree("h3-new-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 3 files
            helpers.write_file(info.worktree_path .. "/a.txt", "agent a")
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b")
            helpers.write_file(info.worktree_path .. "/c.txt", "agent c")

            -- Simulate: user accepts all, snapshot updated
            local ok = git.update_snapshot(info.worktree_path)
            assert.is_truthy(ok)

            -- Now agent makes 1 new change
            helpers.write_file(info.worktree_path .. "/b.txt", "agent b v2")

            local changed = git.get_worktree_changed_files(info.worktree_path)
            eq(1, #changed, "Only the newly changed file should appear")
            eq("b.txt", changed[1])
        end)
    end)

    -- H4: scan_for_vibe_worktrees resets snapshot_commit to first commit,
    -- ignoring persisted update_snapshot advances.
    describe("H4: scan resets snapshot after worktree eviction", function()
        it("snapshot_commit is preserved in persisted sessions", function()
            local repo_path = helpers.create_test_repo("h4-persist", {
                ["test.txt"] = "original",
            })
            local info = git.create_worktree("h4-sess", repo_path)
            assert.is_not_nil(info)

            local original_snapshot = info.snapshot_commit
            assert.is_not_nil(original_snapshot)

            -- Agent modifies file
            helpers.write_file(info.worktree_path .. "/test.txt", "agent version")

            -- Update snapshot
            local ok = git.update_snapshot(info.worktree_path)
            assert.is_truthy(ok)

            local updated_snapshot = git.worktrees[info.worktree_path].snapshot_commit
            assert.is_not_nil(updated_snapshot)
            assert.are_not.equal(original_snapshot, updated_snapshot,
                "snapshot_commit should change after update_snapshot")

            -- Verify persisted data has the updated snapshot
            local persist = require("vibe.persist")
            local sessions = persist.load_sessions()
            local found = false
            for _, s in ipairs(sessions) do
                if s.worktree_path == info.worktree_path then
                    eq(updated_snapshot, s.snapshot_commit,
                        "Persisted snapshot should match updated value")
                    found = true
                    break
                end
            end
            assert.is_true(found, "Session should be in persisted data")
        end)

        it("evicting worktree from memory and re-scanning loses updated snapshot", function()
            local repo_path = helpers.create_test_repo("h4-evict", {
                ["a.txt"] = "original a",
                ["b.txt"] = "original b",
            })
            local info = git.create_worktree("h4-evict-sess", repo_path)
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

            -- After update, no changed files
            eq(0, #git.get_worktree_changed_files(info.worktree_path))

            -- Now simulate Neovim restart: evict from memory
            local worktree_path = info.worktree_path
            git.worktrees[worktree_path] = nil

            -- Re-scan discovers the worktree
            local worktree_mod = require("vibe.git.worktree")
            worktree_mod.scan_for_vibe_worktrees()

            -- After fix: persisted snapshot should be used
            local rescanned_info = git.worktrees[worktree_path]
            assert.is_not_nil(rescanned_info, "Worktree should be re-discovered")
            eq(updated_snapshot, rescanned_info.snapshot_commit,
                "After re-scan, persisted (updated) snapshot should be used")
            local changed = git.get_worktree_changed_files(worktree_path)
            eq(0, #changed,
                "After re-scan with correct snapshot, count should be 0")
        end)
    end)

    -- H5: Gitignore filtering is consistent between both functions
    describe("H5: gitignore consistency", function()
        it("gitignored files are excluded from both changed and unresolved", function()
            local repo_path = helpers.create_test_repo("h5-gitignore", {
                ["src/app.lua"] = "app code",
                [".gitignore"] = "*.log\nbuild/",
            })
            local info = git.create_worktree("h5-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent creates files: some normal, some matching gitignore
            helpers.write_file(info.worktree_path .. "/src/app.lua", "modified app code")
            helpers.write_file(info.worktree_path .. "/debug.log", "log output")
            helpers.write_file(info.worktree_path .. "/build/output.js", "built code")
            helpers.write_file(info.worktree_path .. "/src/new.lua", "new file")

            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            local changed_set = {}
            for _, f in ipairs(changed) do
                changed_set[f] = true
            end

            local unresolved_set = {}
            for _, f in ipairs(unresolved) do
                unresolved_set[f] = true
            end

            -- Normal files should be present
            assert.is_true(changed_set["src/app.lua"],
                "src/app.lua should be in changed_files")

            -- Gitignored files should be ABSENT from both
            assert.is_falsy(changed_set["debug.log"],
                "debug.log (gitignored) should NOT be in changed_files")
            assert.is_falsy(unresolved_set["debug.log"],
                "debug.log (gitignored) should NOT be in unresolved")
            assert.is_falsy(changed_set["build/output.js"],
                "build/output.js (gitignored) should NOT be in changed_files")
            assert.is_falsy(unresolved_set["build/output.js"],
                "build/output.js (gitignored) should NOT be in unresolved")
        end)

        it("gitignored files cannot explain count mismatch", function()
            -- Since both functions filter gitignored files identically
            -- (unresolved starts from changed_files output),
            -- gitignore cannot cause count != picker discrepancy.
            local repo_path = helpers.create_test_repo("h5-no-explain", {
                ["code.lua"] = "original",
                [".gitignore"] = "*.tmp",
            })
            local info = git.create_worktree("h5-no-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent creates a gitignored file and modifies a real file
            helpers.write_file(info.worktree_path .. "/code.lua", "agent code")
            helpers.write_file(info.worktree_path .. "/temp.tmp", "temp data")

            local changed, ignored_c = git.get_worktree_changed_files(info.worktree_path)
            local unresolved, ignored_u = git.get_unresolved_files(info.worktree_path)

            -- Both should exclude temp.tmp
            -- The ignored counts should be consistent
            eq(ignored_c, ignored_u,
                "Ignored file count should be the same from both functions")

            -- With no content-matching files, counts should match
            eq(#changed, #unresolved,
                "When all changed files actually differ, counts should match")
        end)
    end)

    -- Scenario test: Full user scenario reproduction
    describe("Full scenario: user's reported bug", function()
        it("reproduces count mismatch throughout review lifecycle", function()
            -- Setup: repo with many files
            local files = {}
            for i = 1, 15 do
                files["module" .. i .. ".lua"] = "-- module " .. i .. "\nlocal M = {}\nreturn M"
            end
            local repo_path = helpers.create_test_repo("scenario", files)
            local info = git.create_worktree("scenario-sess", repo_path)
            assert.is_not_nil(info)

            -- Step 1: Agent modifies all 15 files
            for i = 1, 15 do
                helpers.write_file(
                    info.worktree_path .. "/module" .. i .. ".lua",
                    "-- module " .. i .. " (agent)\nlocal M = {}\nM.new = true\nreturn M"
                )
            end

            -- Step 2: Meanwhile, user already had 10 of these changes
            -- (perhaps from a previous merge round)
            for i = 1, 10 do
                helpers.write_file(
                    repo_path .. "/module" .. i .. ".lua",
                    "-- module " .. i .. " (agent)\nlocal M = {}\nM.new = true\nreturn M"
                )
            end

            -- Step 3: User runs :VibeReview
            local changed = git.get_worktree_changed_files(info.worktree_path)
            local unresolved = git.get_unresolved_files(info.worktree_path)

            -- BUG: count shows 15, picker shows 5
            eq(15, #changed, "Bracket count would show 15")
            eq(5, #unresolved, "Picker would show only 5 files")

            -- Step 4: User merges all 5 visible files
            for _, filepath in ipairs(unresolved) do
                local ok = git.merge_accept_file(info.worktree_path, filepath)
                assert.is_truthy(ok)
            end

            -- Step 5: Verify unresolved is now 0
            local unresolved_after = git.get_unresolved_files(info.worktree_path)
            eq(0, #unresolved_after,
                "After merging all picker files, unresolved should be 0")

            -- Step 6: This would trigger update_snapshot in the real UI
            local ok = git.update_snapshot(info.worktree_path)
            assert.is_truthy(ok)

            -- Step 7: Verify both counts are now 0
            local changed_post_snapshot = git.get_worktree_changed_files(info.worktree_path)
            local unresolved_post_snapshot = git.get_unresolved_files(info.worktree_path)
            eq(0, #changed_post_snapshot, "After update_snapshot, changed should be 0")
            eq(0, #unresolved_post_snapshot, "After update_snapshot, unresolved should be 0")

            -- Step 8: Agent makes 1 new change
            helpers.write_file(
                info.worktree_path .. "/module1.lua",
                "-- module 1 (agent v2)\nlocal M = {}\nM.new = true\nM.extra = true\nreturn M"
            )

            -- Step 9: User runs :VibeReview again
            local changed_final = git.get_worktree_changed_files(info.worktree_path)
            local unresolved_final = git.get_unresolved_files(info.worktree_path)

            -- After proper update_snapshot, count matches picker
            eq(1, #changed_final, "Count should show 1 new file")
            eq(1, #unresolved_final, "Picker should show 1 new file")
        end)

        it("reproduces stale count when update_snapshot is skipped", function()
            -- This simulates the scenario where update_snapshot is never called
            -- (e.g., user closes dialog without finishing all files, or the
            -- code path doesn't trigger update_snapshot)
            local files = {}
            for i = 1, 15 do
                files["mod" .. i .. ".lua"] = "original " .. i
            end
            local repo_path = helpers.create_test_repo("scenario-stale", files)
            local info = git.create_worktree("stale-sess", repo_path)
            assert.is_not_nil(info)

            -- Agent modifies all 15 files
            for i = 1, 15 do
                helpers.write_file(
                    info.worktree_path .. "/mod" .. i .. ".lua", "agent " .. i
                )
            end

            -- User "merges" by copying content to repo (without going through dialog)
            for i = 1, 15 do
                helpers.write_file(repo_path .. "/mod" .. i .. ".lua", "agent " .. i)
            end

            -- Now unresolved is 0 but snapshot was NOT updated
            local unresolved = git.get_unresolved_files(info.worktree_path)
            eq(0, #unresolved, "All files match, nothing unresolved")

            -- But changed_files still shows 15!
            local changed = git.get_worktree_changed_files(info.worktree_path)
            eq(15, #changed,
                "Without update_snapshot, changed_files still shows all files")

            -- Agent makes 1 new change
            helpers.write_file(info.worktree_path .. "/mod1.lua", "agent 1 v2")

            -- Count is STILL inflated
            local changed_new = git.get_worktree_changed_files(info.worktree_path)
            local unresolved_new = git.get_unresolved_files(info.worktree_path)
            eq(1, #unresolved_new, "Picker correctly shows 1 file")
            eq(15, #changed_new,
                "BUG: Count still shows 15 files (stale snapshot)")
        end)
    end)
end)
