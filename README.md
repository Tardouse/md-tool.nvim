# md-tool.nvim

`md-tool.nvim` is a unified Markdown toolkit for Neovim. It combines preview, TOC management, table formatting, list continuation, and in-editor rendering under one command prefix and one configuration model.

Current implementation highlights:

- Treesitter-driven in-editor render with decorated headings, lists, quotes, callouts, tables, code fences, and thematic breaks
- Browser preview with auto browser detection, manual browser commands, and echo-only mode
- Current-table formatting with optional auto-align and format-on-save
- TOC generation and update using fenced markers
- Conservative smart `<CR>` continuation for Markdown lists

Neovim `0.11.6+` is the supported baseline. The render module requires Treesitter parsers for `markdown` and `markdown_inline`.

## Installation

### Lazy.nvim

```lua
{
  "Tardouse/md-tool.nvim",
  ft = { "markdown" },
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  opts = {},
}
```

## Commands

### Render

- `MDTrenderToggle`
- `MDTrenderEnable`
- `MDTrenderDisable`

### Preview

- `MDTpriviewToggle`
- `MDTpriviewEnable`
- `MDTpriviewDisable`

### Table

- `MDTtableToggle`
- `MDTtableEnable`
- `MDTtableDisable`
- `MDTtableFormat`

`MDTtableEnable` enables buffer-local table mode even when the cursor is not currently inside a table. Once enabled, `md-tool.nvim` watches editing events, detects the table under the cursor, and realigns that table automatically. In insert mode, typing `|` at the end of a cell expands the row and moves the cursor into the next cell, while `<CR>` creates the Markdown separator row or the next empty table row when appropriate. `MDTtableFormat` remains the explicit one-shot formatter for the current table under the cursor.

By default, table mode is off on newly opened buffers. If you want it enabled automatically for every Markdown buffer, set `table.enabled = true` in your setup.

### TOC

- `MDTtocGen`
- `MDTtocUpdate`

### List

- `MDTlistToggle`
- `MDTlistEnable`
- `MDTlistDisable`
- `MDTlistFormat`

Toggle and enable/disable commands operate on the current Markdown buffer so you can turn off features that are getting in the way without changing your global defaults.

## Configuration

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
    enabled = true,
    auto_update_on_save = true,
    list_marker = "-",
    max_depth = 6,
    fence_start = "<!-- markdown-toc-start -->",
    fence_end = "<!-- markdown-toc-end -->",
    GenAsUpdate = true,
  },

  list = {
    enabled = true,
    ordered = true,
    unordered = true,
    checklist = true,
    exit_on_empty = true,
    renumber_on_continue = true,
    continue_in_quote = false,
    checked_to_unchecked = true,
  },
})
```

## Preview Browser Modes

`md-tool.nvim` supports three preview modes:

1. `browser = "auto"`
   Uses platform-specific opener detection. On Linux it tries commands such as `xdg-open` or `gio open`; on macOS it uses `open`; on Windows it uses `cmd.exe /c start ""`.
2. `browser = "echo"`
   Does not launch a browser. The generated preview URL is echoed so it works cleanly over SSH and other remote sessions.
3. `browser = "..."` with a custom command
   You can provide a browser or opener command directly, for example:

```lua
preview = {
  browser = 'open -a "Google Chrome"',
}
```

`auto_open = "auto"` opens locally and falls back to echo-only behavior when an SSH session is detected. Even when auto-open is disabled, the preview URL is still shown.

The current preview implementation writes a styled HTML file under `stdpath("cache")/md-tool/preview/` and opens that file URI. The `host` and `port` options are kept for later upgrade paths to a real local preview server.

## Render Behavior

The render module keeps the original markdown text untouched and adds styling with Treesitter + extmarks. Rendering is restricted to the visible window range and refreshed with debounce instead of repainting the whole buffer on every edit.

- Headings get a stronger line treatment with level-based icons and highlights.
- Unordered list markers and task checkboxes are visually replaced with cleaner symbols.
- Block quotes get left bars, and common GitHub/Obsidian callout markers such as `[!NOTE]` are rendered more clearly.
- Code fences get a light block treatment with top and bottom borders and a language label when present.
- Thematic breaks are redrawn as a full-width rule, and inline code / italic / bold / bold-italic spans conceal their markdown delimiters while keeping dedicated inline highlights.
- Pipe tables get border styling and delimiter/alignment highlights.

By default, render is active in normal/visual/command-like modes through `render.modes`, and the cursor line stays rendered as well. In normal mode, `render.skip_concealed = true` makes the cursor jump across concealed markdown delimiters instead of landing on hidden `*` or `` ` `` positions. Set `render.hide_on_cursorline = true` if you prefer the current line to fall back to raw Markdown while navigating. For compatibility, `render.hide_in_insert` is still accepted and mapped to the new mode model when `render.modes` is not set.

## List Behavior

The list module is intentionally conservative:

- It only applies in `markdown` buffers.
- It skips fenced code blocks, frontmatter, and probable table rows.
- It continues lists when pressing `<CR>` at the end of a list line or `o` in normal mode on an existing list item.
- Empty items like `- ` or `3. ` exit the list instead of generating another marker when `exit_on_empty = true`.
- Task list continuation can either preserve checkbox state or reset checked items back to unchecked.

`MDTlistFormat` currently renumbers the current ordered list block under the cursor.

## TOC Markers

TOC generation uses the following fenced markers:

```md
<!-- markdown-toc-start -->
...
<!-- markdown-toc-end -->
```

TOC markers inside fenced code blocks are ignored.

`MDTtocGen` follows `toc.GenAsUpdate`:

- When `GenAsUpdate = true` (default), `MDTtocGen` behaves like update mode. If the cursor is inside a TOC block it updates that block; otherwise it updates the first TOC block. If no TOC block exists, it inserts one near the top of the document, usually after frontmatter and an opening H1 heading.
- When `GenAsUpdate = false`, `MDTtocGen` always inserts a new TOC block at the current cursor position, even if older TOC blocks already exist elsewhere in the file.

`MDTtocUpdate` always works in update mode:

- If the cursor is inside a TOC block, only that block is updated.
- If the cursor is outside all TOC blocks, the first TOC block is updated.
- If no TOC block exists, a new one is inserted near the top of the document.

## Limitations And Future Improvements

- Preview is file-based, not a live HTTP server yet.
- Table formatting is conservative and only targets obvious pipe tables.
- List continuation avoids aggressive editing behaviors on purpose.
- TOC anchors aim for GitHub-style slugs, but the implementation is still a simplified approximation.
- Render currently focuses on core Markdown UI elements; footnotes, LaTeX, HTML comments, and frontmatter decoration are not covered yet.

Likely next steps:

- Upgrade preview into a real local server with live reload
- Expand table parsing for more Markdown edge cases
- Add richer syntax-aware list handling inside complex block structures

## Acknowledgements

This plugin draws feature inspiration and prior-art guidance from:

- `MeanderingProgrammer/render-markdown.nvim`
- `iamcco/markdown-preview.nvim`
- `dhruvasagar/vim-table-mode`
- `mzlogin/vim-markdown-toc`
- `dkarter/bullets.vim`

The implementation here is a fresh MVP built for a unified `md-tool` workflow rather than a direct code copy from those projects.
