local M = {}

local ms = vim.lsp.protocol.Methods
local log = require("vim.lsp.log")

---Dispatchers for sending messages to client (set by create_rpc)
---@type vim.lsp.rpc.Dispatchers|nil
local dispatchers = nil

---Default configuration values (spellwand-specific settings only)
---@type spellwand.Config
M.default_config = {
  max_file_size = 10000,
  strategy = "treesitter",
  severity = {
    SpellBad = vim.diagnostic.severity.WARN,
    SpellCap = vim.diagnostic.severity.HINT,
    SpellLocal = vim.diagnostic.severity.HINT,
    SpellRare = vim.diagnostic.severity.INFO,
  },
  suggest_in_diagnostics = false,
  num_suggestions = 3,
}

---Global server configuration (single instance, all clients share)
---@type spellwand.Config
M.config = vim.deepcopy(M.default_config)

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

---Built-in commands for code actions
---@type table<string, fun(spellfile_index: integer, ...): any>
local commands = {
  ["spellwand.addToSpellfile"] = function(spellfile_index, word)
    vim.cmd(spellfile_index .. "spellgood " .. word)
  end,

  ["spellwand.fix"] = function(_, index)
    vim.api.nvim_feedkeys(index .. "z=", "n", false)
  end,
}

---Get LSP server capabilities
---@return lsp.ServerCapabilities
local function get_capabilities()
  return {
    textDocumentSync = {
      openClose = true,
      change = vim.lsp.protocol.TextDocumentSyncKind.None, -- We read buffer directly
    },
    codeActionProvider = true,
    executeCommandProvider = {
      commands = vim.tbl_keys(commands),
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
local function get_diagnostics(bufnr)
  log.debug("[spellwand.diagnostics.get] called for bufnr=" .. bufnr)

  if M.config.max_file_size then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    log.debug("[spellwand.diagnostics.get] line_count=" .. line_count .. ", max_file_size=" .. tostring(M.config.max_file_size))
    if line_count > M.config.max_file_size then
      log.debug("[spellwand.diagnostics.get] File too large, skipping spell check")
      return {}
    end
  end
  -- Log spell status for debugging (do not block)
  log.debug("[spellwand.diagnostics.get] vim.wo.spell=" .. tostring(vim.wo.spell))

  local errors = require("spellwand.spelling").get_spelling_errors(bufnr, M.config)
  log.debug("[spellwand.diagnostics.get] Found " .. #errors .. " spelling errors")

  local diagnostics = {}
  for _, err in ipairs(errors) do
    local severity = M.config.severity[err.type]
    if severity then
      local message = err.word
      if M.config.suggest_in_diagnostics and M.config.num_suggestions > 0 then
        local suggestions = vim.fn.spellsuggest(err.word, M.config.num_suggestions)
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

---Publish diagnostics for a buffer (server -> client)
---Uses dispatchers to send notification to the LSP client
---@param bufnr integer
local function publish_diagnostics(bufnr)
  log.debug("[spellwand.diagnostics.publish] called for bufnr=" .. bufnr)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    log.debug("[spellwand.diagnostics.publish] Buffer " .. bufnr .. " is not valid")
    return
  end

  if not dispatchers then
    log.error("[spellwand.diagnostics.publish] Dispatchers not available")
    return
  end

  local diagnostics = get_diagnostics(bufnr)
  log.debug("[spellwand.diagnostics.publish] Publishing " .. #diagnostics .. " diagnostics")

  local uri = vim.uri_from_bufnr(bufnr)
  log.debug("[spellwand.diagnostics.publish] payload=" .. vim.inspect(diagnostics))

  dispatchers.notification(ms.textDocument_publishDiagnostics, {
    uri = uri,
    diagnostics = diagnostics,
  })
  log.debug("[spellwand.diagnostics.publish] success")
end

---LSP method handlers
---Signature matches Neovim's handler format: (err, result, ctx, config)
M.handlers = {
  [ms.initialize] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.initialize] called")

    -- Apply settings from initializationOptions
    local init_settings = params.initializationOptions and params.initializationOptions.settings
    if init_settings and init_settings.spellwand then
      M.config = vim.tbl_deep_extend("force", M.default_config, init_settings.spellwand)
      log.debug("[spellwand.handler.initialize] Applied settings: " .. vim.inspect(M.config))
    end

    log.debug("[spellwand.handler.initialize] Server initialized with config: " .. vim.inspect(M.config))

    return {
      capabilities = get_capabilities(),
      serverInfo = {
        name = "spellwand",
        version = "0.1.0",
      },
    }
  end,

  [ms.initialized] = function(_, _, _, _)
    log.debug("[spellwand.handler.initialized] called")
    -- Server is initialized, nothing to do
  end,

  [ms.shutdown] = function(_, _, _, _)
    log.debug("[spellwand.handler.shutdown] called")
    -- Reset to defaults on shutdown
    M.config = vim.deepcopy(M.default_config)
    return nil
  end,

  [ms.textDocument_didOpen] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.textDocument.didOpen] called for uri=" .. params.textDocument.uri)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didChange] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.textDocument.didChange] called for uri=" .. params.textDocument.uri)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    publish_diagnostics(bufnr)
  end,

  [ms.textDocument_didClose] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.textDocument.didClose] called")
    -- Client automatically clears diagnostics on buffer close
  end,

  [ms.textDocument_codeAction] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.textDocument.codeAction] called")
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local actions = {}
    local word = vim.fn.expand("<cword>")
    log.debug("[spellwand.handler.textDocument.codeAction] word=: '" .. tostring(word) .. "'")

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

    local suggestions = vim.fn.spellsuggest(word, M.config.num_suggestions)
    for idx, sug in ipairs(suggestions) do
      table.insert(actions, {
        title = string.format("Change '%s' to '%s'", word, sug),
        command = {
          title = string.format("Change '%s' to '%s'", word, sug),
          command = "spellwand.fix",
          arguments = { 0, idx },
        },
      })
    end

    return actions
  end,

  [ms.workspace_executeCommand] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.workspace.executeCommand] called: " .. params.command)
    local cmd_fn = commands[params.command]
    if not cmd_fn then
      -- Return LSP error response
      return {
        code = -32601,  -- MethodNotFound
        message = "Unknown command: " .. params.command,
      }
    end

    local ok, result = pcall(cmd_fn, unpack(params.arguments))
    if not ok then
      -- Return LSP error response
      return {
        code = -32603,  -- InternalError
        message = tostring(result),
      }
    end

    -- Success: return null (nil in Lua)
    return nil
  end,

  [ms.workspace_didChangeConfiguration] = function(err, params, ctx, _)
    log.debug("[spellwand.handler.workspace.didChangeConfiguration] called")
    if params.settings and params.settings.spellwand then
      -- Update global config
      M.config = vim.tbl_deep_extend("force", M.config, params.settings.spellwand)
      log.debug("[spellwand.handler.workspace.didChangeConfiguration] Config received: " .. vim.inspect(params.settings.spellwand))
      log.debug("[spellwand.handler.workspace.didChangeConfiguration] Full config: " .. vim.inspect(M.config))

      -- Re-publish diagnostics for all attached buffers
      local clients = vim.lsp.get_clients({ name = "spellwand" })
      for _, client in ipairs(clients) do
        for bufnr, _ in pairs(client.attached_buffers or {}) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            publish_diagnostics(bufnr)
          end
        end
      end
    end
    return nil
  end,
}

