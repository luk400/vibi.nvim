local M = {}

local config = require("vibe.config")

function M.git_cmd(args, opts)
    opts = opts or {}
    local cmd_parts = {}
    if opts.cwd then
        table.insert(cmd_parts, "cd")
        table.insert(cmd_parts, vim.fn.shellescape(opts.cwd))
        table.insert(cmd_parts, "&&")
    end
    table.insert(cmd_parts, "git")
    for _, arg in ipairs(args) do
        table.insert(cmd_parts, arg:match("[%s\"'`$]") and vim.fn.shellescape(arg) or arg)
    end
    local cmd = table.concat(cmd_parts, " ")
    local result = vim.fn.systemlist(cmd)
    local exit_code = vim.v.shell_error
    local output = table.concat(result, "\n")

    if exit_code ~= 0 then
        local error_msg = output:gsub("^%s+", ""):gsub("%s+$", "")
        if opts.ignore_error then
            return output, exit_code, error_msg
        end
        return "", exit_code, error_msg
    end
    return output, exit_code, nil
end

function M.get_worktree_base_dir()
    local opts = config.options or {}
    local worktree_opts = opts.worktree or {}
    return worktree_opts.worktree_dir or vim.fn.stdpath("cache") .. "/vibe-worktrees"
end

--- Execute a git command asynchronously via jobstart
---@param args string[] Git arguments
---@param opts table|nil Options (cwd, ignore_error)
---@param callback function Called with (output, exit_code, error_msg)
---@return integer job_id
function M.git_cmd_async(args, opts, callback)
    opts = opts or {}
    local cmd_parts = { "git" }
    for _, arg in ipairs(args) do
        table.insert(cmd_parts, arg)
    end

    local stdout_lines = {}
    local stderr_lines = {}

    local job_id = vim.fn.jobstart(cmd_parts, {
        cwd = opts.cwd,
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        table.insert(stdout_lines, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        table.insert(stderr_lines, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            vim.schedule(function()
                local output = table.concat(stdout_lines, "\n")
                local error_msg = nil
                if exit_code ~= 0 then
                    error_msg = table.concat(stderr_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
                    if error_msg == "" then
                        error_msg = output:gsub("^%s+", ""):gsub("%s+$", "")
                    end
                    if not opts.ignore_error then
                        output = ""
                    end
                end
                callback(output, exit_code, error_msg)
            end)
        end,
    })

    return job_id
end

--- Execute a function with temporary files, guaranteeing cleanup
---@param count number Number of temp files to create
---@param fn function Function receiving temp file paths as arguments
---@return any result from fn
function M.with_temp_files(count, fn)
    local files = {}
    for i = 1, count do
        files[i] = vim.fn.tempname()
    end
    local ok, result = pcall(fn, unpack(files))
    for _, f in ipairs(files) do
        vim.fn.delete(f)
    end
    if not ok then
        error(result)
    end
    return result
end

return M
