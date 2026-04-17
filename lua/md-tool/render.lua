local config = require("md-tool.config")
local state = require("md-tool.state")
local utils = require("md-tool.utils")
local Decorator = require("md-tool.render.decorator")
local ts = require("md-tool.render.ts")

local M = {}

local namespace = vim.api.nvim_create_namespace("md-tool-render")
local render_state = {}
local window_state = {}
local cursor_state = {}
local schedule_refresh
local highlights_ready = false

local callouts = {
  note = { icon = "ℹ ", group = "MDTCalloutInfo" },
  info = { icon = "ℹ ", group = "MDTCalloutInfo" },
  tip = { icon = "✓ ", group = "MDTCalloutSuccess" },
  hint = { icon = "✓ ", group = "MDTCalloutSuccess" },
  success = { icon = "✓ ", group = "MDTCalloutSuccess" },
  check = { icon = "✓ ", group = "MDTCalloutSuccess" },
  done = { icon = "✓ ", group = "MDTCalloutSuccess" },
  important = { icon = "✦ ", group = "MDTCalloutHint" },
  warning = { icon = "! ", group = "MDTCalloutWarn" },
  caution = { icon = "! ", group = "MDTCalloutError" },
  danger = { icon = "✗ ", group = "MDTCalloutError" },
  error = { icon = "✗ ", group = "MDTCalloutError" },
  failure = { icon = "✗ ", group = "MDTCalloutError" },
  fail = { icon = "✗ ", group = "MDTCalloutError" },
  missing = { icon = "✗ ", group = "MDTCalloutError" },
  bug = { icon = "✗ ", group = "MDTCalloutError" },
  question = { icon = "? ", group = "MDTCalloutWarn" },
  help = { icon = "? ", group = "MDTCalloutWarn" },
  faq = { icon = "? ", group = "MDTCalloutWarn" },
  attention = { icon = "! ", group = "MDTCalloutWarn" },
  example = { icon = "≡ ", group = "MDTCalloutHint" },
  quote = { icon = "❝ ", group = "MDTCalloutQuote" },
  cite = { icon = "❝ ", group = "MDTCalloutQuote" },
}

local function group_name(bufnr)
  return "MDToolRender" .. bufnr
end

local function delete_group(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, group_name(bufnr))
end

local function ensure_buffer_state(bufnr)
  if not render_state[bufnr] then
    render_state[bufnr] = {
      attached = false,
      signature = nil,
      refresh_seq = 0,
      pending_force = false,
      conceal_rows = nil,
      warned_missing_parser = false,
    }
  end
  return render_state[bufnr]
end

