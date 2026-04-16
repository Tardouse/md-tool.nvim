# md-tool.nvim

`md-tool.nvim` is a unified Markdown toolkit for Neovim. It combines preview, TOC management, table formatting, list continuation, and in-editor rendering under one command prefix and one configuration model.

The current implementation focuses on a practical MVP:

- Render enhancement inside Neovim with extmarks and highlights
- Browser preview with auto browser detection, manual browser commands, and echo-only mode
- Current-table formatting with optional auto-align and format-on-save
- TOC generation and update using fenced markers
- Conservative smart `<CR>` continuation for Markdown lists

## Installation

### Lazy.nvim

```lua
{
  "Tardouse/md-tool.nvim",
  ft = { "markdown" },
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

## List Behavior

The list module is intentionally conservative:

- It only applies in `markdown` buffers.
- It skips fenced code blocks, frontmatter, and probable table rows.
- It only continues lists when pressing `<CR>` at the end of a list line.
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

## MVP Limitations And Future Improvements

- Preview is file-based, not a live HTTP server yet.
- Render enhancement is regex-driven and intentionally lightweight.
- Table formatting is conservative and only targets obvious pipe tables.
- List continuation avoids aggressive editing behaviors on purpose.
- TOC anchors aim for GitHub-style slugs, but the implementation is still a simplified approximation.

Likely next steps:

- Upgrade preview into a real local server with live reload
- Improve render quality with Treesitter when available
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
