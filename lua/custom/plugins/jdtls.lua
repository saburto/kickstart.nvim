local java_filetypes = { 'java' }

local function extend_or_override(config, custom, ...)
  if type(custom) == 'function' then
    config = custom(config, ...) or config
  elseif custom then
    config = vim.tbl_deep_extend('force', config, custom) --[[@as table]]
  end
  return config
end

return {
  {
    'mfussenegger/nvim-jdtls',
    dependencies = { 'folke/which-key.nvim' },
    ft = java_filetypes,
    opts = function()
      local cmd = { vim.fn.exepath 'jdtls' }
      local lombok_jar = vim.fn.expand '$MASON/packages/jdtls/lombok.jar'
      table.insert(cmd, string.format('--jvm-arg=-javaagent:%s', lombok_jar))
      return {
        -- How to find the root dir for a given filename. The default comes from
        -- lspconfig which provides a function specifically for java projects.
        root_dir = function()
          return vim.fs.dirname(vim.fs.find({ 'gradlew', '.git', 'mvnw', 'pom.xml' }, { upward = true })[1])
        end,
        -- How to find the project name for a given root dir.
        project_name = function(root_dir)
          return root_dir and vim.fs.basename(root_dir)
        end,

        -- Where are the config and workspace dirs for a project?
        jdtls_config_dir = function(project_name)
          return vim.fn.stdpath 'cache' .. '/jdtls/' .. project_name .. '/config'
        end,
        jdtls_workspace_dir = function(project_name)
          return vim.fn.stdpath 'cache' .. '/jdtls/' .. project_name .. '/workspace'
        end,

        -- How to run jdtls. This can be overridden to a full java command-line
        -- if the Python wrapper script doesn't suffice.
        cmd = cmd,
        full_cmd = function(opts)
          local fname = vim.api.nvim_buf_get_name(0)
          local root_dir = opts.root_dir(fname)
          local project_name = opts.project_name(root_dir)
          local cmd = vim.deepcopy(opts.cmd)
          if project_name then
            vim.list_extend(cmd, {
              '-configuration',
              opts.jdtls_config_dir(project_name),
              '-data',
              opts.jdtls_workspace_dir(project_name),
            })
          end
          return cmd
        end,

        -- These depend on nvim-dap, but can additionally be disabled by setting false here.
        dap = { hotcodereplace = 'auto', config_overrides = {} },
        -- Can set this to false to disable main class scan, which is a performance killer for large project
        dap_main = {},
        test = true,
        settings = {
          java = {
            inlayHints = {
              parameterNames = {
                enabled = 'all',
              },
            },
          },
        },
      }
    end,
    config = function(_, opts)
      -- Find the extra bundles that should be passed on the jdtls command-line
      -- if nvim-dap is enabled with java debug/test.
      local bundles = {} ---@type string[]
      --   local java_dbg_pkg = mason_registry.get_package 'java-debug-adapter'
      local java_dbg_path = vim.fn.expand '$MASON/packages/java-debug-adapter'
      local jar_patterns = {
        java_dbg_path .. '/extension/server/com.microsoft.java.debug.plugin-*.jar',
      }
      --   -- java-test also depends on java-debug-adapter.
      local java_test_path = vim.fn.expand '$MASON/packages/java-test'
      vim.list_extend(jar_patterns, {
        java_test_path .. '/extension/server/*.jar',
      })
      for _, jar_pattern in ipairs(jar_patterns) do
        for _, bundle in ipairs(vim.split(vim.fn.glob(jar_pattern), '\n')) do
          table.insert(bundles, bundle)
        end
      end
      -- end
      local function attach_jdtls()
        local fname = vim.api.nvim_buf_get_name(0)

        -- Configuration can be augmented and overridden by opts.jdtls
        local config = extend_or_override({
          cmd = opts.full_cmd(opts),
          root_dir = opts.root_dir(fname),
          init_options = {
            bundles = bundles,
          },
          settings = opts.settings,
          capabilities = require('blink.cmp').get_lsp_capabilities(),
        }, opts.jdtls)

        -- Existing server will be reused if the root_dir matches.
        require('jdtls').start_or_attach(config)
        -- not need to require("jdtls.setup").add_commands(), start automatically adds commands
      end

      -- Attach the jdtls for each java buffer. HOWEVER, this plugin loads
      -- depending on filetype, so this autocmd doesn't run for the first file.
      -- For that, we call directly below.
      vim.api.nvim_create_autocmd('FileType', {
        pattern = java_filetypes,
        callback = attach_jdtls,
      })

      -- Setup keymap and dap after the lsp is fully attached.
      -- https://github.com/mfussenegger/nvim-jdtls#nvim-dap-configuration
      -- https://neovim.io/doc/user/lsp.html#LspAttach
      vim.api.nvim_create_autocmd('LspAttach', {
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client and client.name == 'jdtls' then
            local wk = require 'which-key'
            wk.add {
              {
                mode = 'n',
                buffer = args.buf,
                { '<leader>cx', group = 'extract' },
                { '<leader>cxv', require('jdtls').extract_variable_all, desc = 'Extract Variable' },
                { '<leader>cxc', require('jdtls').extract_constant, desc = 'Extract Constant' },
                { '<leader>cgs', require('jdtls').super_implementation, desc = 'Goto Super' },
                { '<leader>cgS', require('jdtls.tests').goto_subjects, desc = 'Goto Subjects' },
                { '<leader>co', require('jdtls').organize_imports, desc = 'Organize Imports' },
              },
            }
            wk.add {
              {
                mode = 'v',
                buffer = args.buf,
                { '<leader>cx', group = 'extract' },
                {
                  '<leader>cxm',
                  [[<ESC><CMD>lua require('jdtls').extract_method(true)<CR>]],
                  desc = 'Extract Method',
                },
                {
                  '<leader>cxv',
                  [[<ESC><CMD>lua require('jdtls').extract_variable_all(true)<CR>]],
                  desc = 'Extract Variable',
                },
                {
                  '<leader>cxc',
                  [[<ESC><CMD>lua require('jdtls').extract_constant(true)<CR>]],
                  desc = 'Extract Constant',
                },
              },
            }

            require('jdtls').setup_dap(opts.dap)
            if opts.dap_main then
              require('jdtls.dap').setup_dap_main_class_configs(opts.dap_main)
            end

            if opts.test then
              wk.add {
                {
                  mode = 'n',
                  buffer = args.buf,
                  { '<leader>t', group = 'test' },
                  {
                    '<leader>tt',
                    function()
                      require('jdtls.dap').test_class {
                        config_overrides = type(opts.test) ~= 'boolean' and opts.test.config_overrides or nil,
                      }
                    end,
                    desc = 'Run All Test',
                  },
                  {
                    '<leader>tr',
                    function()
                      require('jdtls.dap').test_nearest_method {
                        config_overrides = type(opts.test) ~= 'boolean' and opts.test.config_overrides or nil,
                      }
                    end,
                    desc = 'Run Nearest Test',
                  },
                  { '<leader>tT', require('jdtls.dap').pick_test, desc = 'Run Test' },
                },
              }
            end
            if opts.on_attach then
              opts.on_attach(args)
            end
          end
        end,
      })

      -- Avoid race condition by calling attach the first time, since the autocmd won't fire.
      attach_jdtls()
    end,
  },
}
