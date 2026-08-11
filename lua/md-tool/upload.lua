local config = require("md-tool.config")
local utils = require("md-tool.utils")

local uv = vim.uv

local M = {}

local namespace = vim.api.nvim_create_namespace("md-tool-upload")

local function path_exists(path)
  return type(path) == "string" and path ~= "" and uv.fs_stat(path) ~= nil
end

local function trim(text)
  return vim.trim(text or "")
end

local function is_space(char)
  return char ~= nil and char ~= "" and char:match("%s") ~= nil
end

local function is_escaped(text, index)
  local count = 0
  local cursor = index - 1

  while cursor >= 1 and text:sub(cursor, cursor) == "\\" do
    count = count + 1
    cursor = cursor - 1
  end

  return count % 2 == 1
end

local function find_matching_bracket(text, open_index, open_char, close_char)
  local depth = 0

  for index = open_index, #text do
    local char = text:sub(index, index)
    if not is_escaped(text, index) then
      if char == open_char then
        depth = depth + 1
      elseif char == close_char then
        depth = depth - 1
        if depth == 0 then
          return index
        end
      end
    end
  end

  return nil
end

local function parse_link_destination(line, open_paren_index)
  local length = #line
  local index = open_paren_index + 1

  while index <= length and is_space(line:sub(index, index)) do
    index = index + 1
  end

  if index > length then
    return nil
  end

  local dest_start
  local dest_end

  if line:sub(index, index) == "<" then
    index = index + 1
    dest_start = index

    while index <= length do
      if line:sub(index, index) == ">" and not is_escaped(line, index) then
        dest_end = index - 1
        index = index + 1
        break
      end
      index = index + 1
    end
  else
    dest_start = index
    local depth = 0

    while index <= length do
      local char = line:sub(index, index)
      if char == "\\" then
        index = index + 2
      elseif char == "(" then
        depth = depth + 1
        index = index + 1
      elseif char == ")" then
        if depth == 0 then
          dest_end = index - 1
          break
        end
        depth = depth - 1
        index = index + 1
      elseif is_space(char) and depth == 0 then
        dest_end = index - 1
        break
      else
        index = index + 1
      end
    end
  end

  if dest_end == nil then
    return nil
  end

  while index <= length and is_space(line:sub(index, index)) do
    index = index + 1
  end

  if index <= length and line:sub(index, index) ~= ")" then
    local quote = line:sub(index, index)
    if quote ~= '"' and quote ~= "'" then
      return nil
    end

    index = index + 1
    while index <= length do
      if line:sub(index, index) == quote and not is_escaped(line, index) then
        index = index + 1
        break
      end
      index = index + 1
    end

    while index <= length and is_space(line:sub(index, index)) do
      index = index + 1
    end
  end

  if index > length or line:sub(index, index) ~= ")" then
    return nil
  end

  return {
    close_index = index,
    dest_start = dest_start,
    dest_end = dest_end,
  }
end

local function parse_inline_image_at(line, bang_index)
  if line:sub(bang_index, bang_index + 1) ~= "![" then
    return nil
  end

  local alt_open = bang_index + 1
  local alt_close = find_matching_bracket(line, alt_open, "[", "]")
  if not alt_close then
    return nil
  end

  local cursor = alt_close + 1
  while cursor <= #line and is_space(line:sub(cursor, cursor)) do
    cursor = cursor + 1
  end

  if line:sub(cursor, cursor) ~= "(" then
    return nil
  end

  local destination = parse_link_destination(line, cursor)
  if not destination then
    return nil
  end

  return {
    start_col = bang_index - 1,
    end_col = destination.close_index,
    dest_start_col = destination.dest_start - 1,
    dest_end_col = destination.dest_end,
    destination = line:sub(destination.dest_start, destination.dest_end),
  }
end

local function find_image_under_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local search_from = 1

  while true do
    local bang_index = line:find("![", search_from, true)
    if not bang_index then
      return nil
    end

    local image = parse_inline_image_at(line, bang_index)
    if image and col >= image.start_col and col < image.end_col then
      image.row = row
      return image
    end

    search_from = bang_index + 2
  end
end

local function strip_ansi(text)
  return (text or ""):gsub("\27%[[0-9;]*m", "")
end

local function command_error(prefix, result)
  local detail = trim(strip_ansi((result.stderr or "") ~= "" and result.stderr or result.stdout or ""))
  if detail == "" then
    detail = "exit code " .. tostring(result.code or -1)
  end
  return ("%s: %s"):format(prefix, detail)
