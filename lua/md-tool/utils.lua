local M = {}

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "md-tool" })
end

function M.line_is_blank(line)
  return vim.trim(line or "") == ""
end

function M.is_markdown_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.bo[bufnr].filetype == "markdown"
end

function M.get_buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.find_markdown_buffers()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and M.is_markdown_buffer(bufnr) then
      table.insert(buffers, bufnr)
    end
  end
  return buffers
end

function M.display_width(text)
  return vim.fn.strdisplaywidth(text or "")
end

function M.html_escape(text)
  text = text or ""
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  text = text:gsub('"', "&quot;")
  return text
end

function M.join_path(...)
  return table.concat({ ... }, "/")
end

function M.mkdir_p(path)
  vim.fn.mkdir(path, "p")
end

function M.detect_os()
  local sysname = vim.loop.os_uname().sysname
  if sysname == "Darwin" then
    return "macos"
  end
  if sysname:match("Windows") then
    return "windows"
  end
  return "linux"
end

function M.is_ssh()
  return vim.env.SSH_CONNECTION ~= nil or vim.env.SSH_CLIENT ~= nil or vim.env.SSH_TTY ~= nil
end

function M.command_exists(command)
  return vim.fn.exepath(command) ~= ""
end

function M.extract_executable(command)
  if type(command) ~= "string" then
    return nil
  end

  local quoted = command:match([[^%s*"(.-)"]])
  if quoted then
    return quoted
  end

  local single_quoted = command:match([[^%s*'(.-)']])
  if single_quoted then
    return single_quoted
  end

  return command:match("^%s*([^%s]+)")
end

function M.shell_escape(value)
  return vim.fn.shellescape(value)
end

function M.run_detached(command)
  local job_id = vim.fn.jobstart({ vim.o.shell, vim.o.shellcmdflag, command }, { detach = true })
  return job_id > 0, job_id
end

function M.sanitize_filename(text)
  text = text or ""
  text = text:gsub("[^%w%-_]+", "-")
  text = text:gsub("%-+", "-")
  text = text:gsub("^%-+", "")
  text = text:gsub("%-+$", "")
  return text
end

function M.is_fence_line(line)
  local backticks = line:match("^%s*(```+)")
  if backticks then
    return "`", #backticks
  end

  local tildes = line:match("^%s*(~~~+)")
  if tildes then
    return "~", #tildes
  end

  return nil
end

function M.in_fenced_code_block(bufnr, row)
  local lines = M.get_buf_lines(bufnr)
  local active = nil

  for index = 1, math.min(row, #lines) do
    local marker, length = M.is_fence_line(lines[index])
    if marker then
      if not active then
        active = { marker = marker, length = length }
      elseif active.marker == marker and length >= active.length then
        if index == row then
          return true
        end
        active = nil
      end
    end

    if index == row and active then
      return true
    end
  end

  return false
end

function M.frontmatter_end(bufnr)
  local lines = M.get_buf_lines(bufnr)
  if lines[1] ~= "---" then
    return nil
  end

  for index = 2, #lines do
    if lines[index] == "---" or lines[index] == "..." then
      return index
    end
  end

  return nil
end

function M.in_frontmatter(bufnr, row)
  local ending = M.frontmatter_end(bufnr)
  return ending ~= nil and row <= ending
end

function M.is_horizontal_rule(line)
  local compact = (line or ""):gsub("%s+", "")
  if #compact < 3 then
    return false
  end
  if compact:match("^%-+$") or compact:match("^%*+$") or compact:match("^_+$") then
    return true
  end
  return false
end

return M
