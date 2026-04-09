--- In-process LSP server for spell checking, leveraging Neovim's built-in
--- spell check capabilities to provide diagnostics and code actions.
--- See README.md for configuration details.

---@type vim.lsp.Config
return {
  cmd = function(dispatchers, config)
    -- In-process LSP: create RPC interface that dispatches directly to handlers
    return require("spellwand.lsp").create_rpc(dispatchers, config)
  end,
  settings = {
    spellwand = vim.deepcopy(require("spellwand.lsp").default_config),
  },
}
