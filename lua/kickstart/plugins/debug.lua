-- debug.lua
--
-- Shows how to use the DAP plugin to debug your code.
--
-- Primarily focused on configuring the debugger for Go, but can
-- be extended to other languages as well. That's why it's called
-- kickstart.nvim and not kitchen-sink.nvim ;)

return {
  -- NOTE: Yes, you can install new plugins here!
  'mfussenegger/nvim-dap',
  -- NOTE: And you can specify dependencies as well
  dependencies = {
    -- Creates a beautiful debugger UI
    'rcarriga/nvim-dap-ui',

    -- Required dependency for nvim-dap-ui
    'nvim-neotest/nvim-nio',

    -- Installs the debug adapters for you
    'williamboman/mason.nvim',
    'jay-babu/mason-nvim-dap.nvim',

    -- Add your own debuggers here
    'leoluz/nvim-dap-go',
  },
  keys = function(_, keys)
    local dap = require 'dap'
    local dapui = require 'dapui'
    return {
      -- Basic debugging keymaps, feel free to change to your liking!
      { '<F5>', dap.continue, desc = 'Debug: Start/Continue' },
      { '<F1>', dap.step_into, desc = 'Debug: Step Into' },
      { '<F2>', dap.step_over, desc = 'Debug: Step Over' },
      { '<F3>', dap.step_out, desc = 'Debug: Step Out' },
      { '<leader>b', dap.toggle_breakpoint, desc = 'Debug: Toggle Breakpoint' },
      {
        '<leader>B',
        function()
          dap.set_breakpoint(vim.fn.input 'Breakpoint condition: ')
        end,
        desc = 'Debug: Set Breakpoint',
      },
      -- Toggle to see last session result. Without this, you can't see session output in case of unhandled exception.
      { '<F7>', dapui.toggle, desc = 'Debug: See last session result.' },
      unpack(keys),
    }
  end,
  config = function()
    local dap = require 'dap'
    local dapui = require 'dapui'

    require('mason-nvim-dap').setup {
      -- Makes a best effort to setup the various debuggers with
      -- reasonable debug configurations
      automatic_installation = true,

      -- You can provide additional configuration to the handlers,
      -- see mason-nvim-dap README for more information
      handlers = {},

      -- You'll need to check that you have the required things installed
      -- online, please don't ask me how to install them :)
      ensure_installed = {
        -- Update this to ensure that you have the debuggers for the langs you want
        'delve',
        'codelldb',
      },
    }

    -- Dap UI setup
    -- For more information, see |:help nvim-dap-ui|
    dapui.setup {
      -- Set icons to characters that are more likely to work in every terminal.
      --    Feel free to remove or use ones that you like more! :)
      --    Don't feel like these are good choices.
      icons = { expanded = '▾', collapsed = '▸', current_frame = '*' },
      controls = {
        icons = {
          pause = '⏸',
          play = '▶',
          step_into = '⏎',
          step_over = '⏭',
          step_out = '⏮',
          step_back = 'b',
          run_last = '▶▶',
          terminate = '⏹',
          disconnect = '⏏',
        },
      },
    }

    -- Change breakpoint icons
    -- vim.api.nvim_set_hl(0, 'DapBreak', { fg = '#e51400' })
    -- vim.api.nvim_set_hl(0, 'DapStop', { fg = '#ffcc00' })
    -- local breakpoint_icons = vim.g.have_nerd_font
    --     and { Breakpoint = '', BreakpointCondition = '', BreakpointRejected = '', LogPoint = '', Stopped = '' }
    --   or { Breakpoint = '●', BreakpointCondition = '⊜', BreakpointRejected = '⊘', LogPoint = '◆', Stopped = '⭔' }
    -- for type, icon in pairs(breakpoint_icons) do
    --   local tp = 'Dap' .. type
    --   local hl = (type == 'Stopped') and 'DapStop' or 'DapBreak'
    --   vim.fn.sign_define(tp, { text = icon, texthl = hl, numhl = hl })
    -- end

    dap.listeners.after.event_initialized['dapui_config'] = dapui.open
    dap.listeners.before.event_terminated['dapui_config'] = dapui.close
    dap.listeners.before.event_exited['dapui_config'] = dapui.close

    -- Install golang specific config
    require('dap-go').setup {
      delve = {
        -- On Windows delve must be run attached or it crashes.
        -- See https://github.com/leoluz/nvim-dap-go/blob/main/README.md#configuring
        detached = vim.fn.has 'win32' == 0,
      },
    }

    -- [[ Rust / C / C++ via codelldb ]] --------------------------------------
    --
    -- codelldb speaks DAP over a TCP socket: nvim-dap launches the binary with
    -- a port it picked, then connects to it.
    dap.adapters.codelldb = {
      type = 'server',
      port = '${port}',
      executable = {
        command = vim.fn.stdpath 'data' .. '/mason/bin/codelldb',
        args = { '--port', '${port}' },
      },
    }

    -- Rust's stdlib ships LLDB pretty-printers, without which a `String` shows
    -- up as a raw struct of pointers instead of its text. Load them per-session.
    local function rust_init_commands()
      local sysroot = vim.fn.system('rustc --print sysroot'):gsub('%s+$', '')
      if vim.v.shell_error ~= 0 or sysroot == '' then
        return {}
      end
      local etc = sysroot .. '/lib/rustlib/etc'
      return {
        'command script import "' .. etc .. '/lldb_lookup.py"',
        'command source -s 0 "' .. etc .. '/lldb_commands"',
      }
    end

    -- Build with cargo and return the path of the executable it produced.
    -- `--message-format=json` makes cargo report each artifact it emits, so we
    -- never have to guess at `target/debug/<name>` or invoke rustc by hand.
    --
    -- Runs inside nvim-dap's coroutine, so `vim.ui.select` can block on a
    -- choice when a crate builds more than one binary.
    local function cargo_artifact(args)
      local root = vim.fs.root(0, { 'Cargo.toml' })
      if not root then
        error 'not inside a cargo project (no Cargo.toml found)'
      end

      local cmd = vim.list_extend({ 'cargo', 'build', '--message-format=json' }, args)
      vim.notify('Running: ' .. table.concat(cmd, ' '), vim.log.levels.INFO)
      local out = vim.system(cmd, { cwd = root, text = true }):wait()

      local exes = {}
      for line in vim.gsplit(out.stdout or '', '\n', { trimempty = true }) do
        local ok, msg = pcall(vim.json.decode, line)
        -- `executable` is JSON null (vim.NIL) for lib crates and rmeta artifacts.
        if ok and msg.reason == 'compiler-artifact' and type(msg.executable) == 'string' then
          table.insert(exes, msg.executable)
        end
      end

      if #exes == 0 then
        error('cargo produced no executable:\n' .. (out.stderr or ''))
      elseif #exes == 1 then
        return exes[1]
      end

      local co = coroutine.running()
      vim.ui.select(exes, { prompt = 'Which binary to debug?' }, function(choice)
        coroutine.resume(co, choice)
      end)
      return coroutine.yield() or error 'no binary selected'
    end

    local function rust_config(name, build_args)
      return {
        name = name,
        type = 'codelldb',
        request = 'launch',
        program = function()
          return cargo_artifact(build_args)
        end,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
        -- codelldb's own key (not vscode's `console`): send the debuggee's
        -- stdout/stdin to a real terminal buffer so `println!` is visible and
        -- stdin works. Use 'console' instead if you don't need input.
        terminal = 'integrated',
        initCommands = rust_init_commands,
        -- Prompted for at launch; leave blank for none.
        args = function()
          return vim.split(vim.fn.input 'Program args: ', ' ', { trimempty = true })
        end,
      }
    end

    dap.configurations.rust = {
      rust_config('Debug binary (cargo build)', {}),
      rust_config('Debug unit tests (cargo test --no-run)', { '--tests' }),
      rust_config('Debug release binary', { '--release' }),
    }
  end,
}
