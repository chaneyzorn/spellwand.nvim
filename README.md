# spellwand.nvim

An in-process LSP server for Neovim that provides spell checking diagnostics and code actions, leveraging Neovim's built-in spell checking capabilities.

Uses Neovim's built-in spell checking, so results are always consistent with native behavior. Also shares how to implement an in-process LSP server — see [Limitations](#limitations) for its advantages and disadvantages.

![Screenshot showing spellwand.nvim diagnostics in Neovim](https://github.com/user-attachments/assets/abb61fdc-b4d2-41d7-9d90-54d568917de4)

- [spellwand.nvim](#spellwandnvim)
  - [Features](#features)
  - [Installation](#installation)
    - [lazy.nvim](#lazynvim)
    - [vim.pack (Neovim 0.12+)](#vimpack-neovim-012)
  - [Configuration](#configuration)
    - [Available Options](#available-options)
    - [Customization Examples](#customization-examples)
  - [Usage](#usage)
    - [Spell Configuration](#spell-configuration)
    - [Standard LSP Commands](#standard-lsp-commands)
    - [Key Mappings](#key-mappings)
    - [Code Actions](#code-actions)
  - [Limitations](#limitations)
  - [Alternative Spell Checking LSP Servers](#alternative-spell-checking-lsp-servers)
  - [Acknowledgments](#acknowledgments)

## Features

- In-process LSP server - zero external dependencies, seamless access to Neovim's internal spell APIs
- Native LSP integration - works with `vim.lsp.buf.code_action()`, telescope, trouble.nvim, etc.
- Standard LSP configuration - provides `lsp/spellwand.lua` runtime path, just like nvim-lspconfig
- Treesitter-aware - uses `@spell` captures for context-aware checking, with fallback to full buffer scan
- Spellfile support - works with Neovim's `spellfile` option for multiple dictionaries
- Performance-optimized - insert-mode pending strategy and normal-mode debounce mechanism to keep the UI responsive
- Customizable processing - users can define `cond` and `preprocess` functions to customize spell checking

## Installation

**Version Compatibility:**

- Neovim 0.11+ for basic LSP functionality (`vim.lsp.config`)
- Neovim 0.12+ for `:lsp stop` and other LSP management commands

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

### Available Options

All configuration options and their defaults (passed via `settings.spellwand`):

```lua
vim.lsp.config("spellwand", {
  filetypes = nil,  ---@type string[]? Filetypes to attach to (nil = all filetypes)
  settings = {
    spellwand = {
      ---@type fun(bufnr: integer): boolean
      ---Return false to skip spell checking for this buffer entirely (no diagnostics will be produced)
      cond = function(bufnr) return true end,

      ---@type ("treesitter"|"full")[] | fun(bufnr: integer): ("treesitter"|"full")[]
      ---Tries each strategy in order until one succeeds
      strategies = { "treesitter", "full" },

      ---@type integer
      ---Early-return limit to keep performance acceptable on large buffers.
      ---Once this many spelling errors are found, scanning stops immediately.
      max_errors = 999,

      ---@type fun(bufnr: integer, spell_errors: spellwand.SpellingError[]): spellwand.SpellingError[]
      ---Transform or filter the raw spell errors before they are converted to diagnostics and code actions.
      ---Use this to ignore short words, deduplicate, or inject custom logic.
      preprocess = function(bufnr, spell_errors) return spell_errors end,

      ---@type table<string, integer> Severity mapping
      severity = {
        SpellBad = vim.diagnostic.severity.WARN,
        SpellCap = vim.diagnostic.severity.HINT,
        SpellLocal = vim.diagnostic.severity.HINT,
        SpellRare = vim.diagnostic.severity.INFO,
      },

      ---@type spellwand.Messages Diagnostic message formatter (templates or custom function)
      messages = {
        SpellBad = 'Unknown word: "%s"',
        SpellCap = 'Capitalization error: "%s"',
        SpellLocal = 'Local word: "%s"',
        SpellRare = 'Rare word: "%s"',
        SuggestPrefix = "did you mean: %s",
      },

      ---@type integer Number of spelling suggestions shown in diagnostic messages (0 to disable)
      num_suggestions_in_diagnostics = 0,

      ---@type integer Number of spelling suggestions offered in code actions
      num_suggestions_in_code_action = 3,

      ---@type integer Debounce delay in milliseconds before re-computing diagnostics
      debounce_ms = 300,
    }
  }
})
```

See `lua/spellwand/types.lua` for complete type definitions.

Since spellwand runs in-process, it is possible to use runtime Lua functions for `cond` and `preprocess` — no JSON serialization involved.

The `treesitter` strategy only checks `@spell` nodes (typically comments and string literals), defined in query files like `queries/lua/highlights.scm`. Use the `full` strategy to check all buffer text.

### Debounce

There are two independent debounce layers you can tune:

**Client-side debounce** (`flags.debounce_text_changes`):

- Controls how often Neovim's LSP client sends `textDocument/didChange` to spellwand.
- Default is `150` milliseconds (Neovim built-in default).
- Increase this value if you want fewer change notifications sent to the server.

**Server-side debounce** (`settings.spellwand.debounce_ms`):

- Controls how long spellwand waits after receiving a change before re-computing diagnostics.
- Default is `300` milliseconds.
- **Normal mode**: `textDocument/didChange` triggers the debounce timer; diagnostics are refreshed after you stop typing for `300` ms.
- **Insert/Replace mode**: `didChange` is completely ignored to avoid blocking the UI. Old diagnostics are hidden immediately on `InsertEnter` (by pushing an empty list), and refreshed immediately on `InsertLeave`. Because of this, `vim.diagnostic.config({ update_in_insert = true })` has no effect on spellwand diagnostics.

```lua
vim.lsp.config("spellwand", {
  flags = {
    debounce_text_changes = 150,  -- client-side: throttle didChange notifications
  },
  settings = {
    spellwand = {
      debounce_ms = 300,  -- server-side: delay before re-computing diagnostics
    }
  }
})
```

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

Use a function for `strategies` to dynamically choose based on buffer:

```lua
strategies = function(bufnr)
  -- Use full scan for gitcommit (typically short, no treesitter parser needed)
  if vim.bo[bufnr].filetype == "gitcommit" then
    return { "full" }
  end
  return { "treesitter", "full" }
end
```

Use a custom `messages` function for full control:

```lua
messages = function(word, type, suggestions)
  local icons = { SpellBad = "🚨", SpellCap = "⚠️ ", SpellLocal = "📌", SpellRare = "📎" }
  local icon = icons[type] or "❓"
  if suggestions and #suggestions > 0 then
    return string.format("%s %s (try: %s)", icon, word, table.concat(suggestions, ", "))
  end
  return string.format("%s %s", icon, word)
end
```

## Usage

### Spell Configuration

spellwand uses Neovim's built-in `vim.spell.check()` function, which respects your window-local and buffer-local settings:

- **`spell`** - Enables native spell checking, highlighting, and navigation (`]s`/`[s`). spellwand diagnostics work independently of this setting.
- **`spelllang`** - Language dictionaries to use (e.g., `:set spelllang=en_us,de_de`).
- **`spellfile`** - Additional word lists. spellwand reads this to determine where to add words.
- **`spelloptions`** - Additional options like `camel` to accept CamelCase words as correct (e.g., `:set spelloptions+=camel`).

### Standard LSP Commands

Since spellwand is a standard LSP server, you control it using Neovim's built-in LSP commands:

```vim
" Enable spellwand (start the LSP client)
:lua vim.lsp.enable('spellwand')

" Disable spellwand (detach from all buffers)
:lsp disable spellwand

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

If you add or remove words via native commands (`zg`, `zw`, etc.) or an external editor, spellwand won't automatically notice the spellfile change. You can manually refresh diagnostics:

```vim
" Refresh current buffer
:SpellwandRefresh

" Refresh all attached buffers
:SpellwandRefresh!
```

Or wrap native mappings to refresh automatically:

```lua
vim.keymap.set("n", "zg", "zg<cmd>SpellwandRefresh!<cr>", { remap = false })
vim.keymap.set("n", "zw", "zw<cmd>SpellwandRefresh!<cr>", { remap = false })
```

For `zg`/`zw`, `SpellwandRefresh!` is recommended because the spellfile is shared across buffers.

### Code Actions

When your cursor is on a misspelled word, use `gra` (or `:lua vim.lsp.buf.code_action()`):

Available actions:

- Add word to each configured spellfile (shown with full path)
- Add all misspelled words in buffer to each configured spellfile
- Change to one of the suggestions

## Limitations

As an in-process LSP server, spellwand has different trade-offs compared to external servers that run in a separate process:

**Advantages**:

- Direct access to Neovim's internal state and APIs (e.g. `vim.spell`, `vim.fn.spellsuggest()`, buffer-local `spellfile` and `spelllang`) without RPC serialization overhead.
- Seamless integration with native Vim features and runtime Lua functions.

**Disadvantages**:

- Spell checking runs synchronously on Neovim's main thread. Large buffers or files with thousands of spelling errors may cause temporary TUI lag. We carefully designed the insert-mode pending strategy and normal-mode debounce mechanism to mitigate this; you can further tune performance with the `max_errors`, `debounce_ms`, and `cond` options.
- The server must implement the `vim.lsp.rpc.PublicClient` interface correctly and explicitly trigger `on_exit`, because Neovim's `vim.system` callback mechanism (used for external LSP servers to detect process exit) does not apply to in-process servers. Autocmds and timers are additional performance optimizations that also need careful cleanup.

**Why is native Vim spell checking fast while spellwand may lag in large buffers?**

Native Vim only spell-checks the *visible* window range during screen rendering. spellwand, as an LSP server, must scan the *entire buffer* to produce a complete diagnostic list, which is inherently heavier work.

A future `vim.lsp.server` API may simplify the boilerplate, but it won't remove the fundamental bottleneck of running on the main thread. Offloading to `uv` threads is possible, yet becomes awkward once you need direct access to Neovim's internal state — at which point an external LSP server is the cleaner choice.

## Alternative Spell Checking LSP Servers

If you need more advanced features or asynchronous processing, consider these dedicated spell checking LSP servers:

- [typos-lsp](https://github.com/tekumara/typos-lsp) - Source code spell checker based on typos
- [harper-ls](https://github.com/elijah-potter/harper) - The Grammar Checker for Developers
- [codebook](https://github.com/blopker/codebook) - A fast, semantic, cross-platform spell checker
- [cspell-lsp](https://github.com/davidmh/cspell.nvim) - cspell integration for Neovim

## Acknowledgments

- [spellwarn.nvim](https://github.com/ravibrock/spellwarn.nvim): Inspired the spell checking approach
- [spellsitter.nvim](https://github.com/lewis6991/spellsitter.nvim): Precursor to Neovim's built-in Treesitter spell checking (merged in 0.8)
- [in-process-lsp-guide](https://neo451.github.io/blog/posts/in-process-lsp-guide/): A guide for implementing the in-process LSP pattern
