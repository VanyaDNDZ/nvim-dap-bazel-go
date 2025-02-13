local M = {}

M.levels = {
	TRACE = 0,
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
	ERROR = 4,
}

-- Default log level (can be changed in setup)
M.current_level = M.levels.ERROR

-- Log file path inside Neovim's cache directory
M.log_file_path = vim.fn.stdpath("cache") .. "/dap-bazel-go.log"

local function write_to_file(level, message)
	-- Skip logging if the level is lower than the current log level
	if M.levels[level] < M.current_level then
		return
	end

	local f = io.open(M.log_file_path, "a")
	if not f then
		return
	end
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	f:write(string.format("[%s] [%s] %s\n", timestamp, level, message))
	f:close()
end

function M.log(level, ...)
	local args = { ... }
	local msg = table.concat(vim.tbl_map(vim.inspect, args), " ")
	write_to_file(level, msg)

	if level == "ERROR" then
		vim.notify("[dap-bazel-go] " .. msg, vim.log.levels.ERROR)
	end
end

function M.trace(...)
	M.log("TRACE", ...)
end
function M.debug(...)
	M.log("DEBUG", ...)
end
function M.info(...)
	M.log("INFO", ...)
end
function M.warn(...)
	M.log("WARN", ...)
end
function M.error(...)
	M.log("ERROR", ...)
end

-- Set the logging level from user configuration
function M.set_level(level)
	if type(level) == "string" then
		level = M.levels[level:upper()]
	end
	if level ~= nil then -- Ensure level exists in our defined levels
		M.current_level = level
	else
		M.warn("Invalid log level: " .. vim.inspect(level))
	end
end

function M.get_log_file()
	return M.log_file_path
end

return M
