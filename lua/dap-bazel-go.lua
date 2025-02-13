local M = {
	last_testname = nil,
	last_target = nil,
}
local log = require("dap-bazel-go-log")

--------------------------------------------------------------------------------
-- 1) Find the WORKSPACE root by walking up from the current file's directory
--------------------------------------------------------------------------------
local function find_bazel_workspace_root()
	local start_dir = vim.fn.expand("%:p:h") or vim.fn.getcwd()
	log.debug("[dap-bazel-go] Searching for WORKSPACE from: " .. start_dir)

	local dir = start_dir
	while dir ~= "/" do
		local ws1 = dir .. "/WORKSPACE"
		local ws2 = dir .. "/WORKSPACE.bazel"
		if vim.fn.filereadable(ws1) == 1 or vim.fn.filereadable(ws2) == 1 then
			log.debug("[dap-bazel-go] Found WORKSPACE at: " .. dir)
			return dir
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end

	local fallback = vim.fn.getcwd()
	log.warn("[dap-bazel-go] No WORKSPACE found; fallback to CWD: " .. fallback)
	return fallback
end

--------------------------------------------------------------------------------
-- 2) Convert absolute path -> workspace-relative path, logging what happens.
--------------------------------------------------------------------------------
local function to_workspace_relative(abs_path)
	local ws_root = find_bazel_workspace_root()
	local pattern = "^" .. vim.pesc(ws_root) .. "[/\\]?"
	local rel = abs_path:gsub(pattern, "")
	log.info(string.format("[dap-bazel-go] Converted '%s' -> '%s' (WS root: %s)", abs_path, rel, ws_root))
	return rel, ws_root
end

--------------------------------------------------------------------------------
-- 3) Use bazel query to find which go_test references this file
--------------------------------------------------------------------------------
local function find_go_test_target_for_file(file_path)
	local rel_path = to_workspace_relative(file_path)
	local cmd = string.format([[bazel query "kind(go_test, rdeps(//..., '%s'))" 2>/dev/null]], rel_path)

	log.info("[dap-bazel-go] Running Bazel query: " .. cmd)
	local lines = vim.fn.systemlist(cmd)
	if #lines > 0 then
		log.info("[dap-bazel-go] Bazel query output:\n" .. table.concat(lines, "\n"))
	else
		log.debug("[dap-bazel-go] Bazel query returned no lines")
	end

	if vim.v.shell_error ~= 0 or #lines == 0 then
		log.debug("[dap-bazel-go] Bazel query error or empty result")
		return nil
	end

	local target = lines[1]
	log.info("[dap-bazel-go] Found matching go_test target: " .. target)
	return target
end

--------------------------------------------------------------------------------
-- 4) Convert label //pkg:my_test -> bazel-bin/pkg/my_test_/my_test
--------------------------------------------------------------------------------
local function bazel_label_to_binpath(label)
	local trimmed = label:gsub("^//", "")
	local pkg, rulename = trimmed:match("^(.-):(.*)$")
	if not pkg or not rulename then
		log.error("[dap-bazel-go] Could not parse label: " .. label)
		return nil
	end
	local binpath = string.format("bazel-bin/%s/%s_/%s", pkg, rulename, rulename)
	log.info(string.format("[dap-bazel-go] Label '%s' => binary path '%s'", label, binpath))
	return binpath
end

--------------------------------------------------------------------------------
-- 5) Build with Bazel in debug mode, logging the command and output
--------------------------------------------------------------------------------
local function build_bazel_target(label)
	local cmd = string.format("bazel build -c dbg %s", label)
	log.info("[dap-bazel-go] Building: " .. cmd)
	local output = vim.fn.systemlist(cmd)
	if #output > 0 then
		log.info("[dap-bazel-go] Build output:\n" .. table.concat(output, "\n"))
	end

	if vim.v.shell_error ~= 0 then
		log.error("[dap-bazel-go] Bazel build failed. See output above.")
		return nil
	end

	local binpath = bazel_label_to_binpath(label)
	return binpath
