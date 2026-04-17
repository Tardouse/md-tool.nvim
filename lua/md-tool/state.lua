local M = {
  buffers = {},
}

local function ensure_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.buffers[bufnr] then
    M.buffers[bufnr] = {
      enabled_overrides = {},
      preview = {
        active = false,
        opened = false,
        url = nil,
        inflight = false,
        last_scroll_signature = nil,
        pending = false,
        pending_force = false,
        pending_scroll = nil,
        scroll_inflight = false,
        last_sent_tick = -1,
      },
    }
  end
  return M.buffers[bufnr]
end

function M.ensure_buffer(bufnr)
  return ensure_buffer(bufnr)
end

function M.cleanup_buffer(bufnr)
  M.buffers[bufnr] = nil
end

function M.is_module_enabled(module, bufnr)
  local buffer = ensure_buffer(bufnr)
  local override = buffer.enabled_overrides[module]
  if override ~= nil then
    return override
  end

  local config = require("md-tool.config").get()
  local section = config[module]
  return section ~= nil and section.enabled ~= false
end

function M.set_module_enabled(module, value, bufnr)
  local buffer = ensure_buffer(bufnr)
  buffer.enabled_overrides[module] = value
end

function M.clear_module_override(module, bufnr)
  local buffer = ensure_buffer(bufnr)
  buffer.enabled_overrides[module] = nil
end

function M.get_module_override(module, bufnr)
  return ensure_buffer(bufnr).enabled_overrides[module]
end

function M.toggle_module(module, bufnr)
  local next_value = not M.is_module_enabled(module, bufnr)
  M.set_module_enabled(module, next_value, bufnr)
  return next_value
end

function M.get_preview(bufnr)
  return ensure_buffer(bufnr).preview
end

function M.set_preview(bufnr, values)
  local preview = ensure_buffer(bufnr).preview
  for key, value in pairs(values) do
    preview[key] = value
  end
  return preview
end

return M
