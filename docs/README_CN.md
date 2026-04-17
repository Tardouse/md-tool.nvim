# md-tool.nvim

`md-tool.nvim` 是一个统一的 Neovim Markdown 工具插件。它把渲染增强、浏览器预览、表格格式化、目录生成、列表续写整合在同一套命名和配置下。

当前版本要求 Neovim `0.11.6+`。渲染模块依赖 Treesitter 的 `markdown` 与 `markdown_inline` parser。

## 功能概览

- `MDTrender*`：在 Neovim 内对标题、列表、引用、Callout、表格、代码块、分割线做增强渲染，不改动原始文本
- `MDTpriview*`：生成 HTML 预览，支持自动打开、手动浏览器命令、仅回显 URL
- `MDTtable*`：打开 buffer-local 表格模式，编辑时自动识别并格式化当前表格；插入态下 `|` 会补下一个单元格，`<CR>` 会生成分隔线或下一行，也支持手动格式化
- `MDTtoc*`：根据标题生成或更新 TOC，使用固定标记块
- `MDTlist*`：更保守的 Markdown 列表续写，替代侵入性更强的行为

默认情况下，新打开的 Markdown buffer 不会自动开启 table mode。若要每次打开都默认开启，可以在配置里设置 `table.enabled = true`。

## 安装

```lua
{
  "Tardouse/md-tool.nvim",
  ft = { "markdown" },
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  build = function(plugin)
    dofile(plugin.dir .. "/lua/md-tool/install.lua").build(plugin.dir)
  end,
  opts = {},
}
```

预览功能现在依赖仓库内的 Rust 二进制。对于 tag 版本安装，`build` 钩子会优先下载对应 GitHub Releases 的预编译二进制到 `bin/md-tool-preview`；如果当前 checkout 不是精确 tag、release 里没有对应 asset，或者本机没有可用下载工具，则自动回退到 `cargo build --release`。开发环境下插件仍会自动探测 `target/release/md-tool-preview`。你也可以把二进制放到 `$PATH`，或者显式设置 `preview.binary`。

### 示例文件

- [examples/lazy.lua](../examples/lazy.lua)：最简 `lazy.nvim` 配置，和 README 里的写法一致
- [examples/lazy_config.lua](../examples/lazy_config.lua)：完整 `lazy.nvim` 配置，包含所有默认值、中英文注释和可选值说明
- [examples/packer.lua](../examples/packer.lua)：`packer.nvim` 配置示例

其他插件管理器也可以直接复用同一份 `require("md-tool").setup({...})` 配置表。

## 基本配置

如果你想看“完整默认值 + 中英文注释 + 可选值说明”，直接参考 [examples/lazy_config.lua](../examples/lazy_config.lua)。下面这段仍然保留为简版示例。

```lua
require("md-tool").setup({
  render = {
    enabled = true,
    modes = { "n", "v", "V", "\22", "c" },
    debounce = 80,
    max_file_size = 5.0,
    visible_only = true,
    hide_on_cursorline = false,
    skip_concealed = true,
    heading = {
      enabled = true,
    },
    bullet = {
      enabled = true,
    },
    checkbox = {
      enabled = true,
    },
    quote = {
      enabled = true,
    },
    callout = {
      enabled = true,
    },
    code = {
      enabled = true,
      border = true,
      language = true,
      min_width = 24,
    },
    hr = {
      enabled = true,
    },
    table = {
      enabled = true,
      border = true,
      align = true,
    },
    link = {
      enabled = true,
    },
  },
  preview = {
    enabled = true,
    host = "127.0.0.1",
    port = 4399,
    binary = "auto",
    debounce = 150,
    startup_timeout = 5000,
    log_level = "info",
    auto_open = "auto",
    browser = "auto",
    echo_url = true,
  },
  table = {
    enabled = false,
    auto_align = false,
    format_on_save = false,
  },
  toc = {
    auto_update_on_save = true,
    GenAsUpdate = true,
  },
  list = {
    exit_on_empty = true,
    checked_to_unchecked = true,
  },
})
```

几个关键可选项说明：

- `render.modes` 按 `vim.api.nvim_get_mode().mode` 的前缀匹配；常见值有 `"n"`、`"no"`、`"i"`、`"R"`、`"v"`、`"V"`、`"\22"`、`"c"`。
- `preview.binary` 可选 `"auto"` 或一个可执行文件路径。
- `preview.auto_open` 可选 `true`、`false`、`"auto"`。
- `preview.browser` 可选 `"auto"`、`"echo"` 或自定义命令字符串；自定义命令可以包含 `%s` 作为 URL 占位符。
- `preview.log_level` 可选 `"trace"`、`"debug"`、`"info"`、`"warn"`、`"error"`。
- `toc.list_marker` 可选 `"-"`、`"*"`、`"+"`。
- `table.auto_align` 和 `render.link.*` 当前属于预留/兼容字段，已经做校验，但现阶段实现还没有实际消费它们。

## 预览服务

