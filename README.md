# spellwand.nvim 🔮

An in-process LSP server for Neovim that provides spell checking diagnostics and code actions, leveraging Neovim's built-in spell checking capabilities.

## Features

- 🎯 **In-process LSP server** - No external dependencies, runs within Neovim
- 🔗 **Native LSP integration** - Works with `vim.lsp.buf.code_action()`, telescope, trouble.nvim, etc.
- 🌳 **Treesitter-aware** - Uses `@spell` captures for context-aware checking
- 📁 **Spellfile support** - Works with Neovim's `spellfile` option for multiple dictionaries
- ⚡ **Fast & lightweight** - Direct access to Neovim's spell state, no RPC overhead
- 🎨 **LSP Native** - Uses standard LSP protocol: `textDocument/didChange` → `textDocument/publishDiagnostics`

## Requirements

- Neovim 0.11+
- `spell` option enabled (`:set spell`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "chaneyzorn/spellwand.nvim",
  event = "VeryLazy",
  config = function()
    vim.lsp.enable("spellwand")
  end,
}
```

## Quick Start

1. Enable spell checking:

   ```vim
   :set spell
   ```

2. Enable spellwand:

   ```lua
   vim.lsp.enable("spellwand")
   ```

3. Open a markdown file and misspell some words

4. See diagnostics appear automatically (refreshed via LSP protocol)

5. Use code actions to fix:
   - `<leader>ca` or `:lua vim.lsp.buf.code_action()` to see suggestions
   - Or use native `z=` to fix spelling
   - Use `zg` to add to dictionary

## Configuration

spellwand uses the standard Neovim 0.11+ LSP configuration API:

```lua
-- Default configuration (no setup needed)
vim.lsp.enable("spellwand")

-- Custom configuration via settings
vim.lsp.config("spellwand", {
  filetypes = { "markdown", "text", "gitcommit" },
  settings = {
    spellwand = {
      suggest = true,
      num_suggestions = 5,
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
      suggest = true,
    }
  }
}
```

Then just enable:

```lua
vim.lsp.enable("spellwand")
```

### Available Options

All server options are passed via `settings.spellwand`:

```lua
vim.lsp.config("spellwand", {
  filetypes = nil,  -- Filetypes to attach to (nil = all filetypes)
  settings = {
    spellwand = {
      -- Maximum file size to check in lines (nil for no limit)
      max_file_size = 10000,

      -- Spell checking strategy: "treesitter" or "full"
      strategy = "treesitter",

      -- Severity levels for different error types
      severity = {
        spellbad = vim.diagnostic.severity.WARN,
        spellcap = vim.diagnostic.severity.HINT,
        spelllocal = vim.diagnostic.severity.HINT,
        spellrare = vim.diagnostic.severity.INFO,
      },

      -- Show suggestions in diagnostic message
      suggest = false,

      -- Number of suggestions in code actions
      num_suggestions = 3,
    }
  }
})
```

## Spellfile Configuration

spellwand reads Neovim's `spellfile` option to determine where to add words. Configure this option to control which spellfiles are used.

### Basic Setup

```lua
-- Single global spellfile
vim.opt.spellfile = vim.fn.expand("~/.config/nvim/spell/en.utf-8.add")

-- Multiple spellfiles (global + project local)
vim.opt.spellfile = vim.fn.expand("~/.config/nvim/spell/en.utf-8.add") ..
                      ",.spell/en.utf-8.add"
```

### Project-Specific Spellfiles

Use `.nvim.lua` (project-local config) or autocmds to set up per-project spellfiles:

```lua
-- ~/.config/nvim/init.lua
vim.api.nvim_create_autocmd("BufRead", {
  pattern = vim.fn.expand("~/projects/my-project/**/*"),
  callback = function()
    -- Use project-local spellfile
    vim.bo.spellfile = vim.fn.expand("~/projects/my-project/.spell/en.utf-8.add")
  end,
})
```

Or create `.nvim.lua` in your project root:

```lua
-- ~/projects/my-project/.nvim.lua
vim.bo.spellfile = vim.fn.getcwd() .. "/.spell/en.utf-8.add"
```

### Code Action Display Names

spellwand displays spellfile names in code actions based on path patterns:

- Files in `.spell/` directory → shown as **"local"**
- First spellfile in list → shown as **"global"**
- Others → shown by filename

Example with multiple spellfiles:

```text
Add 'neovim' to global spellfile    → ~/.config/nvim/spell/en.utf-8.add
Add 'neovim' to local spellfile     → ./.spell/en.utf-8.add
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

spellwand.nvim works with native spell keybindings:

- `]s` - Next spelling error
- `[s` - Previous spelling error
- `z=` - Suggestions for word under cursor
- `zg` - Add word to dictionary (uses first spellfile)
- `2zg` - Add word to second spellfile (if configured)
- `zw` - Mark word as wrong

### Code Actions

When your cursor is on a misspelled word:

```vim
:lua vim.lsp.buf.code_action()
```

Or with a keybinding:

```lua
vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code Action" })
```

Available actions:

- Add word to each configured spellfile (with appropriate display name)
- Change to one of the suggestions

## How It Works

spellwand.nvim implements a pure LSP protocol flow:

```text
┌─────────────┐     textDocument/didOpen      ┌─────────────┐
│   Neovim    │ ─────────────────────────────→│  spellwand  │
│   (Client)  │                               │   (Server)  │
│             │←──────────────────────────────│             │
│             │     textDocument/publishDiagnostics          │
└─────────────┘                               └─────────────┘
       │                                              ↑
       │ textDocument/didChange                       │
       └──────────────────────────────────────────────┘
```

1. **LSP Config**: Defined in `lsp/spellwand.lua` using `vim.lsp.config()`
2. **Protocol**: Uses standard LSP `textDocumentSync` capability
3. **Change Detection**: Neovim sends `textDocument/didChange` on buffer edits
4. **Diagnostics**: Server responds with `textDocument/publishDiagnostics`
5. **No Vim autocmds**: Pure LSP protocol implementation

## Troubleshooting

### No diagnostics showing

1. Check if spell is enabled: `:set spell?`
2. Check if spellwand is attached: `:checkhealth vim.lsp`
3. Check if filetype is configured: Set `filetypes` in vim.lsp.config()

### Spellfile not working

1. Check spellfile option: `:echo &spellfile`
2. Verify spellfile paths exist (create if needed)
3. Check file permissions

### Too many diagnostics

1. Set `max_file_size` to skip large files
2. Disable for specific filetypes using `filetypes` option

## Credits

- Inspired by [spellwarn.nvim](https://github.com/ravibrock/spellwarn.nvim) for the spell checking approach
- In-process LSP pattern from [in-process-lsp-guide](https://github.com/neo451/in-process-lsp-guide) by Zizhou Teng