end

local function binary_command_error(prefix, result)
  local detail = trim(strip_ansi(result.stderr or ""))
  if detail == "" then
    detail = "exit code " .. tostring(result.code or -1)
  end
  return ("%s: %s"):format(prefix, detail)
end

local function extract_uploaded_url(stdout, stderr)
  local combined = strip_ansi((stdout or "") .. "\n" .. (stderr or ""))
  local last_url = nil

  for url in combined:gmatch("https?://%S+") do
    last_url = url:gsub("[\"')%]%s]+$", "")
  end

  return last_url
end

local function split_filename(name)
  local stem, ext = (name or ""):match("^(.*)%.([^.]+)$")
  if not stem or stem == "" then
    return name or "", ""
  end
  return stem, "." .. ext
end

local function guess_extension(value)
  local cleaned = (value or ""):gsub("[?#].*$", "")
  local ext = cleaned:match("%.([A-Za-z0-9]+)$")
  if not ext then
    return ""
  end
  return "." .. ext
end

local function basename_from_url(url)
  local cleaned = (url or ""):gsub("[?#].*$", "")
  local name = cleaned:match("/([^/]+)$")
  if name and name ~= "" then
    return name
  end
  return nil
end

local function unique_suffix()
  return ("%d-%x"):format(os.time(), uv.hrtime())
end

local clipboard_mime_types = {
  { mime = "image/png", ext = ".png" },
  { mime = "image/jpeg", ext = ".jpg" },
  { mime = "image/jpg", ext = ".jpg" },
  { mime = "image/webp", ext = ".webp" },
  { mime = "image/gif", ext = ".gif" },
  { mime = "image/bmp", ext = ".bmp" },
  { mime = "image/tiff", ext = ".tiff" },
}

local function select_clipboard_image_type(output)
  local available = {}
  for value in (output or ""):gmatch("[^%s]+") do
    available[value:lower():gsub(";.*$", "")] = true
  end

  for _, image_type in ipairs(clipboard_mime_types) do
    if available[image_type.mime] then
      return image_type
    end
  end

  return nil
end

local function write_binary_file(path, data)
  if type(data) ~= "string" or data == "" then
    return nil, "The clipboard image was empty."
  end

  local fd, open_err = uv.fs_open(path, "w", 384)
  if not fd then
    return nil, "Failed to create the clipboard image: " .. tostring(open_err)
  end

  local offset = 0
  while offset < #data do
    local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written then
      uv.fs_close(fd)
      return nil, "Failed to save the clipboard image: " .. tostring(write_err)
    end
    offset = offset + written
  end

  local close_ok, close_err = uv.fs_close(fd)
  if not close_ok then
    return nil, "Failed to close the clipboard image: " .. tostring(close_err)
  end

  return true
end

local function resolve_temp_root()
  local root = trim(config.get().upload.temp_dir)
  if root == "" then
    root = vim.fs.joinpath(vim.fn.stdpath("cache"), "md-tool", "upload")
  else
    root = vim.fs.normalize(vim.fn.expand(root))
  end

  utils.mkdir_p(root)
  return root
end

local function create_operation_dir()
  local root = resolve_temp_root()

  for _ = 1, 8 do
    local path = vim.fs.joinpath(root, "op-" .. unique_suffix())
    local ok, err = uv.fs_mkdir(path, 448)
    if ok then
      return path
    end
    if err and not tostring(err):match("EEXIST") then
      return nil, "Failed to create temporary upload directory: " .. tostring(err)
    end
  end

  return nil, "Failed to allocate a temporary upload directory."
end

local function ensure_operation_dir(operation)
  if operation.dir then
    return operation.dir
  end

  local dir, err = create_operation_dir()
  if not dir then
    return nil, err
  end

  operation.dir = dir
  table.insert(operation.dirs, dir)
  return dir
end

local function cleanup_operation(operation)
  for _, file in ipairs(operation.files) do
    if path_exists(file) then
      pcall(uv.fs_unlink, file)
    end
  end

  for index = #operation.dirs, 1, -1 do
    local dir = operation.dirs[index]
    if path_exists(dir) then
      pcall(uv.fs_rmdir, dir)
    end
  end
end

local function allocate_clipboard_path(operation, ext)
  local dir, dir_err = ensure_operation_dir(operation)
  if not dir then
    return nil, dir_err
  end

  local filename = ("clipboard-%s-%06d%s"):format(os.date("%Y%m%d-%H%M%S"), uv.hrtime() % 1000000, ext)
  local path = vim.fs.joinpath(dir, filename)
  table.insert(operation.files, path)
  return path
