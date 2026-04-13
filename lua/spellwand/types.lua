---@meta

---@module 'spellwand.types'

---Spellwand LSP configuration options (settings.spellwand namespace)
---@class spellwand.LspConfig
---@field cond fun(bufnr: integer): boolean Condition function to determine whether to check the buffer
---@field strategies ("treesitter"|"full")[] | fun(bufnr: integer): ("treesitter"|"full")[] List of strategies to try in order, or a function returning the strategy list
---@field max_errors integer Maximum number of spell errors to return (early return for performance)
---@field preprocess fun(bufnr: integer, spell_errors: spellwand.SpellingError[]): spellwand.SpellingError[] Preprocess spell errors before converting to diagnostics
---@field severity table<string, integer> Severity levels for different error types
---@field messages spellwand.Messages Diagnostic message templates
---@field suggest_in_diagnostics boolean Show suggestions in diagnostic message
---@field num_suggestions integer Number of suggestions in code actions

---Spelling error data structure
---@class spellwand.SpellingError
---@field word string The misspelled word
---@field lnum integer 1-indexed line number
---@field col integer 1-indexed column number
---@field type string Error type: "SpellBad", "SpellCap", "SpellLocal", "SpellRare"

---Diagnostic message format templates
---@class spellwand.MessageTemplates
---@field SpellBad string Format template for unknown words, e.g. 'Unknown word: "%s"'
---@field SpellCap string Format template for capitalization errors, e.g. 'Capitalization error: "%s"'
---@field SpellLocal string Format template for local words, e.g. 'Local word: "%s"'
---@field SpellRare string Format template for rare words, e.g. 'Rare word: "%s"'
---@field SuggestPrefix string Format template for suggestions prefix, e.g. "did you mean: %s"

---Diagnostic message formatter type (templates table or custom function)
---@alias spellwand.Messages spellwand.MessageTemplates|fun(word: string, type: string, suggestions: string[]|nil): string
