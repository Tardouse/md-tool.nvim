local M = {}

local uv = vim.uv or vim.loop

local function trim(text)
  if type(text) ~= "string" then
    return ""
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function path_sep()
  return package.config:sub(1, 1)
end

local function join_path(...)
  return table.concat({ ... }, path_sep())
end

local function plugin_root(plugin)
  if type(plugin) == "table" then
    plugin = plugin.dir or plugin.path
  end

  if type(plugin) == "string" and plugin ~= "" then
    return vim.fs.normalize(plugin)
  end

  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end

  return vim.fs.normalize(vim.fn.fnamemodify(source, ":p:h:h:h"))
end

local function log(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "md-tool install" })
end

local function run(command, opts)
  opts = opts or {}
  local result = vim.system(command, {
    cwd = opts.cwd,
    text = true,
  }):wait()

  return result.code == 0, result
end

local function command_exists(command)
  return vim.fn.executable(command) == 1
end

local function failure_message(result)
  if not result then
    return "unknown failure"
  end

  local stderr = trim(result.stderr)
  if stderr ~= "" then
    return stderr
  end

  local stdout = trim(result.stdout)
  if stdout ~= "" then
    return stdout
  end

  return ("exit code %s"):format(result.code or "?")
end

local function detect_os()
  local sysname = uv.os_uname().sysname
  if sysname == "Darwin" then
    return "macos"
  end
  if sysname:match("Windows") then
    return "windows"
  end
  if sysname == "Linux" then
    return "linux"
  end
  return nil, ("unsupported OS: %s"):format(sysname)
end

local function detect_arch()
  local machine = uv.os_uname().machine:lower()
  local map = {
    ["x86_64"] = "x86_64",
    ["amd64"] = "x86_64",
    ["arm64"] = "aarch64",
    ["aarch64"] = "aarch64",
  }

  local arch = map[machine]
  if arch then
    return arch
  end

  return nil, ("unsupported architecture: %s"):format(machine)
end

local function rust_target_triple()
  local os_name, os_err = detect_os()
  if not os_name then
    return nil, os_err
  end

  local arch, arch_err = detect_arch()
  if not arch then
    return nil, arch_err
  end

  if os_name == "macos" then
    return ("%s-apple-darwin"):format(arch)
  end
  if os_name == "windows" then
    return ("%s-pc-windows-msvc"):format(arch)
  end
  return ("%s-unknown-linux-gnu"):format(arch)
end

local function binary_name()
  local os_name = detect_os()
  if os_name == "windows" then
    return "md-tool-preview.exe"
  end
  return "md-tool-preview"
end

local function release_archive_name(target)
  if target:match("windows") then
    return ("md-tool-preview-%s.zip"):format(target)
  end
  return ("md-tool-preview-%s.tar.gz"):format(target)
end

local function github_repo_slug(root)
  if vim.env.MD_TOOL_RELEASE_REPO and vim.env.MD_TOOL_RELEASE_REPO ~= "" then
    return vim.env.MD_TOOL_RELEASE_REPO
  end

  if not command_exists("git") then
    return "Tardouse/md-tool.nvim"
  end

  local ok, result = run({ "git", "-C", root, "remote", "get-url", "origin" })
  if not ok then
    return "Tardouse/md-tool.nvim"
  end

  local url = trim(result.stdout)
  return url:match("github.com[:/](.-/.-)%.git$")
    or url:match("github.com[:/](.-/.-)$")
    or "Tardouse/md-tool.nvim"
end

local function release_tag(root)
  if vim.env.MD_TOOL_RELEASE_TAG and vim.env.MD_TOOL_RELEASE_TAG ~= "" then
    return vim.env.MD_TOOL_RELEASE_TAG
  end

  if not command_exists("git") then
    return nil, "git not found"
  end

  local ok, result = run({ "git", "-C", root, "describe", "--tags", "--exact-match", "HEAD" })
  if not ok then
    return nil, "current checkout is not on an exact git tag"
  end

  local tag = trim(result.stdout)
  if tag == "" then
    return nil, "current checkout is not on an exact git tag"
  end

  return tag
end

local function temp_path(suffix)
  return vim.fn.tempname() .. suffix
end

local function download_with_curl(url, output)
  return run({ "curl", "-fsSL", "-o", output, url })
end

local function download_with_wget(url, output)
  return run({ "wget", "-q", "-O", output, url })
end