end

local function clipboard_source(path, ext)
  local stat = uv.fs_stat(path)
  if not stat or not stat.size or stat.size == 0 then
    return nil, "The clipboard did not contain a readable image."
  end

  return {
    basename = vim.fs.basename(path),
    ext = ext,
    kind = "local",
    original = "clipboard",
    path = path,
  }
end

local function capture_stdout_image(list_command, read_command, operation, provider_name, callback)
  vim.system(list_command, { text = true, timeout = 10000 }, function(list_result)
    vim.schedule(function()
      if list_result.code ~= 0 then
        callback(command_error(("Failed to inspect the clipboard with %s"):format(provider_name), list_result))
        return
      end

      local image_type = select_clipboard_image_type(list_result.stdout)
      if not image_type then
        callback("The clipboard does not contain a supported image type.")
        return
      end

      local output_path, path_err = allocate_clipboard_path(operation, image_type.ext)
      if not output_path then
        callback(path_err)
        return
      end

      vim.system(read_command(image_type.mime), { timeout = 10000 }, function(read_result)
        vim.schedule(function()
          if read_result.code ~= 0 then
            callback(binary_command_error(("Failed to read the clipboard image with %s"):format(provider_name), read_result))
            return
          end

          local write_ok, write_err = write_binary_file(output_path, read_result.stdout)
          if not write_ok then
            callback(write_err)
            return
          end

          local source, source_err = clipboard_source(output_path, image_type.ext)
          callback(source_err, source)
        end)
      end)
    end)
  end)
end

local function capture_wayland_image(operation, callback)
  capture_stdout_image(
    { "wl-paste", "--list-types" },
    function(mime)
      return { "wl-paste", "--type", mime }
    end,
    operation,
    "wl-paste",
    callback
  )
end

local function capture_x11_image(operation, callback)
  capture_stdout_image(
    { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
    function(mime)
      return { "xclip", "-selection", "clipboard", "-t", mime, "-o" }
    end,
    operation,
    "xclip",
    callback
  )
end

local function run_file_clipboard_command(command, output_path, provider_name, callback)
  vim.system(command, { text = true, timeout = 10000 }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(command_error(("Failed to read the clipboard image with %s"):format(provider_name), result))
        return
      end

      local source, source_err = clipboard_source(output_path, ".png")
      callback(source_err, source)
    end)
  end)
end

local function capture_macos_image(operation, callback)
  local output_path, path_err = allocate_clipboard_path(operation, ".png")
  if not output_path then
    callback(path_err)
    return
  end

  if utils.command_exists("pngpaste") then
    run_file_clipboard_command({ "pngpaste", output_path }, output_path, "pngpaste", callback)
    return
  end

  local script = [[
on run argv
  set outputPath to item 1 of argv
  set imageData to the clipboard as «class PNGf»
  set fileRef to open for access (POSIX file outputPath) with write permission
  try
    set eof fileRef to 0
    write imageData to fileRef
    close access fileRef
  on error errorMessage number errorNumber
    try
      close access fileRef
    end try
    error errorMessage number errorNumber
  end try
end run
]]
  run_file_clipboard_command({ "osascript", "-e", script, "--", output_path }, output_path, "osascript", callback)
end