预览模块现在是一个本地 Rust 服务：

- Neovim 把原始 Markdown 发送到 `POST /update`
- Rust 服务用 `pulldown-cmark` 渲染成 HTML
- 浏览器通过 `GET /ws` 接收实时更新
- `GET /` 返回内嵌的最小 HTML 客户端

服务端只保存最新一份文档内容；如果 Markdown 没变化，就不会重复渲染或广播。Neovim 侧会对高频编辑事件做 debounce，避免输入时对本地服务造成无意义压力。

### 浏览器打开模式

- `browser = "auto"`：自动检测系统 opener
- `browser = "echo"`：只回显预览地址，不启动浏览器
- `browser = 'open -a "Google Chrome"'`：手动指定浏览器命令

在 SSH / 远程环境里，`auto_open = "auto"` 会默认退化成只回显地址。

### 手动运行预览服务

先构建二进制：

```bash
cargo build --release
```

带 tag 的插件 release 也会提供常见目标平台的预编译包：

- `x86_64-unknown-linux-gnu`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`
- `x86_64-pc-windows-msvc`

安装辅助脚本会尽量下载匹配的预编译包；如果不满足条件，再自动回退到本地 Cargo 编译。

如果你想单独看服务日志，也可以自己启动：

```bash
./target/release/md-tool-preview --host 127.0.0.1 --port 4399 --log-level info
```

插件默认会在第一次启用预览时自动拉起服务，并探活 `http://127.0.0.1:4399/health`，浏览器访问地址为 `http://127.0.0.1:4399/`。

## 渲染行为

- 渲染模块基于 Treesitter + extmark，不会修改 Markdown 原文
- 默认只刷新当前窗口可见区域，并对高频事件做 debounce，而不是每次编辑都整 buffer 重绘
- 标题会带层级图标和更明显的整行样式
- 无序列表和 task checkbox 会换成更干净的符号
- blockquote 会显示左侧引用条，常见的 `[!NOTE]` / `[!WARNING]` 这类 callout 也会更清晰
- fenced code block 会带上下边框和语言标签
- 分割线会重绘成整行 rule，inline code、斜体、粗体、粗斜体会隐藏各自的 Markdown 分隔符，并保留单独的内联高亮
- pipe table 会有表格边框/分隔行增强

现在推荐直接使用 `render.modes` 控制哪些模式下启用渲染。默认光标行也保持渲染；在 normal 模式下，`render.skip_concealed = true` 会让光标直接跳过被隐藏的 Markdown 分隔符，而不是停在看不见的 `*` 或 `` ` `` 上。如果你更希望当前行退回原始 Markdown，可以设置 `render.hide_on_cursorline = true`。为了兼容旧配置，`render.hide_in_insert` 仍然可用；如果没有显式设置 `render.modes`，它会被自动映射到新的模式配置。

## 列表行为

- 只在 `markdown` buffer 生效
- 跳过 fenced code block、frontmatter、疑似表格行
- 在已有列表项上，行尾按 `<CR>` 或 normal 模式按 `o` 时才尝试续写，尽量减少干扰
- insert 模式下可用 `<Tab>` / `<S-Tab>` 调整当前列表项层级
- `- `、`3. ` 这种空项在 `exit_on_empty = true` 时会退出列表
- task list 可配置为续写未勾选项，或者保留原始勾选状态

## TOC 标记

```md
<!-- markdown-toc-start -->
...
<!-- markdown-toc-end -->
```

- fenced code block 里的 TOC 标记会被忽略，不会被当成真实目录块。
- `MDTtocGen` 的行为由 `toc.GenAsUpdate` 控制。
- 当 `GenAsUpdate = true` 时，`MDTtocGen` 默认按“更新”处理：光标在某个 TOC 块内时，只更新当前这个块；光标不在任何 TOC 块内时，更新第一个；如果不存在 TOC，则在 frontmatter 和开头标题后附近插入一个新的。
- 当 `GenAsUpdate = false` 时，`MDTtocGen` 总是在当前光标位置直接生成一个新的 TOC，不管文件里是否已经存在旧 TOC。
- `MDTtocUpdate` 始终按“更新”处理：光标在某个 TOC 块内时，只更新这一个；光标不在任何 TOC 块内时，默认更新第一个；如果不存在 TOC，则在默认位置插入新的。

## 当前限制

- 预览目前是单文档实时会话，还没有做成多 buffer / 多路由预览
- 表格格式化只处理明显的 pipe table
- TOC anchor 是 GitHub 风格的近似实现
- 渲染目前聚焦核心 Markdown UI 元素，还没有覆盖 footnote、LaTeX、HTML comment、frontmatter 装饰

## 致谢

功能设计参考了这些项目的思路与经验：

- `MeanderingProgrammer/render-markdown.nvim`
- `iamcco/markdown-preview.nvim`
- `dhruvasagar/vim-table-mode`
- `mzlogin/vim-markdown-toc`
- `dkarter/bullets.vim`
