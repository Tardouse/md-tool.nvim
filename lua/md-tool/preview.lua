local config = require("md-tool.config")
local state = require("md-tool.state")
local utils = require("md-tool.utils")

local uv = vim.uv

local M = {}

local lifecycle_group = "MDToolPreviewLifecycle"
local refresh_timers = {}
local scroll_timers = {}

local server = {
  active_bufnr = nil,
  browser_opened = false,
  current_bufnr = nil,
  handle = nil,
  managed = false,
  pending = {},
  ready = false,
  spawning = false,
  start_timer = nil,
  stopping = false,
  url = nil,
}

local function group_name(bufnr)
  return "MDToolPreview" .. bufnr
end

local function delete_group(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, group_name(bufnr))
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function stop_refresh_timer(bufnr)
  close_timer(refresh_timers[bufnr])
  refresh_timers[bufnr] = nil
end

local function stop_scroll_timer(bufnr)
  close_timer(scroll_timers[bufnr])
  scroll_timers[bufnr] = nil
end

local function stop_start_timer()
  close_timer(server.start_timer)
  server.start_timer = nil
end

local function build_server_url()
  local cfg = config.get().preview
  return ("http://%s:%d/"):format(cfg.host, cfg.port)
end

local function preview_binary_name()
  if utils.detect_os() == "windows" then
    return "md-tool-preview.exe"
  end
  return "md-tool-preview"
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local function is_executable(path)
  return type(path) == "string" and path ~= "" and vim.fn.executable(path) == 1
end

local function newest_executable(paths)
  local best_path = nil
  local best_mtime = -1

  for _, path in ipairs(paths) do
    local expanded = vim.fn.expand(path)
    if is_executable(expanded) then
      local stat = uv.fs_stat(expanded)
      local mtime = stat and stat.mtime and (stat.mtime.sec or 0) or 0
      if mtime >= best_mtime then
        best_path = expanded
        best_mtime = mtime
      end
    end
  end

  return best_path
end

local function resolve_binary_path()
  local cfg = config.get().preview
  local configured = vim.fn.expand(cfg.binary)

  if configured ~= "auto" then
    if is_executable(configured) then
      return configured
    end
    return nil, ("Configured preview binary is not executable: %s"):format(cfg.binary)
  end

  local name = preview_binary_name()
  local root = plugin_root()
  local local_candidates = {
    utils.join_path(root, "bin", name),
    utils.join_path(root, "target", "release", name),
    utils.join_path(root, "target", "debug", name),
  }

  local local_binary = newest_executable(local_candidates)
  if local_binary then
    return local_binary
  end

  local from_path = vim.fn.exepath(name)
  if from_path ~= "" and is_executable(from_path) then
    return from_path
  end

  return nil, "Preview binary not found. Build `md-tool-preview` or set `preview.binary`."
end

local function parse_http_response(raw)
  local status = tonumber(raw:match("^HTTP/%d%.%d%s+(%d+)"))
  local separator = raw:find("\r\n\r\n", 1, true)
  local body = separator and raw:sub(separator + 4) or ""
  return status, body
end

