local M = {}

local ms = vim.lsp.protocol.Methods
local log = require("vim.lsp.log")

---Default configuration values
---@type spellwand.LspConfig
local default_config = {
  cond = function(_bufnr)
    return true
  end,
  strategies = { "treesitter", "full" },
  max_errors = 999,
  preprocess = function(_bufnr, spell_errors)
    return spell_errors
  end,
  severity = {
    SpellBad = vim.diagnostic.severity.WARN,
    SpellCap = vim.diagnostic.severity.HINT,
    SpellLocal = vim.diagnostic.severity.HINT,
    SpellRare = vim.diagnostic.severity.INFO,
  },
  suggest_in_diagnostics = false,
  num_suggestions = 3,
}

---Parse spellfile option to get list of spellfile paths
---@param bufnr integer
---@return string[] List of spellfile paths (may be empty)
local function get_spellfiles(bufnr)
  local spellfile = vim.bo[bufnr].spellfile
  if spellfile == "" then
    return {}
  end
  return vim.split(spellfile, ",", { plain = true })
end

---Get spellfile display name (basename or "global"/"local" alias)
---@param path string
---@param index integer
---@return string
local function get_spellfile_display_name(path, index)
  if path:match("/.spell/") then
    return "local"
  end
  if index == 1 then
    return "global"
  end
  return vim.fn.fnamemodify(path, ":t:r")
end

---@class spellwand.Client
---@field private _dispatchers vim.lsp.rpc.Dispatchers Dispatchers for server→client communication
---@field config spellwand.LspConfig Client-specific configuration
---@field private _commands table<string, fun(...): any> Built-in commands for code actions
local Client = {}
Client.__index = Client

---Create a new spellwand Client instance
---@param dispatchers vim.lsp.rpc.Dispatchers Dispatchers provided by Neovim
---@param config spellwand.LspConfig? Initial configuration
---@return spellwand.Client
function Client.new(dispatchers, config)
  local self = setmetatable({}, Client)
  self._dispatchers = dispatchers
  self.config = vim.deepcopy(config or default_config)
  self._commands = {
    ["spellwand.addToSpellfile"] = function(spellfile_index, word)
      vim.cmd(spellfile_index .. "spellgood " .. word)
    end,
    ["spellwand.fixTypo"] = function(_, index)
      vim.api.nvim_feedkeys(index .. "z=", "n", false)
    end,
  }
  return self
end

---Get server capabilities
---@return lsp.ServerCapabilities
function Client:_get_capabilities()
  return {
    textDocumentSync = {
      openClose = true,
      change = vim.lsp.protocol.TextDocumentSyncKind.None,
    },
    codeActionProvider = true,
    executeCommandProvider = {
      commands = vim.tbl_keys(self._commands),
    },
    workspace = {
      workspaceFolders = true,
      configuration = true,
    },
  }
end

