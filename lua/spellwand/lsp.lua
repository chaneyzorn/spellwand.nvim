local M = {}

local ms = vim.lsp.protocol.Methods

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
  messages = {
    SpellBad = "Unknown word",
    SpellCap = "Capitalization error",
    SpellLocal = "Local word",
    SpellRare = "Rare word",
    SuggestPrefix = "did you mean",
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
    -- TODO: add more code actions
    -- TODO: support auto refresh after addToSpellfile
    ["spellwand.addToSpellfile"] = function(spellfile_index, word)
      vim.cmd(spellfile_index .. "spellgood " .. word)
    end,
    ["spellwand.fixTypo"] = function(_, index)
      vim.api.nvim_feedkeys(index .. "z=", "n", false)
    end,
  }
  return self
end

---Get server capabilities (Server-side)
---@return lsp.ServerCapabilities
function Client:_server_get_capabilities()
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

---Get spelling errors and convert to LSP diagnostics (Server-side)
---@param bufnr integer
---@return lsp.Diagnostic[]
function Client:_server_get_diagnostics(bufnr)
  if not self.config.cond(bufnr) then
    return {}
  end

  local spell_errors = require("spellwand.spelling").get_spelling_errors(bufnr, self.config)

  -- Apply user-defined preprocessing
  spell_errors = self.config.preprocess(bufnr, spell_errors)

  local diagnostics = {}
  for _, err in ipairs(spell_errors) do
    local severity = self.config.severity[err.type]
    if severity then
      local prefix = self.config.messages[err.type] or "Spelling issue"
      local message = string.format('%s: "%s"', prefix, err.word)
      if self.config.suggest_in_diagnostics and self.config.num_suggestions > 0 then
        local suggestions = vim.fn.spellsuggest(err.word, self.config.num_suggestions)
        if #suggestions > 0 then
          local suggest_prefix = self.config.messages.SuggestPrefix or "did you mean"
          message = string.format("%s (%s: %s)", message, suggest_prefix, table.concat(suggestions, ", "))
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

---Publish diagnostics for a buffer (Server-side)
---Uses dispatchers.notification to trigger Neovim's standard diagnostic flow
---@param bufnr integer
function Client:_server_publish_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local diagnostics = self:_server_get_diagnostics(bufnr)
  local uri = vim.uri_from_bufnr(bufnr)

  ---@diagnostic disable-next-line: param-type-mismatch
  self._dispatchers.notification(ms.textDocument_publishDiagnostics, {
    uri = uri,
    diagnostics = diagnostics,
  })
end

---Re-publish diagnostics for all attached buffers (Server-side)
function Client:_server_refresh_all_diagnostics()
  local clients = vim.lsp.get_clients({ name = "spellwand" })
  for _, client in ipairs(clients) do
    for bufnr, _ in pairs(client.attached_buffers or {}) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        self:_server_publish_diagnostics(bufnr)
      end
    end
  end
end

