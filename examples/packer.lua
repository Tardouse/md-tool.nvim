return require("packer").startup(function(use)
  use({
    "Tardouse/md-tool.nvim",

    -- [CN] 只在 Markdown 文件中加载。
    -- [EN] Load only for Markdown buffers.
    ft = "markdown",

    -- [CN] 渲染模块依赖 Treesitter 的 Markdown parser。
    -- [EN] The render module depends on Treesitter Markdown parsers.
    requires = {
      "nvim-treesitter/nvim-treesitter",
    },

    -- [CN] 构建本地预览服务二进制。
    -- [EN] Build the local preview-server binary.
    run = "cargo build --release",

    -- [CN] 插件初始化入口。
    -- [EN] Plugin setup entrypoint.
    config = function()
      -- [CN] `setup({})` 表示使用默认配置；完整带中英文注释的默认值见 `examples/lazy_config.lua`。
      -- [EN] `setup({})` uses defaults; see `examples/lazy_config.lua` for the fully annotated config.
      require("md-tool").setup({})
    end,
  })
end)
