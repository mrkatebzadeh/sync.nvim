--[[ init.lua

Author: M.R. Siavash Katebzadeh <mr@katebzadeh.xyz>
Keywords: Lua, Neovim
Version: 0.0.1

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

local M = {}
local uv = vim.loop

M.defaults = {
  ignore = {},
  auto_sync = false,
  dry_run = false,
  auto_start = false,
}

local exclude_dirs = {
  ".git",
}

-- Function to check if the file is inside an excluded directory
local function is_excluded_dir(filename)
  for _, dir in ipairs(exclude_dirs) do
    if string.find(filename, dir .. "/") then
      return true
    end
  end
  return false
end

-- Function to get the project root directory
local function get_project_root(filename)
  local dir = vim.fn.fnamemodify(filename, ":p:h")
  while dir ~= "/" do
    if vim.fn.isdirectory(dir .. "/.git") == 1 or vim.fn.filereadable(dir .. "/.deploy.lua") == 1 then
      return dir
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  return nil
end

-- Function to check if the file is inside the project
local function is_file_in_project(filename)
  local project_root = get_project_root(filename)
  if not project_root then
    return false
  end

  local file_dir = vim.fn.fnamemodify(filename, ":p:h")
  local is_in_project = string.find(file_dir, project_root, 1, true) == 1

  if is_in_project and not is_excluded_dir(filename) then
    return true
  else
    return false
  end
end

-- Find .deploy.lua in current dir or parent
local function find_deploy_file(start_path)
  local function is_file(path)
    local stat = uv.fs_stat(path)
    return stat and stat.type == "file"
  end

  local function join(...)
    return table.concat({ ... }, "/")
  end

  local path = get_project_root(start_path or vim.api.nvim_buf_get_name(0), ":p:h")
  local candidate = join(path, ".deploy.lua")
  if is_file(candidate) then
    return candidate
  else
    return nil
  end
end

-- Auto-sync on save if enabled
local function setup_auto_sync()
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = "SyncAutoGroup",
    pattern = "*",
    callback = function(args)
      local filename = vim.api.nvim_buf_get_name(args.buf)
      if filename == "" then
        return
      end
      if is_file_in_project(filename) then
        if M.options.auto_sync then
          M.sync_now()
        end
      end
    end,
  })
end

local function setup_auto_start()
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = "SyncAutoGroup",
    pattern = "*",
    callback = function(args)
      local filename = vim.api.nvim_buf_get_name(args.buf)
      if filename == "" then
        return
      end
      if is_file_in_project(filename) then
        local config_path = find_deploy_file(filename)
        if config_path then
          vim.notify("[sync.nvim] Auto-loading deploy config for: " .. filename)
          M.load_config(config_path)
        end
      end
    end,
  })
end

--- Setup the plugin
---@param opts any
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})

  vim.api.nvim_create_augroup("SyncAutoGroup", { clear = true })
  if M.options.auto_start then
    setup_auto_start()
  end
  if M.options.auto_sync then
    setup_auto_sync()
  end
end

--- Load config file
function M.load_config()
  local config_file = find_deploy_file()
  if config_file then
    local ok, config = pcall(dofile, config_file)
    if ok and type(config) == "table" then
      M.config = config
      if config.ignore then
        M.options.ignore = config.ignore
      end

      if config.auto_sync ~= nil then
        M.options.auto_sync = config.auto_sync
        if config.auto_sync then
          setup_auto_sync()
        end
      end

      if config.dry_run ~= nil then
        M.options.dry_run = config.dry_run
      end

      vim.notify("[sync.nvim] Loaded config from " .. config_file)
    else
      vim.notify("[sync.nvim] ❌ Invalid config file", vim.log.levels.ERROR)
    end
  else
    vim.notify("[sync.nvim] ❌ No .deploy.lua found", vim.log.levels.WARN)
  end
end

--- Reload config on demand
function M.reload_config()
  M.config = nil
  M.load_config()
  vim.notify("[sync.nvim] 🔄 Config reloaded from .deploy.lua")
end

