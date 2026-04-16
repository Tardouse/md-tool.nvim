local M = {}

local defaults = {
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
}

local options = vim.deepcopy(defaults)

local function validate_boolean_or_auto(name, value)
  if type(value) == "boolean" or value == "auto" then
    return
  end
  error(("md-tool: `%s` must be a boolean or \"auto\"."):format(name))
end

local function validate_string(name, value)
  if type(value) ~= "string" then
    error(("md-tool: `%s` must be a string."):format(name))
  end
end

local function validate_boolean(name, value)
  if type(value) ~= "boolean" then
    error(("md-tool: `%s` must be a boolean."):format(name))
  end
end

local function validate_positive_integer(name, value)
  if type(value) ~= "number" or value < 1 or math.floor(value) ~= value then
    error(("md-tool: `%s` must be a positive integer."):format(name))
  end
end

local function validate(opts)
  validate_boolean("render.enabled", opts.render.enabled)

  validate_boolean("preview.enabled", opts.preview.enabled)
  validate_string("preview.host", opts.preview.host)
  validate_positive_integer("preview.port", opts.preview.port)
  validate_boolean_or_auto("preview.auto_open", opts.preview.auto_open)
  validate_string("preview.browser", opts.preview.browser)
  validate_boolean("preview.echo_url", opts.preview.echo_url)

  validate_boolean("table.enabled", opts.table.enabled)
  validate_boolean("table.auto_align", opts.table.auto_align)
  validate_boolean("table.format_on_save", opts.table.format_on_save)

  validate_boolean("toc.enabled", opts.toc.enabled)
  validate_boolean("toc.auto_update_on_save", opts.toc.auto_update_on_save)
  validate_string("toc.list_marker", opts.toc.list_marker)
  validate_positive_integer("toc.max_depth", opts.toc.max_depth)
  validate_string("toc.fence_start", opts.toc.fence_start)
  validate_string("toc.fence_end", opts.toc.fence_end)
  validate_boolean("toc.GenAsUpdate", opts.toc.GenAsUpdate)
  if not vim.tbl_contains({ "-", "*", "+" }, opts.toc.list_marker) then
    error('md-tool: `toc.list_marker` must be one of "-", "*", "+".')
  end

  validate_boolean("list.enabled", opts.list.enabled)
  validate_boolean("list.ordered", opts.list.ordered)
  validate_boolean("list.unordered", opts.list.unordered)
  validate_boolean("list.checklist", opts.list.checklist)
  validate_boolean("list.exit_on_empty", opts.list.exit_on_empty)
  validate_boolean("list.renumber_on_continue", opts.list.renumber_on_continue)
  validate_boolean("list.continue_in_quote", opts.list.continue_in_quote)
  validate_boolean("list.checked_to_unchecked", opts.list.checked_to_unchecked)
end

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.get()
  return options
end

function M.setup(user_opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user_opts or {})
  validate(merged)
  options = merged
  return options
end

return M
