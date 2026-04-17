local M = {}

local default_render_modes = { "n", "v", "V", "\22", "c" }

local defaults = {
  render = {
    enabled = true,
    hide_in_insert = true,
    modes = vim.deepcopy(default_render_modes),
    debounce = 80,
    max_file_size = 5.0,
    visible_only = true,
    hide_on_cursorline = false,
    skip_concealed = true,
    heading = {
      enabled = true,
      icons = { "① ", "② ", "③ ", "④ ", "⑤ ", "⑥ " },
      highlight_line = true,
    },
    bullet = {
      enabled = true,
      icons = { "● ", "○ ", "◆ ", "◇ " },
    },
    checkbox = {
      enabled = true,
      unchecked = "☐ ",
      checked = "☑ ",
      partial = "◐ ",
    },
    quote = {
      enabled = true,
      icon = "▎",
    },
    callout = {
      enabled = true,
    },
    code = {
      enabled = true,
      border = true,
      language = true,
      min_width = 24,
    },
    hr = {
      enabled = true,
      char = "─",
    },
    table = {
      enabled = true,
      border = true,
      align = true,
    },
    link = {
      enabled = true,
      icon = "↗ ",
      wikilink_icon = "§ ",
      image_icon = "◫ ",
    },
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

local function validate_string_list(name, value)
  if type(value) ~= "table" or vim.tbl_isempty(value) then
    error(("md-tool: `%s` must be a non-empty list of strings."):format(name))
  end

  for _, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      error(("md-tool: `%s` must be a non-empty list of strings."):format(name))
    end
  end
end

local function validate_positive_integer(name, value)
  if type(value) ~= "number" or value < 1 or math.floor(value) ~= value then
    error(("md-tool: `%s` must be a positive integer."):format(name))
  end
end

local function validate_non_negative_integer(name, value)
  if type(value) ~= "number" or value < 0 or math.floor(value) ~= value then
    error(("md-tool: `%s` must be a non-negative integer."):format(name))
  end
end

local function validate_positive_number(name, value)
  if type(value) ~= "number" or value <= 0 then
    error(("md-tool: `%s` must be a positive number."):format(name))
  end
end

local function normalize_render(render_opts, raw_render)
  if raw_render and raw_render.modes == nil and raw_render.hide_in_insert ~= nil then
    render_opts.modes = vim.deepcopy(default_render_modes)
    if not raw_render.hide_in_insert then
      table.insert(render_opts.modes, "i")
      table.insert(render_opts.modes, "R")
    end
  end

  return render_opts
end

local function validate(opts)
  validate_boolean("render.enabled", opts.render.enabled)
  validate_boolean("render.hide_in_insert", opts.render.hide_in_insert)
  validate_string_list("render.modes", opts.render.modes)
  validate_non_negative_integer("render.debounce", opts.render.debounce)
  validate_positive_number("render.max_file_size", opts.render.max_file_size)
  validate_boolean("render.visible_only", opts.render.visible_only)
  validate_boolean("render.hide_on_cursorline", opts.render.hide_on_cursorline)
  validate_boolean("render.skip_concealed", opts.render.skip_concealed)
  validate_boolean("render.heading.enabled", opts.render.heading.enabled)
  validate_string_list("render.heading.icons", opts.render.heading.icons)
  validate_boolean("render.heading.highlight_line", opts.render.heading.highlight_line)
  validate_boolean("render.bullet.enabled", opts.render.bullet.enabled)
  validate_string_list("render.bullet.icons", opts.render.bullet.icons)
  validate_boolean("render.checkbox.enabled", opts.render.checkbox.enabled)
  validate_string("render.checkbox.unchecked", opts.render.checkbox.unchecked)
  validate_string("render.checkbox.checked", opts.render.checkbox.checked)
  validate_string("render.checkbox.partial", opts.render.checkbox.partial)
  validate_boolean("render.quote.enabled", opts.render.quote.enabled)
  validate_string("render.quote.icon", opts.render.quote.icon)
  validate_boolean("render.callout.enabled", opts.render.callout.enabled)
  validate_boolean("render.code.enabled", opts.render.code.enabled)
  validate_boolean("render.code.border", opts.render.code.border)
  validate_boolean("render.code.language", opts.render.code.language)
  validate_positive_integer("render.code.min_width", opts.render.code.min_width)
  validate_boolean("render.hr.enabled", opts.render.hr.enabled)
  validate_string("render.hr.char", opts.render.hr.char)
  validate_boolean("render.table.enabled", opts.render.table.enabled)
  validate_boolean("render.table.border", opts.render.table.border)
  validate_boolean("render.table.align", opts.render.table.align)
  validate_boolean("render.link.enabled", opts.render.link.enabled)
  validate_string("render.link.icon", opts.render.link.icon)
  validate_string("render.link.wikilink_icon", opts.render.link.wikilink_icon)
  validate_string("render.link.image_icon", opts.render.link.image_icon)

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
  merged.render = normalize_render(merged.render, user_opts and user_opts.render or nil)
  validate(merged)
  options = merged
  return options
end

return M
