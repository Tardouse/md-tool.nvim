local commands = require("md-tool.commands")
local config = require("md-tool.config")
local list = require("md-tool.list")
local preview = require("md-tool.preview")
local render = require("md-tool.render")
local state = require("md-tool.state")
local table_module = require("md-tool.table")
local toc = require("md-tool.toc")
local utils = require("md-tool.utils")

local M = {
  bootstrapped = false,
}

local function ensure_supported_version()
  local current = vim.version()
  if vim.version.ge(current, { 0, 11, 6 }) then
    return
  end

  error(("md-tool.nvim requires Neovim 0.11.6+, found %d.%d.%d."):format(
    current.major or 0,
    current.minor or 0,
    current.patch or 0
  ))
end

local function cleanup_modules(bufnr)
  render.detach(bufnr)
  list.detach(bufnr)
  table_module.detach(bufnr)
  toc.detach(bufnr)
  preview.detach(bufnr)
  state.cleanup_buffer(bufnr)
end

local function attach_modules(bufnr)
  if not utils.is_markdown_buffer(bufnr) then
    return
  end

  state.ensure_buffer(bufnr)
  render.attach(bufnr)
  list.attach(bufnr)
  table_module.attach(bufnr)
  toc.attach(bufnr)
  preview.attach(bufnr)
end

function M.bootstrap()
  ensure_supported_version()

  if M.bootstrapped then
    return
  end

  preview.bootstrap()
  commands.register()

  local group = vim.api.nvim_create_augroup("MDTool", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(args)
      attach_modules(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      if utils.is_markdown_buffer(args.buf) then
        attach_modules(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    callback = function(args)
      if utils.is_markdown_buffer(args.buf) then
        table_module.detach(args.buf)
        state.clear_module_override("table", args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      if vim.api.nvim_buf_is_valid(args.buf) then
        cleanup_modules(args.buf)
      else
        state.cleanup_buffer(args.buf)
      end
    end,
  })

  for _, bufnr in ipairs(utils.find_markdown_buffers()) do
    attach_modules(bufnr)
  end

  M.bootstrapped = true
end

function M.setup(opts)
  M.bootstrap()
  config.setup(opts)

  for _, bufnr in ipairs(utils.find_markdown_buffers()) do
    attach_modules(bufnr)
  end
end

return M
