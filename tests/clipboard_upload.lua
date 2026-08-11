vim.opt.runtimepath:append(vim.fn.getcwd())

local config = require("md-tool.config")
local utils = require("md-tool.utils")

local temp_root = vim.fn.tempname()
config.setup({
  upload = {
    temp_dir = temp_root,
    filename = "capture-{timestamp}",
    picgo = {
      command = vim.v.progpath,
    },
  },
})

local notifications = {}
local completed = false
utils.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
  if message:match("^Clipboard image uploaded:") then
    completed = true
  end
end
utils.detect_os = function()
  return "linux"
end
utils.command_exists = function(command)
  return command == "wl-paste"
end

vim.env.WAYLAND_DISPLAY = "wayland-test"

local clipboard_bytes = "\137PNG\r\n\26\n\0md-tool-test"
local uploaded_path
vim.system = function(command, _, callback)
  if command[1] == "wl-paste" and command[2] == "--list-types" then
    callback({ code = 0, signal = 0, stdout = "text/plain\nimage/png\n", stderr = "" })
  elseif command[1] == "wl-paste" then
    callback({ code = 0, signal = 0, stdout = clipboard_bytes, stderr = "" })
  else
    uploaded_path = command[#command]
    local stat = assert(vim.uv.fs_stat(uploaded_path))
    local fd = assert(vim.uv.fs_open(uploaded_path, "r", 384))
    local contents = assert(vim.uv.fs_read(fd, stat.size, 0))
    assert(vim.uv.fs_close(fd))
    assert(contents == clipboard_bytes, "clipboard bytes changed before the PicGo upload")
    callback({ code = 0, signal = 0, stdout = "https://cdn.example.test/capture.png\n", stderr = "" })
  end
  return {}
end

vim.cmd.enew()
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })

require("md-tool.upload").upload_clipboard_image("architecture")
assert(vim.wait(1000, function()
  return completed
end, 10), "clipboard upload did not complete")

assert(uploaded_path and uploaded_path:match("capture%-%d+%.png$"), "upload.filename was not applied")
assert(
  vim.api.nvim_get_current_line() == "ab![architecture](<https://cdn.example.test/capture.png>)c",
  "uploaded Markdown image was not inserted after the cursor"
)
assert(vim.uv.fs_stat(uploaded_path) == nil, "temporary upload file was not removed")
assert(vim.uv.fs_rmdir(temp_root))
