--- Unit tests for classify_regions in sequential multi-session merge scenarios.
--- Simulates: session 1 merged into local, then session 2 reviewed.
--- base = original snapshot (shared by both sessions)
--- user = local state after merging session 1
--- ai   = session 2's worktree state
local classifier = require("vibe.review.classifier")
local types = require("vibe.review.types")

local function classify(base, user, ai)
    return classifier.classify_regions(base, user, ai)
end

local function find_by_class(regions, cls)
    local found = {}
    for _, r in ipairs(regions) do
        if r.classification == cls then
            table.insert(found, r)
        end
    end
    return found
end

describe("Sequential multi-session classify_regions", function()
    -- Shared realistic base file used by most tests
    local base_code = {
        "function greet(name)",
        "  return 'Hello, ' .. name",
        "end",
        "",
        "function add(a, b)",
        "  return a + b",
        "end",
        "",
        "function main()",
        "  print(greet('world'))",
        "  print(add(1, 2))",
        "end",
    }

    -- Helper: clone table with line replacements
    local function with_lines(tbl, replacements)
        local copy = {}
        for i, v in ipairs(tbl) do
            copy[i] = replacements[i] or v
        end
        return copy
    end

    -- Helper: clone table with lines inserted after a position
    local function with_insert(tbl, after_pos, new_lines)
        local copy = {}
        for i = 1, after_pos do
            table.insert(copy, tbl[i])
        end
        for _, line in ipairs(new_lines) do
            table.insert(copy, line)
        end
        for i = after_pos + 1, #tbl do
            table.insert(copy, tbl[i])
        end
        return copy
    end

    -- Helper: clone table with lines removed
    local function with_delete(tbl, from, to)
        local copy = {}
        for i = 1, #tbl do
            if i < from or i > to then
                table.insert(copy, tbl[i])
            end
        end
        return copy
    end

    -- ──────────────────────────────────────────────
    -- Scenario 1: Both sessions edit same line differently → CONFLICT
    -- ──────────────────────────────────────────────
    it("detects CONFLICT when both sessions edit same line differently", function()
        local user = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" }) -- session 1 merged
        local ai = with_lines(base_code, { [2] = "  return 'Hey, ' .. name" }) -- session 2

        local regions = classify(base_code, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.CONFLICT, regions[1].classification)
        assert.are.equal(types.MOD_VS_MOD, regions[1].conflict_type)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 2: Session 1 edits, session 2 doesn't → USER_ONLY
    -- ──────────────────────────────────────────────
    it("detects USER_ONLY when only session 1 changed a line", function()
        local user = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" }) -- session 1 merged
        local ai = {} -- session 2 didn't change this file at all
        for i, v in ipairs(base_code) do
            ai[i] = v
        end

        local regions = classify(base_code, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.USER_ONLY, regions[1].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 3: Session 2 edits, session 1 didn't → AI_ONLY
    -- ──────────────────────────────────────────────
    it("detects AI_ONLY when only session 2 changed a line", function()
        local user = {} -- session 1 didn't change this file
        for i, v in ipairs(base_code) do
            user[i] = v
        end
        local ai = with_lines(base_code, { [6] = "  return a * b" }) -- session 2

        local regions = classify(base_code, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.AI_ONLY, regions[1].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 4: Both make identical edit → CONVERGENT
    -- ──────────────────────────────────────────────
    it("detects CONVERGENT when both sessions made identical edit", function()
        local user = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" })
        local ai = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" })

        local regions = classify(base_code, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.CONVERGENT, regions[1].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 5: Session 1 inserts line, session 2 edits adjacent line → CONFLICT
    -- ──────────────────────────────────────────────
    it("detects CONFLICT when session 1 inserts and session 2 edits adjacent region", function()
        -- Session 1 inserted a comment after line 2 and changed line 3
        local user = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" })
        -- Session 2 also changed line 2
        local ai = with_lines(base_code, { [2] = "  return 'Hey, ' .. name" })

        local regions = classify(base_code, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.CONFLICT, regions[1].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 6: Session 1 deletes lines, session 2 edits those lines → CONFLICT
    -- ──────────────────────────────────────────────
    it("detects CONFLICT (del_vs_mod) when session 1 deleted lines that session 2 edited", function()
        -- Session 1 deleted lines 5-7 (function add)
        local user = with_delete(base_code, 5, 7)
        -- Session 2 modified line 6 within that function
        local ai = with_lines(base_code, { [6] = "  return a * b" })

        local regions = classify(base_code, user, ai)
        local conflicts = find_by_class(regions, types.CONFLICT)
        assert.is_true(#conflicts >= 1, "Should have at least one conflict")
        -- The user deleted the entire range; AI modified within it
        assert.are.equal(types.DEL_VS_MOD, conflicts[1].conflict_type)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 7: Non-overlapping edits → USER_ONLY + AI_ONLY
    -- ──────────────────────────────────────────────
    it("produces separate USER_ONLY and AI_ONLY for non-overlapping edits", function()
        -- Session 1 changed line 2, session 2 changed line 10
        local user = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" })
        local ai = with_lines(base_code, { [10] = "  print(greet('universe'))" })

        local regions = classify(base_code, user, ai)
        assert.are.equal(2, #regions)
        -- Sorted by base position: line 2 first, then line 10
        assert.are.equal(types.USER_ONLY, regions[1].classification)
        assert.are.equal(types.AI_ONLY, regions[2].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 8: Session 1 refactors function, session 2 adds to same function → CONFLICT
    -- ──────────────────────────────────────────────
    it("detects CONFLICT when session 1 refactored and session 2 edited same function", function()
        -- Session 1 rewrote the add function entirely (lines 5-7)
        local user = with_lines(base_code, {
            [5] = "function sum(x, y)",
            [6] = "  return x + y",
            [7] = "end",
        })
        -- Session 2 added validation inside original add function (changed line 6)
        local ai = with_lines(base_code, {
            [6] = "  assert(type(a) == 'number' and type(b) == 'number')",
        })

        local regions = classify(base_code, user, ai)
        local conflicts = find_by_class(regions, types.CONFLICT)
        assert.is_true(#conflicts >= 1, "Overlapping refactor + edit should conflict")
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 9: Large file with multiple functions, mixed classifications
    -- ──────────────────────────────────────────────
    it("handles large file with USER_ONLY + AI_ONLY + CONFLICT across functions", function()
        local large_base = {
            "-- module start",        -- 1
            "function fn1()",         -- 2
            "  return 'fn1'",         -- 3
            "end",                    -- 4
            "",                       -- 5
            "function fn2()",         -- 6
            "  return 'fn2'",         -- 7
            "end",                    -- 8
            "",                       -- 9
            "function fn3()",         -- 10
            "  return 'fn3'",         -- 11
            "end",                    -- 12
            "",                       -- 13
            "function fn4()",         -- 14
            "  return 'fn4'",         -- 15
            "end",                    -- 16
        }

        -- Session 1 edits fn1 (line 3) and fn3 (line 11)
        local user = with_lines(large_base, {
            [3] = "  return 'fn1-v2'",
            [11] = "  return 'fn3-session1'",
        })
        -- Session 2 edits fn2 (line 7) and fn3 (line 11)
        local ai = with_lines(large_base, {
            [7] = "  return 'fn2-v2'",
            [11] = "  return 'fn3-session2'",
        })

        local regions = classify(large_base, user, ai)
        local user_only = find_by_class(regions, types.USER_ONLY)
        local ai_only = find_by_class(regions, types.AI_ONLY)
        local conflicts = find_by_class(regions, types.CONFLICT)

        assert.are.equal(1, #user_only, "fn1 edit should be USER_ONLY")
        assert.are.equal(1, #ai_only, "fn2 edit should be AI_ONLY")
        assert.are.equal(1, #conflicts, "fn3 edit should be CONFLICT")
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 10: Both sessions add at EOF → CONFLICT
    -- ──────────────────────────────────────────────
    it("detects CONFLICT when both sessions add lines at EOF", function()
        local base = { "line 1", "line 2", "line 3" }
        -- Session 1 added a line at end (now in user)
        local user = { "line 1", "line 2", "line 3", "session1 new line" }
        -- Session 2 added a different line at end
        local ai = { "line 1", "line 2", "line 3", "session2 new line" }

        local regions = classify(base, user, ai)
        -- Both inserted after line 3, different content → conflict
        local conflicts = find_by_class(regions, types.CONFLICT)
        assert.is_true(#conflicts >= 1, "EOF insertions from both sessions should conflict")
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 11: Single-line file, both edit it → CONFLICT
    -- ──────────────────────────────────────────────
    it("detects CONFLICT on single-line file when both sessions edit it", function()
        local base = { "original content" }
        local user = { "session1 content" }
        local ai = { "session2 content" }

        local regions = classify(base, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.CONFLICT, regions[1].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 12: Session 2 unchanged (AI=base) → no regions
    -- ──────────────────────────────────────────────
    it("returns only USER_ONLY when session 2 made no changes", function()
        local user = with_lines(base_code, { [2] = "  return 'Hi, ' .. name" })
        local ai = {} -- exact copy of base
        for i, v in ipairs(base_code) do
            ai[i] = v
        end

        local regions = classify(base_code, user, ai)
        -- Only session 1's merged change should appear as USER_ONLY
        assert.are.equal(1, #regions)
        assert.are.equal(types.USER_ONLY, regions[1].classification)
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 13: Session 1 inserts between functions, session 2 edits different function
    -- ──────────────────────────────────────────────
    it("keeps USER_ONLY + AI_ONLY separate when session 1 inserts and session 2 edits far away", function()
        -- Session 1 inserted a helper after line 3 (between greet and add)
        local user = with_insert(base_code, 4, { "-- helper added by session 1" })
        -- Session 2 edited line 10 (print in main) — which is line 10 in base, unaffected by insertion
        local ai = with_lines(base_code, { [10] = "  print(greet('universe'))" })

        local regions = classify(base_code, user, ai)
        local user_only = find_by_class(regions, types.USER_ONLY)
        local ai_only = find_by_class(regions, types.AI_ONLY)

        assert.is_true(#user_only >= 1, "Insertion should be USER_ONLY")
        assert.is_true(#ai_only >= 1, "Edit at line 10 should be AI_ONLY")
        assert.are.equal(0, #find_by_class(regions, types.CONFLICT), "No conflicts expected")
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 14: Three sequential sessions — merge S1, S2, then S3
    -- ──────────────────────────────────────────────
    it("handles three sequential sessions correctly", function()
        local base = {
            "line 1",
            "line 2",
            "line 3",
            "line 4",
            "line 5",
            "line 6",
            "line 7",
            "line 8",
        }

        -- After merging session 1 (changed line 1) and session 2 (changed line 4):
        local post_s1_s2 = with_lines(base, {
            [1] = "S1 line 1",
            [4] = "S2 line 4",
        })

        -- Session 3 started from original base, changed lines 1, 6, 4
        local s3_ai = with_lines(base, {
            [1] = "S3 line 1", -- conflicts with S1's merged change
            [4] = "S3 line 4", -- conflicts with S2's merged change
            [6] = "S3 line 6", -- no conflict, AI_ONLY
        })

        -- Merging session 3: base=original, user=post S1+S2 merge, ai=S3 worktree
        local regions = classify(base, post_s1_s2, s3_ai)
        local user_only = find_by_class(regions, types.USER_ONLY)
        local ai_only = find_by_class(regions, types.AI_ONLY)
        local conflicts = find_by_class(regions, types.CONFLICT)

        assert.are.equal(2, #conflicts, "Lines 1 and 4 should conflict (S1/S2 vs S3)")
        assert.are.equal(1, #ai_only, "Line 6 should be AI_ONLY")
        -- No pure USER_ONLY since S3 also touches lines 1 and 4
        assert.are.equal(0, #user_only, "No pure USER_ONLY expected")
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 15: Session 1 changes multiple scattered lines, session 2 changes one overlapping
    -- ──────────────────────────────────────────────
    it("correctly isolates one conflict among multiple user-only changes", function()
        local base = {
            "alpha",
            "bravo",
            "charlie",
            "delta",
            "echo",
            "foxtrot",
        }

        -- Session 1 changed lines 1, 3, 5
        local user = with_lines(base, {
            [1] = "ALPHA",
            [3] = "CHARLIE",
            [5] = "ECHO",
        })
        -- Session 2 changed only line 3
        local ai = with_lines(base, {
            [3] = "charlie-v2",
        })

        local regions = classify(base, user, ai)
        local user_only = find_by_class(regions, types.USER_ONLY)
        local conflicts = find_by_class(regions, types.CONFLICT)

        assert.are.equal(2, #user_only, "Lines 1 and 5 should be USER_ONLY")
        assert.are.equal(1, #conflicts, "Line 3 should be CONFLICT")
    end)

    -- ──────────────────────────────────────────────
    -- Scenario 16: Both sessions add identical lines at EOF → CONVERGENT
    -- ──────────────────────────────────────────────
    it("detects CONVERGENT when both sessions add identical lines at EOF", function()
        local base = { "line 1", "line 2" }
        local user = { "line 1", "line 2", "new shared line" }
        local ai = { "line 1", "line 2", "new shared line" }

        local regions = classify(base, user, ai)
        assert.are.equal(1, #regions)
        assert.are.equal(types.CONVERGENT, regions[1].classification)
    end)
end)
