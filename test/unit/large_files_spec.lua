-- test/unit/large_files_spec.lua
local large_files = require("vibe.large_files")
local git = require("vibe.git")
local helpers = require("test.helpers.git_repo")
local config = require("vibe.config")
local eq = assert.are.equal
local is_true = assert.is_true
local is_false = assert.is_false

-- Ensure test cache directory exists (needed when running single file)
if not vim.g.vibe_test_cache then
    vim.g.vibe_test_cache = vim.fn.tempname() .. "-vibe-test"
    vim.fn.mkdir(vim.g.vibe_test_cache, "p")
end

describe("Large Files Detection and Dialog", function()
    local original_threshold

    before_each(function()
        original_threshold = config.options.large_files and config.options.large_files.threshold
        config.options.large_files = { threshold = 100, enabled = true }
        for path, _ in pairs(git.worktrees) do
            git.remove_worktree(path)
        end
    end)

    after_each(function()
        if original_threshold then
            config.options.large_files.threshold = original_threshold
        end
        large_files.close()
        helpers.cleanup_all()
    end)

    describe("format_size", function()
        it("formats bytes", function()
            eq("0 B", large_files.format_size(0))
            eq("512 B", large_files.format_size(512))
        end)

        it("formats kilobytes", function()
            eq("1.0 KB", large_files.format_size(1024))
            eq("1.5 KB", large_files.format_size(1536))
        end)

        it("formats megabytes", function()
            eq("1.0 MB", large_files.format_size(1048576))
            eq("10.5 MB", large_files.format_size(11010048))
        end)

        it("formats gigabytes", function()
            eq("1.0 GB", large_files.format_size(1073741824))
        end)

        it("handles negative values", function()
            eq("0 B", large_files.format_size(-1))
        end)
    end)

    describe("detect_large_files", function()
        it("returns empty when no files exceed threshold", function()
            local repo_path = helpers.create_test_repo("lf-small", {
                ["small.txt"] = "hello",
            })

            local info = git.create_worktree("lf-small-sess", repo_path)
            helpers.write_file(info.worktree_path .. "/small.txt", "hello world")

            local entries, has_large, total_size = large_files.detect_large_files(
                info.worktree_path, { "small.txt" }, repo_path
            )
            is_false(has_large)
            eq(0, #entries)
            eq(0, total_size)
        end)

        it("detects files above threshold", function()
            local repo_path = helpers.create_test_repo("lf-big", {
                ["small.txt"] = "hello",
            })

            local info = git.create_worktree("lf-big-sess", repo_path)
            -- Create a file larger than 100 bytes threshold
            local big_content = string.rep("x", 200)
            helpers.write_file(info.worktree_path .. "/big.bin", big_content)

            local entries, has_large, total_size = large_files.detect_large_files(
                info.worktree_path, { "small.txt", "big.bin" }, repo_path
            )
            is_true(has_large)
            eq(1, #entries)
            eq("big.bin", entries[1].path)
            eq("file", entries[1].type)
            is_false(entries[1].selected)
            is_true(total_size > 100)
        end)

        it("groups files in same directory when 2+", function()
            local repo_path = helpers.create_test_repo("lf-group", {
                ["src/keep.txt"] = "ok",
            })

            local info = git.create_worktree("lf-group-sess", repo_path)
            local big = string.rep("x", 200)
            helpers.write_file(info.worktree_path .. "/assets/big1.bin", big)
            helpers.write_file(info.worktree_path .. "/assets/big2.bin", big)

            local entries, has_large = large_files.detect_large_files(
                info.worktree_path, { "assets/big1.bin", "assets/big2.bin" }, repo_path
            )
            is_true(has_large)
            eq(1, #entries)
            eq("dir", entries[1].type)
            eq("assets/", entries[1].path)
            eq(2, #entries[1].children)
            is_false(entries[1].selected)
        end)

        it("leaves single file in directory as top-level", function()
            local repo_path = helpers.create_test_repo("lf-single", {
                ["src/keep.txt"] = "ok",
            })

            local info = git.create_worktree("lf-single-sess", repo_path)
            local big = string.rep("x", 200)
            helpers.write_file(info.worktree_path .. "/assets/big1.bin", big)

            local entries, has_large = large_files.detect_large_files(
                info.worktree_path, { "assets/big1.bin" }, repo_path
            )
            is_true(has_large)
            eq(1, #entries)
            eq("file", entries[1].type)
            eq("assets/big1.bin", entries[1].path)
        end)

        it("default selected state is false (excluded)", function()
            local repo_path = helpers.create_test_repo("lf-default", {
                ["a.txt"] = "ok",
            })

            local info = git.create_worktree("lf-default-sess", repo_path)
            helpers.write_file(info.worktree_path .. "/big.bin", string.rep("x", 200))

            local entries = large_files.detect_large_files(
                info.worktree_path, { "big.bin" }, repo_path
            )
            is_false(entries[1].selected)
        end)
    end)

    describe("collect_decisions", function()
        it("maps selected to merge, unselected to ignore", function()
            large_files.entries = {
                { type = "file", path = "a.bin", selected = true },
                { type = "file", path = "b.bin", selected = false },
            }

            local decisions = large_files.collect_decisions()
            eq("merge", decisions["a.bin"])
            eq("ignore", decisions["b.bin"])
        end)

        it("collects directory children decisions", function()
            large_files.entries = {
                {
                    type = "dir",
                    path = "assets/",
                    children = {
                        { type = "file", path = "assets/a.bin", selected = true },
                        { type = "file", path = "assets/b.bin", selected = false },
                    },
                },
            }

            local decisions = large_files.collect_decisions()
            eq("merge", decisions["assets/a.bin"])
            eq("ignore", decisions["assets/b.bin"])
        end)
    end)

    describe("count_selected", function()
        it("counts selected files including dir children", function()
            large_files.entries = {
                { type = "file", path = "a.bin", selected = true },
                { type = "file", path = "b.bin", selected = false },
                {
                    type = "dir",
                    path = "out/",
                    children = {
                        { type = "file", path = "out/c.bin", selected = true },
                        { type = "file", path = "out/d.bin", selected = true },
                    },
                },
            }

            eq(3, large_files.count_selected())
        end)

        it("returns 0 when nothing selected", function()
            large_files.entries = {
                { type = "file", path = "a.bin", selected = false },
            }
            eq(0, large_files.count_selected())
        end)
    end)

    describe("sync_dir_selections", function()
        it("marks dir selected when any child is selected", function()
            large_files.entries = {
                {
                    type = "dir",
                    path = "out/",
                    selected = false,
                    children = {
                        { type = "file", path = "out/a.bin", selected = true },
                        { type = "file", path = "out/b.bin", selected = false },
                    },
                },
            }

            large_files.sync_dir_selections()
            is_true(large_files.entries[1].selected)
        end)

        it("marks dir unselected when no children selected", function()
            large_files.entries = {
                {
                    type = "dir",
                    path = "out/",
                    selected = true,
                    children = {
                        { type = "file", path = "out/a.bin", selected = false },
                        { type = "file", path = "out/b.bin", selected = false },
                    },
                },
            }

            large_files.sync_dir_selections()
            is_false(large_files.entries[1].selected)
        end)
    end)

    describe("build_flat_entries", function()
        it("includes children of expanded dirs", function()
            large_files.entries = {
                {
                    type = "dir",
                    path = "out/",
                    expanded = true,
                    children = {
                        { type = "file", path = "out/a.bin" },
                        { type = "file", path = "out/b.bin" },
                    },
                },
                { type = "file", path = "root.bin" },
            }

            large_files.build_flat_entries()
            eq(4, #large_files.flat_entries)
            eq("out/", large_files.flat_entries[1].path)
            eq("out/a.bin", large_files.flat_entries[2].path)
            eq("out/b.bin", large_files.flat_entries[3].path)
            eq("root.bin", large_files.flat_entries[4].path)
        end)

        it("hides children of collapsed dirs", function()
            large_files.entries = {
                {
                    type = "dir",
                    path = "out/",
                    expanded = false,
                    children = {
                        { type = "file", path = "out/a.bin" },
                    },
                },
                { type = "file", path = "root.bin" },
            }

            large_files.build_flat_entries()
            eq(2, #large_files.flat_entries)
            eq("out/", large_files.flat_entries[1].path)
            eq("root.bin", large_files.flat_entries[2].path)
        end)
    end)

    describe("execute_decisions", function()
        it("returns merge files for merge decisions", function()
            local merge_files = large_files.execute_decisions("/tmp/wt", { repo_root = "/tmp/repo" }, {
                ["a.bin"] = "merge",
                ["b.bin"] = "ignore",
                ["c.bin"] = "merge",
            })
            table.sort(merge_files)
            eq(2, #merge_files)
            eq("a.bin", merge_files[1])
            eq("c.bin", merge_files[2])
        end)

        it("returns empty for all-ignore decisions", function()
            local merge_files = large_files.execute_decisions("/tmp/wt", { repo_root = "/tmp/repo" }, {
                ["a.bin"] = "ignore",
            })
            eq(0, #merge_files)
        end)

        it("returns empty for nil decisions", function()
            local merge_files = large_files.execute_decisions("/tmp/wt", { repo_root = "/tmp/repo" }, nil)
            eq(0, #merge_files)
        end)
    end)

    describe("show (integration)", function()
        it("calls on_complete immediately when no large files", function()
            local repo_path = helpers.create_test_repo("lf-show-none", {
                ["small.txt"] = "hello",
            })
            local info = git.create_worktree("lf-show-none-sess", repo_path)

            local completed = false
            local result_decisions = nil
            large_files.show(info.worktree_path, info, { "small.txt" }, function(decisions)
                completed = true
                result_decisions = decisions
            end)

            is_true(completed)
            eq(0, vim.tbl_count(result_decisions))
        end)

        it("calls on_complete immediately when feature disabled", function()
            config.options.large_files.enabled = false

            local completed = false
            large_files.show("/tmp/wt", { repo_root = "/tmp" }, { "big.bin" }, function(decisions)
                completed = true
            end)

            is_true(completed)
            config.options.large_files.enabled = true
        end)
    end)

    describe("update_snapshot excludes ignored large files", function()
        it("excludes ignored files from git add", function()
            local repo_path = helpers.create_test_repo("lf-snapshot", {
                ["app.js"] = "console.log('hello');",
            })

            local info = git.create_worktree("lf-snapshot-sess", repo_path)

            -- Create a large file and a normal change
            helpers.write_file(info.worktree_path .. "/app.js", "console.log('updated');")
            helpers.write_file(info.worktree_path .. "/big.bin", string.rep("x", 200))

            -- Set large file decision to ignore
            info.large_file_decisions = { ["big.bin"] = "ignore" }

            -- Accept the normal change
            helpers.write_file(repo_path .. "/app.js", "console.log('updated');")

            -- Update snapshot
            local ok = git.update_snapshot(info.worktree_path)
            is_true(ok)

            -- big.bin should still be untracked (not committed)
            local untracked = helpers.git_cmd(
                { "ls-files", "--others", "--exclude-standard" },
                { cwd = info.worktree_path }
            )
            assert.truthy(untracked:find("big.bin"), "big.bin should remain untracked")
        end)
    end)
end)
