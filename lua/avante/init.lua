local api = vim.api

local Utils = require("avante.utils")
local Sidebar = require("avante.sidebar")
local Selection = require("avante.selection")
local Config = require("avante.config")
local Diff = require("avante.diff")

---@class Avante
local M = {
  ---@type avante.Sidebar[] we use this to track chat command across tabs
  sidebars = {},
  ---@type avante.Selection[]
  selections = {},
  ---@type {sidebar?: avante.Sidebar, selection?: avante.Selection}
  current = { sidebar = nil, selection = nil },
}

M.did_setup = false

local H = {}

H.commands = function()
  ---@param n string
  ---@param c vim.api.keyset.user_command.callback
  ---@param o vim.api.keyset.user_command.opts
  local cmd = function(n, c, o)
    o = vim.tbl_extend("force", { nargs = 0 }, o or {})
    api.nvim_create_user_command("Avante" .. n, c, o)
  end

  cmd("Ask", function(opts)
    require("avante.api").ask(vim.trim(opts.args))
  end, { desc = "avante: ask AI for code suggestions", nargs = "*" })
  cmd("Toggle", function()
    M.toggle()
  end, { desc = "avante: toggle AI panel" })
  cmd("Edit", function(opts)
    require("avante.api").edit(vim.trim(opts.args))
  end, { desc = "avante: edit selected block", nargs = "*" })
  cmd("Refresh", function()
    require("avante.api").refresh()
  end, { desc = "avante: refresh windows" })
  cmd("Build", function()
    M.build()
  end, { desc = "avante: build dependencies" })
  cmd("SwitchProvider", function(opts)
    require("avante.api").switch_provider(vim.trim(opts.args or ""))
  end, {
    nargs = 1,
    desc = "avante: switch provider",
    complete = function(_, line, _)
      local prefix = line:match("AvanteSwitchProvider%s*(.*)$") or ""
      ---@param key string
      return vim.tbl_filter(function(key)
        return key:find(prefix, 1, true) == 1
      end, Config.providers)
    end,
  })
end

H.keymaps = function()
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteAsk)", function()
    require("avante.api").ask()
  end, { noremap = true })
  vim.keymap.set("v", "<Plug>(AvanteEdit)", function()
    require("avante.api").edit()
  end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteRefresh)", function()
    require("avante.api").refresh()
  end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteToggle)", function()
    M.toggle()
  end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteToggleDebug)", function()
    M.toggle.debug()
  end)
  vim.keymap.set("n", "<Plug>(AvanteToggleHint)", function()
    M.toggle.hint()
  end)

  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictOurs)", function()
    Diff.choose("ours")
  end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictBoth)", function()
    Diff.choose("both")
  end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictTheirs)", function()
    Diff.choose("theirs")
  end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictAllTheirs)", function()
    Diff.choose("all_theirs")
  end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictCursor)", function()
    Diff.choose("cursor")
  end)
  vim.keymap.set("n", "<Plug>(AvanteConflictNextConflict)", function()
    Diff.find_next("ours")
  end)
  vim.keymap.set("n", "<Plug>(AvanteConflictPrevConflict)", function()
    Diff.find_prev("ours")
  end)

  if Config.behaviour.auto_set_keymaps then
    Utils.safe_keymap_set({ "n", "v" }, Config.mappings.ask, function()
      require("avante.api").ask()
    end, { desc = "avante: ask" })
    Utils.safe_keymap_set("v", Config.mappings.edit, function()
      require("avante.api").edit()
    end, { desc = "avante: edit" })
    Utils.safe_keymap_set("n", Config.mappings.refresh, function()
      require("avante.api").refresh()
    end, { desc = "avante: refresh" })
    Utils.safe_keymap_set("n", Config.mappings.toggle.default, function()
      M.toggle()
    end, { desc = "avante: toggle" })
    Utils.safe_keymap_set("n", Config.mappings.toggle.debug, function()
      M.toggle.debug()
    end, { desc = "avante: toggle debug" })
    Utils.safe_keymap_set("n", Config.mappings.toggle.hint, function()
      M.toggle.hint()
    end, { desc = "avante: toggle hint" })
  end
end

---@class ApiCaller
---@operator call(...): any

H.api = function(fun)
  return setmetatable({ api = true }, {
    __call = function(...)
      return fun(...)
    end,
  }) --[[@as ApiCaller]]
end

H.signs = function()
  vim.fn.sign_define("AvanteInputPromptSign", { text = Config.windows.input.prefix })
end

H.augroup = api.nvim_create_augroup("avante_autocmds", { clear = true })

