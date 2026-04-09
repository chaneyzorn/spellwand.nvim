---@meta

---@module 'spellwand.types'

---Spellwand LSP configuration options (settings.spellwand namespace)
---@class spellwand.LspConfig
---@field cond fun(bufnr: integer): boolean Condition function to determine whether to check the buffer
---@field strategies ("treesitter"|"full")[] List of strategies to try in order, until one succeeds
---@field severity table<string, integer> Severity levels for different error types
---@field suggest_in_diagnostics boolean Show suggestions in diagnostic message
---@field num_suggestions integer Number of suggestions in code actions

---Spelling error data structure
---@class spellwand.SpellingError
---@field word string The misspelled word
---@field lnum integer 1-indexed line number
---@field col integer 1-indexed column number
---@field type string Error type: "SpellBad", "SpellCap", "SpellLocal", "SpellRare"