end

--------------------------------------------------------------------------------
-- 6) Load nvim-dap or error
--------------------------------------------------------------------------------
local function load_dap()
	local ok, dap = pcall(require, "dap")
	if not ok then
		error("[dap-bazel-go] nvim-dap not installed or require failed.")
	end
	dap.set_log_level("DEBUG")
	return dap
end

--------------------------------------------------------------------------------
-- 7) Delve default config. We'll add mode='exec' for test binaries.
--------------------------------------------------------------------------------
local default_delve_config = {
	path = "dlv",
	initialize_timeout_sec = 20,
	port = "${port}",
	args = {},
	detached = (vim.fn.has("win32") == 0),
	output_mode = "remote",
}

--------------------------------------------------------------------------------
-- 8) Setup the Delve "go" adapter. We'll log the final dlv command line.
--------------------------------------------------------------------------------
local function setup_delve_adapter(dap, conf)
	-- The base command arguments for dlv:
	local adapter_args = { "dap", "-l", "127.0.0.1:" .. conf.port }
	if conf.args and #conf.args > 0 then
		log.info("[dap-bazel-go] Additional dlv args: " .. table.concat(conf.args, " "))
	end
	vim.list_extend(adapter_args, conf.args or {})

	local base = {
		type = "server",
		port = conf.port,
		executable = {
			command = conf.path,
			args = adapter_args,
			detached = conf.detached,
			cwd = conf.cwd,
		},
		options = {
			initialize_timeout_sec = conf.initialize_timeout_sec,
		},
	}

	-- Log the final dlv command
	log.info(
		string.format(
			"[dap-bazel-go] Delve adapter command: %s %s",
			base.executable.command,
			table.concat(base.executable.args, " ")
		)
	)

	dap.adapters.go = function(callback, client_config)
		if not client_config.port then
			callback(base)
			return
		end

		local host = client_config.host or "127.0.0.1"
		local addr = host .. ":" .. client_config.port
		local new_cfg = vim.deepcopy(base)
		new_cfg.port = client_config.port
		new_cfg.executable.args = { "dap", "-l", addr }

		log.info(
			string.format(
				"[dap-bazel-go] Overriding dlv adapter to: %s %s",
				new_cfg.executable.command,
				table.concat(new_cfg.executable.args, " ")
			)
		)

		callback(new_cfg)
	end
end

