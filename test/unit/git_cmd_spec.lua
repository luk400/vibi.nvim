-- test/unit/git_cmd_spec.lua
local git_cmd_mod = require("vibe.git.cmd")
local helpers = require("test.helpers.git_repo")
local eq = assert.are.equal

describe("Git Command Module", function()
    after_each(function()
        helpers.cleanup_all()
    end)

    describe("git_cmd", function()
        it("executes git commands and returns output", function()
            local repo_path = helpers.create_test_repo("cmd-test")
            local output, exit_code = git_cmd_mod.git_cmd({ "rev-parse", "--is-inside-work-tree" }, { cwd = repo_path })
            eq(0, exit_code)
            assert.is_truthy(output:match("true"))
        end)

        it("returns error for invalid commands", function()
            local output, exit_code, err = git_cmd_mod.git_cmd({ "invalid-command" }, { ignore_error = true })
            assert.is_not.equal(0, exit_code)
        end)

        it("respects cwd option", function()
            local repo_path = helpers.create_test_repo("cmd-cwd")
            local output, exit_code = git_cmd_mod.git_cmd(
                { "rev-parse", "--show-toplevel" },
                { cwd = repo_path, ignore_error = true }
            )
            eq(0, exit_code)
            assert.is_truthy(output)
        end)
    end)

    describe("with_temp_files", function()
        it("creates and cleans up temp files", function()
            local temp_paths = {}
            git_cmd_mod.with_temp_files(2, function(f1, f2)
                temp_paths = { f1, f2 }
                -- Files should be creatable
                vim.fn.writefile({ "test" }, f1)
                vim.fn.writefile({ "test2" }, f2)
                assert.is_true(vim.fn.filereadable(f1) == 1)
                assert.is_true(vim.fn.filereadable(f2) == 1)
            end)
            -- Files should be cleaned up after
            assert.is_true(vim.fn.filereadable(temp_paths[1]) == 0)
            assert.is_true(vim.fn.filereadable(temp_paths[2]) == 0)
        end)

        it("cleans up temp files even on error", function()
            local temp_paths = {}
            local ok = pcall(function()
                git_cmd_mod.with_temp_files(2, function(f1, f2)
                    temp_paths = { f1, f2 }
                    vim.fn.writefile({ "test" }, f1)
                    vim.fn.writefile({ "test2" }, f2)
                    error("intentional error")
                end)
            end)
            assert.is_false(ok)
            assert.is_true(vim.fn.filereadable(temp_paths[1]) == 0)
            assert.is_true(vim.fn.filereadable(temp_paths[2]) == 0)
        end)
    end)

    describe("get_worktree_base_dir", function()
        it("returns a valid directory path", function()
            local dir = git_cmd_mod.get_worktree_base_dir()
            assert.is_truthy(dir)
            assert.is_truthy(dir:match("vibe%-worktrees"))
        end)
    end)
end)