local function ps_quote(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function download_with_powershell(url, output)
  local script = table.concat({
    "$ProgressPreference = 'SilentlyContinue'",
    ("Invoke-WebRequest -Uri %s -OutFile %s"):format(ps_quote(url), ps_quote(output)),
  }, "; ")

  return run({ "powershell", "-NoProfile", "-Command", script })
end

local function download_file(url, output)
  if command_exists("curl") then
    return download_with_curl(url, output)
  end
  if command_exists("wget") then
    return download_with_wget(url, output)
  end
  if command_exists("powershell") then
    return download_with_powershell(url, output)
  end

  return false, { stderr = "no supported downloader found (curl, wget, or powershell)" }
end

local function extract_archive(archive, destination)
  if archive:sub(-4) == ".zip" then
    if command_exists("unzip") then
      return run({ "unzip", "-o", archive, "-d", destination })
    end
    if command_exists("powershell") then
      local script = ("Expand-Archive -Path %s -DestinationPath %s -Force"):format(
        ps_quote(archive),
        ps_quote(destination)
      )
      return run({ "powershell", "-NoProfile", "-Command", script })
    end
    return false, { stderr = "no supported zip extractor found (unzip or powershell)" }
  end

  if command_exists("tar") then
    return run({ "tar", "-xzf", archive, "-C", destination })
  end

  return false, { stderr = "no supported tar extractor found" }
end

local function copy_file(source, destination)
  pcall(uv.fs_unlink, destination)

  local ok, err = uv.fs_copyfile(source, destination)
  if not ok then
    return false, err
  end

  if detect_os() ~= "windows" then
    uv.fs_chmod(destination, 493)
  end

  return true
end

local function install_binary(root, source)
  local bin_dir = join_path(root, "bin")
  local destination = join_path(bin_dir, binary_name())

  vim.fn.mkdir(bin_dir, "p")

  local ok, err = copy_file(source, destination)
  if not ok then
    return nil, ("failed to copy binary to %s: %s"):format(destination, err)
  end

  return destination
end

local function find_extracted_binary(directory)
  local matches = vim.fs.find(binary_name(), {
    path = directory,
    type = "file",
    limit = 1,
  })

  return matches[1]
end

local function install_from_release(root)
  if vim.env.MD_TOOL_SKIP_RELEASE_DOWNLOAD == "1" then
    return nil, "release download disabled by MD_TOOL_SKIP_RELEASE_DOWNLOAD=1"
  end

  local tag, tag_err = release_tag(root)
  if not tag then
    return nil, tag_err
  end

  local target, target_err = rust_target_triple()
  if not target then
    return nil, target_err
  end

  local archive_name = release_archive_name(target)
  local repo = github_repo_slug(root)
  local url = ("https://github.com/%s/releases/download/%s/%s"):format(repo, tag, archive_name)
  local archive_path = temp_path(archive_name:match("%.zip$") and ".zip" or ".tar.gz")
  local extract_dir = temp_path(".md-tool-preview")

  vim.fn.mkdir(extract_dir, "p")

  local downloaded, download_result = download_file(url, archive_path)
  if not downloaded then
    return nil, ("failed to download %s: %s"):format(url, failure_message(download_result))
  end

  local extracted, extract_result = extract_archive(archive_path, extract_dir)
  if not extracted then
    return nil, ("failed to extract %s: %s"):format(archive_name, failure_message(extract_result))
  end

  local extracted_binary = find_extracted_binary(extract_dir)
  if not extracted_binary then
    return nil, ("archive %s did not contain %s"):format(archive_name, binary_name())
  end

  local installed, install_err = install_binary(root, extracted_binary)
  if not installed then
    return nil, install_err
  end

  return installed, ("downloaded %s"):format(url)
end

local function build_from_source(root)
  if not command_exists("cargo") then
    return nil, "cargo not found"
  end

  local built, build_result = run({ "cargo", "build", "--release" }, { cwd = root })
  if not built then
    return nil, ("cargo build --release failed: %s"):format(failure_message(build_result))
  end

  local source = join_path(root, "target", "release", binary_name())
  local stat = uv.fs_stat(source)
  if not stat or stat.type ~= "file" then
    return nil, ("built binary not found at %s"):format(source)
  end

  local installed, install_err = install_binary(root, source)
  if not installed then
    return nil, install_err
  end

  return installed
end

function M.build(plugin)
  local root = plugin_root(plugin)

  local installed, release_info = install_from_release(root)
  if installed then
    log(("installed prebuilt preview binary at %s (%s)"):format(installed, release_info))
    return installed
  end

  log(("prebuilt preview binary unavailable, falling back to cargo build: %s"):format(release_info), vim.log.levels.WARN)

  local built, build_err = build_from_source(root)
  if built then
    log(("built preview binary at %s"):format(built))
    return built
  end

  error(("md-tool preview install failed.\nrelease: %s\nbuild: %s"):format(release_info, build_err))
end

return M
