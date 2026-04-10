local M = {}

---Error type mapping from vim.spell.check() codes to LSP error types
---@type table<string, string>
local ERROR_TYPES = {
  bad = "SpellBad",
  cap = "SpellCap",
  ["local"] = "SpellLocal",
  rare = "SpellRare",
}

---Get spelling errors using Treesitter @spell captures
---@param bufnr integer
---@param opts spellwand.LspConfig
---@return spellwand.SpellingError[]|nil Returns nil if treesitter is not available
function M.get_spelling_errors_treesitter(bufnr, opts)
  -- Get the treesitter parser for the buffer
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  -- Parse the buffer and get all trees (for injections)
  local trees = parser:parse()
  if not trees or #trees == 0 then
    return nil
  end

  -- Get the highlight query which contains @spell captures
  local query = vim.treesitter.query.get(parser:lang(), "highlights")
  if not query then
    return nil
  end

  -- Check if query has @spell capture
  local has_spell_capture = false
  for _, name in ipairs(query.captures) do
    if name == "spell" then
      has_spell_capture = true
      break
    end
  end
  if not has_spell_capture then
    return nil
  end

  local spell_errors = {}
  local seen = {}
  local max_errors = opts.max_errors

  -- Helper to process a single spell error and check max_errors limit
  local function add_spell_error(start_row, start_col, err)
    local word = err[1]
    local err_code = err[2]
    local col_offset = err[3]

    local abs_lnum = start_row + 1
    local abs_col = start_col + col_offset + 1
    local key = abs_lnum .. ":" .. abs_col .. ":" .. word

    if seen[key] then
      return false
    end

    seen[key] = true
    table.insert(spell_errors, {
      word = word,
      lnum = abs_lnum,
      col = abs_col,
      type = ERROR_TYPES[err_code] or ("Spell" .. err_code:gsub("^%l", string.upper)),
    })

    return #spell_errors >= max_errors
  end

  -- Process each tree (handles injected languages)
  for _, tree in ipairs(trees) do
    local root = tree:root()

    for id, node in query:iter_captures(root, bufnr, 0, -1) do
      if query.captures[id] ~= "spell" then
        goto continue
      end

      local start_row, start_col = node:range()
      local text = vim.treesitter.get_node_text(node, bufnr)
      if not text then
        goto continue
      end

      local check_results
      vim.api.nvim_buf_call(bufnr, function()
        check_results = vim.spell.check(text)
      end)
      for _, err in ipairs(check_results or {}) do
        if add_spell_error(start_row, start_col, err) then
          return spell_errors
        end
      end

      ::continue::
    end
  end

  return spell_errors
end

---Get spelling errors by iterating through buffer content (full buffer scan)
---@param bufnr integer
---@param opts spellwand.LspConfig
---@param start_row integer|nil 0-indexed
---@param start_col integer|nil 0-indexed
---@param end_row integer|nil 0-indexed
---@param end_col integer|nil 0-indexed
---@return spellwand.SpellingError[]
function M.get_spelling_errors_full(bufnr, opts, start_row, start_col, end_row, end_col)
  start_row = start_row or 0
  start_col = start_col or 0

  if end_row == nil then
    end_row = vim.api.nvim_buf_line_count(bufnr) - 1
  end
  if end_col == nil then
    local last_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
    end_col = #last_line
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  if #lines == 0 then
    return {}
  end

  -- Trim last line to end_col
  lines[#lines] = string.sub(lines[#lines], 1, end_col)
  -- Trim first line from start_col
  lines[1] = string.sub(lines[1], start_col + 1)

  local spell_errors = {}
  local seen = {}
  local max_errors = opts.max_errors

  for n, line in ipairs(lines) do
    local line_spell_errors
    vim.api.nvim_buf_call(bufnr, function()
      line_spell_errors = vim.spell.check(line)
    end)
    for _, err in ipairs(line_spell_errors or {}) do
      local word = err[1]
      local err_code = err[2]
      local col = err[3]

      -- Calculate absolute position
      local abs_lnum = start_row + n
      local abs_col = (n == 1 and start_col or 0) + col + 1
      local key = abs_lnum .. ":" .. abs_col .. ":" .. word

      if not seen[key] then
        seen[key] = true
        table.insert(spell_errors, {
          word = word,
          lnum = abs_lnum,
          col = abs_col,
          type = ERROR_TYPES[err_code] or ("Spell" .. err_code:gsub("^%l", string.upper)),
        })

        -- Early return if max_errors reached
        if #spell_errors >= max_errors then
          return spell_errors
        end
      end
    end
  end

  return spell_errors
end

---Strategy implementations map
---@type table<string, fun(bufnr: integer, opts: spellwand.LspConfig): spellwand.SpellingError[]|nil>
local strategy_impl = {
  treesitter = M.get_spelling_errors_treesitter,
  full = M.get_spelling_errors_full,
}

---Main entry point for getting spelling errors
---Filetype filtering is handled by vim.lsp.config's filetypes field
---@param bufnr integer
---@param opts spellwand.LspConfig
---@return spellwand.SpellingError[]
function M.get_spelling_errors(bufnr, opts)
  -- Resolve strategies (function or array)
  local strategies = opts.strategies or { "full" }
  if type(strategies) == "function" then
    strategies = strategies(bufnr)
  end

  -- Try strategies in order until one succeeds (returns non-nil)
  for _, strategy in ipairs(strategies) do
    local impl = strategy_impl[strategy]
    if impl then
      local spell_errors = impl(bufnr, opts)
      if spell_errors ~= nil then
        return spell_errors
      end
    end
  end

  -- All strategies failed or strategies list was empty
  return {}
end

return M