---Create in-process LSP RPC interface
---Implements vim.lsp.rpc.PublicClient for use as vim.lsp.Config.cmd function
---@param dispatchers_arg vim.lsp.rpc.Dispatchers Dispatchers for server->client messages
---@return vim.lsp.rpc.PublicClient RPC client interface
function M.create_rpc(dispatchers_arg)
  -- Store dispatchers for publishDiagnostics
  dispatchers = dispatchers_arg
  log.debug("[spellwand.rpc.create] called, dispatchers stored")

  return {
    ---Send a request to the server and call callback with response
    ---@param method string LSP method name
    ---@param params table|nil Request parameters
    ---@param callback fun(err: lsp.ResponseError?, result: any) Response callback
    ---@param notify_reply_callback fun(message_id: integer)? Optional reply notification callback
    ---@return boolean success Whether request was sent
    ---@return integer|nil message_id Request ID (nil for notifications)
    request = function(method, params, callback, notify_reply_callback)
      log.debug("[spellwand.rpc.request] called: " .. method)
      local handler = M.handlers[method]
      if handler then
        -- ctx is created for handler compatibility with Neovim's LSP convention
        -- client_id=0 is hardcoded as handlers don't currently use it
        local ctx = { client_id = 0 }
        local result = handler(nil, params, ctx, {})
        if callback then
          -- Check if result is an error response (has code field)
          if result and result.code then
            callback(result, nil)
          else
            callback(nil, result)
          end
        end
        -- For in-process, we don't have a real message_id
        -- Return true and a dummy id (1) for compatibility
        return true, 1
      else
        -- Method not found
        if callback then
          callback({
            code = -32601,
            message = "Method not found: " .. method,
          }, nil)
        end
        return false, nil
      end
    end,

    ---Send a notification to the server (no response expected)
    ---@param method string LSP method name
    ---@param params table|nil Notification parameters
    ---@return boolean success Whether notification was sent
    notify = function(method, params)
      log.debug("[spellwand.rpc.notify] called: " .. method)
      local handler = M.handlers[method]
      if handler then
        local ctx = { client_id = 0 }
        handler(nil, params, ctx, {})
      else
        log.debug("[spellwand.rpc.notify] no handler for " .. method)
      end
      return true
    end,

    ---Check if RPC connection is closing
    ---@return boolean is_closing True if RPC is closing
    is_closing = function()
      log.debug("[spellwand.rpc.lifecycle] is_closing called")
      return false
    end,

    ---Terminate the RPC connection
    terminate = function()
      log.debug("[spellwand.rpc.lifecycle] terminate called")
      -- Cleanup is handled via shutdown handler
    end,
  }
end

return M
