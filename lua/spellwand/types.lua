---@meta

---@module 'spellwand.types'

---Spellwand LSP configuration options (settings.spellwand namespace)
---@class spellwand.Config
---@field max_file_size integer|nil Maximum file size to check in lines (nil for no limit)
---@field strategy "treesitter"|"full" Spell checking strategy: "treesitter" or "full"
---@field severity table<string, integer> Severity levels for different error types
---@field suggest_in_diagnostics boolean Show suggestions in diagnostic message
---@field num_suggestions integer Number of suggestions in code actions

---Spelling error data structure
---@class spellwand.SpellingError
---@field word string The misspelled word
---@field lnum integer 1-indexed line number
---@field col integer 1-indexed column number
---@field type string Error type: "SpellBad", "SpellCap", "SpellLocal", "SpellRare"
