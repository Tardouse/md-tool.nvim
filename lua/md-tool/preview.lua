local config = require("md-tool.config")
local state = require("md-tool.state")
local utils = require("md-tool.utils")

local M = {}
local build_html

local function group_name(bufnr)
  return "MDToolPreview" .. bufnr
end

local function delete_group(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, group_name(bufnr))
end

local function split_row(line)
  local cells = {}
  local current = {}
  local escaped = false

  for index = 1, #line do
    local char = line:sub(index, index)
    if escaped then
      current[#current + 1] = char
      escaped = false
    elseif char == "\\" then
      current[#current + 1] = char
      escaped = true
    elseif char == "|" then
      table.insert(cells, table.concat(current))
      current = {}
    else
      current[#current + 1] = char
    end
  end

  table.insert(cells, table.concat(current))
  if line:match("^%s*|") then
    table.remove(cells, 1)
  end
  if line:match("|%s*$") then
    table.remove(cells, #cells)
  end
  for index, cell in ipairs(cells) do
    cells[index] = vim.trim(cell)
  end
  return cells
end

local function is_separator_row(line)
  local cells = split_row(line)
  if #cells == 0 then
    return false
  end

  for _, cell in ipairs(cells) do
    if not vim.trim(cell):match("^:?-+:?$") then
      return false
    end
  end

  return true
end

local function render_inline(text)
  local rendered = utils.html_escape(text)
  rendered = rendered:gsub("!%[([^%]]*)%]%(([^%)]+)%)", '<img alt="%1" src="%2" />')
  rendered = rendered:gsub("%[([^%]]+)%]%(([^%)]+)%)", '<a href="%2">%1</a>')
  rendered = rendered:gsub("`([^`]+)`", "<code>%1</code>")
  rendered = rendered:gsub("%*%*([^*]+)%*%*", "<strong>%1</strong>")
  rendered = rendered:gsub("__([^_]+)__", "<strong>%1</strong>")
  rendered = rendered:gsub("%*([^*]+)%*", "<em>%1</em>")
  rendered = rendered:gsub("_([^_]+)_", "<em>%1</em>")
  return rendered
end

local function list_item(line)
  local checkbox_state, checkbox_text = line:match("^%s*[-*+]%s+%[([ xX])%]%s+(.*)$")
  if checkbox_state then
    local icon = checkbox_state:lower() == "x" and "☑" or "☐"
    return icon .. " " .. render_inline(checkbox_text)
  end

  local unordered = line:match("^%s*[-*+]%s+(.*)$")
  if unordered then
    return render_inline(unordered)
  end

  local ordered = line:match("^%s*%d+[.)]%s+(.*)$")
  if ordered then
    return render_inline(ordered)
  end

  return nil
end

local function build_table_html(lines, start_row)
  if start_row >= #lines or not lines[start_row]:find("|", 1, true) or not is_separator_row(lines[start_row + 1]) then
    return nil
  end

  local html = { "<table>", "<thead>" }
  local header = split_row(lines[start_row])
  local separator = split_row(lines[start_row + 1])
  local alignments = {}
  for index, cell in ipairs(separator) do
    local starts = cell:sub(1, 1) == ":"
    local ends = cell:sub(-1) == ":"
    if starts and ends then
      alignments[index] = "center"
    elseif ends then
      alignments[index] = "right"
    else
      alignments[index] = "left"
    end
  end

  html[#html + 1] = "<tr>"
  for index, cell in ipairs(header) do
    html[#html + 1] = ('<th style="text-align:%s">%s</th>'):format(alignments[index] or "left", render_inline(cell))
  end
  html[#html + 1] = "</tr>"
  html[#html + 1] = "</thead>"
  html[#html + 1] = "<tbody>"

  local row = start_row + 2
  while row <= #lines and lines[row]:find("|", 1, true) do
    html[#html + 1] = "<tr>"
    for index, cell in ipairs(split_row(lines[row])) do
      html[#html + 1] = ('<td style="text-align:%s">%s</td>'):format(alignments[index] or "left", render_inline(cell))
    end
    html[#html + 1] = "</tr>"
    row = row + 1
  end

  html[#html + 1] = "</tbody>"
  html[#html + 1] = "</table>"
  return table.concat(html, "\n"), row - 1
end

local function render_markdown(lines)
  local html = {}
  local row = 1

  while row <= #lines do
    local line = lines[row]

    if utils.line_is_blank(line) then
      row = row + 1
    else
      local marker = utils.is_fence_line(line)
      if marker then
        local lang = vim.trim(line:gsub("^%s*[`~]+", ""))
        html[#html + 1] = ('<pre><code class="language-%s">'):format(utils.html_escape(lang))
        row = row + 1
        while row <= #lines and not utils.is_fence_line(lines[row]) do
          html[#html + 1] = utils.html_escape(lines[row])
          row = row + 1
        end
        html[#html + 1] = "</code></pre>"
        row = row + 1
      elseif line:match("^#+%s+") then
        local marks, text = line:match("^(#+)%s+(.+)$")
        if #marks <= 6 then
          html[#html + 1] = ("<h%d>%s</h%d>"):format(#marks, render_inline(text:gsub("%s*#+%s*$", "")), #marks)
        else
          html[#html + 1] = "<p>" .. render_inline(vim.trim(line)) .. "</p>"
        end
        row = row + 1
      elseif utils.is_horizontal_rule(line) then
        html[#html + 1] = "<hr />"
        row = row + 1
      elseif line:match("^%s*>") then
        local quote = {}
        while row <= #lines and lines[row]:match("^%s*>") do
          quote[#quote + 1] = render_inline(vim.trim(lines[row]:gsub("^%s*>%s?", "", 1)))
          row = row + 1
        end
        html[#html + 1] = "<blockquote><p>" .. table.concat(quote, "<br />") .. "</p></blockquote>"
      else
        local table_html, table_end = build_table_html(lines, row)
        if table_html then
          html[#html + 1] = table_html
          row = table_end + 1
        else
          local first_item = list_item(line)
          if first_item then
            local ordered = line:match("^%s*%d+[.)]%s+") ~= nil
            html[#html + 1] = ordered and "<ol>" or "<ul>"
            while row <= #lines do
              local item = list_item(lines[row])
              local current_ordered = lines[row]:match("^%s*%d+[.)]%s+") ~= nil
              if not item or current_ordered ~= ordered then
                break
              end
              html[#html + 1] = "<li>" .. item .. "</li>"
              row = row + 1
            end
            html[#html + 1] = ordered and "</ol>" or "</ul>"
          else
            local paragraph = { render_inline(vim.trim(line)) }
            row = row + 1
            while row <= #lines do
              local next_line = lines[row]
              if utils.line_is_blank(next_line)
                or utils.is_fence_line(next_line)
                or next_line:match("^#+%s+")
                or next_line:match("^%s*>")
                or utils.is_horizontal_rule(next_line)
                or list_item(next_line)
              then
                break
              end

              local table_html_break = build_table_html(lines, row)
              if table_html_break then
                break
              end

              paragraph[#paragraph + 1] = render_inline(vim.trim(next_line))
              row = row + 1
            end
            html[#html + 1] = "<p>" .. table.concat(paragraph, " ") .. "</p>"
          end
        end
      end
    end
  end

  return table.concat(html, "\n")
end

local function preview_path(bufnr)
  local cache_dir = utils.join_path(vim.fn.stdpath("cache"), "md-tool", "preview")
  utils.mkdir_p(cache_dir)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local basename = utils.sanitize_filename(vim.fn.fnamemodify(name, ":t:r"))
  if basename == "" then
    basename = "markdown"
  end
  return utils.join_path(cache_dir, ("%s-%d.html"):format(basename, bufnr))
end

local function preview_title(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local tail = vim.fn.fnamemodify(name, ":t")
  if tail == "" then
    return "Markdown Preview"
  end
  return tail
end

local function write_preview_file(bufnr)
  local html_lines = vim.split(build_html(bufnr, render_markdown(utils.get_buf_lines(bufnr))), "\n", { plain = true })
  local last_error = nil

  for _, path in ipairs({ preview_path(bufnr), vim.fn.tempname() .. ".html" }) do
    local ok, err = pcall(vim.fn.writefile, html_lines, path)
    if ok then
      return path
    end
    last_error = err
  end

  return nil, last_error
end

build_html = function(bufnr, body)
  local title = utils.html_escape(preview_title(bufnr))
  return ([[
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>%s</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f7f6f1;
      --fg: #1d1d1d;
      --muted: #5f5a50;
      --border: #d5d0c3;
      --accent: #8a3d12;
      --code-bg: #ebe6d8;
      --quote-bg: #f0ece1;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #181816;
        --fg: #ece8de;
        --muted: #c0b8a8;
        --border: #3a382f;
        --accent: #f0a36b;
        --code-bg: #26251f;
        --quote-bg: #22211c;
      }
    }
    body {
      margin: 0;
      padding: 2rem 1.25rem 4rem;
      background: linear-gradient(180deg, rgba(138, 61, 18, 0.06), transparent 280px), var(--bg);
      color: var(--fg);
      font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Palatino, serif;
      line-height: 1.7;
    }
    main {
      max-width: 860px;
      margin: 0 auto;
    }
    h1, h2, h3, h4, h5, h6 {
      line-height: 1.25;
      color: var(--accent);
      margin-top: 1.7em;
      margin-bottom: 0.6em;
    }
    p, ul, ol, blockquote, table, pre {
      margin: 1em 0;
    }
    code {
      background: var(--code-bg);
      padding: 0.1em 0.35em;
      border-radius: 0.3em;
      font-family: "Iosevka", "SFMono-Regular", Consolas, monospace;
      font-size: 0.95em;
    }
    pre {
      background: var(--code-bg);
      padding: 1rem;
      border: 1px solid var(--border);
      border-radius: 0.8rem;
      overflow-x: auto;
    }
    pre code {
      background: transparent;
      padding: 0;
    }
    blockquote {
      background: var(--quote-bg);
      border-left: 4px solid var(--accent);
      padding: 0.85rem 1rem;
      color: var(--muted);
    }
    table {
      width: 100%%;
      border-collapse: collapse;
      border: 1px solid var(--border);
      overflow: hidden;
      border-radius: 0.6rem;
    }
    th, td {
      border: 1px solid var(--border);
      padding: 0.6rem 0.8rem;
      vertical-align: top;
    }
    th {
      background: rgba(138, 61, 18, 0.08);
    }
    a {
      color: var(--accent);
    }
    hr {
      border: 0;
      border-top: 1px solid var(--border);
    }
    img {
      max-width: 100%%;
      height: auto;
    }
  </style>
</head>
<body>
  <main>
%s
  </main>
</body>
</html>]]):format(title, body)
end

local function resolve_browser_command()
  local cfg = config.get().preview
  if cfg.browser == "echo" then
    return nil
  end

  if cfg.browser ~= "auto" then
    local executable = utils.extract_executable(cfg.browser)
    if executable and not utils.command_exists(executable) then
      return nil, ("Configured browser command is unavailable: %s"):format(cfg.browser)
    end
    return cfg.browser
  end

  local os_name = utils.detect_os()
  if os_name == "macos" then
    return "open"
  end
  if os_name == "windows" then
    return 'cmd.exe /c start ""'
  end

  for _, command in ipairs({ "xdg-open", "gio open", "sensible-browser", "google-chrome", "firefox" }) do
    local executable = utils.extract_executable(command)
    if executable and utils.command_exists(executable) then
      return command
    end
  end

  return nil, "No browser opener command was found. Set `preview.browser` or use `browser = \"echo\"`."
end

local function should_open_browser()
  local cfg = config.get().preview
  if cfg.browser == "echo" then
    return false
  end
  if cfg.auto_open == true then
    return true
  end
  if cfg.auto_open == false then
    return false
  end
  return not utils.is_ssh()
end

local function open_browser(target)
  local browser, err = resolve_browser_command()
  if not browser then
    return false, err
  end

  local command = browser
  if browser:find("%%s", 1, true) then
    command = browser:format(target)
  else
    command = browser .. " " .. utils.shell_escape(target)
  end

  local ok = utils.run_detached(command)
  if not ok then
    return false, ("Failed to launch browser command: %s"):format(browser)
  end
  return true
end

function M.refresh(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Preview only works for markdown buffers.", vim.log.levels.ERROR)
    return false
  end

  local path, err = write_preview_file(bufnr)
  if not path then
    utils.notify("Preview generation failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local url = vim.uri_from_fname(path)
  local preview = state.set_preview(bufnr, {
    active = true,
    path = path,
    url = url,
  })

  local open_requested = opts.open ~= false and should_open_browser()
  if open_requested and not preview.opened then
    local opened, err = open_browser(url)
    if not opened then
      utils.notify(err, vim.log.levels.ERROR)
      return false
    end
    state.set_preview(bufnr, { opened = true })
  end

  if opts.notify_url ~= false and (config.get().preview.echo_url or not open_requested) then
    utils.notify("Preview: " .. url)
  end

  return true
end

function M.detach(bufnr)
  delete_group(bufnr)
end

function M.attach(bufnr)
  delete_group(bufnr)

  local preview = state.get_preview(bufnr)
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("preview", bufnr) or not preview.active then
    return
  end

  local group = vim.api.nvim_create_augroup(group_name(bufnr), { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    group = group,
    callback = function()
      if state.is_module_enabled("preview", bufnr) and state.get_preview(bufnr).active then
        M.refresh(bufnr, { open = false, notify_url = false })
      end
    end,
  })
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Preview only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  state.set_module_enabled("preview", true, bufnr)
  state.set_preview(bufnr, { active = true, opened = false })
  if M.refresh(bufnr, { open = true }) then
    M.attach(bufnr)
  else
    state.set_preview(bufnr, { active = false, opened = false })
  end
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  state.set_module_enabled("preview", false, bufnr)
  state.set_preview(bufnr, { active = false, opened = false })
  M.detach(bufnr)
  utils.notify("Preview disabled for the current buffer.")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Preview only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  local preview = state.get_preview(bufnr)
  if preview.active and state.is_module_enabled("preview", bufnr) then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

return M