---Handler for textDocument/codeAction (Server-side)
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function Client:_server_handle_code_action(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local actions = {}
  local cword = vim.fn.expand("<cword>")

  if not cword or cword == "" then
    return actions
  end

  local spellbad_result = vim.fn.spellbadword(cword)
  if spellbad_result[1] == "" then
    return actions
  end

  local badword = spellbad_result[1]
  local spellfiles = get_spellfiles(bufnr)
  for idx, path in ipairs(spellfiles) do
    table.insert(actions, {
      title = string.format("Add '%s' to %s spellfile", badword, path),
      command = {
        title = string.format("Add '%s' to %s spellfile", badword, path),
        command = "spellwand.addToSpellfile",
        arguments = { idx, badword },
      },
    })
  end

  if #spellfiles == 0 then
    table.insert(actions, {
      title = string.format("Add '%s' to spellfile (no spellfile configured)", badword),
      command = {
        title = string.format("Add '%s' to spellfile", badword),
        command = "spellwand.addToSpellfile",
        arguments = { 1, badword },
      },
    })
  end

  local suggestions = vim.fn.spellsuggest(badword, self.config.num_suggestions)
  for idx, sug in ipairs(suggestions) do
    table.insert(actions, {
      title = string.format("Change '%s' to '%s'", badword, sug),
      command = {
        title = string.format("Change '%s' to '%s'", badword, sug),
        command = "spellwand.fixTypo",
        arguments = { 0, idx },
      },
    })
  end

  return actions
end

---Handler for workspace/executeCommand (Server-side)
---@param params lsp.ExecuteCommandParams
---@return lsp.ResponseError? error
function Client:_server_handle_execute_command(params)
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

---Request handlers table (Server-side)
---@type table<vim.lsp.protocol.Method.ClientToServer.Request, fun(self: spellwand.Client, params: table): any, lsp.ResponseError?>
Client._server_request_handlers = {
  [ms.initialize] = function(self, params)
    local init_settings = params.initializationOptions and params.initializationOptions.settings
    if init_settings and init_settings.spellwand then
      self.config = vim.tbl_deep_extend("force", default_config, init_settings.spellwand)
    end
    return {
      capabilities = self:_server_get_capabilities(),
      serverInfo = {
        name = "spellwand",
        version = "0.1.0",
      },
    },
      nil
  end,

  [ms.shutdown] = function(self, _params)
    self.config = vim.deepcopy(default_config)
    return nil, nil
  end,

  [ms.textDocument_codeAction] = function(self, params)
    return self:_server_handle_code_action(params), nil
  end,

  [ms.workspace_executeCommand] = function(self, params)
    return nil, self:_server_handle_execute_command(params)
  end,
}

---Handle LSP requests using table-driven dispatch (Client-side dispatcher)
---@param method vim.lsp.protocol.Method.ClientToServer.Request
---@param params table
---@return any result
---@return lsp.ResponseError? error
function Client:_client_handle_request(method, params)
  local handler = self._server_request_handlers[method]
  if handler then
    return handler(self, params)
  end
  return nil, { code = -32601, message = "Method not found: " .. method }
end

---Notification handlers table (Server-side)
---@type table<vim.lsp.protocol.Method.ClientToServer.Notification, fun(self: spellwand.Client, params: table)>
Client._server_notification_handlers = {
  [ms.initialized] = function(_self, _params) end,

  [ms.textDocument_didOpen] = function(self, params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    self:_server_publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didChange] = function(self, params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    self:_server_publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didClose] = function(_self, _params) end,

  [ms.workspace_didChangeConfiguration] = function(self, params)
    if params.settings and params.settings.spellwand then
      self.config = vim.tbl_deep_extend("force", self.config, params.settings.spellwand)
      self:_server_refresh_all_diagnostics()
    end
  end,
}

---Handle LSP notifications using table-driven dispatch (Client-side dispatcher)
---@param method vim.lsp.protocol.Method.ClientToServer.Notification
---@param params table
function Client:_client_handle_notification(method, params)
  local handler = self._server_notification_handlers[method]
  if handler then
    handler(self, params)
  end
end

---Create the RPC public client interface (Client-side)
---@return vim.lsp.rpc.PublicClient
function Client:_create_rpc_interface()
  local client = self

  return {
    request = function(method, params, callback, _)
      local result, err = client:_client_handle_request(method, params)
      if callback then
        callback(err, result)
      end
      return true, 1
    end,

    notify = function(method, params)
      client:_client_handle_notification(method, params)
      return true
    end,

    is_closing = function()
      -- TODO: test stop_client
      return false
    end,

    terminate = function() end,
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
  local conf = config and config.settings and config.settings.spellwand
  ---@cast conf spellwand.LspConfig
  local client = Client.new(dispatchers, conf)
  return client:_create_rpc_interface()
end

return M