local function buffer_windows(bufnr)
  local wins = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      wins[#wins + 1] = winid
    end
  end
  return wins
end

local function ensure_cursor_state(winid)
  if not cursor_state[winid] then
    cursor_state[winid] = {
      cursor = nil,
      adjusting = false,
    }
  end
  return cursor_state[winid]
end

local function remember_window_cursor(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    cursor_state[winid] = nil
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local win_cursor_state = ensure_cursor_state(winid)
  win_cursor_state.cursor = { cursor[1], cursor[2] }
  win_cursor_state.adjusting = false
end

local function clear_window_cursor(winid)
  cursor_state[winid] = nil
end

local function remember_window_options(winid)
  if window_state[winid] then
    return
  end

  window_state[winid] = {
    conceallevel = vim.wo[winid].conceallevel,
    concealcursor = vim.wo[winid].concealcursor,
  }
end

local function restore_window_options(winid)
  local saved = window_state[winid]
  if not saved or not vim.api.nvim_win_is_valid(winid) then
    window_state[winid] = nil
    return
  end

  vim.wo[winid].conceallevel = saved.conceallevel
  vim.wo[winid].concealcursor = saved.concealcursor
  window_state[winid] = nil
end

local function apply_window_options(bufnr, rendered, cfg)
  for _, winid in ipairs(buffer_windows(bufnr)) do
    if rendered then
      remember_window_options(winid)
      vim.wo[winid].conceallevel = 3
      vim.wo[winid].concealcursor = cfg and cfg.hide_on_cursorline and "" or "ncv"
    else
      restore_window_options(winid)
    end
  end
end

local function cycle(values, index)
  return values[((index - 1) % #values) + 1]
end

local function fit_text(text, target_width)
  target_width = math.max(target_width or 0, 0)
  local width = utils.display_width(text)
  if width >= target_width then
    return text
  end
  return text .. string.rep(" ", target_width - width)
end

local function render_width_fill(char, width)
  if width <= 0 then
    return ""
  end
  return string.rep(char, width)
end

local function parse_quote_prefix(text)
  local prefix = ""
  local rest = text
  local level = 0

  while true do
    local piece, next_rest = rest:match("^(>%s*)(.*)$")
    if not piece then
      break
    end
    prefix = prefix .. piece
    rest = next_rest
    level = level + 1
  end

  return prefix, rest, level
end

local function fence_info(line)
  return vim.trim((line or ""):match("^%s*[`~]+%s*(.-)%s*$") or "")
end

local function code_language(info)
  return vim.trim((info or ""):match("^([%w%._%-%+]+)") or "")
end

local function separator_positions(line)
  local positions = {}
  local escaped = false

  for index = 1, #line do
    local char = line:sub(index, index)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "|" then
      positions[#positions + 1] = index
    end
  end

  return positions
end

local function node_key(node)
  local start_row, start_col, end_row, end_col = node:range()
  return table.concat({ node:type(), start_row, start_col, end_row, end_col }, ":")
end

local function node_children_of_type(node, type_name)
  local matches = {}
  for child in node:iter_children() do
    if child:type() == type_name then
      matches[#matches + 1] = child
    end
  end
  return matches
end

local function node_first_child_of_type(node, type_name)
  for child in node:iter_children() do
    if child:type() == type_name then
      return child
    end
  end
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
      cells[#cells + 1] = table.concat(current)
      current = {}
    else
      current[#current + 1] = char
    end
  end

  cells[#cells + 1] = table.concat(current)

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
    if not cell:match("^:?-+:?$") then
      return false
    end
  end

  return true
end

local function merge_ranges(ranges)
  if #ranges == 0 then
    return {}
  end

  table.sort(ranges, function(left, right)
    if left[1] == right[1] then
      return left[2] < right[2]
    end
    return left[1] < right[1]
  end)

  local merged = { { ranges[1][1], ranges[1][2] } }
  for index = 2, #ranges do
    local current = ranges[index]
    local previous = merged[#merged]
    if current[1] <= previous[2] + 1 then
      previous[2] = math.max(previous[2], current[2])
    else
      merged[#merged + 1] = { current[1], current[2] }
    end
  end

  return merged
end

local function normalize_conceal_rows(rows)
  local normalized = {}

  for row, ranges in pairs(rows) do
    table.sort(ranges, function(left, right)
      if left[1] == right[1] then
        return left[2] < right[2]
      end
      return left[1] < right[1]
    end)

    local merged = {}
    for _, range in ipairs(ranges) do
      local start_col = range[1]
      local end_col = range[2]
      if start_col < end_col then
        local previous = merged[#merged]
        if previous and start_col <= previous[2] then
          previous[2] = math.max(previous[2], end_col)
        else
          merged[#merged + 1] = { start_col, end_col }
        end
      end
    end

    if #merged > 0 then
      normalized[row] = merged
    end
  end

  return normalized
end

local function concealed_range_at(ranges, col)
  if not ranges then
    return nil
  end

  for _, range in ipairs(ranges) do
    if col < range[1] then
      return nil
    end
    if col < range[2] then
      return range
    end
  end

  return nil
end

local function next_visible_col(ranges, col, line_length)
  local candidate = math.max(col, 0)
  while candidate < line_length do
    local range = concealed_range_at(ranges, candidate)
    if not range then
      return candidate
    end
    candidate = range[2]
  end
end

local function previous_visible_col(ranges, col)
  local candidate = col
  while candidate >= 0 do
    local range = concealed_range_at(ranges, candidate)
    if not range then
      return candidate
    end
    candidate = range[1] - 1
  end
end

local function cursor_direction(previous, current)
  if not previous then
    return nil
  end

  if current[1] > previous[1] then
    return "down"
  end
  if current[1] < previous[1] then
    return "up"
  end
  if current[2] > previous[2] then
    return "right"
  end
  if current[2] < previous[2] then
    return "left"
  end
end

local function skip_concealed_cursor(bufnr, winid, cfg)
  if not cfg.skip_concealed or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local mode = vim.api.nvim_get_mode().mode
  if not (mode == "n" or vim.startswith(mode, "no")) then
    return false
  end

  local win_cursor_state = ensure_cursor_state(winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local current = { cursor[1], cursor[2] }
  if win_cursor_state.adjusting then
    win_cursor_state.adjusting = false
    win_cursor_state.cursor = current
    return false
  end

  local direction = cursor_direction(win_cursor_state.cursor, current)
  win_cursor_state.cursor = current
  if not direction then
    return false
  end

  local buffer_state = ensure_buffer_state(bufnr)
  local ranges = buffer_state.conceal_rows and buffer_state.conceal_rows[current[1]]
  local range = concealed_range_at(ranges, current[2])
  if not range then
    return false
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, current[1] - 1, current[1], false)[1] or ""
  local line_length = #line
  local target
  if direction == "left" or direction == "up" then
    target = previous_visible_col(ranges, range[1] - 1)
    if target == nil then
      target = next_visible_col(ranges, range[2], line_length)
    end
  else
    target = next_visible_col(ranges, range[2], line_length)
    if target == nil then
      target = previous_visible_col(ranges, range[1] - 1)
    end
  end

  if target == nil or target == current[2] then
    return false
  end

  win_cursor_state.adjusting = true
  vim.api.nvim_win_set_cursor(winid, { current[1], target })
  return true
end

local function mode_enabled(modes, mode)
  for _, prefix in ipairs(modes) do
    if mode == prefix or vim.startswith(mode, prefix) then
      return true
    end
  end
  return false
end

local function collect_view(bufnr, cfg)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid)
      and vim.api.nvim_win_get_buf(winid) == bufnr
      and vim.api.nvim_win_get_config(winid).relative == ""
      and not vim.wo[winid].diff
    then
      wins[#wins + 1] = winid
    end
  end

  if #wins == 0 then
    return nil
  end

  local ranges = {}
  local hidden_rows = {}
  local width

  for _, winid in ipairs(wins) do
    local view = vim.api.nvim_win_call(winid, function()
      local saved = vim.fn.winsaveview()
      return {
        top = vim.fn.line("w0"),
        bottom = vim.fn.line("w$"),
        leftcol = saved.leftcol,
        cursor = vim.api.nvim_win_get_cursor(0)[1],
      }
    end)

    if view.leftcol == 0 then
      if cfg.visible_only then
        ranges[#ranges + 1] = { view.top, view.bottom }
      end
      if cfg.hide_on_cursorline then
        hidden_rows[view.cursor] = true
      end
      local win_width = math.max(vim.api.nvim_win_get_width(winid), 20)
      width = width and math.min(width, win_width) or win_width
    end
  end

  if not width then
    return nil
  end

  if not cfg.visible_only then
    ranges = { { 1, vim.api.nvim_buf_line_count(bufnr) } }
  else
    ranges = merge_ranges(ranges)
  end

  local visible_rows = {}
  for _, range in ipairs(ranges) do
    for row = range[1], range[2] do
      visible_rows[row] = true
    end
  end

  return {
    ranges = ranges,
    hidden_rows = hidden_rows,
    visible_rows = visible_rows,
    width = width,
  }
end

local function build_signature(bufnr, mode, view)
  local parts = {
    tostring(vim.api.nvim_buf_get_changedtick(bufnr)),
    mode,
    tostring(view.width),
  }

  for _, range in ipairs(view.ranges) do
    parts[#parts + 1] = ("%d-%d"):format(range[1], range[2])
  end

  local hidden = {}
  for row in pairs(view.hidden_rows) do
    hidden[#hidden + 1] = row
  end
  table.sort(hidden)
  if #hidden > 0 then
    parts[#parts + 1] = table.concat(hidden, ",")
  end

  return table.concat(parts, "|")
end

local function get_highlight(name)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and highlight and next(highlight) ~= nil then
    return highlight
  end
  return nil
end

local function first_highlight(names)
  for _, name in ipairs(names) do
    local highlight = get_highlight(name)
    if highlight then
      return highlight
    end
  end
  return {}
end

local function visible_color(key, normal_value, ...)
  local fallback = nil
  for index = 1, select("#", ...) do
    local highlight = select(index, ...)
    if type(highlight) == "table" then
      local value = highlight[key]
      if value ~= nil then
        fallback = fallback or value
        if value ~= normal_value then
          return value
        end
      end
    end
  end
  return fallback
end

local function merge_style(base, ...)
  local merged = vim.deepcopy(base)
  local keys = {
    "fg",
    "bg",
    "sp",
    "bold",
    "italic",
    "underline",
    "undercurl",
    "strikethrough",
    "reverse",
  }

  for index = 1, select("#", ...) do
    local highlight = select(index, ...)
    if type(highlight) == "table" then
      for _, key in ipairs(keys) do
        if merged[key] == nil and highlight[key] ~= nil then
          merged[key] = highlight[key]
        end
      end
    end
  end

  return merged
end

local function ensure_highlights()
  if highlights_ready then
    return
  end

  local normal = first_highlight({ "Normal" })
  local italic_hl = first_highlight({
    "@markup.italic.markdown_inline",
    "@markup.italic",
    "markdownItalic",
    "Italic",
  })
  local strong_hl = first_highlight({
    "@markup.strong.markdown_inline",
    "@markup.strong",
    "markdownBold",
    "Bold",
  })
  local code_hl = first_highlight({
    "@markup.raw.markdown_inline",
    "@markup.raw",
    "markdownCode",
    "String",
  })
  local comment_hl = first_highlight({ "@comment.markdown", "@comment", "Comment" })
  local title_hl = first_highlight({ "Title", "Function", "Statement" })
  local accent_hl = first_highlight({ "Identifier", "Special", "Type" })
  local string_hl = first_highlight({ "String", "@string", "Special" })
  local cursorline_hl = first_highlight({ "CursorLine", "ColorColumn" })

  vim.api.nvim_set_hl(0, "MDTHeadingLine", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "MDTHeading1", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "MDTHeading2", { default = true, link = "Function" })
  vim.api.nvim_set_hl(0, "MDTHeading3", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "MDTHeading4", { default = true, link = "Statement" })
  vim.api.nvim_set_hl(0, "MDTHeading5", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "MDTHeading6", { default = true, link = "Special" })

  vim.api.nvim_set_hl(0, "MDTBullet1", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "MDTBullet2", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "MDTBullet3", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "MDTBullet4", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "MDTOrderedMarker", { default = true, link = "Special" })

  vim.api.nvim_set_hl(0, "MDTCheckboxUnchecked", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "MDTCheckboxChecked", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "MDTCheckboxPartial", { default = true, link = "DiagnosticInfo" })

  vim.api.nvim_set_hl(0, "MDTQuote1", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MDTQuote2", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "MDTQuote3", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "MDTQuote4", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "MDTQuote5", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "MDTQuote6", { default = true, link = "Special" })

  vim.api.nvim_set_hl(0, "MDTCalloutInfo", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "MDTCalloutSuccess", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "MDTCalloutWarn", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "MDTCalloutError", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "MDTCalloutHint", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "MDTCalloutQuote", { default = true, link = "Comment" })

  vim.api.nvim_set_hl(0, "MDTCodeBlock", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "MDTCodeBorder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MDTCodeInfo", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "MDTHorizontalRule", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MDTInlineCode", merge_style({
    default = true,
    fg = visible_color("fg", normal.fg, code_hl, string_hl, accent_hl),
    bg = visible_color("bg", normal.bg, code_hl, cursorline_hl),
  }, code_hl, string_hl))
  vim.api.nvim_set_hl(0, "MDTItalic", merge_style({
    default = true,
    italic = true,
    fg = visible_color("fg", normal.fg, italic_hl, comment_hl, accent_hl),
  }, italic_hl))
  vim.api.nvim_set_hl(0, "MDTBold", merge_style({
    default = true,
    bold = true,
    fg = visible_color("fg", normal.fg, strong_hl, title_hl, accent_hl),
  }, strong_hl))
  vim.api.nvim_set_hl(0, "MDTBoldItalic", merge_style({
    default = true,
    bold = true,
    italic = true,
    fg = visible_color("fg", normal.fg, strong_hl, italic_hl, title_hl, accent_hl),
  }, strong_hl, italic_hl))
  vim.api.nvim_set_hl(0, "MDTTableBorder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MDTTableSeparator", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "MDTTableAlign", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "MDTLinkText", { default = true, link = "Underlined" })
  vim.api.nvim_set_hl(0, "MDTLinkUrl", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MDTWikiLink", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "MDTImageLink", { default = true, link = "Type" })
  highlights_ready = true
end

local function code_open_chunks(width, cfg, info)
  local label = code_language(info)
  if label == "" or not cfg.language then
    return {
      { "╭" .. render_width_fill("─", math.max(width - 1, 2)), "MDTCodeBorder" },
    }
  end

  label = " " .. label .. " "
  local left = "╭─"
  local fill = render_width_fill("─", math.max(width - utils.display_width(left) - utils.display_width(label), 2))
  return {
    { left, "MDTCodeBorder" },
    { label, "MDTCodeInfo" },
    { fill, "MDTCodeBorder" },
  }
end

local function code_close_chunks(width)
  return {
    { "╰" .. render_width_fill("─", math.max(width - 1, 2)), "MDTCodeBorder" },
  }
end

local function render_heading(ctx, capture)
  local cfg = ctx.cfg.heading
  if not cfg.enabled then
    return
  end

  local node = capture.node
  local row = capture.start_row
  if ctx.flags.code[row] then
    return
  end

  local line = ctx.lines[row] or ""
  local level
  if node:type() == "setext_heading" then
    local underline_row = capture.end_row
    local underline = ctx.lines[underline_row] or ""
    level = underline:match("^%s*=") and 1 or 2
    local icon = fit_text(cycle(cfg.icons, level), 2)
    if cfg.highlight_line then
      ctx.decorator:line(row, line, "MDTHeadingLine")
      if ctx.visible_rows[underline_row] then
        ctx.decorator:line(underline_row, underline, "MDTHeadingLine")
      end
    end
    ctx.decorator:overlay(row, 0, { { icon, "MDTHeading" .. level } })
    ctx.decorator:highlight(row, 0, #line, "MDTHeading" .. level)
    if ctx.visible_rows[underline_row] then
      local fill = render_width_fill(level == 1 and "═" or "─", math.max(ctx.width - 1, 8))
      ctx.decorator:overlay(underline_row, 0, { { fill, "MDTHeading" .. level } })
    end
    return
  end

  local marks = line:match("^(#+)%s+")
  if not marks then
    return
  end

  level = math.min(#marks, 6)
  local marker_width = #marks + 1
  local icon = fit_text(cycle(cfg.icons, level), marker_width)

  if cfg.highlight_line then
    ctx.decorator:line(row, line, "MDTHeadingLine")
  end
  ctx.decorator:overlay(row, 0, { { icon, "MDTHeading" .. level } })
  ctx.decorator:highlight(row, marker_width, #line, "MDTHeading" .. level)
end

local function render_list_item(ctx, capture)
  local bullet_cfg = ctx.cfg.bullet
  local checkbox_cfg = ctx.cfg.checkbox
  local row = capture.start_row
  if ctx.flags.code[row] or ctx.flags.table[row] then
    return
  end

  local line = ctx.lines[row] or ""
  local indent, rest = line:match("^(%s*)(.*)$")
  local quote_prefix, body, quote_level = parse_quote_prefix(rest)
  local start_col = #indent + #quote_prefix
  local list_level = math.max(1, math.floor(#indent / 2) + quote_level + 1)

  local raw_task = body:match("^([-*+]%s+%[[ xX%-]%]%s+)") or body:match("^(%d+[.)]%s+%[[ xX%-]%]%s+)")
  if raw_task and checkbox_cfg.enabled then
    local state_char = raw_task:match("%[([ xX%-])%]")
    local icon
    local group
    if state_char == "x" or state_char == "X" then
      icon = checkbox_cfg.checked
      group = "MDTCheckboxChecked"
    elseif state_char == "-" then
      icon = checkbox_cfg.partial
      group = "MDTCheckboxPartial"
    else
      icon = checkbox_cfg.unchecked
      group = "MDTCheckboxUnchecked"
    end

    ctx.decorator:overlay(row, start_col, { { fit_text(icon, #raw_task), group } })
    return
  end

  local raw_ordered = body:match("^(%d+[.)]%s+)")
  if raw_ordered then
    ctx.decorator:highlight(row, start_col, start_col + #raw_ordered, "MDTOrderedMarker")
    return
  end

  if not bullet_cfg.enabled then
    return
  end

  local raw_bullet = body:match("^([-*+]%s+)")
  if raw_bullet then
    local group = "MDTBullet" .. ((list_level - 1) % #bullet_cfg.icons + 1)
    local icon = fit_text(cycle(bullet_cfg.icons, list_level), #raw_bullet)
    ctx.decorator:overlay(row, start_col, { { icon, group } })
  end
end

local function render_quote_line(ctx, row)
  if ctx.flags.code[row] then
    return
  end

  local line = ctx.lines[row] or ""
  local indent, rest = line:match("^(%s*)(.*)$")
  local quote_prefix, body, quote_level = parse_quote_prefix(rest)
  if quote_level == 0 then
    return
  end

  local quote_cfg = ctx.cfg.quote
  local quote_group = "MDTQuote" .. math.min(quote_level, 6)
  local quote_start = #indent
  local icon = fit_text(string.rep(quote_cfg.icon, quote_level), #quote_prefix)
  ctx.decorator:overlay(row, quote_start, { { icon, quote_group } }, { priority = 180 })

  if ctx.cfg.callout.enabled then
    local callout_token, callout_name = body:match("^(%[!([%w%-_]+)%])")
    if callout_token and callout_name then
      local style = callouts[callout_name:lower()] or { icon = "ℹ ", group = "MDTCalloutInfo" }
      local rendered = fit_text(style.icon .. callout_name:upper(), #callout_token)
      local token_col = quote_start + #quote_prefix
      ctx.decorator:overlay(row, token_col, { { rendered, style.group } })
      ctx.decorator:highlight(row, token_col, #line, style.group)
      return
    end
  end

  ctx.decorator:highlight(row, quote_start + #quote_prefix, #line, quote_group)
end

local function render_code_block(ctx, capture)
  local cfg = ctx.cfg.code
  if not cfg.enabled then
    return
  end

  local start_row = capture.start_row
  local end_row = capture.end_row
  local width = math.max(ctx.width, cfg.min_width)

  for row = start_row, end_row do
    if ctx.visible_rows[row] then
      ctx.flags.code[row] = true
      ctx.decorator:line(row, ctx.lines[row] or "", "MDTCodeBlock")
    end
  end

  local info = fence_info(ctx.lines[start_row] or "")
  if cfg.border and ctx.visible_rows[start_row] then
    ctx.decorator:overlay(start_row, 0, code_open_chunks(width, cfg, info), {
      priority = 240,
    })
  elseif cfg.language and info ~= "" and ctx.visible_rows[start_row] then
    local label = " " .. code_language(info) .. " "
    ctx.decorator:overlay(start_row, 0, { { label, "MDTCodeInfo" } }, {
      priority = 240,
    })
  end

  if cfg.border and end_row ~= start_row and ctx.visible_rows[end_row] then
    ctx.decorator:overlay(end_row, 0, code_close_chunks(width), {
      priority = 240,
    })
  end
end

local function render_horizontal_rule(ctx, capture)
  local cfg = ctx.cfg.hr
  if not cfg.enabled then
    return
  end

  local row = capture.start_row
  if ctx.flags.code[row] then
    return
  end

  local line = ctx.lines[row] or ""
  local rule = render_width_fill(cfg.char, math.max(ctx.width - 1, 8))
  ctx.decorator:overlay(row, 0, { { rule, "MDTHorizontalRule" } })
  ctx.decorator:line(row, line, "MDTHorizontalRule")
end

local function render_table(ctx, capture)
  local cfg = ctx.cfg.table
  if not cfg.enabled then
    return
  end

  for row = capture.start_row, capture.end_row do
    if ctx.visible_rows[row] then
      ctx.flags.table[row] = true
    end
  end

  for row = capture.start_row, capture.end_row do
    if ctx.visible_rows[row] then
      local line = ctx.lines[row] or ""
      local positions = separator_positions(line)
      if #positions >= 2 then
        local separator = is_separator_row(line)
        if separator then
          ctx.decorator:line(row, line, "MDTTableSeparator")
        end

        if cfg.border then
          for index, position in ipairs(positions) do
            local char = (index == 1 or index == #positions) and "┃" or "│"
            ctx.decorator:overlay(row, position - 1, { { char, separator and "MDTTableSeparator" or "MDTTableBorder" } }, {
              priority = 205,
            })
          end
        end

        if cfg.align and separator then
          for index = 1, #line do
            if line:sub(index, index) == ":" then
              ctx.decorator:highlight(row, index - 1, index, "MDTTableAlign")
            end
          end
        end
      end
    end
  end
end

local function highlight_ts_range(ctx, start_row, start_col, end_row, end_col, group, opts)
  if start_row == end_row then
    ctx.decorator:highlight(start_row + 1, start_col, end_col, group, opts)
    return
  end

  ctx.decorator:highlight(start_row + 1, start_col, #(ctx.lines[start_row + 1] or ""), group, opts)
  for row = start_row + 1, end_row - 1 do
    ctx.decorator:highlight(row + 1, 0, #(ctx.lines[row + 1] or ""), group, opts)
  end
  ctx.decorator:highlight(end_row + 1, 0, end_col, group, opts)
end

local function conceal_ts_node(ctx, node, opts)
  local start_row, start_col, end_row, end_col = node:range()
  if start_row == end_row then
    ctx.decorator:conceal(start_row + 1, start_col, end_col, opts)
  end
end

local function delimiters_and_body(node, delimiter_type)
  local delimiters = node_children_of_type(node, delimiter_type)
  if #delimiters < 2 then
    return nil
  end

  local first_start_row, first_start_col, first_end_row, first_end_col = delimiters[1]:range()
  local last_start_row, last_start_col = delimiters[#delimiters]:range()
  return {
    delimiters = delimiters,
    body = {
      start_row = first_end_row,
      start_col = first_end_col,
      end_row = last_start_row,
      end_col = last_start_col,
    },
  }
end

local function render_inline_code_capture(ctx, capture)
  local row = capture.start_row
  if ctx.flags.code[row] then
    return
  end

  local body = delimiters_and_body(capture.node, "code_span_delimiter")
  if not body then
    return
  end

  highlight_ts_range(
    ctx,
    capture.start_row - 1,
    capture.start_col,
    capture.end_row - 1,
    capture.end_col,
    "MDTInlineCode",
    { priority = 170 }
  )

  for _, delimiter in ipairs(body.delimiters) do
    conceal_ts_node(ctx, delimiter, { priority = 231 })
  end
end

local function render_emphasis_capture(ctx, capture, kind)
  local row = capture.start_row
  if ctx.flags.code[row] then
    return
  end

  local key = node_key(capture.node)
  if ctx.inline_skip[key] then
    return
  end

  local group = kind == "emphasis" and "MDTItalic" or "MDTBold"
  local info = delimiters_and_body(capture.node, "emphasis_delimiter")
  if not info then
    return
  end

  local nested_type = kind == "emphasis" and "strong_emphasis" or "emphasis"
  local nested = node_first_child_of_type(capture.node, nested_type)
  if nested then
    local nsr, nsc, ner, nec = nested:range()
    if nsr == info.body.start_row
      and nsc == info.body.start_col
      and ner == info.body.end_row
      and nec == info.body.end_col
    then
      local nested_info = delimiters_and_body(nested, "emphasis_delimiter")
      if nested_info then
        ctx.inline_skip[node_key(nested)] = true
        group = "MDTBoldItalic"
        highlight_ts_range(
          ctx,
          nested_info.body.start_row,
          nested_info.body.start_col,
          nested_info.body.end_row,
          nested_info.body.end_col,
          group,
          { priority = 168 }
        )
        for _, delimiter in ipairs(info.delimiters) do
          conceal_ts_node(ctx, delimiter, { priority = 231 })
        end
        for _, delimiter in ipairs(nested_info.delimiters) do
          conceal_ts_node(ctx, delimiter, { priority = 231 })
        end
        return
      end
    end
  end

  highlight_ts_range(
    ctx,
    info.body.start_row,
    info.body.start_col,
    info.body.end_row,
    info.body.end_col,
    group,
    { priority = 166 }
  )

  for _, delimiter in ipairs(info.delimiters) do
    conceal_ts_node(ctx, delimiter, { priority = 231 })
  end
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
  local buffer_state = render_state[bufnr]
  if buffer_state then
    buffer_state.signature = nil
    buffer_state.conceal_rows = nil
  end
end

function M.refresh(bufnr, force)
  if not utils.is_markdown_buffer(bufnr) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  ensure_highlights()
  local buffer_state = ensure_buffer_state(bufnr)
  local cfg = config.get().render
  local decorator = Decorator.new(bufnr, namespace)

  if not state.is_module_enabled("render", bufnr) then
    decorator:clear()
    apply_window_options(bufnr, false)
    buffer_state.signature = nil
    buffer_state.conceal_rows = nil
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  if not mode_enabled(cfg.modes, mode) then
    decorator:clear()
    apply_window_options(bufnr, false)
    buffer_state.signature = nil
    buffer_state.conceal_rows = nil
    return
  end

  if utils.file_size_mb(bufnr) > cfg.max_file_size then
    decorator:clear()
    apply_window_options(bufnr, false)
    buffer_state.signature = nil
    buffer_state.conceal_rows = nil
    return
  end

  if not ts.supported(bufnr) then
    decorator:clear()
    apply_window_options(bufnr, false)
    buffer_state.signature = nil
    buffer_state.conceal_rows = nil
    if not buffer_state.warned_missing_parser then
      utils.notify("Render requires Treesitter parsers for markdown and markdown_inline.", vim.log.levels.WARN)
      buffer_state.warned_missing_parser = true
    end
    return
  end

  buffer_state.warned_missing_parser = false

  local view = collect_view(bufnr, cfg)
  if not view then
    decorator:clear()
    apply_window_options(bufnr, false)
    buffer_state.signature = nil
    buffer_state.conceal_rows = nil
    return
  end

  apply_window_options(bufnr, true, cfg)

  local signature = build_signature(bufnr, mode, view)
  if not force and signature == buffer_state.signature then
    return
  end

  local captures = ts.collect(bufnr, view.ranges)
  local lines = utils.get_buf_lines(bufnr)
  local ctx = {
    bufnr = bufnr,
    cfg = cfg,
    conceal_rows = {},
    decorator = nil,
    width = view.width,
    lines = lines,
    visible_rows = view.visible_rows,
    flags = {
      code = {},
      table = {},
    },
    inline_skip = {},
  }
  ctx.decorator = Decorator.new(bufnr, namespace, view.hidden_rows, lines, ctx.conceal_rows)

  ctx.decorator:clear()

  for _, capture in ipairs(captures.code_block) do
    render_code_block(ctx, capture)
  end
  for _, capture in ipairs(captures.hr) do
    render_horizontal_rule(ctx, capture)
  end
  for _, capture in ipairs(captures.heading) do
    render_heading(ctx, capture)
  end
  for _, capture in ipairs(captures.table) do
    render_table(ctx, capture)
  end
  for _, capture in ipairs(captures.list_item) do
    render_list_item(ctx, capture)
  end
  if cfg.quote.enabled then
    for _, range in ipairs(view.ranges) do
      for row = range[1], range[2] do
        render_quote_line(ctx, row)
      end
    end
  end
  for _, capture in ipairs(captures.inline_code) do
    render_inline_code_capture(ctx, capture)
  end
  for _, capture in ipairs(captures.emphasis) do
    render_emphasis_capture(ctx, capture, "emphasis")
  end
  for _, capture in ipairs(captures.strong) do
    render_emphasis_capture(ctx, capture, "strong")
  end

  buffer_state.signature = signature
  buffer_state.conceal_rows = normalize_conceal_rows(ctx.conceal_rows)
end

schedule_refresh = function(bufnr, force)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local buffer_state = ensure_buffer_state(bufnr)
  local cfg = config.get().render
  buffer_state.refresh_seq = buffer_state.refresh_seq + 1
  buffer_state.pending_force = buffer_state.pending_force or force or false
  local current_seq = buffer_state.refresh_seq
  local delay = cfg.debounce or 0

  vim.defer_fn(function()
    local current_state = render_state[bufnr]
    if not current_state or not current_state.attached or current_state.refresh_seq ~= current_seq then
      return
    end

    local requested_force = current_state.pending_force
    current_state.pending_force = false
    M.refresh(bufnr, requested_force)
  end, delay)
end

function M.detach(bufnr)
  delete_group(bufnr)
  M.clear(bufnr)
  apply_window_options(bufnr, false)
  for _, winid in ipairs(buffer_windows(bufnr)) do
    clear_window_cursor(winid)
  end
  local buffer_state = render_state[bufnr]
  if buffer_state then
    buffer_state.attached = false
    buffer_state.pending_force = false
    buffer_state.refresh_seq = buffer_state.refresh_seq + 1
  end
end

function M.attach(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  local buffer_state = ensure_buffer_state(bufnr)
  local cfg = config.get().render
  buffer_state.attached = true

  if not state.is_module_enabled("render", bufnr) then
    M.detach(bufnr)
    return
  end

  local group = vim.api.nvim_create_augroup(group_name(bufnr), { clear = true })
  local events = {
    "BufEnter",
    "BufLeave",
    "BufWinEnter",
    "BufWinLeave",
    "CursorMoved",
    "InsertEnter",
    "InsertLeave",
    "ModeChanged",
    "TextChanged",
    "TextChangedI",
    "WinScrolled",
  }
  vim.api.nvim_create_autocmd(events, {
    buffer = bufnr,
    group = group,
    callback = function(args)
      if args.event == "BufLeave" or args.event == "BufWinLeave" then
        apply_window_options(bufnr, false)
        clear_window_cursor(vim.api.nvim_get_current_win())
        return
      end

      local winid = vim.api.nvim_get_current_win()
      if args.event == "BufEnter" or args.event == "BufWinEnter" then
        remember_window_cursor(winid)
      elseif args.event == "CursorMoved" and skip_concealed_cursor(bufnr, winid, cfg) then
        return
      end

      if state.is_module_enabled("render", bufnr) then
        schedule_refresh(bufnr, false)
      else
        M.detach(bufnr)
      end
    end,
  })

  for _, winid in ipairs(buffer_windows(bufnr)) do
    remember_window_cursor(winid)
  end
  schedule_refresh(bufnr, true)
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Render enhancement only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  state.set_module_enabled("render", true, bufnr)
  M.attach(bufnr)
  utils.notify("Render enhancement enabled for the current buffer.")
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  state.set_module_enabled("render", false, bufnr)
  M.detach(bufnr)
  utils.notify("Render enhancement disabled for the current buffer.")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Render enhancement only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  if state.toggle_module("render", bufnr) then
    M.attach(bufnr)
    utils.notify("Render enhancement enabled for the current buffer.")
  else
    M.detach(bufnr)
    utils.notify("Render enhancement disabled for the current buffer.")
  end
end

vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("MDToolRenderGlobal", { clear = true }),
  callback = function()
    for bufnr, buffer_state in pairs(render_state) do
      if buffer_state.attached and state.is_module_enabled("render", bufnr) then
        schedule_refresh(bufnr, true)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("MDToolRenderHighlights", { clear = true }),
  callback = function()
    highlights_ready = false
  end,
})

return M
