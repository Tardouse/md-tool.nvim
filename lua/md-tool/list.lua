local config = require("md-tool.config")
local state = require("md-tool.state")
local utils = require("md-tool.utils")

local M = {}

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

local function parse_quote_prefix(text)
  local quote = ""
  local rest = text

  while true do
    local piece, next_rest = rest:match("^(>%s*)(.*)$")
    if not piece then
      break
    end
    quote = quote .. piece
    rest = next_rest
  end

  return quote, rest
end

local function parse_list_line(line)
  local indent, rest = (line or ""):match("^(%s*)(.*)$")
  local quote, body = parse_quote_prefix(rest)

  local task_marker, task_state, task_text = body:match("^([-*+])%s+%[([ xX%-])%]%s*(.-)%s*$")
  if task_marker then
    return {
      indent = indent,
      quote = quote,
      body = body,
      kind = "task",
      marker = task_marker,
      task_state = task_state,
      text = task_text,
    }
  end

  local ordered_number, ordered_delim, ordered_text = body:match("^(%d+)([.)])%s*(.-)%s*$")
  if ordered_number then
    return {
      indent = indent,
      quote = quote,
      body = body,
      kind = "ordered",
      number = tonumber(ordered_number),
      delim = ordered_delim,
      text = ordered_text,
    }
  end

  local bullet_marker, bullet_text = body:match("^([-*+])%s*(.-)%s*$")
  if bullet_marker then
    return {
      indent = indent,
      quote = quote,
      body = body,
      kind = "bullet",
      marker = bullet_marker,
      text = bullet_text,
    }
  end
end

