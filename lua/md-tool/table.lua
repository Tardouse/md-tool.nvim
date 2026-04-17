local config = require("md-tool.config")
local state = require("md-tool.state")
local utils = require("md-tool.utils")

local M = {}
local formatting = {}
local debounce_tokens = {}

local function group_name(bufnr)
  return "MDToolTable" .. bufnr
end

local function delete_group(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, group_name(bufnr))
end

local function is_tableish_line(line)
  return not utils.line_is_blank(line) and line:find("|", 1, true) ~= nil
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

local function is_separator_cell(cell)
  return vim.trim(cell):match("^:?-+:?$") ~= nil
end

local function is_separator_row(line)
  local cells = split_row(line)
  if #cells == 0 then
    return false
  end

  for _, cell in ipairs(cells) do
    if not is_separator_cell(cell) then
      return false
    end
  end

  return true
end

local function parse_alignment(cell)
  local trimmed = vim.trim(cell)
  local starts = trimmed:sub(1, 1) == ":"
  local ends = trimmed:sub(-1) == ":"

  if starts and ends then
    return "center"
  end
  if ends then
    return "right"
  end
  if starts then
    return "left"
  end
  return "none"
end

local function pad_text(text, width, align)
  local display_width = utils.display_width(text)
  local padding = math.max(width - display_width, 0)
  if align == "right" then
    return string.rep(" ", padding) .. text
  end
  if align == "center" then
    local left = math.floor(padding / 2)
    local right = padding - left
    return string.rep(" ", left) .. text .. string.rep(" ", right)
  end
  return text .. string.rep(" ", padding)
end

local function separator_text(width, align)
  local length = math.max(width, 3)
  if align == "center" then
    return ":" .. string.rep("-", length - 2) .. ":"
  end
  if align == "right" then
    return string.rep("-", length - 1) .. ":"
  end
  if align == "left" then
    return ":" .. string.rep("-", length - 1)
  end
  return string.rep("-", length)
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

local function line_cell_count(line)
  local positions = separator_positions(line)
  if #positions >= 2 then
    return #positions - 1
  end
  return #split_row(line)
end

local function is_partial_table_row(line)
  return line:match("^%s*|") ~= nil and line_cell_count(line) > 0 and line:match("|%s*$") ~= nil
end

