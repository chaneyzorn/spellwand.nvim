local M = {}

local log = require("vim.lsp.log")

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
  log.debug("[spellwand.spelling.treesitter] called for bufnr=" .. bufnr)

  -- Get the treesitter parser for the buffer
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    log.debug("[spellwand.spelling.treesitter] parser not available: " .. tostring(parser))
    return nil
  end
  log.debug("[spellwand.spelling.treesitter] parser for lang=" .. parser:lang())

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
    log.debug("[spellwand.spelling.treesitter] no @spell capture in highlights query")
    return nil
  end
  log.debug("[spellwand.spelling.treesitter] has @spell capture in query")

  local spell_errors = {}
  local seen = {}
  local max_errors = opts.max_errors

  -- Process each tree (handles injected languages)
  for _, tree in ipairs(trees) do
    local root = tree:root()

    -- Iterate over all captures in the query
    for id, node in query:iter_captures(root, bufnr, 0, -1) do
      local capture_name = query.captures[id]
      if capture_name == "spell" then
        local start_row, start_col, end_row, end_col = node:range()
        local text = vim.treesitter.get_node_text(node, bufnr)

        if text then
          local line_spell_errors = vim.spell.check(text)
          for _, err in ipairs(line_spell_errors) do
            local word = err[1]
            local err_code = err[2]
            local col_offset = err[3]

            -- Calculate absolute position
            local abs_lnum = start_row + 1
            local abs_col = start_col + col_offset + 1
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
                log.debug("[spellwand.spelling.treesitter] reached max_errors limit (" .. max_errors .. ")")
                return spell_errors
              end
            end
          end
        end
      end
    end
  end

  log.debug("[spellwand.spelling.treesitter] found " .. #spell_errors .. " total spell errors")
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
    local line_spell_errors = vim.spell.check(line)
    for _, err in ipairs(line_spell_errors) do
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
          log.debug("[spellwand.spelling.full] reached max_errors limit (" .. max_errors .. ")")
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
  log.debug("[spellwand.spelling.get] called for bufnr=" .. bufnr)

  -- Log spell status for debugging (do not block)
  log.debug("[spellwand.spelling.get] vim.wo.spell=" .. tostring(vim.wo.spell))

  -- Try strategies in order until one succeeds (returns non-nil)
  for _, strategy in ipairs(opts.strategies or { "full" }) do
    log.debug("[spellwand.spelling.get] trying strategy: " .. strategy)
    local impl = strategy_impl[strategy]
    if impl then
      local spell_errors = impl(bufnr, opts)
      if spell_errors ~= nil then
        log.debug(
          "[spellwand.spelling.get] strategy '" .. strategy .. "' succeeded with " .. #spell_errors .. " spell errors"
        )
        return spell_errors
      end
      log.debug("[spellwand.spelling.get] strategy '" .. strategy .. "' returned nil, trying next")
    else
      log.warn("[spellwand.spelling.get] unknown strategy: " .. tostring(strategy))
    end
  end

  -- All strategies failed or strategies list was empty
  log.debug("[spellwand.spelling.get] all strategies exhausted, returning empty")
  return {}
end

return M