local function setup_bazel_go_configuration(dap)
	local ws_root_fn = function()
		return find_bazel_workspace_root()
	end
	local substitutePath_fn = function()
		local ws = find_bazel_workspace_root()
		return { { from = ws, to = "" } }
	end

	local common_configs = {
		{
			type = "go",
			name = "Debug File Test (Bazel)",
			request = "launch",
			mode = "exec", -- using pre-built test binaries
			program = function()
				local file_path = vim.fn.expand("%:p")
				local target = find_go_test_target_for_file(file_path)
				if not target then
					log.error("[dap-bazel-go] No go_test target found for: " .. file_path)
					return nil
				end
				local binpath = build_bazel_target(target)
				if binpath and not binpath:match("^/") then
					binpath = find_bazel_workspace_root() .. "/" .. binpath
				end
				return binpath
			end,
			cwd = ws_root_fn,
			substitutePath = substitutePath_fn,
		},
		{
			type = "go",
			name = "Debug Test at Cursor (Bazel)",
			request = "launch",
			mode = "exec",
			program = function()
				local file_path = vim.fn.expand("%:p")
				local target = find_go_test_target_for_file(file_path)
				if not target then
					log.error("[dap-bazel-go] No go_test target found for: " .. file_path)
					return nil
				end
				local binpath = build_bazel_target(target)
				if binpath and not binpath:match("^/") then
					binpath = find_bazel_workspace_root() .. "/" .. binpath
				end
				return binpath
			end,
			args = function()
				local has_ts, ts = pcall(require, "dap-bazel-go-ts")
				if has_ts then
					local info = ts.closest_test()
					if info and info.name then
						return { "-test.run", "^" .. info.name .. "$" }
					end
				end
				return {}
			end,
			cwd = ws_root_fn,
			substitutePath = substitutePath_fn,
		},
		{
			type = "go",
			name = "Debug Last Test (Bazel)",
			request = "launch",
			mode = "exec",
			program = function()
				if not M.last_target then
					log.warn("[dap-bazel-go] No last Bazel-Go test target recorded")
					return nil
				end
				local binpath = build_bazel_target(M.last_target)
				if binpath and not binpath:match("^/") then
					binpath = find_bazel_workspace_root() .. "/" .. binpath
				end
				return binpath
			end,
			args = function()
				if M.last_testname then
					return { "-test.run", "^" .. M.last_testname .. "$" }
				end
				return {}
			end,
			cwd = ws_root_fn,
			substitutePath = substitutePath_fn,
		},

		{
			type = "go",
			name = "Attach to Bazel Program (Bazel)", -- changed name to indicate attach mode
			request = "attach", -- attach request instead of launch
			mode = "local", -- local mode for attaching
			processId = require("dap.utils").pick_process, -- uses the built-in process picker
			cwd = function()
				return find_bazel_workspace_root()
			end,
			substitutePath = substitutePath_fn,
		},
	}

	dap.configurations.go = common_configs
end

--------------------------------------------------------------------------------
-- 8.5) (Optional) A breakpoint listener that tries to adjust breakpoint paths.
-- You can disable this if you rely on substitutePath.
--------------------------------------------------------------------------------
local function adjust_breakpoint_paths()
	local dap = load_dap()
	dap.listeners.before["setBreakpoints"] = dap.listeners.before["setBreakpoints"] or {}
	dap.listeners.before["setBreakpoints"]["adjust_paths"] = function(session, body)
		if not body then
			return
		end
		local ws_root = find_bazel_workspace_root()
		if body.breakpoints then
			for _, bp in ipairs(body.breakpoints) do
				if bp.source and bp.source.path then
					local original = bp.source.path
					bp.source.path = bp.source.path:gsub("^" .. vim.pesc(ws_root) .. "[/\\]?", "")
					log.info("[dap-bazel-go] Adjusted breakpoint path: " .. original .. " -> " .. bp.source.path)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 9) The .setup() function called by your plugin spec
--------------------------------------------------------------------------------
function M.setup(opts)
	opts = opts or {}

	local log_level = opts.logging and opts.logging.level or "ERROR"
	log.set_level(log_level) -- Set log level from user config

	local dap_conf = vim.tbl_deep_extend("force", default_delve_config, opts)
	local dap = load_dap()
	setup_delve_adapter(dap, dap_conf)

	require("dap-bazel-go-commands").setup_commands()
	-- Remove any pre-defined configurations so we can use our custom ones.

	setup_bazel_go_configuration(dap)
	-- Optionally adjust breakpoint file paths.
	adjust_breakpoint_paths()

	log.info(string.format("[dap-bazel-go] Setup complete. Using dlv: %s", dap_conf.path))
end

