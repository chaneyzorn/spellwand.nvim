---@brief
---
--- In-process LSP server for spell checking, leveraging Neovim's built-in
--- spell check capabilities to provide diagnostics and code actions.
---
--- ## Configuration
---
--- ```lua
--- -- Default configuration
--- vim.lsp.enable('spellwand')
---
--- -- Custom configuration
--- vim.lsp.config('spellwand', {
---   filetypes = { 'markdown', 'text', 'gitcommit' },
---   root_markers = { '.git', '.spell', '.markdownlint.json' },
---   settings = {
---     spellwand = {
---       suggest = true,
---       num_suggestions = 5,
---     }
---   }
--- })
--- vim.lsp.enable('spellwand')
--- ```
---
--- ## Standard vim.lsp.config options:
---
--- - `filetypes`: Array of filetypes to enable (nil = all filetypes)
--- - `root_markers`: Markers to find project root (default: {".git", ".spell"})
---
--- ## Available Options (settings.spellwand):
---
--- - `max_file_size`: Maximum file size in lines (default: 10000)
--- - `method`: Spell checking method - "ts" or "iter" (default: "ts")
--- - `severity`: Severity levels for different error types
--- - `suggest`: Show suggestions in diagnostic message (default: false)
--- - `num_suggestions`: Number of suggestions in code actions (default: 3)

local lsp = require("spellwand.lsp")

---@type vim.lsp.Config
return {
  cmd = function(dispatchers)
    -- In-process LSP: create RPC interface that dispatches directly to handlers
    return lsp.create_rpc(dispatchers)
  end,
  filetypes = nil,
  root_markers = { ".git", ".spell" },
  -- Settings are sent to server via workspace/didChangeConfiguration
  settings = {
    spellwand = vim.deepcopy(lsp.default_config),
  },
}
