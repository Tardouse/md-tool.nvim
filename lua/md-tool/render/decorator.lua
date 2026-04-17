local Decorator = {}
Decorator.__index = Decorator

local function clamp_range(decorator, row, start_col, end_col)
  local line = decorator.lines[row]
  if line == nil then
    line = vim.api.nvim_buf_get_lines(decorator.bufnr, row - 1, row, false)[1] or ""
    decorator.lines[row] = line
  end

  local length = decorator.line_lengths[row]
  if length == nil then
    length = #line
    decorator.line_lengths[row] = length
  end

  start_col = math.max(math.min(start_col, length), 0)
  end_col = math.max(math.min(end_col, length), start_col)
  return line, start_col, end_col
end

function Decorator.new(bufnr, namespace, hidden_rows, lines, conceal_rows)
  return setmetatable({
    bufnr = bufnr,
    namespace = namespace,
    hidden_rows = hidden_rows or {},
    lines = lines or {},
    line_lengths = {},
    conceal_rows = conceal_rows,
  }, Decorator)
end

function Decorator:clear()
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
  end
end

function Decorator:is_hidden(row)
  return self.hidden_rows[row] == true
end

function Decorator:highlight(row, start_col, end_col, group, opts)
  opts = opts or {}
  if self:is_hidden(row) and not opts.allow_hidden then
    return
  end

  local _, clamped_start, clamped_end = clamp_range(self, row, start_col, end_col)
  if clamped_start == clamped_end then
    return
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, row - 1, clamped_start, {
    end_row = row - 1,
    end_col = clamped_end,
    hl_group = group,
    priority = opts.priority or 120,
  })
end

function Decorator:line(row, line, group, opts)
  opts = opts or {}
  if self:is_hidden(row) and not opts.allow_hidden then
    return
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, row - 1, 0, {
    end_row = row - 1,
    end_col = #(line or ""),
    line_hl_group = group,
    hl_eol = true,
    priority = opts.priority or 100,
  })
end

function Decorator:overlay(row, col, chunks, opts)
  opts = opts or {}
  if self:is_hidden(row) and not opts.allow_hidden then
    return
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, row - 1, col, {
    virt_text = chunks,
    virt_text_pos = opts.pos or "overlay",
    hl_mode = opts.hl_mode or "combine",
    priority = opts.priority or 220,
  })
end

function Decorator:conceal(row, start_col, end_col, opts)
  opts = opts or {}
  if self:is_hidden(row) and not opts.allow_hidden then
    return
  end

  local _, clamped_start, clamped_end = clamp_range(self, row, start_col, end_col)
  if clamped_start == clamped_end then
    return
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, row - 1, clamped_start, {
    end_row = row - 1,
    end_col = clamped_end,
    conceal = opts.text or "",
    priority = opts.priority or 230,
  })

  if self.conceal_rows then
    local ranges = self.conceal_rows[row]
    if not ranges then
      ranges = {}
      self.conceal_rows[row] = ranges
    end
    ranges[#ranges + 1] = { clamped_start, clamped_end }
  end
end

return Decorator