local function capture_windows_image(operation, callback)
  local powershell
  for _, executable in ipairs({ "pwsh", "powershell" }) do
    if utils.command_exists(executable) then
      powershell = executable
      break
    end
  end

  if not powershell then
    callback("PowerShell is required to read clipboard images on Windows.")
    return
  end

  local output_path, path_err = allocate_clipboard_path(operation, ".png")
  if not output_path then
    callback(path_err)
    return
  end

  local script = [[
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$image = [System.Windows.Forms.Clipboard]::GetImage()
if ($null -eq $image) {
  [Console]::Error.WriteLine("The clipboard does not contain an image.")
  exit 2
}
try {
  $image.Save($args[0], [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
  $image.Dispose()
}
]]
  run_file_clipboard_command(
    { powershell, "-NoProfile", "-STA", "-Command", script, output_path },
    output_path,
    powershell,
    callback
  )
end

local function capture_clipboard_image(operation, callback)
  local os_name = utils.detect_os()
  if os_name == "macos" then
    capture_macos_image(operation, callback)
    return
  end
  if os_name == "windows" then
    capture_windows_image(operation, callback)
    return
  end

  if vim.env.WAYLAND_DISPLAY and utils.command_exists("wl-paste") then
    capture_wayland_image(operation, callback)
    return
  end
  if vim.env.DISPLAY and utils.command_exists("xclip") then
    capture_x11_image(operation, callback)
    return
  end
  if utils.command_exists("wl-paste") then
    capture_wayland_image(operation, callback)
    return
  end
  if utils.command_exists("xclip") then
    capture_x11_image(operation, callback)
    return
  end

  callback("No clipboard image reader was found. Install wl-clipboard (Wayland) or xclip (X11).")
end

local function render_filename(template, context)
  return (template:gsub("{([%w_]+)}", function(key)
    return context[key] or "{" .. key .. "}"
  end))
end

local function sanitize_stage_name(name)
  local sanitized = trim(name)
  sanitized = sanitized:gsub('[<>:"/\\|?*]', "-")
  sanitized = sanitized:gsub("[%z\1-\31]", "")
  sanitized = sanitized:gsub("^%.+$", "image")
  return sanitized
end

local function build_filename_context(source)
  local basename = source.basename or "image"
  local stem, ext = split_filename(basename)
  if stem == "" then
    stem = "image"
  end

  return {
    basename = basename,
    datetime = os.date("%Y%m%d%H%M%S"),
    date = os.date("%Y%m%d"),
    d = os.date("%d"),
    ext = ext ~= "" and ext:sub(2) or "",
    file = basename,
    h = os.date("%H"),
    i = os.date("%M"),
    m = os.date("%m"),
    name = stem,
    origin = stem,
    rand = tostring(uv.hrtime() % 1000000),
    s = os.date("%S"),
    source = source.original,
    timestamp = tostring(os.time()),
    y = os.date("%Y"),
  }
end

local function build_stage_filename(source)
  local configured = config.get().upload.filename
  if configured == nil or configured == "" then
    return source.basename or ("image" .. source.ext)
  end

  local context = build_filename_context(source)
  local value

  if type(configured) == "function" then
    local ok, result = pcall(configured, context)
    if not ok then
      return nil, "upload.filename callback failed: " .. tostring(result)
    end
    value = tostring(result or "")
  else
    value = render_filename(configured, context)
  end

  value = sanitize_stage_name(value)
  if value == "" then
    value = context.origin ~= "" and context.origin or "image"
  end

  if not value:match("%.[^%.]+$") and source.ext ~= "" then
    value = value .. source.ext
  end

  return value
end

local function is_windows_absolute(path)
  return path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

local function resolve_local_path(destination, bufnr)
  local expanded = vim.fn.expand(destination)
  local path = expanded

  if not path:match("^/") and not is_windows_absolute(path) then
    local buffer_name = vim.api.nvim_buf_get_name(bufnr)
    local base_dir = buffer_name ~= "" and vim.fs.dirname(buffer_name) or vim.fn.getcwd()
    path = vim.fs.joinpath(base_dir, path)
  end

  path = vim.fs.normalize(path)
  if not path_exists(path) then
    return nil, ("Local image not found: %s"):format(destination)
  end

  return path
end

local function resolve_source(destination, bufnr)
  local target = trim(destination)
  if target == "" then
    return nil, "The Markdown image link has an empty destination."
  end

  if target:match("^https?://") then
    local basename = basename_from_url(target)
    local ext = guess_extension(basename or target)
    return {
      basename = basename or ("image" .. ext),
      ext = ext ~= "" and ext or ".png",
      kind = "remote",
      original = target,
      url = target,
    }
  end

  if target:match("^file://") then
    local ok, path = pcall(vim.uri_to_fname, target)
    if not ok or type(path) ~= "string" or path == "" then
      return nil, ("Unsupported file URI: %s"):format(target)
    end
    target = path
  end

  local path, err = resolve_local_path(target, bufnr)
  if not path then
    return nil, err
  end

  local basename = vim.fs.basename(path)
  return {
    basename = basename,
    ext = guess_extension(basename),
    kind = "local",
    original = target,
    path = path,
  }
end

local function resolve_picgo_command()
  local command = config.get().upload.picgo.command
  local expanded = vim.fn.expand(command)

  if vim.fn.executable(expanded) == 1 then
    return expanded
  end

  local from_path = vim.fn.exepath(command)
  if from_path ~= "" then
    return from_path
  end

  return nil, ("PicGo command is not executable: %s"):format(command)
end

local function default_picgo_config_path()
  return vim.fs.normalize(vim.fn.expand("~/.picgo/config.json"))
end

local function resolve_inline_picgo_config_dir()
  local configured = trim(config.get().upload.picgo.config_path)
  if configured ~= "" then
    return vim.fs.dirname(vim.fs.normalize(vim.fn.expand(configured)))
  end

  return vim.fs.dirname(default_picgo_config_path())
end

local function resolve_picgo_config_path(operation)
  local picgo = config.get().upload.picgo

  if type(picgo.config) == "table" then
    local dir = resolve_inline_picgo_config_dir()
    utils.mkdir_p(dir)

    local config_path = vim.fs.joinpath(dir, "md-tool-picgo-" .. unique_suffix() .. ".json")
    local ok, encoded = pcall(vim.json.encode, picgo.config)
    if not ok then
      return nil, "Failed to encode the inline PicGo config table."
    end

    local write_ok, write_err = pcall(vim.fn.writefile, { encoded }, config_path)
    if not write_ok then
      return nil, "Failed to write the inline PicGo config file: " .. tostring(write_err)
    end

    table.insert(operation.files, config_path)
    return config_path
  end

  local configured = trim(picgo.config_path)
  if configured == "" then
    return nil
  end

  local expanded = vim.fs.normalize(vim.fn.expand(configured))
  if not path_exists(expanded) then
    return nil, ("Configured PicGo config was not found: %s"):format(configured)
  end

  return expanded
end

local function build_download_command(url, output_path)
  if utils.command_exists("curl") then
    return { "curl", "-L", "--fail", "--silent", "--show-error", "-o", output_path, url }
  end

  if utils.command_exists("wget") then
    return { "wget", "-q", "-O", output_path, url }
  end

  for _, executable in ipairs({ "pwsh", "powershell" }) do
    if utils.command_exists(executable) then
      return {
        executable,
        "-NoProfile",
        "-Command",
        "Invoke-WebRequest -Uri $args[0] -OutFile $args[1]",
        url,
        output_path,
      }
    end
  end

  return nil
end

local function download_remote_image(url, output_path, callback)
  local command = build_download_command(url, output_path)
  if not command then
    callback("No supported downloader was found. Install curl, wget, or PowerShell.")
    return
  end

  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(command_error("Failed to download the remote image", result))
        return
      end

      callback(nil, output_path)
    end)
  end)
