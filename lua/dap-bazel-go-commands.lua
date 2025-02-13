local M = {}

function M.setup_commands()
	vim.api.nvim_create_user_command("DapBazelGoShowLogs", function()
		local log_file = require("dap-bazel-go-log").get_log_file()
		vim.cmd("tabnew " .. log_file)
	end, { desc = "Show nvim-dap-bazel-go logs" })
end

return M
