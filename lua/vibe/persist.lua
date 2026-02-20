local M = {}

---@class AddressedHunk
---@field filepath string Relative file path
---@field hunk_hash string Hash identifying the hunk
---@field action "accepted"|"rejected"
---@field timestamp number Unix timestamp

---@class PersistedSession
---@field name string Session name
---@field worktree_path string Path to the worktree directory
---@field branch string The vibe branch name
---@field snapshot_commit string Commit hash of the snapshot
---@field original_branch string The branch the user was on
---@field repo_root string Path to the main repository root
---@field cwd string Original working directory (user's repo)
---@field created_at number Unix timestamp when session was created
---@field last_active number Unix timestamp of last activity
---@field has_terminal boolean Whether the terminal is currently active
---@field addressed_hunks AddressedHunk[]|nil Hunks that have been explicitly addressed

--- Get the path to the sessions file
---@return string
local function get_sessions_file()
	local cache_dir = vim.fn.stdpath("cache") .. "/vibe-worktrees"
	vim.fn.mkdir(cache_dir, "p")
	return cache_dir .. "/sessions.json"
end

--- Load all persisted sessions
---@return PersistedSession[]
function M.load_sessions()
	local sessions_file = get_sessions_file()
	if vim.fn.filereadable(sessions_file) == 0 then
		return {}
	end

	local content = vim.fn.readfile(sessions_file)
	if not content or #content == 0 then
		return {}
	end

	local ok, sessions = pcall(vim.fn.json_decode, table.concat(content, "\n"))
	if not ok or type(sessions) ~= "table" then
		return {}
	end

	return sessions
end

--- Save all sessions to disk
---@param sessions PersistedSession[]
function M.save_sessions(sessions)
	sessions = sessions or {}
	local sessions_file = get_sessions_file()
	local content = vim.fn.json_encode(sessions)
	vim.fn.writefile({ content }, sessions_file)
end

--- Save or update a single session
---@param session PersistedSession
function M.save_session(session)
	if not session or not session.worktree_path then
		return
	end

	local sessions = M.load_sessions()

	-- Update existing or add new
	local found = false
	for i, s in ipairs(sessions) do
		if s.worktree_path == session.worktree_path then
			sessions[i] = session
			found = true
			break
		end
	end

	if not found then
		table.insert(sessions, session)
	end

	M.save_sessions(sessions)
end

--- Remove a session by worktree path
---@param worktree_path string
function M.remove_session(worktree_path)
	local sessions = M.load_sessions()
	local new_sessions = {}

	for _, s in ipairs(sessions) do
		if s.worktree_path ~= worktree_path then
			table.insert(new_sessions, s)
		end
	end

	M.save_sessions(new_sessions)
end

--- Get sessions that have valid worktrees (worktree directory exists)
---@return PersistedSession[]
function M.get_valid_persisted_sessions()
	local sessions = M.load_sessions()
	local valid = {}

	for _, s in ipairs(sessions) do
		if s.worktree_path and vim.fn.isdirectory(s.worktree_path) == 1 then
			table.insert(valid, s)
		end
	end

	return valid
end

--- Format a timestamp to human-readable format
---@param timestamp number Unix timestamp
---@return string
function M.format_timestamp(timestamp)
	if not timestamp then
		return "unknown"
	end

	local time = os.time() - timestamp

	-- Less than a minute
	if time < 60 then
		return "just now"
	end
	-- Less than an hour
	if time < 3600 then
		local mins = math.floor(time / 60)
		return mins .. " min" .. (mins ~= 1 and "s" or "") .. " ago"
	end
	-- Less than a day
	if time < 86400 then
		local hours = math.floor(time / 3600)
		return hours .. " hour" .. (hours ~= 1 and "s" or "") .. " ago"
	end
	-- Less than a week
	if time < 604800 then
		local days = math.floor(time / 86400)
		return days .. " day" .. (days ~= 1 and "s" or "") .. " ago"
	end

	-- Format as date
	return os.date("%b %d, %H:%M", timestamp)
end

--- Mark all sessions as not having active terminals (called on quit)
function M.mark_all_sessions_paused()
	local sessions = M.load_sessions()
	for i, s in ipairs(sessions) do
		s.has_terminal = false
		s.last_active = os.time()
	end
	M.save_sessions(sessions)
end

--- Clean up sessions with invalid worktrees
function M.cleanup_invalid_sessions()
	local sessions = M.load_sessions()
	local valid = {}

	for _, s in ipairs(sessions) do
		if s.worktree_path and vim.fn.isdirectory(s.worktree_path) == 1 then
			table.insert(valid, s)
		end
	end

	M.save_sessions(valid)
end

return M