end

local function stage_source(source, operation, callback)
  local rename_configured = config.get().upload.filename ~= nil and config.get().upload.filename ~= ""
  if source.kind == "local" and not rename_configured then
    callback(nil, source.path)
    return
  end

  local dir, dir_err = ensure_operation_dir(operation)
  if not dir then
    callback(dir_err)
    return
  end

  local filename, name_err = build_stage_filename(source)
  if not filename then
    callback(name_err)
    return
  end

  local staged_path = vim.fs.joinpath(dir, filename)
  table.insert(operation.files, staged_path)

  if source.kind == "local" then
    local ok, err = uv.fs_copyfile(source.path, staged_path)
    if not ok then
      callback("Failed to stage the local image for upload: " .. tostring(err))
      return
    end

    callback(nil, staged_path)
    return
  end

  download_remote_image(source.url, staged_path, callback)
end

local function run_picgo(upload_path, config_path, callback)
  local command, command_err = resolve_picgo_command()
  if not command then
    callback(command_err)
    return
  end

  local picgo = config.get().upload.picgo
  local cmd = { command }

  for _, arg in ipairs(picgo.args or {}) do
    table.insert(cmd, arg)
  end

  if config_path then
    table.insert(cmd, "-c")
    table.insert(cmd, config_path)
  end

  table.insert(cmd, "u")
  table.insert(cmd, upload_path)

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(command_error("PicGo upload failed", result))
        return
      end

      local url = extract_uploaded_url(result.stdout, result.stderr)
      if not url then
        callback("PicGo completed without returning an uploaded URL.")
        return
      end

      callback(nil, url)
    end)
  end)
end

local function replace_destination(bufnr, mark_id, url)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "The buffer was closed before the upload finished."
  end

  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark_id, { details = true })
  if not mark or #mark == 0 then
    return "The Markdown image link changed before the upload finished."
  end

  local row = mark[1]
  local start_col = mark[2]
  local details = mark[3] or {}
  local end_row = details.end_row or row
  local end_col = details.end_col

  if end_col == nil or end_row ~= row then
    return "Only single-line Markdown image links are supported."
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return "Failed to reload the Markdown image link."
  end

  local before = line:sub(1, start_col)
  local after = line:sub(end_col + 1)
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before .. "<" .. url .. ">" .. after })
  vim.api.nvim_buf_del_extmark(bufnr, namespace, mark_id)

  return nil