--------------------------------------------------------------------------------
-- 10) debug_test_internal(): build + run dlv with mode='exec'
-- Pre-built Bazel test binaries are already compiled, so we use mode "exec"
-- to avoid invoking "go test -c", which fails because the package path is invalid.
--------------------------------------------------------------------------------
local function debug_test_internal(subtest, label)
	local dap = load_dap()
	log.info("[dap-bazel-go] About to build target: " .. label)

	local binpath = build_bazel_target(label)
	if not binpath then
		log.error("[dap-bazel-go] Build step failed or returned nil path")
		return
	end

	-- Get the workspace root and ensure the binary path is absolute.
	local ws_root = find_bazel_workspace_root()
	if not binpath:match("^/") then
		binpath = ws_root .. "/" .. binpath
	end

	log.info("[dap-bazel-go] Delve launching program: " .. binpath)

	local config = {
		type = "go",
		name = "[Bazel-Go] " .. (subtest or label),
		request = "launch",
		mode = "exec", -- use "exec" mode for pre-built test binaries
		program = binpath,
		args = {},
		cwd = ws_root,
		-- This substitutePath mapping tells Delve to remove the workspace prefix
		-- so that source paths become relative to the cwd.
		substitutePath = {
			{ from = ws_root, to = "" },
		},
	}

	if subtest then
		table.insert(config.args, "-test.run")
		table.insert(config.args, "^" .. subtest .. "$")
		log.info(string.format("[dap-bazel-go] Running only subtest: ^%s$", subtest))
	else
		log.info("[dap-bazel-go] Running all tests in: " .. label)
	end

	dap.run(config)
end

--------------------------------------------------------------------------------
-- 11) Public methods:
--     debug_test_at_cursor(), debug_file_test(), debug_last_test(),
--     and new debug_program() for regular (non-test) Go files.
--------------------------------------------------------------------------------
function M.debug_test_at_cursor()
	local file_path = vim.fn.expand("%:p")
	local target = find_go_test_target_for_file(file_path)
	if not target then
		log.error("[dap-bazel-go] No go_test target found for: " .. file_path)
		return
	end

	local has_ts, ts = pcall(require, "dap-bazel-go-ts")
	if has_ts then
		local info = ts.closest_test()
		if info and info.name then
			log.info("[dap-bazel-go] Subtest under cursor: " .. info.name)
			M.last_testname = info.name
			M.last_target = target
			debug_test_internal(M.last_testname, target)
			return
		end
	end

	log.info("[dap-bazel-go] No subtest detection or none found; debugging entire file")
	M.last_testname = nil
	M.last_target = target
	debug_test_internal(nil, target)
end

function M.debug_file_test()
	local file_path = vim.fn.expand("%:p")
	local target = find_go_test_target_for_file(file_path)
	if not target then
		log.error("[dap-bazel-go] No go_test target found for: " .. file_path)
		return
	end
	M.last_testname = nil
	M.last_target = target
	debug_test_internal(nil, target)
end

function M.debug_last_test()
	if not M.last_target then
		log.warn("[dap-bazel-go] No last Bazel-Go test target recorded")
		return
	end
	debug_test_internal(M.last_testname, M.last_target)
end

--------------------------------------------------------------------------------
-- New function: debug_program() for debugging a regular Go file using its full path.
--------------------------------------------------------------------------------
function M.debug_program()
	local dap = load_dap()
	local file_path = vim.fn.expand("%:p")
	if file_path == "" then
		log.error("[dap-bazel-go] No file found")
		return
	end

	local ws_root = find_bazel_workspace_root()
	local config = {
		type = "go",
		name = "Debug Program: " .. file_path,
		request = "launch",
		mode = "debug", -- use "debug" mode for regular executables
		program = file_path, -- full path to your .go file
		cwd = vim.fn.fnamemodify(file_path, ":h"), -- working directory of the file
		substitutePath = {
			{ from = ws_root, to = "" },
		},
	}

	dap.run(config)
end

--------------------------------------------------------------------------------
-- New function: set a breakpoint on a function name.
-- This prompts for a function name and then sets a function breakpoint.
--------------------------------------------------------------------------------
function M.set_function_breakpoint()
	local dap = load_dap()
	local func = vim.fn.input("Function breakpoint: ")
	if func ~= "" then
		-- This uses nvim-dap's built-in breakpoint setter.
		-- Delve’s adapter supports function breakpoints when given a function name.
		dap.set_breakpoint(func)
		log.info("Set function breakpoint on: " .. func)
	end
end

return M
