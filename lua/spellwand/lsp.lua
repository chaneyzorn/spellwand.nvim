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
    SpellBad = 'Unknown word: "%s"',
    SpellCap = 'Capitalization error: "%s"',
    SpellLocal = 'Local word: "%s"',
    SpellRare = 'Rare word: "%s"',
    SuggestPrefix = "did you mean: %s",
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
---@field private _closing boolean Whether the client is closing
---@field private _augroup integer? Augroup ID for InsertLeave autocmd
---@field private _pending_refresh table<integer, boolean> Buffers pending diagnostic refresh after InsertLeave
local Client = {}
Client.__index = Client

---Create a new spellwand Client instance
---@param dispatchers vim.lsp.rpc.Dispatchers Dispatchers provided by Neovim
---@param config spellwand.LspConfig? Initial configuration
---@return spellwand.Client
function Client.new(dispatchers, config)
  local self = setmetatable({}, Client)
  self._dispatchers = dispatchers
  self._closing = false
  self.config = vim.deepcopy(config or default_config)
  self._commands = {
    ["spellwand.addToSpellfile"] = function(bufnr, spellfile_index, word)
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd(spellfile_index .. "spellgood " .. word)
      end)
      self:_server_refresh_all_diagnostics()
    end,
    ["spellwand.addAllToSpellfile"] = function(bufnr, spellfile_index)
      local spell_errors = self:_server_get_spell_words(bufnr)
      local seen = {}
      local words_to_add = {}
      for _, err in ipairs(spell_errors) do
        if not seen[err.word] then
          seen[err.word] = true
          table.insert(words_to_add, err.word)
        end
      end
      vim.api.nvim_buf_call(bufnr, function()
        for _, word in ipairs(words_to_add) do
          vim.cmd(spellfile_index .. "spellgood " .. word)
        end
      end)
      self:_server_refresh_all_diagnostics()
    end,
    ["spellwand.fixTypo"] = function(bufnr, index)
      vim.api.nvim_buf_call(bufnr, function()
        vim.api.nvim_feedkeys(index .. "z=", "n", false)
      end)
    end,
  }
  self._pending_refresh = {}
  return self
end