end

local function upload_source(source, operation, callback)
  stage_source(source, operation, function(stage_err, upload_path)
    if stage_err then
      callback(stage_err)
      return
    end

    local config_path, config_err = resolve_picgo_config_path(operation)
    if config_err then
      callback(config_err)
      return
    end

    run_picgo(upload_path, config_path, callback)
  end)
end

local function begin_upload(bufnr, image)
  local source, source_err = resolve_source(image.destination, bufnr)
  if not source then
    utils.notify(source_err, vim.log.levels.ERROR)
    return
  end

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, image.row - 1, image.dest_start_col, {
    end_col = image.dest_end_col,
    end_row = image.row - 1,
    end_right_gravity = true,
    right_gravity = false,
  })

  local operation = {
    dirs = {},
    files = {},
  }

  utils.notify("Uploading image with PicGo...")

  upload_source(source, operation, function(upload_err, url)
    if upload_err then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, mark_id)
      cleanup_operation(operation)
      utils.notify(upload_err, vim.log.levels.ERROR)
      return
    end

    local replace_err = replace_destination(bufnr, mark_id, url)
    cleanup_operation(operation)
    if replace_err then
      utils.notify(replace_err, vim.log.levels.ERROR)
      return
    end

    utils.notify("Image uploaded: " .. url)
  end)
end

local function create_cursor_mark(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local col = math.min(cursor[2], #line)

  if line ~= "" and col < #line then
    local current_char = vim.fn.strcharpart(line:sub(col + 1), 0, 1)
    col = math.min(col + #current_char, #line)
  end

  return vim.api.nvim_buf_set_extmark(bufnr, namespace, row, col, {
    right_gravity = false,
  })
end

local function escape_image_alt(alt)
  return (alt:gsub("\\", "\\\\"):gsub("]", "\\]"))
end

local function insert_uploaded_image(bufnr, mark_id, url, alt)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "The buffer was closed before the upload finished."
  end

  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark_id, {})
  if not mark or #mark == 0 then
    return "The clipboard insertion point changed before the upload finished."
  end

  local row = mark[1]
  local col = mark[2]
  local markdown = ("![%s](<%s>)"):format(escape_image_alt(alt), url)
  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { markdown })
  vim.api.nvim_buf_del_extmark(bufnr, namespace, mark_id)

  if vim.api.nvim_get_current_buf() == bufnr then
    pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, math.max(col, col + #markdown - 1) })
  end

  return nil
end

local function begin_clipboard_upload(bufnr, alt)
  local mark_id = create_cursor_mark(bufnr)
  local operation = {
    dirs = {},
    files = {},
  }

  utils.notify("Reading image from the clipboard...")
  capture_clipboard_image(operation, function(capture_err, source)
    if capture_err then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, mark_id)
      cleanup_operation(operation)
      utils.notify(capture_err, vim.log.levels.ERROR)
      return
    end

    utils.notify("Uploading clipboard image with PicGo...")
    upload_source(source, operation, function(upload_err, url)
      if upload_err then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, mark_id)
        cleanup_operation(operation)
        utils.notify(upload_err, vim.log.levels.ERROR)
        return
      end

      local insert_err = insert_uploaded_image(bufnr, mark_id, url, alt)
      cleanup_operation(operation)
      if insert_err then
        utils.notify(insert_err, vim.log.levels.ERROR)
        return
      end

      utils.notify("Clipboard image uploaded: " .. url)
    end)
  end)
end

function M.upload_cursor_image()
  local bufnr = vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("MDTupload only works in Markdown buffers.", vim.log.levels.WARN)
    return
  end

  local image = find_image_under_cursor(bufnr)
  if not image then
    utils.notify("Place the cursor on a Markdown image link before running :MDTupload.", vim.log.levels.WARN)
    return
  end

  begin_upload(bufnr, image)
end

function M.upload_clipboard_image(alt)
  local bufnr = vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("MDTuploadClipboard only works in Markdown buffers.", vim.log.levels.WARN)
    return
  end

  alt = trim(alt)
  if alt == "" then
    alt = "image"
  end

  begin_clipboard_upload(bufnr, alt)
end

return M
