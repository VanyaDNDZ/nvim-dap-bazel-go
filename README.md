# nvim-dap-bazel-go

nvim-dap-bazel-go is an extension for [nvim-dap](https://github.com/mfussenegger/nvim-dap) that provides a seamless debugging experience for Go projects built with [Bazel](https://bazel.build/). It integrates with [Delve](https://github.com/go-delve/delve) to launch and debug Go applications and tests compiled by Bazel, handling source path mappings and test execution automatically.

## Features

- Automatically launches Delve for debugging Bazel-built Go binaries.
- Debug individual tests with TreeSitter-based test detection.
- Supports debugging Go applications and test files compiled by Bazel.
- Automatic conversion of source paths for breakpoints using `substitutePath`.
- Works with both `MODULE.bazel` and `WORKSPACE` Bazel workspaces.
- Customizable Delve configurations.
- Supports function breakpoints.

## Requirements

- Neovim 0.10+
- [nvim-dap](https://github.com/mfussenegger/nvim-dap)
- [Delve](https://github.com/go-delve/delve) (`dlv` must be installed and available in `$PATH`)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (for test detection)
- Bazel (installed and available in `$PATH`)

## Installation

### Using LazyVim

Add the following to your LazyVim plugin configuration:

```lua
return {
  {
    "VanyaDNDZ/nvim-dap-bazel-go",
    config = function()
      require("dap-bazel-go").setup({
        -- Delve configurations:
        delve = {
          path = "dlv", -- Path to the Delve binary
          initialize_timeout_sec = 20,
          port = "${port}",
          args = {},
          detached = vim.fn.has("win32") == 0,
        },
      })
      -- Optionally define key mappings:
      local dbgo = require("dap-bazel-go")
      vim.keymap.set("n", "<leader>dt", dbgo.debug_test_at_cursor, { desc = "Debug test at cursor" })
      vim.keymap.set("n", "<leader>df", dbgo.debug_file_test, { desc = "Debug file test" })
      vim.keymap.set("n", "<leader>dl", dbgo.debug_last_test, { desc = "Re-run last test" })
      vim.keymap.set("n", "<leader>dfb", dbgo.set_function_breakpoint, { desc = "Set function breakpoint" })
    end,
    dependencies = {
      "mfussenegger/nvim-dap",
      "nvim-treesitter/nvim-treesitter",
    },
  },
}
```

## Usage

## Key Mappings

## Acknowledgement

I would like to acknowledge [nvim-dap-go](https://github.com/leoluz/nvim-dap-go) for inspiration and [NVIDIA/bluebazel](https://github.com/NVIDIA/bluebazel) for insights on Bazel query.

## License

This plugin is licensed under the MIT License.
