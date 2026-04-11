-- test/unit/vibesync_ca_spec.lua
-- Tests for dialog-level cA (accept AI for conflicts) and cR (keep user for conflicts)
-- Covers: FILE_NEW_BOTH_DIFF, FILE_MODIFIED, vibesynced untracked files,
-- buffer interactions, and edge cases with insertions/deletions.
local git = require("vibe.git")
local merge = require("vibe.review.merge")
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("dialog cA/cR", function()
    before_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
    end)

    after_each(function()
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
        helpers.cleanup_all()
    end)

    -- ──────────────────────────────────────────────
    -- Group 1: _reconstruct_side correctness
    -- ──────────────────────────────────────────────

    describe("_reconstruct_side insertion ordering", function()
        it("places insertion AFTER anchor line", function()
            -- Base: A B C
            -- Side inserts "X" after line 2 (B): A B X C
            -- Reconstruct for range [2,2] should be: ["B", "X"]
            local base = {"A", "B", "C"}
            local side = {"A", "B", "X", "C"}

            -- Hunk: insert at base position 2, side position 3
            local ranges = {{
                base_start = 2, base_end = 2,
                count_a = 0, side_start = 3, side_count = 1,
                is_insert = true,
            }}

            local result = classifier._reconstruct_side(base, side, ranges, {1}, 2, 2)
            eq(2, #result, "should have 2 lines (anchor + insertion)")
            eq("B", result[1], "anchor line should come first")
            eq("X", result[2], "insertion should come after anchor")
        end)

        it("places insertion at start of range correctly", function()
            -- Base: A B C D E
            -- Side inserts "X" after line 1 (A): A X B C D E
            -- Reconstruct for range [1,3]
            local base = {"A", "B", "C", "D", "E"}
            local side = {"A", "X", "B", "C", "D", "E"}

            local ranges = {{
                base_start = 1, base_end = 1,
                count_a = 0, side_start = 2, side_count = 1,
                is_insert = true,
            }}

            local result = classifier._reconstruct_side(base, side, ranges, {1}, 1, 3)
            eq(4, #result, "should have 4 lines (3 base + 1 insertion)")
            eq("A", result[1])
            eq("X", result[2])
            eq("B", result[3])
            eq("C", result[4])
        end)

        it("handles replacement followed by insertion", function()
            -- Base: A B C D
            -- Side: A X C Y D (B→X, insert Y after C)
            -- Range [2,3]: replace B→X, insert Y after C
            local base = {"A", "B", "C", "D"}
            local side = {"A", "X", "C", "Y", "D"}

            local ranges = {
                { base_start = 2, base_end = 2, count_a = 1, side_start = 2, side_count = 1, is_insert = false },
                { base_start = 3, base_end = 3, count_a = 0, side_start = 4, side_count = 1, is_insert = true },
            }

            local result = classifier._reconstruct_side(base, side, ranges, {1, 2}, 2, 3)
            eq(3, #result)
            eq("X", result[1])    -- replacement for B
            eq("C", result[2])    -- anchor line for insertion
            eq("Y", result[3])    -- insertion after C
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 2: merge_file with conflict_resolution
    -- ──────────────────────────────────────────────

    describe("merge_file conflict_resolution='ai'", function()
        it("uses AI version for overlapping insert conflict", function()
            -- Base: A B C
            -- User inserts U after B: A B U C
            -- AI inserts I after B: A B I C
            -- cA should produce: A B I C
            local repo_path = helpers.create_test_repo("ca-insert-conflict", {
                ["test.txt"] = "A\nB\nC",
            })

            local info = git.create_worktree("ca-insert-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nB\nI\nC")
            helpers.write_file(repo_path .. "/test.txt", "A\nB\nU\nC")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(4, #result, "should have 4 lines")
            eq("A", result[1])
            eq("B", result[2])
            eq("I", result[3])
            eq("C", result[4])
        end)

        it("uses AI version for same-line modification conflict", function()
            -- Base: A B C D E
            -- User: A U C D E (changed B→U)
            -- AI: A I C D E (changed B→I)
            -- cA should produce: A I C D E
            local repo_path = helpers.create_test_repo("ca-mod-conflict", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("ca-mod-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nI\nC\nD\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nU\nC\nD\nE")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(5, #result)
            eq("A", result[1])
            eq("I", result[2])
            eq("C", result[3])
            eq("D", result[4])
            eq("E", result[5])
        end)

        it("preserves non-overlapping changes alongside conflict", function()
            -- Base: A B C D E
            -- User: A U C D Eu (changed B→U, E→Eu)
            -- AI: A I C Da E (changed B→I, D→Da)
            -- cA: conflicts at B (user U vs AI I → AI wins: I)
            -- Non-conflict: AI_ONLY at D (D→Da), USER_ONLY at E (E→Eu)
            -- Expected: A I C Da Eu
            local repo_path = helpers.create_test_repo("ca-mixed", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("ca-mixed-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nI\nC\nDa\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nU\nC\nD\nEu")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(5, #result)
            eq("A", result[1])
            eq("I", result[2])
            eq("C", result[3])
            eq("Da", result[4])
            eq("Eu", result[5])
        end)

        it("handles AI inserting new lines while user modifies adjacent line", function()
            -- Base: A B C
            -- User: A Bu C (changed B→Bu)
            -- AI: A B X C (inserted X after B)
            -- These overlap at line 2 → CONFLICT
            -- cA should produce: A B X C (AI's version of the overlapping region)
            local repo_path = helpers.create_test_repo("ca-insert-vs-mod", {
                ["test.txt"] = "A\nB\nC",
            })

            local info = git.create_worktree("ca-insert-mod-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nB\nX\nC")
            helpers.write_file(repo_path .. "/test.txt", "A\nBu\nC")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(4, #result)
            eq("A", result[1])
            eq("B", result[2])
            eq("X", result[3])
            eq("C", result[4])
        end)

        it("handles user inserting new lines while AI modifies adjacent line", function()
            -- Base: A B C
            -- User: A B X C (inserted X after B)
            -- AI: A Ba C (changed B→Ba)
            -- These overlap at line 2 → CONFLICT
            -- cA should produce: A Ba C (AI's version)
            local repo_path = helpers.create_test_repo("ca-mod-vs-insert", {
                ["test.txt"] = "A\nB\nC",
            })

            local info = git.create_worktree("ca-mod-insert-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nBa\nC")
            helpers.write_file(repo_path .. "/test.txt", "A\nB\nX\nC")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(3, #result)
            eq("A", result[1])
            eq("Ba", result[2])
            eq("C", result[3])
        end)

        it("handles multiple conflicts in same file", function()
            -- Base: A B C D E F G
            -- User: A U1 C D U2 F G (changed B→U1, E→U2)
            -- AI: A I1 C D I2 F G (changed B→I1, E→I2)
            -- cA: both conflicts resolve to AI
            -- Expected: A I1 C D I2 F G
            local repo_path = helpers.create_test_repo("ca-multi-conflict", {
                ["test.txt"] = "A\nB\nC\nD\nE\nF\nG",
            })

            local info = git.create_worktree("ca-multi-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nI1\nC\nD\nI2\nF\nG")
            helpers.write_file(repo_path .. "/test.txt", "A\nU1\nC\nD\nU2\nF\nG")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(7, #result)
            eq("I1", result[2])
            eq("I2", result[5])
        end)
    end)

    describe("merge_file conflict_resolution='user'", function()
        it("uses user version for overlapping insert conflict", function()
            -- Base: A B C
            -- User inserts U after B: A B U C
            -- AI inserts I after B: A B I C
            -- cR should produce: A B U C
            local repo_path = helpers.create_test_repo("cr-insert-conflict", {
                ["test.txt"] = "A\nB\nC",
            })

            local info = git.create_worktree("cr-insert-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nB\nI\nC")
            helpers.write_file(repo_path .. "/test.txt", "A\nB\nU\nC")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "user")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(4, #result, "should have 4 lines")
            eq("A", result[1])
            eq("B", result[2])
            eq("U", result[3])
            eq("C", result[4])
        end)

        it("uses user version for same-line modification conflict", function()
            local repo_path = helpers.create_test_repo("cr-mod-conflict", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("cr-mod-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nI\nC\nD\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nU\nC\nD\nE")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "user")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(5, #result)
            eq("U", result[2])
        end)

        it("preserves non-overlapping changes alongside conflict", function()
            -- Base: A B C D E
            -- User: A U C D Eu
            -- AI: A I C Da E
            -- cR: conflict at B → keep user (U). AI_ONLY at D→Da kept. USER_ONLY at E→Eu kept.
            -- Expected: A U C Da Eu
            local repo_path = helpers.create_test_repo("cr-mixed", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("cr-mixed-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nI\nC\nDa\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nU\nC\nD\nEu")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "user")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(5, #result)
            eq("U", result[2])
            eq("Da", result[4])
            eq("Eu", result[5])
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 3: FILE_NEW_BOTH_DIFF (no base)
    -- ──────────────────────────────────────────────

    describe("FILE_NEW_BOTH_DIFF", function()
        it("cA uses AI version entirely", function()
            local repo_path = helpers.create_test_repo("new-both-ca", {
                ["tracked.txt"] = "tracked",
            })

            local info = git.create_worktree("new-both-ca-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/new.lua", "agent line 1\nagent line 2\nagent line 3")
            helpers.write_file(repo_path .. "/new.lua", "user line 1\nuser line 2\nuser line 3")

            local ok, err = git.merge_accept_file(info.worktree_path, "new.lua", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/new.lua")
            eq(3, #result)
            eq("agent line 1", result[1])
            eq("agent line 2", result[2])
            eq("agent line 3", result[3])
        end)

        it("cR uses user version entirely", function()
            local repo_path = helpers.create_test_repo("new-both-cr", {
                ["tracked.txt"] = "tracked",
            })

            local info = git.create_worktree("new-both-cr-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/new.lua", "agent line 1\nagent line 2")
            helpers.write_file(repo_path .. "/new.lua", "user line 1\nuser line 2")

            local ok, err = git.merge_accept_file(info.worktree_path, "new.lua", "both", nil, "user")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/new.lua")
            eq(2, #result)
            eq("user line 1", result[1])
            eq("user line 2", result[2])
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 4: Vibesynced untracked files
    -- ──────────────────────────────────────────────

    describe("vibesynced untracked files", function()
        it("cA resolves vibesynced file and marks as no longer unresolved", function()
            local repo_path = helpers.create_test_repo("vibesync-ca", {
                ["tracked.txt"] = "tracked content",
            })

            local info = git.create_worktree("vibesync-ca-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/untracked.lua", "agent v1\nagent v2")
            helpers.write_file(repo_path .. "/untracked.lua", "user v1\nuser v2")

            local sync_ok = git.sync_local_to_worktree(info.worktree_path)
            assert.is_truthy(sync_ok)

            -- Both modify after sync
            helpers.write_file(info.worktree_path .. "/untracked.lua", "agent modified\nagent v2")
            helpers.write_file(repo_path .. "/untracked.lua", "user modified\nuser v2")

            -- Should be unresolved
            local unresolved = git.get_unresolved_files(info.worktree_path)
            local found = false
            for _, f in ipairs(unresolved) do
                if f == "untracked.lua" then found = true end
            end
            assert.is_true(found, "should be unresolved before cA")

            -- cA
            local ok, err = git.merge_accept_file(info.worktree_path, "untracked.lua", "user", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            -- Should be resolved
            local unresolved_after = git.get_unresolved_files(info.worktree_path)
            for _, f in ipairs(unresolved_after) do
                assert.are_not.equal("untracked.lua", f, "should NOT be unresolved after cA")
            end
        end)

        it("cA produces correct content for vibesynced file with conflict", function()
            local repo_path = helpers.create_test_repo("vibesync-content", {
                ["tracked.txt"] = "tracked",
            })

            local info = git.create_worktree("vibesync-content-test", repo_path)
            assert.is_not_nil(info)

            -- Agent creates, user creates (different content)
            helpers.write_file(info.worktree_path .. "/config.lua", "line 1\nline 2\nline 3")
            helpers.write_file(repo_path .. "/config.lua", "line 1\nline 2\nline 3")

            -- Sync (makes them identical, creates snapshot with this content)
            local sync_ok = git.sync_local_to_worktree(info.worktree_path)
            assert.is_truthy(sync_ok)

            -- Now both modify: agent changes line 2, user changes line 2
            helpers.write_file(info.worktree_path .. "/config.lua", "line 1\nagent 2\nline 3")
            helpers.write_file(repo_path .. "/config.lua", "line 1\nuser 2\nline 3")

            local ok, err = git.merge_accept_file(info.worktree_path, "config.lua", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/config.lua")
            eq(3, #result)
            eq("line 1", result[1])
            eq("agent 2", result[2])
            eq("line 3", result[3])
        end)
    end)

    -- ──────────────────────────────────────────────
    -- Group 5: Complex real-world scenarios
    -- ──────────────────────────────────────────────

    describe("complex scenarios", function()
        it("cA handles conflict + user insertion + AI insertion (non-overlapping)", function()
            -- Base: line1 line2 line3 line4 line5
            -- User: line1 U2 line3 userInsert line4 line5
            -- AI:   line1 A2 line3 line4 aiInsert line5
            -- Conflict at line2 (U2 vs A2) → AI wins (A2)
            -- USER_ONLY insert after line3
            -- AI_ONLY insert after line4
            -- Expected: line1 A2 line3 userInsert line4 aiInsert line5
            local repo_path = helpers.create_test_repo("ca-complex", {
                ["test.txt"] = "line1\nline2\nline3\nline4\nline5",
            })

            local info = git.create_worktree("ca-complex-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "line1\nA2\nline3\nline4\naiInsert\nline5")
            helpers.write_file(repo_path .. "/test.txt", "line1\nU2\nline3\nuserInsert\nline4\nline5")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(7, #result, "should have 7 lines")
            eq("line1", result[1])
            eq("A2", result[2])
            eq("line3", result[3])
            eq("userInsert", result[4])
            eq("line4", result[5])
            eq("aiInsert", result[6])
            eq("line5", result[7])
        end)

        it("cA handles multi-line conflict correctly", function()
            -- Base: A B C D E
            -- User: A X Y D E (B C → X Y, 2 lines → 2 lines)
            -- AI: A P Q R D E (B C → P Q R, 2 lines → 3 lines)
            -- Conflict at lines 2-3 → AI wins: P Q R
            -- Expected: A P Q R D E
            local repo_path = helpers.create_test_repo("ca-multiline", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("ca-multiline-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nP\nQ\nR\nD\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nX\nY\nD\nE")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(6, #result)
            eq("A", result[1])
            eq("P", result[2])
            eq("Q", result[3])
            eq("R", result[4])
            eq("D", result[5])
            eq("E", result[6])
        end)

        it("cR handles user insertion in conflict region", function()
            -- Base: A B C
            -- User: A B X C (inserted X after B)
            -- AI: A Ba C (changed B→Ba)
            -- cR keeps user version of conflict: B X
            -- Expected: A B X C
            local repo_path = helpers.create_test_repo("cr-user-insert", {
                ["test.txt"] = "A\nB\nC",
            })

            local info = git.create_worktree("cr-user-insert-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nBa\nC")
            helpers.write_file(repo_path .. "/test.txt", "A\nB\nX\nC")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "user")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(4, #result)
            eq("A", result[1])
            eq("B", result[2])
            eq("X", result[3])
            eq("C", result[4])
        end)

        it("cA handles AI deletion conflict", function()
            -- Base: A B C D E
            -- User: A Bu C D E (changed B→Bu)
            -- AI: A C D E (deleted B)
            -- Conflict: user modified B, AI deleted B → cA uses AI (deletion)
            -- Expected: A C D E
            local repo_path = helpers.create_test_repo("ca-del-conflict", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("ca-del-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nC\nD\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nBu\nC\nD\nE")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "both", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(4, #result)
            eq("A", result[1])
            eq("C", result[2])
            eq("D", result[3])
            eq("E", result[4])
        end)

        it("cA with merge_mode=user keeps non-conflict user changes", function()
            -- With merge_mode="user", USER_ONLY auto-resolves but AI_ONLY does not
            -- cA should still resolve CONFLICTs to AI
            -- Base: A B C D E
            -- User: A U C D Eu (changed B→U, E→Eu)
            -- AI: A I C Da E (changed B→I, D→Da)
            -- merge_mode=user: USER_ONLY(E→Eu) auto-resolved, AI_ONLY(D→Da) NOT auto-resolved
            -- CONFLICT(B: U vs I) → AI wins
            -- Expected: A I C D Eu (AI_ONLY not applied since not auto-resolved → user_lines=base)
            local repo_path = helpers.create_test_repo("ca-user-mode", {
                ["test.txt"] = "A\nB\nC\nD\nE",
            })

            local info = git.create_worktree("ca-user-mode-test", repo_path)
            assert.is_not_nil(info)

            helpers.write_file(info.worktree_path .. "/test.txt", "A\nI\nC\nDa\nE")
            helpers.write_file(repo_path .. "/test.txt", "A\nU\nC\nD\nEu")

            local ok, err = git.merge_accept_file(info.worktree_path, "test.txt", "user", nil, "ai")
            assert.is_truthy(ok, "merge should succeed: " .. (err or ""))

            local result = vim.fn.readfile(repo_path .. "/test.txt")
            eq(5, #result)
            eq("I", result[2])   -- conflict resolved to AI
            eq("D", result[4])   -- AI_ONLY not auto-resolved → stays as base/user
            eq("Eu", result[5])  -- user change preserved
        end)
    end)
end)