---Get spelling errors and convert to LSP diagnostics
---@param bufnr integer
---@return lsp.Diagnostic[]
function Client:_get_diagnostics(bufnr)
  log.debug("[spellwand.client.get_diagnostics] bufnr=" .. bufnr)

  if not self.config.cond(bufnr) then
    log.debug("[spellwand.client.get_diagnostics] condition not met, skipping")
    return {}
  end

  local spell_errors = require("spellwand.spelling").get_spelling_errors(bufnr, self.config)

  -- Apply user-defined preprocessing
  spell_errors = self.config.preprocess(bufnr, spell_errors)

  local diagnostics = {}
  for _, err in ipairs(spell_errors) do
    local severity = self.config.severity[err.type]
    if severity then
      local message = err.word
      if self.config.suggest_in_diagnostics and self.config.num_suggestions > 0 then
        local suggestions = vim.fn.spellsuggest(err.word, self.config.num_suggestions)
        if #suggestions > 0 then
          message = message .. " (suggestions: " .. table.concat(suggestions, ", ") .. ")"
        end
      end

      table.insert(diagnostics, {
        range = {
          start = { line = err.lnum - 1, character = err.col - 1 },
          ["end"] = { line = err.lnum - 1, character = err.col - 1 + #err.word },
        },
        message = message,
        severity = severity,
        source = "spellwand",
        code = err.type,
      })
    end
  end

  return diagnostics
end

---Publish diagnostics for a buffer
---Uses dispatchers.notification to trigger Neovim's standard diagnostic flow
---@param bufnr integer
function Client:_publish_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local diagnostics = self:_get_diagnostics(bufnr)
  local uri = vim.uri_from_bufnr(bufnr)

  log.debug("[spellwand.client.publish] " .. uri .. " with " .. #diagnostics .. " diagnostics")

  ---@diagnostic disable-next-line: param-type-mismatch
  self._dispatchers.notification(ms.textDocument_publishDiagnostics, {
    uri = uri,
    diagnostics = diagnostics,
  })
end

---Re-publish diagnostics for all attached buffers
function Client:_refresh_all_diagnostics()
  local clients = vim.lsp.get_clients({ name = "spellwand" })
  for _, client in ipairs(clients) do
    for bufnr, _ in pairs(client.attached_buffers or {}) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        self:_publish_diagnostics(bufnr)
      end
    end
  end
end

---Handler for textDocument/codeAction
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function Client:_handle_code_action(params)
  log.debug("[spellwand.client.codeAction] called")
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local actions = {}
  local word = vim.fn.expand("<cword>")

  if not word or word == "" then
    return actions
  end

  local badword = vim.fn.spellbadword(word)
  if badword[1] == "" then
    return actions
  end

  local spellfiles = get_spellfiles(bufnr)
  for idx, path in ipairs(spellfiles) do
    local display_name = get_spellfile_display_name(path, idx)
    table.insert(actions, {
      title = string.format("Add '%s' to %s spellfile", word, display_name),
      command = {
        title = string.format("Add '%s' to %s spellfile", word, display_name),
        command = "spellwand.addToSpellfile",
        arguments = { idx, word },
      },
    })
  end

  if #spellfiles == 0 then
    table.insert(actions, {
      title = string.format("Add '%s' to spellfile (no spellfile configured)", word),
      command = {
        title = string.format("Add '%s' to spellfile", word),
        command = "spellwand.addToSpellfile",
        arguments = { 1, word },
      },
    })
  end

  local suggestions = vim.fn.spellsuggest(word, self.config.num_suggestions)
  for idx, sug in ipairs(suggestions) do
    table.insert(actions, {
      title = string.format("Change '%s' to '%s'", word, sug),
      command = {
        title = string.format("Change '%s' to '%s'", word, sug),
        command = "spellwand.fixTypo",
        arguments = { 0, idx },
      },
    })
  end

  return actions
end

---Handler for workspace/executeCommand
---@param params lsp.ExecuteCommandParams
---@return lsp.ResponseError? error
function Client:_handle_execute_command(params)
  log.debug("[spellwand.client.executeCommand] called: " .. params.command)
  local cmd_fn = self._commands[params.command]
  if not cmd_fn then
    return {
      code = -32601,
      message = "Unknown command: " .. params.command,
    }
  end

  local ok, result = pcall(cmd_fn, unpack(params.arguments))
  if not ok then
    return {
      code = -32603,
      message = tostring(result),
    }
  end

  return nil
end

---Request handlers table
---@type table<vim.lsp.protocol.Method.ClientToServer.Request, fun(self: spellwand.Client, params: table): any, lsp.ResponseError?>
Client._request_handlers = {
  [ms.initialize] = function(self, params)
    log.debug("[spellwand.client.initialize] called")
    local init_settings = params.initializationOptions and params.initializationOptions.settings
    if init_settings and init_settings.spellwand then
      self.config = vim.tbl_deep_extend("force", default_config, init_settings.spellwand)
    end
    return {
      capabilities = self:_get_capabilities(),
      serverInfo = {
        name = "spellwand",
        version = "0.1.0",
      },
    },
    nil
  end,

  [ms.shutdown] = function(self, _params)
    log.debug("[spellwand.client.shutdown] called")
    self.config = vim.deepcopy(default_config)
    return nil, nil
  end,

  [ms.textDocument_codeAction] = function(self, params)
    return self:_handle_code_action(params), nil
  end,

  [ms.workspace_executeCommand] = function(self, params)
    return nil, self:_handle_execute_command(params)
  end,
}

---Handle LSP requests using table-driven dispatch
---@param method vim.lsp.protocol.Method.ClientToServer.Request
---@param params table
---@return any result
---@return lsp.ResponseError? error
function Client:_handle_request(method, params)
  local handler = self._request_handlers[method]
  if handler then
    return handler(self, params)
  end
  return nil, { code = -32601, message = "Method not found: " .. method }
end

---Notification handlers table
---@type table<vim.lsp.protocol.Method.ClientToServer.Notification, fun(self: spellwand.Client, params: table)>
Client._notification_handlers = {
  [ms.initialized] = function(_self, _params)
    log.debug("[spellwand.client.initialized] called")
  end,

  [ms.textDocument_didOpen] = function(self, params)
    log.debug("[spellwand.client.didOpen] uri=" .. params.textDocument.uri)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    self:_publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didChange] = function(self, params)
    log.debug("[spellwand.client.didChange] uri=" .. params.textDocument.uri)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    self:_publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didClose] = function(_self, _params)
    log.debug("[spellwand.client.didClose] called")
  end,

  [ms.workspace_didChangeConfiguration] = function(self, params)
    log.debug("[spellwand.client.didChangeConfiguration] called")
    if params.settings and params.settings.spellwand then
      self.config = vim.tbl_deep_extend("force", self.config, params.settings.spellwand)
      self:_refresh_all_diagnostics()
    end
  end,
}

---Handle LSP notifications using table-driven dispatch
---@param method vim.lsp.protocol.Method.ClientToServer.Notification
---@param params table
function Client:_handle_notification(method, params)
  local handler = self._notification_handlers[method]
  if handler then
    handler(self, params)
  end
end

---Create the RPC public client interface
---@return vim.lsp.rpc.PublicClient
function Client:_create_rpc_interface()
  local client = self

  return {
    request = function(method, params, callback, _)
      log.debug("[spellwand.rpc.request] " .. method)
      local result, err = client:_handle_request(method, params)
      if callback then
        callback(err, result)
      end
      return true, 1
    end,

    notify = function(method, params)
      log.debug("[spellwand.rpc.notify] " .. method)
      client:_handle_notification(method, params)
      return true
    end,

    is_closing = function()
      return false
    end,

    terminate = function()
      log.debug("[spellwand.rpc.terminate] called")
    end,
  }
end

---Default configuration (module-level constant)
M.default_config = vim.deepcopy(default_config)

---Create in-process LSP RPC interface
---Factory function that creates a new Client instance
---@param dispatchers vim.lsp.rpc.Dispatchers Dispatchers provided by Neovim
---@param config vim.lsp.ClientConfig The resolved client configuration
---@return vim.lsp.rpc.PublicClient RPC client interface
function M.create_rpc(dispatchers, config)
  log.debug("[spellwand.create_rpc] called")
  local conf = config and config.settings and config.settings.spellwand
  ---@cast conf spellwand.LspConfig
  local client = Client.new(dispatchers, conf)
  return client:_create_rpc_interface()
end

return M
