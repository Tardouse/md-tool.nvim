local M = {}

local query_cache = {}
local inline_support = nil

local query_sources = {
  markdown = [[
    (fenced_code_block) @code_block
    (thematic_break) @hr
    [
      (atx_heading)
      (setext_heading)
    ] @heading
    (list_item) @list_item
    (pipe_table) @table
  ]],
  markdown_inline = [[
    (code_span) @inline_code
    (emphasis) @emphasis
    (strong_emphasis) @strong
    (inline_link) @inline_link
    (full_reference_link) @full_reference_link
    (collapsed_reference_link) @collapsed_reference_link
    (shortcut_link) @shortcut_link
    (image) @image
    (uri_autolink) @uri_autolink
    (email_autolink) @email_autolink
  ]],
}

local empty_capture_names = {
  code_block = true,
  hr = true,
  heading = true,
  list_item = true,
  table = true,
  inline_code = true,
  emphasis = true,
  strong = true,
  inline_link = true,
  full_reference_link = true,
  collapsed_reference_link = true,
  shortcut_link = true,
  image = true,
  uri_autolink = true,
  email_autolink = true,
}

local function get_query(language)
  if query_cache[language] then
    return query_cache[language]
  end

  local parsed = vim.treesitter.query.parse(language, query_sources[language])
  query_cache[language] = parsed
  return parsed
end

local function add_capture(result, seen, name, node)
  local start_row, start_col, end_row, end_col = node:range()
  local key = table.concat({
    name,
    start_row,
    start_col,
    end_row,
    end_col,
  }, ":")

  if seen[key] then
    return
  end

  seen[key] = true
  result[name][#result[name] + 1] = {
    node = node,
    start_row = start_row + 1,
    start_col = start_col,
    end_row = end_row + 1,
    end_col = end_col,
  }
end

function M.supported(bufnr)
  if not pcall(vim.treesitter.get_parser, bufnr, "markdown") then
    return false
  end

  if inline_support == nil then
    inline_support = pcall(vim.treesitter.query.parse, "markdown_inline", "(inline) @inline")
  end

  return inline_support
end

function M.collect(bufnr, ranges)
  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  for _, range in ipairs(ranges) do
    parser:parse({ range[1] - 1, range[2] })
  end

  local result = {}
  for name in pairs(empty_capture_names) do
    result[name] = {}
  end

  local seen = {}
  parser:for_each_tree(function(tree, language_tree)
    local language = language_tree:lang()
    if not query_sources[language] then
      return
    end

    local query = get_query(language)
    local root = tree:root()
    for _, range in ipairs(ranges) do
      for capture_id, node in query:iter_captures(root, bufnr, range[1] - 1, range[2]) do
        add_capture(result, seen, query.captures[capture_id], node)
      end
    end
  end)

  for _, captures in pairs(result) do
    table.sort(captures, function(left, right)
      if left.start_row == right.start_row then
        if left.start_col == right.start_col then
          if left.end_row == right.end_row then
            return left.end_col < right.end_col
          end
          return left.end_row < right.end_row
        end
        return left.start_col < right.start_col
      end
      return left.start_row < right.start_row
    end)
  end

  return result
end

return M
