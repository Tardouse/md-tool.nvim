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

local function exit_list_item(bufnr, row, replacement)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { replacement })
  end)
end

local function same_ordered_prefix(line, indent, quote)
  local prefix = vim.pesc(indent .. quote)
  return line:match("^" .. prefix .. "%d+[.)]%s+")
end

local function list_action(bufnr, row, line)
  if utils.in_frontmatter(bufnr, row) or utils.in_fenced_code_block(bufnr, row) then
    return nil
  end

  if line:find("|", 1, true) then
    return nil
  end

  local indent, rest = line:match("^(%s*)(.*)$")
  local quote, body = parse_quote_prefix(rest)
  local cfg = config.get().list

  if quote ~= "" and not cfg.continue_in_quote then
    return nil
  end

  local task_marker, task_state, task_text = body:match("^([-*+])%s+%[([ xX])%]%s*(.-)%s*$")
  if task_marker then
    if not cfg.checklist then
      return nil
    end
    if cfg.exit_on_empty and vim.trim(task_text) == "" then
      return {
        kind = "exit",
        replacement = indent .. quote,
      }
    end

    local next_state = cfg.checked_to_unchecked and " " or task_state
    return {
      kind = "repeat",
      prefix = indent .. quote .. task_marker .. " [" .. next_state .. "] ",
    }
  end

  local ordered_number, ordered_delim, ordered_text = body:match("^(%d+)([.)])%s*(.-)%s*$")
  if ordered_number then
    if not cfg.ordered then
      return nil
    end
    if cfg.exit_on_empty and vim.trim(ordered_text) == "" then
      return {
        kind = "exit",
        replacement = indent .. quote,
      }
    end

    local next_number = tonumber(ordered_number)
    if cfg.renumber_on_continue then
      next_number = next_number + 1
    end
    return {
      kind = "ordered",
      indent = indent,
      quote = quote,
      number = next_number,
      delim = ordered_delim,
      renumber = cfg.renumber_on_continue,
    }
  end

  local bullet_marker, bullet_text = body:match("^([-*+])%s*(.-)%s*$")
  if bullet_marker then
    if not cfg.unordered then
      return nil
    end
    if cfg.exit_on_empty and vim.trim(bullet_text) == "" then
      return {
        kind = "exit",
        replacement = indent .. quote,
      }
    end

    return {
      kind = "repeat",
      prefix = indent .. quote .. bullet_marker .. " ",
    }
  end

  return nil
end

local function action_prefix(action)
  if not action then
    return nil
  end

  if action.kind == "repeat" then
    return action.prefix
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
      lines[#lines + 1] = action.prefix
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

  local prefix = action_prefix(action)
  if prefix then
    return "<CR>" .. prefix
  end

  return "<CR>"
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
