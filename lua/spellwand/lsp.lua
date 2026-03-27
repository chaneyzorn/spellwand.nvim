local M = {}

local ms = vim.lsp.protocol.Methods

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
  if M.config.max_file_size then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count > M.config.max_file_size then
      return {}
    end
  end

  if not vim.wo.spell then
    return {}
  end

  local errors = require("spellwand.spelling").get_spelling_errors(bufnr, M.config)

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
---Uses client:notify() for proper LSP server-to-client notification
---@param client vim.lsp.Client
---@param bufnr integer
local function publish_diagnostics(client, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local diagnostics = get_diagnostics(bufnr)
  client:notify(ms.textDocument_publishDiagnostics, {
    uri = vim.uri_from_bufnr(bufnr),
    diagnostics = diagnostics,
  })
end

---LSP method handlers
---Signature matches Neovim's handler format: (err, result, ctx, config)
M.handlers = {
  [ms.initialize] = function(err, params, ctx, _)
    -- Apply settings from initializationOptions
    local init_settings = params.initializationOptions and params.initializationOptions.settings
    if init_settings and init_settings.spellwand then
      M.config = vim.tbl_deep_extend("force", M.default_config, init_settings.spellwand)
    end

    return {
      capabilities = get_capabilities(),
      serverInfo = {
        name = "spellwand",
        version = "0.1.0",
      },
    }
  end,

  [ms.initialized] = function(_, _, _, _)
    -- Server is initialized, nothing to do
  end,

  [ms.shutdown] = function(_, _, _, _)
    -- Reset to defaults on shutdown
    M.config = vim.deepcopy(M.default_config)
    return nil
  end,

  [ms.textDocument_didOpen] = function(err, params, ctx, _)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if not client then
      return
    end

    publish_diagnostics(client, bufnr)
  end,

  [ms.textDocument_didChange] = function(err, params, ctx, _)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if not client then
      return
    end
    publish_diagnostics(client, bufnr)
  end,

  [ms.textDocument_didClose] = function(err, params, ctx, _)
    -- Client automatically clears diagnostics on buffer close
  end,

  [ms.textDocument_codeAction] = function(err, params, ctx, _)
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
    if params.settings and params.settings.spellwand then
      -- Update global config
      M.config = vim.tbl_deep_extend("force", M.config, params.settings.spellwand)

      -- Re-publish diagnostics for all attached buffers
      local client = vim.lsp.get_client_by_id(ctx.client_id)
      if client then
        for bufnr, _ in pairs(client.attached_buffers or {}) do
          publish_diagnostics(client, bufnr)
        end
      end
    end
  end,
}

---Create in-process LSP RPC interface
---Implements vim.lsp.rpc.PublicClient for use as cmd function
---@param dispatchers vim.lsp.rpc.Dispatchers Dispatchers for server->client messages
---@return vim.lsp.rpc.PublicClient RPC client interface
function M.create_rpc(dispatchers)
  return {
    ---Send a request to the server and call callback with response
    ---@param method string LSP method name
    ---@param params table|nil Request parameters
    ---@param callback fun(err: lsp.ResponseError?, result: any) Response callback
    ---@param notify_reply_callback fun(message_id: integer)? Optional reply notification callback
    ---@return boolean success Whether request was sent
    ---@return integer|nil message_id Request ID (nil for notifications)
    request = function(method, params, callback, notify_reply_callback)
      local handler = M.handlers[method]
      if handler then
        -- ctx is created for handler compatibility with Neovim's LSP convention
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
      local handler = M.handlers[method]
      if handler then
        local ctx = { client_id = 0 }
        handler(nil, params, ctx, {})
      end
      return true
    end,

    ---Check if RPC connection is closing
    ---@return boolean is_closing True if RPC is closing
    is_closing = function()
      return false
    end,

    ---Terminate the RPC connection
    terminate = function()
      -- Cleanup is handled via shutdown handler
    end,
  }
end

return M