-- Check if SSH is passwordless
local function is_passwordless_ssh(remote)
  local host = remote:match("^([^:]+):")
  if not host then
    return false
  end

  vim.fn.system({ "ssh", "-o", "BatchMode=yes", host, "exit" })
  return vim.v.shell_error == 0
end

--- Sync the remote path with local path
function M.sync_now()
  if not M.config then
    M.load_config()
  end
  local cfg = M.config or {}

  local local_path = vim.fn.expand(cfg.root_local or "")
  local remote_path = cfg.root_remote or ""

  local_path = local_path:gsub("^~", vim.fn.expand("~"))
  remote_path = remote_path:gsub("^~", vim.fn.expand("~"))

  if not local_path:match("/$") then
    local_path = local_path .. "/"
  end

  if not remote_path:match("/$") then
    remote_path = remote_path .. "/"
  end

  if not local_path or not remote_path then
    vim.notify("[sync.nvim] ❌ Missing root_local or root_remote", vim.log.levels.ERROR)
    return
  end

  local cmd = {}
  local password = nil

  if is_passwordless_ssh(remote_path) then
    cmd = { "rsync", "-az", "--delete" }
  else
    password = vim.fn.inputsecret("SSH Password: ")
    cmd = { "sshpass", "-p", password, "rsync", "-az", "--delete" }
  end

  if M.options.dry_run then
    table.insert(cmd, "--dry-run")
  end

  for _, pattern in ipairs(M.options.ignore or {}) do
    table.insert(cmd, "--exclude")
    table.insert(cmd, pattern)
  end

  table.insert(cmd, local_path)
  table.insert(cmd, remote_path)

  vim.notify("[sync.nvim] 🔁 Starting rsync" .. (M.options.dry_run and " (dry-run mode)" or "") .. "...")

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.notify("[sync.nvim] " .. line, vim.log.levels.INFO)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.notify("[sync.nvim] ❌" .. line, vim.log.levels.ERROR)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[sync.nvim] ✅ Sync complete")
      else
        vim.notify("[sync.nvim] ❌ rsync failed with exit code " .. code, vim.log.levels.ERROR)
      end
    end,
  })
end


local function write_default_deploy_file(path)
  local lines = {
    "-- .deploy.lua",
    "-- Configuration for sync.nvim",
    "",
    "-- You can override the plugin settings like this:",
    "return {",
    "--   root_remote = \"remotepath:~/MyProjects\", ",
    "--   root_local = \"~/MyProjects\", ",
    "  ignore = { \".git\", \"node_modules\" },",
    "  auto_sync = false,",
    "}",
  }

  local file = io.open(path, "w")
  if file then
    for _, line in ipairs(lines) do
      file:write(line .. "\n")
    end
    file:close()
    vim.notify("[sync.nvim] Created .deploy.lua with default comments at " .. path)
  else
    vim.notify("[sync.nvim] ❌ Failed to create .deploy.lua")
  end
end

local function sync_init()
  local root = get_project_root(vim.api.nvim_buf_get_name(0), ":p:h")
  if not root then
    vim.notify("[sync.nvim] ❌ Failed to find the root. SyncInit must be called in a git project.")
    return false
  end
  local target = root .. "/.deploy.lua"

  vim.ui.select({ "Yes", "No" }, {
    prompt = "Initialize sync config at " .. target .. "?",
  }, function(choice)
    if choice == "Yes" then
      if vim.fn.filereadable(target) == 1 then
        vim.notify("[sync.nvim] .deploy.lua already exists.")
      else
        write_default_deploy_file(target)
      end
    end
  end)
end

-- User commands
vim.api.nvim_create_user_command("SyncNow", function()
  require("sync").sync_now()
end, {})

vim.api.nvim_create_user_command("SyncReloadConfig", function()
  require("sync").reload_config()
end, {})

vim.api.nvim_create_user_command("SyncDryRun", function()
  local original = M.options.dry_run
  M.options.dry_run = true

  vim.notify("[sync.nvim] 🚧 Running dry-run sync...")
  M.sync_now()

  vim.defer_fn(function()
    M.options.dry_run = original
  end, 1000)
end, {})


vim.api.nvim_create_user_command("SyncInit", sync_init, {})

return M

--[[ init.lua ends here. ]]