local function exit_list_item(bufnr, row, replacement)
  local winid = vim.api.nvim_get_current_win()
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local end_row = math.min(row + 1, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_buf_set_lines(bufnr, row - 1, end_row, false, { replacement })

    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      pcall(vim.api.nvim_win_set_cursor, winid, { row, #replacement })
    end
  end)
end

local function same_ordered_prefix(line, indent, quote)
  local prefix = vim.pesc(indent .. quote)
  return line:match("^" .. prefix .. "%d+[.)]%s+")
end

local function newline_preserves_indent(bufnr)
  return vim.bo[bufnr].autoindent
    or vim.bo[bufnr].smartindent
    or vim.bo[bufnr].cindent
    or vim.bo[bufnr].indentexpr ~= ""
end

local function action_continuation(action)
  if not action then
    return nil
  end

  if action.kind == "repeat" then
    return action.quote .. action.continuation
  end

  if action.kind == "ordered" then
    return action.quote .. action.number .. action.delim .. " "
  end
end

local function action_insert_text(action, bufnr)
  local continuation = action_continuation(action)
  if not continuation then
    return nil
  end

  if newline_preserves_indent(bufnr) then
    return continuation
  end

  return action.indent .. continuation
end

local function expr_insert(text)
  return "<C-r>=" .. vim.fn.string(text) .. "<CR>"
end

local function list_action(bufnr, row, line)
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return nil
  end

  if line:find("|", 1, true) then
    return nil
  end

  local parsed = parse_list_line(line)
  if not parsed then
    return nil
  end

  local cfg = config.get().list

  if parsed.quote ~= "" and not cfg.continue_in_quote then
    return nil
  end

  if parsed.kind == "task" then
    if not cfg.checklist then
      return nil
    end
    if cfg.exit_on_empty and vim.trim(parsed.text) == "" then
      return {
        kind = "exit",
        replacement = parsed.indent .. parsed.quote,
      }
    end

    local next_state = cfg.checked_to_unchecked and " " or parsed.task_state
    return {
      kind = "repeat",
      indent = parsed.indent,
      quote = parsed.quote,
      continuation = parsed.marker .. " [" .. next_state .. "] ",
    }
  end

  if parsed.kind == "ordered" then
    if not cfg.ordered then
      return nil
    end
    if cfg.exit_on_empty and vim.trim(parsed.text) == "" then
      return {
        kind = "exit",
        replacement = parsed.indent .. parsed.quote,
      }
    end

    local next_number = parsed.number
    if cfg.renumber_on_continue then
      next_number = next_number + 1
    end
    return {
      kind = "ordered",
      indent = parsed.indent,
      quote = parsed.quote,
      number = next_number,
      delim = parsed.delim,
      renumber = cfg.renumber_on_continue,
    }
  end

  if parsed.kind == "bullet" then
    if not cfg.unordered then
      return nil
    end
    if cfg.exit_on_empty and vim.trim(parsed.text) == "" then
      return {
        kind = "exit",
        replacement = parsed.indent .. parsed.quote,
      }
    end

    return {
      kind = "repeat",
      indent = parsed.indent,
      quote = parsed.quote,
      continuation = parsed.marker .. " ",
    }
  end

  return nil
end

local function action_prefix(action)
  if not action then
    return nil
  end

  if action.kind == "repeat" then
    return action.indent .. action.quote .. action.continuation
  end

  if action.kind == "ordered" then
    return action.indent .. action.quote .. action.number .. action.delim .. " "
  end

  return nil
end

local function action_lines(action, count)
  local lines = {}
  count = count or 1

  if action.kind == "repeat" then
    for _ = 1, count do
      lines[#lines + 1] = action_prefix(action)
    end
    return lines
  end

  if action.kind == "ordered" then
    local number = action.number
    for _ = 1, count do
      lines[#lines + 1] = action.indent .. action.quote .. number .. action.delim .. " "
      if action.renumber then
        number = number + 1
      end
    end
    return lines
  end

  for _ = 1, count do
    lines[#lines + 1] = ""
  end
  return lines
end

function M.expr_cr()
  local bufnr = vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("list", bufnr) then
    return "<CR>"
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local cursor_byte = math.min(col + 1, #line)
  if line:sub(cursor_byte + 1):match("%S") then
    return "<CR>"
  end

  local action = list_action(bufnr, row, line:sub(1, cursor_byte))
  if not action then
    return "<CR>"
  end

  if action.kind == "exit" then
    exit_list_item(bufnr, row, action.replacement)
    return "<CR>"
  end

  local insert_text = action_insert_text(action, bufnr)
  if insert_text then
    return "<CR>" .. expr_insert(insert_text)
  end

  return "<CR>"
end

function M.expr_tab()
  local bufnr = vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("list", bufnr) then
    return "<Tab>"
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return "<Tab>"
  end

  local line = vim.api.nvim_get_current_line()
  if line:find("|", 1, true) or not parse_list_line(line) then
    return "<Tab>"
  end

  return "<Esc>>>A"
end

function M.expr_shift_tab()
  local bufnr = vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("list", bufnr) then
    return "<S-Tab>"
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return "<S-Tab>"
  end

  local line = vim.api.nvim_get_current_line()
  if line:find("|", 1, true) or not parse_list_line(line) then
    return "<S-Tab>"
  end

  return "<Esc><<A"
end

function M.normal_o()
  local bufnr = vim.api.nvim_get_current_buf()
  local count = vim.v.count1
  if not utils.is_markdown_buffer(bufnr) or not state.is_module_enabled("list", bufnr) then
    feedkeys(("%do"):format(count))
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local action = list_action(bufnr, row, vim.api.nvim_get_current_line())
  if not action then
    feedkeys(("%do"):format(count))
    return
  end

  if action.kind == "exit" then
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { action.replacement })
  end

  local lines = action_lines(action, count)
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
  vim.api.nvim_win_set_cursor(0, { row + #lines, 0 })
  feedkeys("A")
end

function M.detach(bufnr)
  pcall(vim.keymap.del, "i", "<CR>", { buffer = bufnr })
  pcall(vim.keymap.del, "i", "<Tab>", { buffer = bufnr })
  pcall(vim.keymap.del, "i", "<S-Tab>", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "o", { buffer = bufnr })
end

function M.attach(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  if not state.is_module_enabled("list", bufnr) then
    M.detach(bufnr)
    return
  end

  vim.keymap.set("i", "<CR>", M.expr_cr, {
    buffer = bufnr,
    expr = true,
    noremap = true,
    silent = true,
    desc = "md-tool smart list continuation",
  })
  vim.keymap.set("i", "<Tab>", M.expr_tab, {
    buffer = bufnr,
    expr = true,
    noremap = true,
    silent = true,
    desc = "md-tool list indent",
  })
  vim.keymap.set("i", "<S-Tab>", M.expr_shift_tab, {
    buffer = bufnr,
    expr = true,
    noremap = true,
    silent = true,
    desc = "md-tool list outdent",
  })
  vim.keymap.set("n", "o", M.normal_o, {
    buffer = bufnr,
    noremap = true,
    silent = true,
    desc = "md-tool smart list continuation with o",
  })
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("List continuation only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  state.set_module_enabled("list", true, bufnr)
  M.attach(bufnr)
  utils.notify("List continuation enabled for the current buffer.")
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  state.set_module_enabled("list", false, bufnr)
  M.detach(bufnr)
  utils.notify("List continuation disabled for the current buffer.")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("List continuation only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  if state.toggle_module("list", bufnr) then
    M.attach(bufnr)
    utils.notify("List continuation enabled for the current buffer.")
  else
    M.detach(bufnr)
    utils.notify("List continuation disabled for the current buffer.")
  end
end

function M.format_current_list(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("List formatting only works for markdown buffers.", vim.log.levels.ERROR)
    return false
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    utils.notify("List formatting is not available in the current syntax context.", vim.log.levels.ERROR)
    return false
  end

  local lines = utils.get_buf_lines(bufnr)
  local line = lines[row] or ""
  local indent, rest = line:match("^(%s*)(.*)$")
  local quote, body = parse_quote_prefix(rest)
  local first_number = body:match("^(%d+)[.)]%s+")
  if not first_number then
    utils.notify("Cursor is not inside an ordered list.", vim.log.levels.ERROR)
    return false
  end

  local start_row = row
  while start_row > 1 and same_ordered_prefix(lines[start_row - 1] or "", indent, quote) do
    start_row = start_row - 1
  end

  local end_row = row
  while end_row < #lines and same_ordered_prefix(lines[end_row + 1] or "", indent, quote) do
    end_row = end_row + 1
  end

  local start_indent, start_rest = (lines[start_row] or ""):match("^(%s*)(.*)$")
  local start_quote, start_body = parse_quote_prefix(start_rest or "")
  local counter = tonumber(start_body:match("^(%d+)[.)]%s+") or first_number)
  local replacement = {}
  for index = start_row, end_row do
    local current = lines[index]
    local current_indent, current_rest = current:match("^(%s*)(.*)$")
    local current_quote, current_body = parse_quote_prefix(current_rest)
    local _, delim, text = current_body:match("^(%d+)([.)])%s+(.*)$")
    replacement[#replacement + 1] = current_indent .. current_quote .. counter .. delim .. " " .. text
    counter = counter + 1
  end

  vim.api.nvim_buf_set_lines(bufnr, start_row - 1, end_row, false, replacement)
  utils.notify("Ordered list renumbered.")
  return true
end

return M