---Get server capabilities (Server-side)
---@return lsp.ServerCapabilities
function Client:_server_get_capabilities()
  return {
    textDocumentSync = {
      openClose = true,
      change = vim.lsp.protocol.TextDocumentSyncKind.Incremental,
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

---Get processed spell errors for a buffer (Server-side)
---@param bufnr integer
---@return spellwand.SpellingError[]
function Client:_server_get_spell_words(bufnr)
  local spell_errors = require("spellwand.spelling").get_spelling_errors(bufnr, self.config)
  spell_errors = self.config.preprocess(bufnr, spell_errors)
  return spell_errors
end

---Format diagnostic message for a spelling error (Server-side)
---@param word string The misspelled word
---@param err_type string Error type (SpellBad, SpellCap, etc.)
---@param suggestions string[]? Optional suggestions list
---@return string formatted message
function Client:_server_format_message(word, err_type, suggestions)
  local messages = self.config.messages
  if type(messages) == "function" then
    return messages(word, err_type, suggestions)
  end
  -- Backward compatibility: string templates
  local template = messages[err_type] or 'Spelling issue: "%s"'
  local message = string.format(template, word)
  if suggestions and #suggestions > 0 then
    local suggest_template = messages.SuggestPrefix or "did you mean: %s"
    message = string.format("%s (%s)", message, string.format(suggest_template, table.concat(suggestions, ", ")))
  end
  return message
end

---Get diagnostics for a buffer (Server-side)
---@param bufnr integer
---@return lsp.Diagnostic[]
function Client:_server_get_diagnostics(bufnr)
  if not self.config.cond(bufnr) then
    return {}
  end

  local spell_errors = self:_server_get_spell_words(bufnr)

  local diagnostics = {}
  for _, err in ipairs(spell_errors) do
    local severity = self.config.severity[err.type]
    if severity then
      local suggestions
      if self.config.suggest_in_diagnostics and self.config.num_suggestions > 0 then
        vim.api.nvim_buf_call(bufnr, function()
          suggestions = vim.fn.spellsuggest(err.word, self.config.num_suggestions)
        end)
      end
      local message = self:_server_format_message(err.word, err.type, suggestions)

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
---@param diagnostics lsp.Diagnostic[]? Optional diagnostics to publish (defaults to computed)
function Client:_server_publish_diagnostics(bufnr, diagnostics)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  diagnostics = diagnostics or self:_server_get_diagnostics(bufnr)
  local uri = vim.uri_from_bufnr(bufnr)

  ---@diagnostic disable-next-line: param-type-mismatch
  self._dispatchers.notification(ms.textDocument_publishDiagnostics, {
    uri = uri,
    diagnostics = diagnostics,
  })
end

---Re-publish diagnostics for all attached buffers (Server-side)
function Client:_server_refresh_all_diagnostics()
  local seen = {}
  local clients = vim.lsp.get_clients({ name = "spellwand" })
  for _, client in ipairs(clients) do
    for bufnr, _ in pairs(client.attached_buffers or {}) do
      if not seen[bufnr] then
        seen[bufnr] = true
        self:_server_publish_diagnostics(bufnr)
      end
    end
  end
end

---Setup augroup for InsertLeave refresh (Server-side)
function Client:_server_setup_augroup()
  self._augroup = vim.api.nvim_create_augroup("spellwand_" .. tostring(self), { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = self._augroup,
    callback = function()
      self:_server_flush_pending_refresh()
    end,
  })
end

---Flush pending diagnostics after leaving insert mode (Server-side)
function Client:_server_flush_pending_refresh()
  for bufnr, _ in pairs(self._pending_refresh) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      self:_server_publish_diagnostics(bufnr)
    end
  end
  self._pending_refresh = {}
end

---Terminate the server and trigger the on_exit callback (Server-side).
---
---External LSP servers rely on vim.system to trigger on_exit when the process
---exits. For in-process servers, we must manually trigger it:
---  - Normal exit: via the 'exit' notification handler
---  - Force exit: via the terminate() RPC interface
function Client:_server_terminate()
  if self._closing then
    return
  end
  self._closing = true
  if self._augroup then
    vim.api.nvim_del_augroup_by_id(self._augroup)
    self._augroup = nil
  end
  self._pending_refresh = {}
  self._dispatchers.on_exit(0, 0)
end

---Handler for textDocument/codeAction (Server-side)
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function Client:_server_handle_code_action(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local spellfiles = get_spellfiles(bufnr)
  local actions = {}

  -- Check if cursor is on a misspelled word
  local cword = vim.fn.expand("<cword>")
  local badword = nil
  if cword and cword ~= "" then
    local spellbad_result
    vim.api.nvim_buf_call(bufnr, function()
      spellbad_result = vim.fn.spellbadword(cword)
    end)
    if spellbad_result and spellbad_result[1] ~= "" then
      badword = spellbad_result[1]
    end
  end

  -- Add cursor-specific actions only if cursor is on a misspelled word
  if badword then
    for idx, path in ipairs(spellfiles) do
      table.insert(actions, {
        title = string.format("Add '%s' to %s spellfile", badword, path),
        command = {
          title = string.format("Add '%s' to %s spellfile", badword, path),
          command = "spellwand.addToSpellfile",
          arguments = { bufnr, idx, badword },
        },
      })
    end

    if #spellfiles == 0 then
      table.insert(actions, {
        title = string.format("Add '%s' to spellfile (no spellfile configured)", badword),
        command = {
          title = string.format("Add '%s' to spellfile", badword),
          command = "spellwand.addToSpellfile",
          arguments = { bufnr, 1, badword },
        },
      })
    end

    local suggestions
    vim.api.nvim_buf_call(bufnr, function()
      suggestions = vim.fn.spellsuggest(badword, self.config.num_suggestions)
    end)
    for idx, sug in ipairs(suggestions or {}) do
      table.insert(actions, {
        title = string.format("Change '%s' to '%s'", badword, sug),
        command = {
          title = string.format("Change '%s' to '%s'", badword, sug),
          command = "spellwand.fixTypo",
          arguments = { bufnr, idx },
        },
      })
    end
  end

  -- Use existing diagnostics to avoid recomputing spell errors
  local diagnostics = vim.diagnostic.get(bufnr, { source = "spellwand" })
  local has_diagnostics = #diagnostics > 0

  -- Add "Add all" actions if there are any diagnostics in the buffer
  if has_diagnostics then
    for idx, path in ipairs(spellfiles) do
      table.insert(actions, {
        title = string.format("Add all misspelled words to %s", path),
        command = {
          title = string.format("Add all to %s", path),
          command = "spellwand.addAllToSpellfile",
          arguments = { bufnr, idx },
        },
      })
    end

    if #spellfiles == 0 then
      table.insert(actions, {
        title = "Add all misspelled words to spellfile (no spellfile configured)",
        command = {
          title = "Add all to spellfile",
          command = "spellwand.addAllToSpellfile",
          arguments = { bufnr, 1 },
        },
      })
    end
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
  [ms.initialized] = function(self, _params)
    self:_server_setup_augroup()
  end,

  [ms.textDocument_didOpen] = function(self, params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    self:_server_publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didChange] = function(self, params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^i") or mode:match("^R") then
      self._pending_refresh[bufnr] = true
      return
    end
    self:_server_publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didSave] = function(_self, _params)
    -- noop, refer to https://github.com/tekumara/typos-lsp/blob/main/crates/typos-lsp/src/lsp.rs
  end,

  [ms.textDocument_didClose] = function(self, params)
    -- clear stale diagnostics, refer to https://github.com/tekumara/typos-lsp/blob/main/crates/typos-lsp/src/lsp.rs
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    self._pending_refresh[bufnr] = nil
    self:_server_publish_diagnostics(bufnr, {})
  end,

  [ms.workspace_didChangeConfiguration] = function(self, params)
    if params.settings and params.settings.spellwand then
      self.config = vim.tbl_deep_extend("force", self.config, params.settings.spellwand)
      self:_server_refresh_all_diagnostics()
    end
  end,

  [ms.exit] = function(self, _params)
    -- Called after successful shutdown response during normal client stop
    self:_server_terminate()
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
  return {
    request = function(method, params, callback, _)
      local result, err = self:_client_handle_request(method, params)
      if callback then
        callback(err, result)
      end
      return true, 1
    end,

    notify = function(method, params)
      self:_client_handle_notification(method, params)
      return true
    end,

    is_closing = function()
      return self._closing
    end,

    -- Called when force-stop is requested or shutdown request fails
    terminate = function()
      self:_server_terminate()
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
  local conf = config and config.settings and config.settings.spellwand
  ---@cast conf spellwand.LspConfig
  local client = Client.new(dispatchers, conf)
  return client:_create_rpc_interface()
end

return M
