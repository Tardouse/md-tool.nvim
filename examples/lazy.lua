return {
  {
    "Tardouse/md-tool.nvim",

    -- [CN] 只在 Markdown 文件中加载。
    -- [EN] Load only for Markdown buffers.
    ft = { "markdown" },

    -- [CN] 渲染模块依赖 Treesitter 的 Markdown parser。
    -- [EN] The render module depends on Treesitter Markdown parsers.
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
    },

    -- [CN] 构建本地预览服务二进制。
    -- [EN] Build the local preview-server binary.
    build = "cargo build --release",

    -- [CN] 使用插件默认配置。
    -- [EN] Use the plugin defaults.
    opts = {},
  },
}
