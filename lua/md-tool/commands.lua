local list = require("md-tool.list")
local preview = require("md-tool.preview")
local render = require("md-tool.render")
local table_module = require("md-tool.table")
local toc = require("md-tool.toc")

local M = {
  registered = false,
}

function M.register()
  if M.registered then
    return
  end

  vim.api.nvim_create_user_command("MDTrenderToggle", function()
    render.toggle()
  end, {})
  vim.api.nvim_create_user_command("MDTrenderEnable", function()
    render.enable()
  end, {})
  vim.api.nvim_create_user_command("MDTrenderDisable", function()
    render.disable()
  end, {})

  vim.api.nvim_create_user_command("MDTpriviewToggle", function()
    preview.toggle()
  end, {})
  vim.api.nvim_create_user_command("MDTpriviewEnable", function()
    preview.enable()
  end, {})
  vim.api.nvim_create_user_command("MDTpriviewDisable", function()
    preview.disable()
  end, {})

  vim.api.nvim_create_user_command("MDTtableToggle", function()
    table_module.toggle()
  end, {})
  vim.api.nvim_create_user_command("MDTtableEnable", function()
    table_module.enable()
  end, {})
  vim.api.nvim_create_user_command("MDTtableDisable", function()
    table_module.disable()
  end, {})
  vim.api.nvim_create_user_command("MDTtableFormat", function()
    table_module.format_current_table()
  end, {})

  vim.api.nvim_create_user_command("MDTtocGen", function()
    toc.generate()
  end, {})
  vim.api.nvim_create_user_command("MDTtocUpdate", function()
    toc.update()
  end, {})

  vim.api.nvim_create_user_command("MDTlistToggle", function()
    list.toggle()
  end, {})
  vim.api.nvim_create_user_command("MDTlistEnable", function()
    list.enable()
  end, {})
  vim.api.nvim_create_user_command("MDTlistDisable", function()
    list.disable()
  end, {})
  vim.api.nvim_create_user_command("MDTlistFormat", function()
    list.format_current_list()
  end, {})

  M.registered = true
end

return M