H.autocmds = function()
  local ok, LazyConfig = pcall(require, "lazy.core.config")

  if ok then
    local name = "avante.nvim"
    local load_path = function()
      require("avante_lib").load()
    end

    if LazyConfig.plugins[name] and LazyConfig.plugins[name]._.loaded then
      vim.schedule(load_path)
    else
      api.nvim_create_autocmd("User", {
        pattern = "LazyLoad",
        callback = function(event)
          if event.data == name then
            load_path()
            return true
          end
        end,
      })
    end

    api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      callback = load_path,
    })
  end

  api.nvim_create_autocmd("TabEnter", {
    group = H.augroup,
    pattern = "*",
    once = true,
    callback = function(ev)
      local tab = tonumber(ev.file)
      M._init(tab or api.nvim_get_current_tabpage())
      if Config.hints.enabled and not M.current.selection.did_setup then
        M.current.selection:setup_autocmds()
      end
    end,
  })

  api.nvim_create_autocmd("VimResized", {
    group = H.augroup,
    callback = function()
      local sidebar, _ = M.get()
      if not sidebar then
        return
      end
      if not sidebar:is_open() then
        return
      end
      sidebar:resize()
    end,
  })

  api.nvim_create_autocmd("TabClosed", {
    group = H.augroup,
    pattern = "*",
    callback = function(ev)
      local tab = tonumber(ev.file)
      local s = M.sidebars[tab]
      local sl = M.selections[tab]
      if s then
        s:reset()
      end
      if sl then
        sl:delete_autocmds()
      end
      if tab ~= nil then
        M.sidebars[tab] = nil
      end
    end,
  })

  vim.schedule(function()
    M._init(api.nvim_get_current_tabpage())
    if Config.hints.enabled then
      M.current.selection:setup_autocmds()
    end
  end)

  api.nvim_create_autocmd("ColorSchemePre", {
    group = H.augroup,
    callback = function()
      require("avante.highlights").setup()
    end,
  })

  -- automatically setup Avante filetype to markdown
  vim.treesitter.language.register("markdown", "Avante")
end

---@param current boolean? false to disable setting current, otherwise use this to track across tabs.
---@return avante.Sidebar, avante.Selection
function M.get(current)
  local tab = api.nvim_get_current_tabpage()
  local sidebar = M.sidebars[tab]
  local selection = M.selections[tab]
  if current ~= false then
    M.current.sidebar = sidebar
    M.current.selection = selection
  end
  return sidebar, selection
end

---@param id integer
function M._init(id)
  local sidebar = M.sidebars[id]
  local selection = M.selections[id]

  if not sidebar then
    sidebar = Sidebar:new(id)
    M.sidebars[id] = sidebar
  end
  if not selection then
    selection = Selection:new(id)
    M.selections[id] = selection
  end
  M.current = { sidebar = sidebar, selection = selection }
  return M
end

M.toggle = { api = true }

M.toggle.debug = H.api(Utils.toggle_wrap({
  name = "debug",
  get = function()
    return Config.debug
  end,
  set = function(state)
    Config.override({ debug = state })
  end,
}))

M.toggle.hint = H.api(Utils.toggle_wrap({
  name = "hint",
  get = function()
    return Config.hints.enabled
  end,
  set = function(state)
    Config.override({ hints = { enabled = state } })
  end,
}))

setmetatable(M.toggle, {
  __index = M.toggle,
  __call = function()
    local sidebar, _ = M.get()
    if not sidebar then
      M._init(api.nvim_get_current_tabpage())
      M.current.sidebar:open()
      return true
    end

    return sidebar:toggle()
  end,
})

---@param path string
local function to_windows_path(path)
  local winpath = path:gsub("/", "\\")

  if winpath:match("^%a:") then
    winpath = winpath:sub(1, 2):upper() .. winpath:sub(3)
  end

  winpath = winpath:gsub("\\$", "")

  return winpath
end

M.build = H.api(function()
  local dirname = Utils.trim(string.sub(debug.getinfo(1).source, 2, #"/init.lua" * -1), { suffix = "/" })
  local git_root = vim.fs.find(".git", { path = dirname, upward = true })[1]
  local build_directory = git_root and vim.fn.fnamemodify(git_root, ":h") or (dirname .. "/../../")

  if not vim.fn.executable("cargo") then
    error("Building avante.nvim requires cargo to be installed.", 2)
  end

  ---@type string[]
  local cmd
  local os_name = Utils.get_os_name()

  if vim.tbl_contains({ "linux", "darwin" }, os_name) then
    cmd = { "sh", "-c", ("make -C %s"):format(build_directory) }
  elseif os_name == "windows" then
    build_directory = to_windows_path(build_directory)
    cmd = {
      "powershell",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      ("%s\\Build.ps1"):format(build_directory),
      "-WorkingDirectory",
      build_directory,
    }
  else
    error("Unsupported operating system: " .. os_name, 2)
  end

  local job = vim.system(cmd, { text = true }):wait()

  return vim.tbl_contains({ 0 }, job.code) and true or false
end)

---@param opts? avante.Config
function M.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    vim.api.nvim_echo({
      { "Avante requires at least nvim-0.10", "ErrorMsg" },
      { "Please upgrade your neovim version", "WarningMsg" },
      { "Press any key to exit", "ErrorMsg" },
    }, true, {})
    vim.fn.getchar()
    vim.cmd([[quit]])
  end

  ---PERF: we can still allow running require("avante").setup() multiple times to override config if users wish to
  ---but most of the other functionality will only be called once from lazy.nvim
  Config.setup(opts)

  if M.did_setup then
    return
  end

  require("avante.path").setup()
  require("avante.highlights").setup()
  require("avante.diff").setup()
  require("avante.providers").setup()
  require("avante.clipboard").setup()

  -- setup helpers
  H.autocmds()
  H.commands()
  H.keymaps()
  H.signs()

  M.did_setup = true
end

return M