local function http_request(method, path, body, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end

  opts = opts or {}
  local cfg = config.get().preview
  local client = uv.new_tcp()
  local chunks = {}
  local content_type = opts.content_type or "text/markdown; charset=utf-8"
  local extra_headers = opts.headers or {}
  local finished = false
  body = body or ""

  local function finish(err, status, response_body)
    if finished then
      return
    end
    finished = true

    if client and not client:is_closing() then
      pcall(client.read_stop, client)
      client:close()
    end

    callback(err, status, response_body)
  end

  client:connect(cfg.host, cfg.port, function(err)
    if err then
      finish(err)
      return
    end

    local request_lines = {
      ("%s %s HTTP/1.1"):format(method, path),
      ("Host: %s:%d"):format(cfg.host, cfg.port),
      "Connection: close",
      "Accept: */*",
      ("Content-Type: %s"):format(content_type),
      ("Content-Length: %d"):format(#body),
    }

    for _, header in ipairs(extra_headers) do
      request_lines[#request_lines + 1] = header
    end

    request_lines[#request_lines + 1] = ""
    request_lines[#request_lines + 1] = body

    local request = table.concat(request_lines, "\r\n")

    client:write(request, function(write_err)
      if write_err then
        finish(write_err)
        return
      end

      client:read_start(function(read_err, chunk)
        if read_err then
          finish(read_err)
          return
        end

        if chunk then
          chunks[#chunks + 1] = chunk
          return
        end

        local raw = table.concat(chunks)
        local status, response_body = parse_http_response(raw)
        finish(nil, status, response_body)
      end)
    end)
  end)
end

local function flush_pending(err)
  local pending = server.pending
  server.pending = {}

  for _, callback in ipairs(pending) do
    callback(err, server.url)
  end
end

local function reset_server_process()
  stop_start_timer()
  server.handle = nil
  server.managed = false
  server.ready = false
  server.spawning = false
end

local function mark_server_ready()
  stop_start_timer()
  server.url = build_server_url()
  server.ready = true
  server.spawning = false
  flush_pending(nil)
end

local function mark_server_failed(message)
  local was_spawning = server.spawning
  reset_server_process()
  if was_spawning then
    flush_pending(message)
  end
end

local function wait_for_server()
  local timeout = config.get().preview.startup_timeout
  local started_at = uv.now()
  local probe_inflight = false
  local timer = uv.new_timer()

  server.start_timer = timer

  timer:start(0, 100, vim.schedule_wrap(function()
    if server.ready then
      stop_start_timer()
      return
    end

    if uv.now() - started_at > timeout then
      if server.managed and server.handle then
        pcall(server.handle.kill, server.handle, 15)
      end
      mark_server_failed(("Preview server did not become ready within %d ms."):format(timeout))
      return
    end

    if probe_inflight then
      return
    end

    probe_inflight = true
    http_request("GET", "/health", "", function(err, status)
      vim.schedule(function()
        probe_inflight = false
        if not err and status == 200 then
          mark_server_ready()
        end
      end)
    end)
  end))
end

local function check_server_compatibility(callback)
  http_request("GET", "/capabilities", "", function(err, status, body)
    vim.schedule(function()
      if err then
        callback(err)
        return
      end

      if status ~= 200 then
        callback(("Incompatible preview server is already running at %s. Stop the old server or restart Neovim."):format(
          build_server_url()
        ))
        return
      end

      local ok, decoded = pcall(vim.json.decode, body)
      if not ok or type(decoded) ~= "table" or decoded.protocol_version ~= 3 then
        callback(("Incompatible preview server is already running at %s. Stop the old server or restart Neovim."):format(
          build_server_url()
        ))
        return
      end

      callback(nil)
    end)
  end)
end

local function ensure_server_started(callback)
  server.url = build_server_url()

  if server.ready then
    callback(nil, server.url)
    return
  end

  table.insert(server.pending, callback)
  if server.spawning then
    return
  end

  server.spawning = true
  server.stopping = false

  http_request("GET", "/health", "", function(err, status)
    vim.schedule(function()
      if not err and status == 200 then
        check_server_compatibility(function(compat_err)
          if compat_err then
            mark_server_failed(compat_err)
            return
          end

          server.managed = false
          mark_server_ready()
        end)
        return
      end

      local binary, binary_err = resolve_binary_path()
      if not binary then
        mark_server_failed(binary_err)
        return
      end

      local cfg = config.get().preview
      local cmd = {
        binary,
        "--host",
        cfg.host,
        "--port",
        tostring(cfg.port),
        "--log-level",
        cfg.log_level,
      }

      local ok, handle_or_err = pcall(vim.system, cmd, { text = true }, function(result)
        vim.schedule(function()
          local exited_during_start = server.spawning
          local intentional = server.stopping
          reset_server_process()
          server.stopping = false
          server.browser_opened = false
          server.current_bufnr = nil

          if exited_during_start then
            flush_pending("Preview server exited before becoming ready.")
            return
          end

          if intentional then
            return
          end

          if result.code ~= 0 then
            utils.notify(
              ("Preview server exited with code %d."):format(result.code or -1),
              vim.log.levels.ERROR
            )
          end
        end)
      end)

      if not ok then
        mark_server_failed("Failed to start preview server: " .. tostring(handle_or_err))
        return
      end

      server.handle = handle_or_err
      server.managed = true
      wait_for_server()
    end)
  end)
end

local function resolve_browser_command()
  local cfg = config.get().preview
  if cfg.browser == "echo" then
    return nil
  end

  if cfg.browser ~= "auto" then
    local executable = utils.extract_executable(cfg.browser)
    if executable and not utils.command_exists(executable) then
      return nil, ("Configured browser command is unavailable: %s"):format(cfg.browser)
    end
    return cfg.browser
  end

  local os_name = utils.detect_os()
  if os_name == "macos" then
    return "open"
  end
  if os_name == "windows" then
    return 'cmd.exe /c start ""'
  end

  for _, command in ipairs({ "xdg-open", "gio open", "sensible-browser", "google-chrome", "firefox" }) do
    local executable = utils.extract_executable(command)
    if executable and utils.command_exists(executable) then
      return command
    end
  end

  return nil, "No browser opener command was found. Set `preview.browser` or use `browser = \"echo\"`."
end

local function should_open_browser()
  local cfg = config.get().preview
  if cfg.browser == "echo" then
    return false
  end
  if cfg.auto_open == true then
    return true
  end
  if cfg.auto_open == false then
    return false
  end
  return not utils.is_ssh()
end

local function open_browser(target)
  local browser, err = resolve_browser_command()
  if not browser then
    return false, err
  end

  local command = browser
  if browser:find("%%s", 1, true) then
    command = browser:format(target)
  else
    command = browser .. " " .. utils.shell_escape(target)
  end

  local ok = utils.run_detached(command)
  if not ok then
    return false, ("Failed to launch browser command: %s"):format(browser)
  end
  return true
end

local function maybe_open_preview(opts, url)
  local open_requested = opts.open ~= false and should_open_browser()

  if open_requested and not server.browser_opened then
    local opened, err = open_browser(url)
    if not opened then
      utils.notify(err, vim.log.levels.ERROR)
    else
      server.browser_opened = true
    end
  end

  if opts.notify_url ~= false and (config.get().preview.echo_url or not open_requested) then
    utils.notify("Preview: " .. url)
  end
end

local function can_refresh(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and utils.is_markdown_buffer(bufnr)
    and state.is_module_enabled("preview", bufnr)
    and state.get_preview(bufnr).active
end

local function can_sync_cursor(bufnr)
  return can_refresh(bufnr) and vim.fn.bufwinid(bufnr) ~= -1
end

local function schedule_refresh(bufnr, opts, delay)
  if not can_refresh(bufnr) then
    return
  end

  stop_refresh_timer(bufnr)

  local timer = uv.new_timer()
  refresh_timers[bufnr] = timer

  timer:start(delay or config.get().preview.debounce, 0, vim.schedule_wrap(function()
    stop_refresh_timer(bufnr)
    M.refresh(bufnr, opts)
  end))
end

local function build_scroll_payload(bufnr)
  if not can_sync_cursor(bufnr) then
    return nil
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local winheight = vim.api.nvim_win_get_height(winid)
  local wininfo = vim.fn.getwininfo(winid)[1]
  local topline = wininfo and wininfo.topline or cursor[1]
  local winline = math.max(cursor[1] - topline + 1, 1)

  return {
    cursor = cursor[1],
    line_count = line_count,
    winheight = winheight,
    winline = math.min(winline, winheight),
  }
end

local function scroll_signature(payload)
  return table.concat({
    tostring(payload.cursor),
    tostring(payload.line_count),
    tostring(payload.winheight),
    tostring(payload.winline),
  }, ":")
end

local function post_close_signal(callback)
  if not server.ready then
    if callback then
      callback()
    end
    return
  end

  http_request("POST", "/close", "", { content_type = "text/plain; charset=utf-8" }, function()
    vim.schedule(function()
      if callback then
        callback()
      end
    end)
  end)
end

local function sync_cursor(bufnr, opts)
  opts = opts or {}

  if not can_sync_cursor(bufnr) or server.active_bufnr ~= bufnr then
    return
  end

  ensure_server_started(function(err)
    if err then
      utils.notify(err, vim.log.levels.ERROR)
      return
    end

    if not can_sync_cursor(bufnr) or server.active_bufnr ~= bufnr then
      return
    end

    local payload = build_scroll_payload(bufnr)
    if not payload then
      return
    end

    local preview = state.get_preview(bufnr)
    local signature = scroll_signature(payload)

    if not opts.force and preview.last_scroll_signature == signature then
      return
    end

    if preview.scroll_inflight then
      state.set_preview(bufnr, {
        pending_scroll = payload,
      })
      return
    end

    state.set_preview(bufnr, {
      pending_scroll = nil,
      scroll_inflight = true,
    })

    http_request(
      "POST",
      "/scroll",
      vim.json.encode(payload),
      { content_type = "application/json; charset=utf-8" },
      function(post_err, status)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end

          local current = state.get_preview(bufnr)
          local pending_scroll = current.pending_scroll

          state.set_preview(bufnr, {
            pending_scroll = nil,
            scroll_inflight = false,
          })

          if post_err then
            utils.notify("Preview scroll sync failed: " .. tostring(post_err), vim.log.levels.ERROR)
          elseif status ~= 200 and status ~= 204 then
            utils.notify(("Preview scroll sync returned HTTP %s."):format(tostring(status)), vim.log.levels.ERROR)
          else
            state.set_preview(bufnr, {
              last_scroll_signature = signature,
            })
          end

          if pending_scroll and can_sync_cursor(bufnr) and server.active_bufnr == bufnr then
            state.set_preview(bufnr, {
              last_scroll_signature = nil,
            })
            sync_cursor(bufnr, { force = true })
          end
        end)
      end
    )
  end)
end

local function schedule_scroll_sync(bufnr, opts, delay)
  if not can_sync_cursor(bufnr) then
    return
  end

  stop_scroll_timer(bufnr)

  local timer = uv.new_timer()
  scroll_timers[bufnr] = timer

  timer:start(delay or 16, 0, vim.schedule_wrap(function()
    stop_scroll_timer(bufnr)
    sync_cursor(bufnr, opts)
  end))
end

function M.bootstrap()
  if M.bootstrapped then
    return
  end

  local group = vim.api.nvim_create_augroup(lifecycle_group, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.shutdown()
    end,
  })

  M.bootstrapped = true
end

function M.refresh(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Preview only works for markdown buffers.", vim.log.levels.ERROR)
    return false
  end

  ensure_server_started(function(err, url)
    if err then
      utils.notify(err, vim.log.levels.ERROR)
      return
    end

    if not can_refresh(bufnr) or server.active_bufnr ~= bufnr then
      return
    end

    local preview = state.get_preview(bufnr)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local switched_buffer = server.current_bufnr ~= bufnr

    maybe_open_preview(opts, url)

    if not opts.force and not switched_buffer and preview.last_sent_tick == changedtick then
      return
    end

    if preview.inflight then
      state.set_preview(bufnr, {
        pending = true,
        pending_force = preview.pending_force or opts.force == true,
      })
      return
    end

    local markdown = table.concat(utils.get_buf_lines(bufnr), "\n")
    local buffer_name = vim.api.nvim_buf_get_name(bufnr)
    local base_dir = buffer_name ~= "" and vim.fs.dirname(buffer_name) or vim.fn.getcwd()
    local payload = vim.json.encode({
      markdown = markdown,
      base_dir = base_dir,
    })

    state.set_preview(bufnr, {
      inflight = true,
      url = url,
    })

    http_request("POST", "/update", payload, { content_type = "application/json; charset=utf-8" }, function(post_err, status)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end

        local current = state.get_preview(bufnr)
        local pending = current.pending
        local pending_force = current.pending_force

        state.set_preview(bufnr, {
          inflight = false,
          pending = false,
          pending_force = false,
        })

        if post_err then
          utils.notify("Preview update failed: " .. tostring(post_err), vim.log.levels.ERROR)
        elseif status ~= 200 and status ~= 204 then
          utils.notify(("Preview server returned HTTP %s."):format(tostring(status)), vim.log.levels.ERROR)
        else
          state.set_preview(bufnr, {
            last_sent_tick = changedtick,
            url = url,
          })
          server.current_bufnr = bufnr
          schedule_scroll_sync(bufnr, { force = true }, 0)
        end

        if pending and can_refresh(bufnr) and server.active_bufnr == bufnr then
          schedule_refresh(bufnr, {
            open = false,
            notify_url = false,
            force = pending_force,
          }, 0)
        end
      end)
    end)
  end)

  return true
end

function M.attach(bufnr)
  delete_group(bufnr)

  if not can_refresh(bufnr) then
    return
  end

  local group = vim.api.nvim_create_augroup(group_name(bufnr), { clear = true })
  local function queue_update(args)
    if not can_refresh(args.buf) then
      return
    end

    if vim.api.nvim_get_current_buf() == args.buf then
      server.active_bufnr = args.buf
    end

    schedule_refresh(args.buf, {
      open = false,
      notify_url = false,
    })
  end

  local function queue_scroll(args)
    if not can_sync_cursor(args.buf) then
      return
    end

    if vim.api.nvim_get_current_buf() == args.buf then
      server.active_bufnr = args.buf
    end

    schedule_scroll_sync(args.buf, { force = false }, 16)
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufWritePost" }, {
    buffer = bufnr,
    group = group,
    callback = queue_update,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = bufnr,
    group = group,
    callback = queue_scroll,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    group = group,
    callback = function(args)
      if not can_refresh(args.buf) then
        return
      end
      server.active_bufnr = args.buf
      schedule_refresh(args.buf, {
        open = false,
        notify_url = false,
      }, 0)
      schedule_scroll_sync(args.buf, { force = true }, 0)
    end,
  })
end

function M.detach(bufnr)
  stop_refresh_timer(bufnr)
  stop_scroll_timer(bufnr)
  delete_group(bufnr)
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Preview only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  server.active_bufnr = bufnr
  state.set_module_enabled("preview", true, bufnr)
  state.set_preview(bufnr, {
    active = true,
    last_scroll_signature = nil,
    pending = false,
    pending_force = false,
    pending_scroll = nil,
    scroll_inflight = false,
    last_sent_tick = -1,
  })

  M.attach(bufnr)
  M.refresh(bufnr, { open = true, notify_url = true, force = true })
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local should_close_browser = server.browser_opened and (server.active_bufnr == bufnr or server.current_bufnr == bufnr)

  state.set_module_enabled("preview", false, bufnr)
  state.set_preview(bufnr, {
    active = false,
    inflight = false,
    last_scroll_signature = nil,
    pending = false,
    pending_force = false,
    pending_scroll = nil,
    scroll_inflight = false,
    last_sent_tick = -1,
  })

  if server.active_bufnr == bufnr then
    server.active_bufnr = nil
  end
  if server.current_bufnr == bufnr then
    server.current_bufnr = nil
  end

  M.detach(bufnr)
  if should_close_browser then
    server.browser_opened = false
    post_close_signal()
  end
  utils.notify("Preview disabled for the current buffer.")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_markdown_buffer(bufnr) then
    utils.notify("Preview only works for markdown buffers.", vim.log.levels.ERROR)
    return
  end

  local preview = state.get_preview(bufnr)
  if preview.active and state.is_module_enabled("preview", bufnr) then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

function M.shutdown()
  stop_start_timer()

  for bufnr in pairs(refresh_timers) do
    stop_refresh_timer(bufnr)
  end
  for bufnr in pairs(scroll_timers) do
    stop_scroll_timer(bufnr)
  end

  local function stop_server()
    if server.managed and server.handle then
      server.stopping = true
      pcall(server.handle.kill, server.handle, 15)
    end
  end

  if server.browser_opened then
    post_close_signal(stop_server)
  else
    stop_server()
  end

  server.ready = false
  server.spawning = false
  server.browser_opened = false
  server.current_bufnr = nil
  server.active_bufnr = nil
end

return M
