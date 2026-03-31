local git = require("vibe.git")
local eq = assert.are.equal

describe("Hunk hashing", function()
    it("hunk_hash is deterministic", function()
        local hunk = {
            old_count = 2,
            new_count = 3,
            removed_lines = { "old line 1", "old line 2" },
            added_lines = { "new line 1", "new line 2", "new line 3" },
        }

        local hash1 = git.hunk_hash(hunk)
        local hash2 = git.hunk_hash(hunk)
        eq(hash1, hash2, "Same hunk should produce same hash")
    end)

    it("hunk_hash differs for different content", function()
        local hunk_a = {
            old_count = 1,
            new_count = 1,
            removed_lines = { "old line" },
            added_lines = { "new line A" },
        }

        local hunk_b = {
            old_count = 1,
            new_count = 1,
            removed_lines = { "old line" },
            added_lines = { "new line B" },
        }

        local hash_a = git.hunk_hash(hunk_a)
        local hash_b = git.hunk_hash(hunk_b)
        assert.are_not.equal(hash_a, hash_b, "Different content should produce different hashes")
    end)

    it("hunk_hash differs for different counts", function()
        local hunk_a = {
            old_count = 1,
            new_count = 2,
            removed_lines = { "line" },
            added_lines = { "line" },
        }

        local hunk_b = {
            old_count = 2,
            new_count = 1,
            removed_lines = { "line" },
            added_lines = { "line" },
        }

        local hash_a = git.hunk_hash(hunk_a)
        local hash_b = git.hunk_hash(hunk_b)
        assert.are_not.equal(hash_a, hash_b, "Different counts should produce different hashes")
    end)

    it("hunk_hash handles empty lines", function()
        local hunk = {
            old_count = 0,
            new_count = 0,
            removed_lines = {},
            added_lines = {},
        }

        local hash = git.hunk_hash(hunk)
        assert.is_not_nil(hash, "Hash should not be nil for empty hunk")
        assert.is_truthy(#hash > 0, "Hash should be non-empty")
    end)
end)
