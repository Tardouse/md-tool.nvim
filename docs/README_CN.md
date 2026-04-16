# md-tool.nvim

`md-tool.nvim` 是一个统一的 Neovim Markdown 工具插件。它把渲染增强、浏览器预览、表格格式化、目录生成、列表续写整合在同一套命名和配置下。

## 功能概览

- `MDTrender*`：在 Neovim 内做轻量渲染增强，不改动原始文本
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
  opts = {},
}
```

## 基本配置

```lua
require("md-tool").setup({
  table = {
    enabled = false,
  },
  preview = {
    auto_open = "auto",
    browser = "auto",
    echo_url = true,
  },
  table = {
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

## 预览模式

- `browser = "auto"`：自动检测系统 opener
- `browser = "echo"`：只回显预览地址，不启动浏览器
- `browser = 'open -a "Google Chrome"'`：手动指定浏览器命令

当前 MVP 会把 Markdown 渲染成 HTML，写到 `stdpath("cache")/md-tool/preview/` 下，再打开对应的 `file://` URL。`host` 和 `port` 已保留，方便后续升级成真正的本地预览服务。

在 SSH / 远程环境里，`auto_open = "auto"` 会默认退化成只回显地址。

## 列表行为

- 只在 `markdown` buffer 生效
- 跳过 fenced code block、frontmatter、疑似表格行
- 只在行尾按 `<CR>` 时才尝试续写，尽量减少干扰
- `- `、`3. ` 这种空项在 `exit_on_empty = true` 时会退出列表
- task list 可配置为续写未勾选项，或者保留原始勾选状态

`MDTlistFormat` 当前用于重排光标所在有序列表的编号。

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

- 预览还是文件式 MVP，不是实时 HTTP 服务
- 渲染增强目前以轻量规则匹配为主
- 表格格式化只处理明显的 pipe table
- TOC anchor 是 GitHub 风格的近似实现

## 致谢

功能设计参考了这些项目的思路与经验：

- `MeanderingProgrammer/render-markdown.nvim`
- `iamcco/markdown-preview.nvim`
- `dhruvasagar/vim-table-mode`
- `mzlogin/vim-markdown-toc`
- `dkarter/bullets.vim`
