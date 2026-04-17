local config = require("md-tool.config")
local utils = require("md-tool.utils")

local M = {}

local function group_name(bufnr)
  return "MDToolToc" .. bufnr
end

local function delete_group(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, group_name(bufnr))
end

local function display_heading_text(text)
  text = text:gsub("%s*#+%s*$", "")
  text = text:gsub("!%[([^%]]*)%]%([^%)]+%)", "%1")
  text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
  text = text:gsub("`([^`]+)`", "%1")
  text = text:gsub("[*_~]", "")
  return vim.trim(text)
end

local function slugify(text, seen)
  local slug = text:lower()
  slug = slug:gsub("`", "")
  slug = slug:gsub("<[^>]+>", "")
  slug = slug:gsub("[%!\"#$%%&'()*+,./:;<=>?@%[%]\\^_{|}~]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", "")
  slug = slug:gsub("%-+$", "")
  if slug == "" then
    slug = "section"
  end

  local count = seen[slug] or 0
  seen[slug] = count + 1
  if count > 0 then
    slug = slug .. "-" .. count
  end
  return slug
end

local function parse_headings(lines)
  local cfg = config.get().toc
  local headings = {}
  local seen = {}
  local active_fence = nil
  local skip_toc = false

  for _, line in ipairs(lines) do
    local marker, length = utils.is_fence_line(line)
    if marker then
      if not active_fence then
        active_fence = { marker = marker, length = length }
      elseif active_fence.marker == marker and length >= active_fence.length then
        active_fence = nil
      end
    elseif not active_fence then
      local trimmed = vim.trim(line)
      if trimmed == cfg.fence_start then
        skip_toc = true
      elseif trimmed == cfg.fence_end then
        skip_toc = false
      elseif not skip_toc then
        local marks, raw_text = line:match("^(#+)%s+(.+)$")
        if marks and #marks <= 6 and #marks <= cfg.max_depth then
          local text = display_heading_text(raw_text)
          headings[#headings + 1] = {
            depth = #marks,
            text = text,
            anchor = slugify(text, seen),
          }
        end
      end
    end
  end

  return headings
end

