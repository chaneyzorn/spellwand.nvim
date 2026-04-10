# spellwand.nvim

An in-process LSP server for Neovim that provides spell checking diagnostics and code actions, leveraging Neovim's built-in spell checking capabilities.

Uses Neovim's built-in spell checking, so results are always consistent with native behavior. Also demonstrates how to implement an in-process LSP server.

- [spellwand.nvim](#spellwandnvim)
  - [Features](#features)
  - [Requirements](#requirements)
  - [Installation](#installation)
    - [lazy.nvim](#lazynvim)
    - [vim.pack (Neovim 0.12+)](#vimpack-neovim-012)
  - [Configuration](#configuration)
    - [Available Options](#available-options)
    - [Customization Examples](#customization-examples)
  - [Usage](#usage)
    - [Standard LSP Commands](#standard-lsp-commands)
    - [Key Mappings](#key-mappings)
    - [Code Actions](#code-actions)
  - [Limitations](#limitations)
  - [Alternative Spell Checking LSP Servers](#alternative-spell-checking-lsp-servers)
  - [Acknowledgments](#acknowledgments)

## Features

- In-process LSP server - no external dependencies, runs within Neovim
- Native LSP integration - works with `vim.lsp.buf.code_action()`, telescope, trouble.nvim, etc.
- Standard LSP configuration - provides `lsp/spellwand.lua` runtime path, just like nvim-lspconfig
- Treesitter-aware - uses `@spell` captures for context-aware checking, with fallback to full buffer scan
- Spellfile support - works with Neovim's `spellfile` option for multiple dictionaries
- Fast and lightweight - direct access to Neovim's spell state, no RPC overhead
- Customizable processing - users can define `cond` and `preprocess` functions to customize spell error handling
- Pure LSP protocol - uses standard LSP methods without explicit Vim autocmds

## Requirements

- Neovim 0.11+
- `spell` option enabled (`:set spell`)
- Treesitter queries providing `@spell` captures for context-aware checking (falls back to full buffer scan if unavailable)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "chaneyzorn/spellwand.nvim",
  config = function()
    vim.lsp.enable("spellwand")
  end,
}
```

### [vim.pack](https://neovim.io/doc/user/pack.html) (Neovim 0.12+)

```lua
vim.pack.add({
  { src = "https://github.com/chaneyzorn/spellwand.nvim" },
})
vim.lsp.enable("spellwand")
```

## Configuration

spellwand uses the standard Neovim 0.11+ LSP configuration API:

```lua
-- Default configuration (no setup needed)
vim.lsp.enable("spellwand")

-- Custom configuration with max_errors
vim.lsp.config("spellwand", {
  settings = {
    spellwand = {
      max_errors = 500,
    }
  }
})
vim.lsp.enable("spellwand")
```

Or create a config file at `lsp/spellwand.lua` in your config directory:

```lua
-- ~/.config/nvim/lsp/spellwand.lua
return {
  filetypes = { "markdown", "text", "gitcommit" },
  settings = {
    spellwand = {
      max_errors = 500,
    }
  }
}
```

Then just enable:

```lua
vim.lsp.enable("spellwand")
```

To adjust the debounce time for diagnostic updates (Neovim LSP client built-in option):

```lua
vim.lsp.config("spellwand", {
  flags = {
    debounce_text_changes = 300,  -- milliseconds, default is 150
  },
})
```

### Available Options

All configuration options and their defaults (passed via `settings.spellwand`):

```lua
vim.lsp.config("spellwand", {
  filetypes = nil,  -- Filetypes to attach to (nil = all filetypes)
  settings = {
    spellwand = {
      -- Condition function: fun(bufnr: integer): boolean
      cond = function(bufnr) return true end,

      -- List of strategies with fallback: ("treesitter"|"full")[]
      -- Tries each strategy in order until one succeeds
      strategies = { "treesitter", "full" },

      -- Maximum errors to return
      max_errors = 999,

      -- Preprocess function: fun(bufnr: integer, spell_errors: spellwand.SpellingError[]): spellwand.SpellingError[]
      preprocess = function(bufnr, spell_errors) return spell_errors end,

      -- Severity mapping
      severity = {
        SpellBad = vim.diagnostic.severity.WARN,
        SpellCap = vim.diagnostic.severity.HINT,
        SpellLocal = vim.diagnostic.severity.HINT,
        SpellRare = vim.diagnostic.severity.INFO,
      },

      -- Diagnostic message templates
      messages = {
        SpellBad = "Unknown word",
        SpellCap = "Capitalization error",
        SpellLocal = "Local word",
        SpellRare = "Rare word",
        SuggestPrefix = "did you mean",
      },

      -- Show suggestions in diagnostic message
      suggest_in_diagnostics = false,

      -- Number of suggestions in code actions
      num_suggestions = 3,
    }
  }
})
```

See `lua/spellwand/types.lua` for complete type definitions.

Since spellwand runs in-process, it is possible to use runtime Lua functions for `cond` and `preprocess` — no JSON serialization involved.

The `treesitter` strategy only checks nodes captured as `@spell` (typically comments and string literals), defined in query files like `queries/lua/highlights.scm`. Use the `full` strategy to check all buffer text. You may also want to configure `:spelloptions` (e.g., `noplainbuffer`, automatically set by Neovim when Treesitter is active) to keep spell highlighting consistent across strategies.

### Customization Examples

Use `cond` to skip large files, help files, or readonly buffers:

```lua
cond = function(bufnr)
  -- Skip help files and readonly buffers
  local bo = vim.bo[bufnr]
  if bo.filetype == "help" or bo.readonly then
    return false
  end
  -- Skip large files (>10K lines)
  if vim.api.nvim_buf_line_count(bufnr) > 10000 then
    return false
  end
  return true
end
```

Use `preprocess` to ignore short words (≤2 characters):

```lua
preprocess = function(_bufnr, spell_errors)
  return vim.tbl_filter(function(err)
    return #err.word > 2
  end, spell_errors)
end
```

Deduplicate: keep only the first occurrence of each misspelled word:

```lua
preprocess = function(_bufnr, spell_errors)
  local seen = {}
  return vim.tbl_filter(function(err)
    if seen[err.word] then return false end
    seen[err.word] = true
    return true
  end, spell_errors)
end
```

## Usage

### Standard LSP Commands

Since spellwand is a standard LSP server, you control it using Neovim's built-in LSP commands:

```vim
" Enable spellwand (start the LSP client)
:lua vim.lsp.enable('spellwand')

" Disable spellwand (stop all spellwand clients)
:lua vim.lsp.stop_client(vim.lsp.get_clients({ name = 'spellwand' }))

" Check if spellwand is attached
:checkhealth vim.lsp
```

### Key Mappings

spellwand works with native spell keybindings:

- `]s` / `[s` - Navigate to next/previous spelling error
- `gra` - Code action at cursor position (LSP builtin)
- `z=` - Suggestions for word under cursor (native)
- `zg` - Add word to dictionary (uses first spellfile, native)
- `2zg` - Add word to second spellfile (native)
- `zw` - Mark word as wrong (native)

### Code Actions

When your cursor is on a misspelled word, use `gra` (or `:lua vim.lsp.buf.code_action()`):

Available actions:

- Add word to each configured spellfile (shown with full path)
- Add all misspelled words in buffer to each configured spellfile
- Change to one of the suggestions

## Limitations

Unlike external LSP servers that run asynchronously in a separate process, spellwand runs in-process and performs spell checking synchronously. This means large-scale spell checking (files with thousands of spelling errors) may cause temporary TUI lag. Use the `max_errors` option to set an appropriate limit.

## Alternative Spell Checking LSP Servers

If you need more advanced features or asynchronous processing, consider these dedicated spell checking LSP servers:

- [typos-lsp](https://github.com/tekumara/typos-lsp) - Source code spell checker based on typos
- [harper-ls](https://github.com/elijah-potter/harper) - The Grammar Checker for Developers
- [codebook](https://github.com/blopker/codebook) - A fast, semantic, cross-platform spell checker
- [cspell-lsp](https://github.com/davidmh/cspell.nvim) - cspell integration for Neovim

## Acknowledgments

- [spellwarn.nvim](https://github.com/ravibrock/spellwarn.nvim): Inspired the spell checking approach
- [spellsitter.nvim](https://github.com/lewis6991/spellsitter.nvim): Precursor to Neovim's built-in Treesitter spell checking (merged in 0.8)
- [in-process-lsp-guide](https://github.com/neo451/in-process-lsp-guide): A guide for implementing the in-process LSP pattern