local function build_empty_row(columns, indent)
  local cells = {}
  for _ = 1, columns do
    cells[#cells + 1] = "   "
  end
  return (indent or "") .. "|" .. table.concat(cells, "|") .. "|"
end

local function build_separator_row(columns, indent)
  local cells = {}
  for _ = 1, columns do
    cells[#cells + 1] = "---"
  end
  return (indent or "") .. "|" .. table.concat(cells, "|") .. "|"
end

local function cell_insert_col(line, cell_index)
  local positions = separator_positions(line)
  local opening = positions[cell_index]
  local closing = positions[cell_index + 1]
  if not opening or not closing then
    return math.max(#line - 1, 0)
  end

  return math.min(opening + 1, closing - 1)
end

local function set_current_cursor(bufnr, row, col)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { row, math.max(col, 0) })
end

local function block_is_valid(lines)
  if #lines < 2 then
    return false
  end

  for _, line in ipairs(lines) do
    if is_separator_row(line) then
      return true
    end
  end

  return false
end

local function lines_equal(left, right)
  if #left ~= #right then
    return false
  end

  for index = 1, #left do
    if left[index] ~= right[index] then
      return false
    end
  end

  return true
end

local function edit_mode_enabled(bufnr)
  return state.is_module_enabled("table", bufnr)
end

local function current_cell_index(line, col)
  local positions = separator_positions(line)
  if #positions < 2 then
    return nil
  end

  local byte_col = col + 1
  for index = 1, #positions - 1 do
    if byte_col < positions[index + 1] then
      return index
    end
  end

  return #positions - 1
end

local function with_cursor_preserved(bufnr, callback)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return callback()
  end

  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok, result, extra = pcall(callback)

  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == bufnr then
    local lines = utils.get_buf_lines(bufnr)
    local row = math.min(cursor[1], math.max(#lines, 1))
    local line = lines[row] or ""
    local col = math.min(cursor[2], #line)
    pcall(vim.api.nvim_win_set_cursor, win, { row, col })
  end

  if not ok then
    error(result)
  end

  return result, extra
end

function M.find_table_region(bufnr, row)
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return nil
  end

  local lines = utils.get_buf_lines(bufnr)
  if not is_tableish_line(lines[row] or "") then
    return nil
  end

  local start_row = row
  while start_row > 1 and is_tableish_line(lines[start_row - 1]) do
    if utils.in_frontmatter(bufnr, start_row - 1) or utils.in_fenced_code_block(bufnr, start_row - 1) then
      break
    end
    start_row = start_row - 1
  end

  local end_row = row
  while end_row < #lines and is_tableish_line(lines[end_row + 1]) do
    if utils.in_frontmatter(bufnr, end_row + 1) or utils.in_fenced_code_block(bufnr, end_row + 1) then
      break
    end
    end_row = end_row + 1
  end

  local region_lines = {}
  for index = start_row, end_row do
    region_lines[#region_lines + 1] = lines[index]
  end

  if not block_is_valid(region_lines) then
    return nil
  end

  return {
    start_row = start_row,
    end_row = end_row,
    lines = region_lines,
  }
end

local function format_region(bufnr, region)
  local parsed_rows = {}
  local max_columns = 0
  local separator_index = nil

  for index, line in ipairs(region.lines) do
    local cells = split_row(line)
    max_columns = math.max(max_columns, #cells)
    local separator = is_separator_row(line)
    if separator and not separator_index then
      separator_index = index
    end
    parsed_rows[index] = {
      cells = cells,
      separator = separator,
    }
  end

  if not separator_index then
    return false, "Table separator row is missing."
  end

  local alignments = {}
  for column = 1, max_columns do
    alignments[column] = "left"
  end

  local separator_row = parsed_rows[separator_index]
  for column = 1, max_columns do
    local cell = separator_row.cells[column] or "---"
    alignments[column] = parse_alignment(cell)
  end

  local widths = {}
  for column = 1, max_columns do
    widths[column] = 3
  end

  for _, row in ipairs(parsed_rows) do
    if not row.separator then
      for column = 1, max_columns do
        local text = row.cells[column] or ""
        widths[column] = math.max(widths[column], utils.display_width(text))
      end
    end
  end

  local formatted = {}
  for _, row in ipairs(parsed_rows) do
    local cells = {}
    for column = 1, max_columns do
      if row.separator then
        cells[column] = " " .. separator_text(widths[column], alignments[column]) .. " "
      else
        local text = row.cells[column] or ""
        cells[column] = " " .. pad_text(text, widths[column], alignments[column]) .. " "
      end
    end
    formatted[#formatted + 1] = "|" .. table.concat(cells, "|") .. "|"
  end

  if not lines_equal(region.lines, formatted) then
    vim.api.nvim_buf_set_lines(bufnr, region.start_row - 1, region.end_row, false, formatted)
    return true, true
  end

  return true, false
end

local function format_table_at_row(bufnr, row, opts)
  opts = opts or {}

  local region = M.find_table_region(bufnr, row)
  if not region then
    if not opts.silent then
      utils.notify("Cursor is not inside a Markdown table.", vim.log.levels.ERROR)
    end
    return false
  end

  local ok, changed_or_err = with_cursor_preserved(bufnr, function()
    return format_region(bufnr, region)
  end)

  if not ok then
    if not opts.silent then
      utils.notify(changed_or_err, vim.log.levels.ERROR)
    end
    return false
  end

  if not opts.silent and changed_or_err then
    utils.notify("Current Markdown table formatted.")
  end

  return true
end

local function schedule_current_table_format(bufnr, delay)
  delay = delay or 80
  debounce_tokens[bufnr] = (debounce_tokens[bufnr] or 0) + 1
  local token = debounce_tokens[bufnr]

  vim.defer_fn(function()
    if debounce_tokens[bufnr] ~= token or formatting[bufnr] then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    if not state.is_module_enabled("table", bufnr) or not edit_mode_enabled(bufnr) then
      return
    end

    formatting[bufnr] = true
    pcall(function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      format_table_at_row(bufnr, row, { silent = true })
    end)
    formatting[bufnr] = nil
  end, delay)
end

local function handle_separator_completion(bufnr, row, append_blank)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local columns = line_cell_count(line)
  if not is_partial_table_row(line) or columns == 0 then
    return
  end
  if not append_blank and columns < 2 then
    return
  end
  if not line:match("|%s*$") then
    return
  end

  formatting[bufnr] = true
  if append_blank then
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { line .. "   |" })
  end
  if M.find_table_region(bufnr, row) then
    format_table_at_row(bufnr, row, { silent = true })
  end

  local updated = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  set_current_cursor(bufnr, row, cell_insert_col(updated, line_cell_count(updated)))
  formatting[bufnr] = nil
end

local function handle_table_newline(bufnr, row, previous_line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local columns = line_cell_count(previous_line)
  if columns == 0 then
    return
  end

  local indent = previous_line:match("^(%s*)") or ""
  local replacement
  local target_row = row + 1

  if is_separator_row(previous_line) or M.find_table_region(bufnr, row) then
    replacement = build_empty_row(columns, indent)
  else
    replacement = build_separator_row(columns, indent)
  end

  formatting[bufnr] = true
  vim.api.nvim_buf_set_lines(bufnr, row - 1, row + 1, false, { previous_line, replacement })
  if M.find_table_region(bufnr, row) or is_separator_row(replacement) then
    format_table_at_row(bufnr, row, { silent = true })
  end

  local updated = vim.api.nvim_buf_get_lines(bufnr, target_row - 1, target_row, false)[1] or replacement
  set_current_cursor(bufnr, target_row, cell_insert_col(updated, 1))
  formatting[bufnr] = nil
end

local function handle_tab_navigation(bufnr, row, target_cell)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  if not is_partial_table_row(line) and not is_separator_row(line) then
    return
  end

  local columns = line_cell_count(line)
  if columns == 0 then
    return
  end

  formatting[bufnr] = true
  if target_cell > columns then
    local suffix = is_separator_row(line) and "---|" or "   |"
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { line .. suffix })
  end

  if M.find_table_region(bufnr, row) then
    format_table_at_row(bufnr, row, { silent = true })
  end

  local updated = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or line
  local target = math.min(target_cell, line_cell_count(updated))
  set_current_cursor(bufnr, row, cell_insert_col(updated, target))
  formatting[bufnr] = nil
end

function M.expr_bar()
  local bufnr = vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("table", bufnr) or not edit_mode_enabled(bufnr) then
    return "|"
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return "|"
  end

  local line = vim.api.nvim_get_current_line()
  local cursor_byte = math.min(col + 1, #line)
  local suffix = line:sub(cursor_byte + 1)
  local trailing_closing_bar = suffix:match("^%s*|%s*$") ~= nil
  if suffix:match("%S") and not trailing_closing_bar then
    return "|"
  end

  local prefix = line:sub(1, cursor_byte)
  if prefix:match("^%s*|") == nil or select(2, prefix:gsub("|", "")) < 1 then
    return "|"
  end

  vim.schedule(function()
    if state.is_module_enabled("table", bufnr) and edit_mode_enabled(bufnr) then
      handle_separator_completion(bufnr, row, not trailing_closing_bar)
    end
  end)

  return "|"
end

function M.expr_tab()
  local bufnr = vim.api.nvim_get_current_buf()
  local list = require("md-tool.list")
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("table", bufnr) or not edit_mode_enabled(bufnr) then
    return list.expr_tab()
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return list.expr_tab()
  end

  local line = vim.api.nvim_get_current_line()
  if not is_partial_table_row(line) and not is_separator_row(line) then
    return list.expr_tab()
  end

  local current_cell = current_cell_index(line, col)
  if not current_cell then
    return list.expr_tab()
  end

  vim.schedule(function()
    if state.is_module_enabled("table", bufnr) and edit_mode_enabled(bufnr) then
      handle_tab_navigation(bufnr, row, current_cell + 1)
    end
  end)

  return ""
end

function M.expr_cr()
  local bufnr = vim.api.nvim_get_current_buf()
  local list = require("md-tool.list")
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("table", bufnr) or not edit_mode_enabled(bufnr) then
    return list.expr_cr()
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return list.expr_cr()
  end

  local line = vim.api.nvim_get_current_line()
  local cursor_byte = math.min(col + 1, #line)
  local suffix = line:sub(cursor_byte + 1)
  if suffix:match("%S") and suffix:match("^%s*|%s*$") == nil then
    return list.expr_cr()
  end
  if not is_partial_table_row(line) and not is_separator_row(line) then
    return list.expr_cr()
  end

  vim.schedule(function()
    if state.is_module_enabled("table", bufnr) and edit_mode_enabled(bufnr) then
      handle_table_newline(bufnr, row, line)
    end
  end)

  return "<CR>"
end

function M.format_current_table(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Table formatting only works for markdown buffers.", vim.log.levels.ERROR)
    return false
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  return format_table_at_row(bufnr, row, opts)
end

function M.format_all_tables(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  if not utils.is_markdown_buffer(bufnr) then
    return false
  end

  local row = 1
  local lines = utils.get_buf_lines(bufnr)
  local changed = false

  while row <= #lines do
    local region = M.find_table_region(bufnr, row)
    if region then
      local ok, region_changed = format_region(bufnr, region)
      changed = region_changed or changed
      row = region.end_row + 1
      lines = utils.get_buf_lines(bufnr)
    else
      row = row + 1
    end
  end

  if changed and not opts.silent then
    utils.notify("Markdown tables formatted.")
  end
  return changed
end

function M.detach(bufnr)
  formatting[bufnr] = nil
  debounce_tokens[bufnr] = nil
  pcall(vim.keymap.del, "i", "|", { buffer = bufnr })
  pcall(vim.keymap.del, "i", "<Tab>", { buffer = bufnr })
  pcall(vim.keymap.del, "i", "<CR>", { buffer = bufnr })
  local ok, list = pcall(require, "md-tool.list")
  if ok and state.is_module_enabled("list", bufnr) then
    list.attach(bufnr)
  end
  delete_group(bufnr)
end

function M.attach(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  local cfg = config.get().table
  if not state.is_module_enabled("table", bufnr) then
    M.detach(bufnr)
    return
  end

  local enable_edit_mode = edit_mode_enabled(bufnr)
  if not enable_edit_mode and not cfg.format_on_save then
    M.detach(bufnr)
    return
  end

  local group = vim.api.nvim_create_augroup(group_name(bufnr), { clear = true })

  if enable_edit_mode then
    vim.keymap.set("i", "|", M.expr_bar, {
      buffer = bufnr,
      expr = true,
      noremap = true,
      silent = true,
      desc = "md-tool table separator completion",
    })

    vim.keymap.set("i", "<Tab>", M.expr_tab, {
      buffer = bufnr,
      expr = true,
      noremap = true,
      silent = true,
      desc = "md-tool table next cell",
    })

    vim.keymap.set("i", "<CR>", M.expr_cr, {
      buffer = bufnr,
      expr = true,
      noremap = true,
      silent = true,
      desc = "md-tool table newline handling",
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = bufnr,
      group = group,
      callback = function()
        if state.is_module_enabled("table", bufnr) and edit_mode_enabled(bufnr) then
          schedule_current_table_format(bufnr, 80)
        end
      end,
    })

    vim.api.nvim_create_autocmd("InsertLeave", {
      buffer = bufnr,
      group = group,
      callback = function()
        if state.is_module_enabled("table", bufnr) and edit_mode_enabled(bufnr) then
          schedule_current_table_format(bufnr, 0)
        end
      end,
    })
  end

  if cfg.format_on_save then
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      group = group,
      callback = function()
        if state.is_module_enabled("table", bufnr) then
          M.format_all_tables(bufnr, { silent = true })
        end
      end,
    })
  end
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Table mode only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  state.set_module_enabled("table", true, bufnr)
  M.attach(bufnr)
  utils.notify("Table mode enabled for the current buffer.")
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  state.set_module_enabled("table", false, bufnr)
  M.detach(bufnr)
  utils.notify("Table mode disabled for the current buffer.")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Table mode only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  if state.toggle_module("table", bufnr) then
    M.attach(bufnr)
    utils.notify("Table mode enabled for the current buffer.")
  else
    M.detach(bufnr)
    utils.notify("Table mode disabled for the current buffer.")
  end
end

return M