local function build_toc_lines(lines)
  local headings = parse_headings(lines)
  if vim.tbl_isempty(headings) then
    return nil, "No headings found for TOC generation."
  end

  local min_depth = headings[1].depth
  for _, heading in ipairs(headings) do
    min_depth = math.min(min_depth, heading.depth)
  end

  local out = {}
  local marker = config.get().toc.list_marker
  for _, heading in ipairs(headings) do
    local indent = string.rep("  ", heading.depth - min_depth)
    out[#out + 1] = ("%s%s [%s](#%s)"):format(indent, marker, heading.text, heading.anchor)
  end
  return out
end

local function build_toc_block(toc_lines)
  local cfg = config.get().toc
  local block = { cfg.fence_start }
  vim.list_extend(block, toc_lines)
  block[#block + 1] = cfg.fence_end
  return block
end

local function find_marker_ranges(lines)
  local cfg = config.get().toc
  local ranges = {}
  local start_row = nil
  local active_fence = nil

  for index, line in ipairs(lines) do
    local marker, length = utils.is_fence_line(line)
    if marker then
      if not active_fence then
        active_fence = { marker = marker, length = length }
      elseif active_fence.marker == marker and length >= active_fence.length then
        active_fence = nil
      end
    elseif not active_fence then
      local trimmed = vim.trim(line)
      if trimmed == cfg.fence_start then
        start_row = index
      elseif trimmed == cfg.fence_end then
        if not start_row then
          return nil, "TOC end marker found without a matching start marker."
        end
        ranges[#ranges + 1] = {
          start_row = start_row,
          end_row = index,
        }
        start_row = nil
      end
    end
  end

  if start_row then
    return nil, "TOC start marker found without a matching end marker."
  end

  return ranges
end

local function range_contains_row(range, row)
  return row >= range.start_row and row <= range.end_row
end

local function find_target_range(ranges, row)
  for _, range in ipairs(ranges) do
    if range_contains_row(range, row) then
      return range
    end
  end
  return ranges[1]
end

local function insert_after_line(lines)
  local line = 1
  if lines[1] == "---" then
    for index = 2, #lines do
      if lines[index] == "---" or lines[index] == "..." then
        line = index + 1
        break
      end
    end
  end

  while line <= #lines and utils.line_is_blank(lines[line]) do
    line = line + 1
  end

  if line <= #lines and lines[line]:match("^#%s+") then
    return line
  end

  return line - 1
end

local function replace_range(bufnr, range, block)
  vim.api.nvim_buf_set_lines(bufnr, range.start_row - 1, range.end_row, false, block)
end

local function insert_block_at_row(bufnr, row, block)
  local lines = utils.get_buf_lines(bufnr)
  local insert_at = math.max(math.min(row - 1, #lines), 0)
  local before_line = lines[insert_at]
  local current_line = lines[insert_at + 1]
  local insert_lines = {}

  if before_line and not utils.line_is_blank(before_line) then
    insert_lines[#insert_lines + 1] = ""
  end
  vim.list_extend(insert_lines, block)
  if current_line and not utils.line_is_blank(current_line) then
    insert_lines[#insert_lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, insert_lines)
end

local function insert_block_at_default_location(bufnr, block)
  local lines = utils.get_buf_lines(bufnr)
  local insert_after = insert_after_line(lines)
  local insert_lines = {}
  if insert_after > 0 and not utils.line_is_blank(lines[insert_after]) then
    insert_lines[#insert_lines + 1] = ""
  end
  vim.list_extend(insert_lines, block)
  if not utils.line_is_blank(lines[insert_after + 1]) then
    insert_lines[#insert_lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, insert_after, insert_after, false, insert_lines)
end

local function write_toc_update(bufnr, block)
  local lines = utils.get_buf_lines(bufnr)
  local ranges, err = find_marker_ranges(lines)
  if not ranges then
    return false, err
  end

  if vim.tbl_isempty(ranges) then
    insert_block_at_default_location(bufnr, block)
    return true
  end

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  local target = find_target_range(ranges, cursor_row)
  replace_range(bufnr, target, block)
  return true
end

local function write_toc_generate(bufnr, block)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  insert_block_at_row(bufnr, row, block)
  return true
end

function M.update(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("TOC generation only works for markdown buffers.", vim.log.levels.ERROR)
    return false
  end

  local toc_lines, err = build_toc_lines(utils.get_buf_lines(bufnr))
  if not toc_lines then
    if not opts.silent then
      utils.notify(err, vim.log.levels.ERROR)
    end
    return false
  end

  local ok, write_err = write_toc_update(bufnr, build_toc_block(toc_lines))
  if not ok then
    if not opts.silent then
      utils.notify(write_err, vim.log.levels.ERROR)
    end
    return false
  end

  if not opts.silent then
    utils.notify("Markdown TOC updated.")
  end
  return true
end

function M.generate(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  if config.get().toc.GenAsUpdate then
    return M.update(bufnr, opts)
  end

  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("TOC generation only works for markdown buffers.", vim.log.levels.ERROR)
    return false
  end

  local toc_lines, err = build_toc_lines(utils.get_buf_lines(bufnr))
  if not toc_lines then
    if not opts.silent then
      utils.notify(err, vim.log.levels.ERROR)
    end
    return false
  end

  local ok, write_err = write_toc_generate(bufnr, build_toc_block(toc_lines))
  if not ok then
    if not opts.silent then
      utils.notify(write_err, vim.log.levels.ERROR)
    end
    return false
  end

  if not opts.silent then
    utils.notify("Markdown TOC generated at the current cursor position.")
  end
  return true
end

function M.detach(bufnr)
  delete_group(bufnr)
end

function M.attach(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  local cfg = config.get().toc
  if not cfg.auto_update_on_save then
    M.detach(bufnr)
    return
  end

  local group = vim.api.nvim_create_augroup(group_name(bufnr), { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    group = group,
    callback = function()
      M.update(bufnr, { silent = true })
    end,
  })
end

return M
