---@meta

---@module 'spellwand.types'

---Spellwand LSP configuration options (settings.spellwand namespace)
---@class spellwand.Config
---Maximum file size to check in lines (nil for no limit)
---@field max_file_size integer|nil
---Spell checking method: "ts" (treesitter) or "iter" (buffer scan)
---@field method "ts"|"iter"
---Severity levels for different error types
---@field severity table<string, integer>
---Show suggestions in diagnostic message
---@field suggest boolean
---Number of suggestions in code actions
---@field num_suggestions integer

---Spelling error data structure
---@class spellwand.SpellingError
---@field word string The misspelled word
---@field lnum integer 1-indexed line number
---@field col integer 1-indexed column number
---@field type string Error type: "spellbad", "spellcap", "spelllocal", "spellrare"
