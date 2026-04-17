return {
	{
		"Tardouse/md-tool.nvim",

		-- [CN] 仅在 Markdown buffer 中加载插件，减少非 Markdown 场景的启动开销。
		-- [EN] Load the plugin only for Markdown buffers to reduce startup overhead elsewhere.
		ft = { "markdown" },

		-- [CN] 依赖 Treesitter 提供 `markdown` 和 `markdown_inline` parser。
		-- [EN] Depends on Treesitter for the `markdown` and `markdown_inline` parsers.
		dependencies = {
			"nvim-treesitter/nvim-treesitter",
		},

		-- [CN] 优先下载与当前 tag 匹配的预编译二进制；失败时回退到本地 Cargo 编译。
		-- [EN] Prefer the prebuilt binary for the current tag and fall back to a local Cargo build.
		build = function(plugin)
			dofile(plugin.dir .. "/lua/md-tool/install.lua").build(plugin.dir)
		end,

		-- [CN] 传给 `require("md-tool").setup()` 的完整默认配置。
		-- [EN] Full default configuration passed to `require("md-tool").setup()`.
		opts = {
			render = {
				-- [CN] 是否默认启用缓冲区内 Markdown 渲染增强。
				-- [EN] Enable in-editor Markdown render decorations by default.
				enabled = true,

				-- [CN] 兼容旧配置的开关；仅当你没有显式设置 `render.modes` 时才会参与计算。
				-- [CN] 可选值: `true` = 默认不在插入/替换模式渲染；`false` = 自动把 `"i"` 和 `"R"` 加入默认模式列表。
				-- [EN] Backward-compatible switch; only matters when `render.modes` is not set explicitly.
				-- [EN] Choices: `true` = do not render in insert/replace by default; `false` = append `"i"` and `"R"` to the default mode list.
				hide_in_insert = true,

				-- [CN] 允许渲染的模式前缀列表，按 `vim.api.nvim_get_mode().mode` 前缀匹配。
				-- [CN] 常见可选值: `"n"`(普通模式), `"no"`(operator-pending), `"i"`(插入), `"R"`(替换), `"v"`(字符可视), `"V"`(行可视), `"\22"`(块可视), `"c"`(命令行)。
				-- [EN] Mode-prefix list used to decide when rendering is active, matched against `vim.api.nvim_get_mode().mode`.
				-- [EN] Common values: `"n"` normal, `"no"` operator-pending, `"i"` insert, `"R"` replace, `"v"` visual-char, `"V"` visual-line, `"\22"` visual-block, `"c"` command-line.
				modes = { "n", "v", "V", "\22", "c" },

				-- [CN] 渲染刷新防抖时间，单位毫秒；`0` 表示不额外等待。
				-- [CN] 可选值: 任意非负整数。
				-- [EN] Debounce delay for render refreshes in milliseconds; `0` means no extra wait.
				-- [EN] Choices: any non-negative integer.
				debounce = 80,

				-- [CN] 超过该文件大小后跳过渲染，单位 MB，用于避免大文件卡顿。
				-- [CN] 可选值: 任意正数。
				-- [EN] Skip render when the file is larger than this size in MB to avoid heavy redraw cost.
				-- [EN] Choices: any positive number.
				max_file_size = 5.0,

				-- [CN] 只渲染当前窗口可见区域，减少整 buffer 重绘。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Limit rendering to the visible window range instead of repainting the whole buffer.
				-- [EN] Choices: `true` / `false`.
				visible_only = true,

				-- [CN] 是否在光标所在行隐藏渲染效果并回退为原始 Markdown。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Hide render decorations on the cursor line and show raw Markdown there.
				-- [EN] Choices: `true` / `false`.
				hide_on_cursorline = false,

				-- [CN] 仅在普通模式下生效；让光标跳过被 conceal 的 Markdown 分隔符。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Normal-mode-only helper that skips concealed Markdown delimiter positions when moving the cursor.
				-- [EN] Choices: `true` / `false`.
				skip_concealed = true,

				heading = {
					-- [CN] 是否增强标题显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable heading decoration.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 标题层级图标列表；长度不足 6 时会按层级循环使用。
					-- [CN] 可选值: 任意非空字符串数组。
					-- [EN] Heading icon list; values are cycled when the list is shorter than six levels.
					-- [EN] Choices: any non-empty list of strings.
					icons = { "① ", "② ", "③ ", "④ ", "⑤ ", "⑥ " },

					-- [CN] 是否给整行标题增加额外高亮，包括 setext 标题的下划线行。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Highlight the full heading line, including the underline row of setext headings.
					-- [EN] Choices: `true` / `false`.
					highlight_line = true,
				},

				bullet = {
					-- [CN] 是否替换无序列表符号的显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable visual replacement for unordered list markers.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 无序列表图标列表；嵌套层级增加时会循环使用。
					-- [CN] 可选值: 任意非空字符串数组。
					-- [EN] Icon list for unordered bullets; cycled by nesting depth.
					-- [EN] Choices: any non-empty list of strings.
					icons = { "● ", "○ ", "◆ ", "◇ " },
				},

				checkbox = {
					-- [CN] 是否替换任务列表 checkbox 的显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable visual replacement for task-list checkboxes.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 未勾选任务项显示的图标。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Icon used for unchecked task items.
					-- [EN] Choices: any string.
					unchecked = "☐ ",

					-- [CN] 已勾选任务项显示的图标。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Icon used for checked task items.
					-- [EN] Choices: any string.
					checked = "☑ ",

					-- [CN] 部分完成任务项显示的图标，对应 Markdown 里的 `[-]`。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Icon used for partial task items, mapped from Markdown `[-]`.
					-- [EN] Choices: any string.
					partial = "◐ ",
				},

				quote = {
					-- [CN] 是否增强 blockquote 显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable blockquote decoration.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 引用前缀字符；嵌套引用会重复该字符。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Prefix glyph used for quotes; repeated for nested quote levels.
					-- [EN] Choices: any string.
					icon = "▎",
				},

				callout = {
					-- [CN] 是否增强 `[!NOTE]` / `[!WARNING]` 这类 callout。
					-- [CN] 常见可识别类型: NOTE, INFO, TIP, HINT, SUCCESS, WARNING, CAUTION, DANGER, ERROR, QUESTION, EXAMPLE, QUOTE 等。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable special rendering for callouts such as `[!NOTE]` and `[!WARNING]`.
					-- [EN] Common recognized kinds include NOTE, INFO, TIP, HINT, SUCCESS, WARNING, CAUTION, DANGER, ERROR, QUESTION, EXAMPLE, QUOTE, and more.
					-- [EN] Choices: `true` / `false`.
					enabled = true,
				},

				code = {
					-- [CN] 是否增强 fenced code block 的显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable fenced code block decoration.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 是否为代码块添加上下边框。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Draw top and bottom borders for code blocks.
					-- [EN] Choices: `true` / `false`.
					border = true,

					-- [CN] 是否在代码块起始行显示语言标签；需要围栏后带 info string。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Show the language label on the opening fence when an info string is present.
					-- [EN] Choices: `true` / `false`.
					language = true,

					-- [CN] 代码块装饰宽度的下限，避免窄窗口下边框太短。
					-- [CN] 可选值: 任意正整数。
					-- [EN] Minimum width used when drawing code-block decorations.
					-- [EN] Choices: any positive integer.
					min_width = 24,
				},

				hr = {
					-- [CN] 是否增强分割线显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable thematic-break decoration.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 用于铺满窗口宽度的分割线字符。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Character or string repeated to draw a full-width horizontal rule.
					-- [EN] Choices: any string.
					char = "─",
				},

				table = {
					-- [CN] 是否增强 pipe table 的显示。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Enable pipe-table decoration.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 是否用更明显的竖线字符替换表格边框。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Replace table borders with stronger visual separator glyphs.
					-- [EN] Choices: `true` / `false`.
					border = true,

					-- [CN] 是否高亮分隔行中的对齐冒号，不会改动原文。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Highlight alignment colons in the separator row without modifying source text.
					-- [EN] Choices: `true` / `false`.
					align = true,
				},

				link = {
					-- [CN] 链接渲染配置入口；当前版本配置已保留，但渲染侧暂未消费这些字段。
					-- [CN] 可选值: `true` / `false`。
					-- [EN] Link-render configuration entry point; kept for forward compatibility, but currently not consumed by the renderer.
					-- [EN] Choices: `true` / `false`.
					enabled = true,

					-- [CN] 普通链接前缀图标；当前版本为预留字段，暂未生效。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Prefix icon for normal links; reserved for future use in the current implementation.
					-- [EN] Choices: any string.
					icon = "↗ ",

					-- [CN] Wikilink 前缀图标；当前版本为预留字段，暂未生效。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Prefix icon for wiki links; reserved for future use in the current implementation.
					-- [EN] Choices: any string.
					wikilink_icon = "§ ",

					-- [CN] 图片链接前缀图标；当前版本为预留字段，暂未生效。
					-- [CN] 可选值: 任意字符串。
					-- [EN] Prefix icon for image links; reserved for future use in the current implementation.
					-- [EN] Choices: any string.
					image_icon = "◫ ",
				},
			},

			preview = {
				-- [CN] 仅控制“预览模块是否允许启用”；不会在打开 Markdown 时自动打开浏览器预览。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Controls whether the preview module can be enabled; it does not auto-open preview on buffer enter by itself.
				-- [EN] Choices: `true` / `false`.
				enabled = true,

				-- [CN] 本地预览服务绑定地址。
				-- [CN] 可选值: 任意字符串，例如 `"127.0.0.1"`、`"0.0.0.0"`、`"localhost"`。
				-- [EN] Host/interface used by the local preview server.
				-- [EN] Choices: any string, for example `"127.0.0.1"`, `"0.0.0.0"`, or `"localhost"`.
				host = "127.0.0.1",

				-- [CN] 本地预览服务端口。
				-- [CN] 可选值: 任意正整数。
				-- [EN] TCP port used by the local preview server.
				-- [EN] Choices: any positive integer.
				port = 4399,

				-- [CN] 预览服务二进制路径。
				-- [CN] 可选值: `"auto"` 或可执行文件路径。
				-- [CN] `"auto"` 会依次尝试插件目录下的 `bin/`、`target/release/`、`target/debug/`，最后再查找 `$PATH`。
				-- [EN] Path to the preview-server binary.
				-- [EN] Choices: `"auto"` or a path to an executable file.
				-- [EN] `"auto"` checks the plugin `bin/`, `target/release/`, `target/debug/`, and finally `$PATH`.
				binary = "auto",

				-- [CN] Markdown 内容推送到本地服务前的防抖时间，单位毫秒。
				-- [CN] 可选值: 任意非负整数。
				-- [EN] Debounce delay before Markdown updates are pushed to the local server, in milliseconds.
				-- [EN] Choices: any non-negative integer.
				debounce = 150,

				-- [CN] 启动预览服务后的就绪等待时间，单位毫秒。
				-- [CN] 可选值: 任意正整数。
				-- [EN] Timeout for waiting until the preview server becomes healthy, in milliseconds.
				-- [EN] Choices: any positive integer.
				startup_timeout = 5000,

				-- [CN] 预览服务日志级别。
				-- [CN] 可选值: `"trace"`、`"debug"`、`"info"`、`"warn"`、`"error"`。
				-- [EN] Log level passed to the preview server.
				-- [EN] Choices: `"trace"`, `"debug"`, `"info"`, `"warn"`, `"error"`.
				log_level = "info",

				-- [CN] 是否在启用预览时自动打开浏览器。
				-- [CN] 可选值: `true`、`false`、`"auto"`。
				-- [CN] `"auto"` 会在本地环境自动打开，在 SSH/远程环境退化为只回显 URL。
				-- [EN] Whether preview should auto-open a browser when enabled.
				-- [EN] Choices: `true`, `false`, `"auto"`.
				-- [EN] `"auto"` opens locally and falls back to echo-only behavior during SSH/remote sessions.
				auto_open = "auto",

				-- [CN] 浏览器/打开器命令。
				-- [CN] 可选值: `"auto"`、`"echo"`、或自定义命令字符串。
				-- [CN] 自定义命令可包含 `%s` 占位符；若不包含，插件会把 URL 追加到命令末尾。
				-- [EN] Browser/opener command.
				-- [EN] Choices: `"auto"`, `"echo"`, or a custom command string.
				-- [EN] A custom command may include a `%s` placeholder; otherwise the URL is appended automatically.
				browser = "auto",

				-- [CN] 是否在消息区回显预览 URL；即使禁用自动打开，也建议保留为 `true`。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Echo the preview URL in Neovim notifications; usually worth keeping on even when auto-open is disabled.
				-- [EN] Choices: `true` / `false`.
				echo_url = true,
			},

			table = {
				-- [CN] 是否默认启用 table mode。
				-- [CN] 开启后会为 Markdown buffer 注册表格编辑辅助，并在编辑当前表格时自动格式化。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Enable table mode by default.
				-- [EN] When enabled, Markdown buffers get table-edit helpers and current-table auto-format while editing.
				-- [EN] Choices: `true` / `false`.
				enabled = false,

				-- [CN] 预留字段，当前版本仅做校验和保留，尚未被表格模块实际消费。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Reserved field in the current implementation; validated and kept, but not consumed by the table module yet.
				-- [EN] Choices: `true` / `false`.
				auto_align = false,

				-- [CN] 保存前是否格式化当前 buffer 里的所有 Markdown 表格。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Format all Markdown tables in the current buffer before saving.
				-- [EN] Choices: `true` / `false`.
				format_on_save = false,
			},

			toc = {
				-- [CN] 保存文件时是否自动更新现有 TOC。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Auto-update the TOC block on save.
				-- [EN] Choices: `true` / `false`.
				auto_update_on_save = true,

				-- [CN] TOC 列表项使用的无序列表符号。
				-- [CN] 可选值: `"-"`、`"*"`、`"+"`。
				-- [EN] Unordered-list marker used inside generated TOC blocks.
				-- [EN] Choices: `"-"`, `"*"`, `"+"`.
				list_marker = "-",

				-- [CN] 目录收集的最大标题层级；Markdown 实际只支持 1 到 6 级，设置大于 6 与 6 等效。
				-- [CN] 可选值: 任意正整数，通常建议 `1` 到 `6`。
				-- [EN] Maximum heading depth included in the TOC; Markdown effectively tops out at levels 1 to 6, so values above 6 behave the same as 6.
				-- [EN] Choices: any positive integer, practically `1` to `6`.
				max_depth = 6,

				-- [CN] TOC 起始标记行；需要和 `fence_end` 成对使用。
				-- [CN] 可选值: 任意字符串。
				-- [EN] Start marker line for TOC blocks; must pair with `fence_end`.
				-- [EN] Choices: any string.
				fence_start = "<!-- markdown-toc-start -->",

				-- [CN] TOC 结束标记行；需要和 `fence_start` 成对使用。
				-- [CN] 可选值: 任意字符串。
				-- [EN] End marker line for TOC blocks; must pair with `fence_start`.
				-- [EN] Choices: any string.
				fence_end = "<!-- markdown-toc-end -->",

				-- [CN] 控制 `MDTtocGen` 的行为。
				-- [CN] 可选值: `true` = 优先按更新模式处理；`false` = 总是在当前光标位置插入一个新的 TOC 块。
				-- [EN] Controls how `MDTtocGen` behaves.
				-- [EN] Choices: `true` = prefer update behavior; `false` = always insert a new TOC block at the current cursor position.
				GenAsUpdate = true,
			},

			list = {
				-- [CN] 是否默认启用 Markdown 列表续写模块。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Enable Markdown list continuation by default.
				-- [EN] Choices: `true` / `false`.
				enabled = true,

				-- [CN] 是否续写有序列表，例如 `1.` / `2)`。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Continue ordered lists such as `1.` and `2)`.
				-- [EN] Choices: `true` / `false`.
				ordered = true,

				-- [CN] 是否续写无序列表，例如 `-` / `*` / `+`。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Continue unordered lists such as `-`, `*`, and `+`.
				-- [EN] Choices: `true` / `false`.
				unordered = true,

				-- [CN] 是否续写任务列表，例如 `- [ ]` / `- [x]`。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Continue task lists such as `- [ ]` and `- [x]`.
				-- [EN] Choices: `true` / `false`.
				checklist = true,

				-- [CN] 当前列表项为空时，按回车是否退出列表而不是继续生成下一项。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Exit the list on an empty item instead of creating another marker.
				-- [EN] Choices: `true` / `false`.
				exit_on_empty = true,

				-- [CN] 续写有序列表时是否递增编号。
				-- [CN] 可选值: `true` = `1.` 后继续成 `2.`；`false` = 继续复用原编号。
				-- [EN] Whether ordered-list continuation increments the item number.
				-- [EN] Choices: `true` = `1.` continues as `2.`; `false` = reuse the same number.
				renumber_on_continue = true,

				-- [CN] 是否在 blockquote 内也尝试续写列表。
				-- [CN] 可选值: `true` / `false`。
				-- [EN] Allow list continuation inside blockquotes.
				-- [EN] Choices: `true` / `false`.
				continue_in_quote = false,

				-- [CN] 续写已勾选任务项时，是否重置为未勾选。
				-- [CN] 可选值: `true` = `[x]` 续写为 `[ ]`；`false` = 保留原状态。
				-- [EN] Reset a continued checked task item back to unchecked.
				-- [EN] Choices: `true` = continue `[x]` as `[ ]`; `false` = preserve the previous state.
				checked_to_unchecked = true,
			},
		},
		keys = {
			{ "<leader>mp", "<cmd>MDTpriviewToggle<cr>", desc = "Markdown Preview Toggle" },
			{ "<leader>mt", "<cmd>MDTtableToggle<cr>", desc = "Markdown Table Toggle" },
			{ "<leader>mg", "<cmd>MDTtocGen<cr>", desc = "Markdown TOC Generate" },
			{ "<leader>mc", "<cmd>MDTtocUpdate<cr>", desc = "Markdown TOC Update" },
			{ "<leader>ml", "<cmd>MDTlistToggle<cr>", desc = "Markdown List Toggle" },
			{ "<leader>mr", "<cmd>MDTrenderToggle<cr>", desc = "Markdown Render Toggle" },
		},
	},
}
