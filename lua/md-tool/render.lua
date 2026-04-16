local config = require("md-tool.config")
local state = require("md-tool.state")
local utils = require("md-tool.utils")

local M = {}

local namespace = vim.api.nvim_create_namespace("md-tool-render")

local function group_name(bufnr)
  return "MDToolRender" .. bufnr
end

local function delete_group(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, group_name(bufnr))
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "MDTHeading1", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "MDTHeading2", { default = true, link = "Function" })
  vim.api.nvim_set_hl(0, "MDTHeading3", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "MDTHeading4", { default = true, link = "Statement" })
  vim.api.nvim_set_hl(0, "MDTHeading5", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "MDTHeading6", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "MDTListMarker", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "MDTBlockquote", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MDTCodeBlock", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "MDTHorizontalRule", { default = true, link = "Comment" })
end

local function add_range_highlight(bufnr, row, start_col, end_col, group)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local line_length = #line
  start_col = math.max(math.min(start_col, line_length), 0)
  end_col = math.max(math.min(end_col, line_length), start_col)

  vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, start_col, {
    end_row = row - 1,
    end_col = end_col,
    hl_group = group,
    priority = 120,
  })
end

local function add_line_highlight(bufnr, row, line, group)
  local end_col = #line
  vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, 0, {
    end_row = row - 1,
    end_col = end_col,
    line_hl_group = group,
    hl_eol = true,
    priority = 100,
  })
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

function M.refresh(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  ensure_highlights()
  M.clear(bufnr)

  local lines = utils.get_buf_lines(bufnr)
  local active_fence = nil

  for row, line in ipairs(lines) do
    local fence_marker, fence_length = utils.is_fence_line(line)
    if fence_marker then
      add_line_highlight(bufnr, row, line, "MDTCodeBlock")
      if not active_fence then
        active_fence = { marker = fence_marker, length = fence_length }
      elseif active_fence.marker == fence_marker and fence_length >= active_fence.length then
        active_fence = nil
      end
    elseif active_fence then
      add_line_highlight(bufnr, row, line, "MDTCodeBlock")
    elseif utils.is_horizontal_rule(line) then
      add_line_highlight(bufnr, row, line, "MDTHorizontalRule")
    else
      local heading_marks = line:match("^(#+)%s+")
      if heading_marks then
        local group = "MDTHeading" .. math.min(#heading_marks, 6)
        add_line_highlight(bufnr, row, line, group)
      end

      if line:match("^%s*>") then
        add_line_highlight(bufnr, row, line, "MDTBlockquote")
      end

      local task_prefix = line:match("^(%s*>?%s*[-*+]%s+%[[ xX]%])%s+")
      if task_prefix then
        add_range_highlight(bufnr, row, 0, #task_prefix, "MDTListMarker")
      else
        local ordered_prefix = line:match("^(%s*>?%s*%d+[.)])%s+")
        if ordered_prefix then
          add_range_highlight(bufnr, row, 0, #ordered_prefix, "MDTListMarker")
        else
          local bullet_prefix = line:match("^(%s*>?%s*[-*+])%s+")
          if bullet_prefix then
            add_range_highlight(bufnr, row, 0, #bullet_prefix, "MDTListMarker")
          end
        end
      end
    end
  end
end

function M.detach(bufnr)
  delete_group(bufnr)
  M.clear(bufnr)
end

function M.attach(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  if not state.is_module_enabled("render", bufnr) then
    M.detach(bufnr)
    return
  end

  local group = vim.api.nvim_create_augroup(group_name(bufnr), { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "InsertLeave", "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      if state.is_module_enabled("render", bufnr) then
        M.refresh(bufnr)
      else
        M.detach(bufnr)
      end
    end,
  })

  M.refresh(bufnr)
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

return M
