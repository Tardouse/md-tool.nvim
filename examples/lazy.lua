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

    -- [CN] 优先下载与当前 tag 匹配的预编译二进制；失败时回退到本地 Cargo 编译。
    -- [EN] Prefer the prebuilt binary for the current tag and fall back to a local Cargo build.
    build = function(plugin)
      dofile(plugin.dir .. "/lua/md-tool/install.lua").build(plugin.dir)
    end,

    -- [CN] 使用插件默认配置。
    -- [EN] Use the plugin defaults.
    opts = {},
  },
}
