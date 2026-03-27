local M = {}

---Get the error type for a word
---@param word string
---@param bufnr integer
---@return string
function M.get_error_type(word, bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    local check = vim.spell.check(word)
    -- If the word "is" spelled correctly, but is being flagged, it's a capitalization error
    return "spell" .. ((check[1] and check[1][2]) or "cap")
  end)
end

---Get spelling errors using Treesitter @spell captures
---@param bufnr integer
---@return spellwand.SpellingError[]|nil Returns nil if treesitter is not available
function M.get_spelling_errors_ts(bufnr)
  -- Get the treesitter parser for the buffer
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  local errors = {}
  local seen = {}

  -- Parse the buffer and get all trees (for injections)
  local trees = parser:parse()
  if not trees or #trees == 0 then
    return nil
  end

  -- Get the language for this parser
  local lang = parser:lang()

  -- Get the highlight query which contains @spell captures
  local query = vim.treesitter.query.get(lang, "highlights")
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
          local line_errors = vim.spell.check(text)
          for _, err in ipairs(line_errors) do
            local word = err[1]
            local err_type = "spell" .. err[2]
            local col_offset = err[3]

            -- Calculate absolute position
            local abs_lnum = start_row + 1
            local abs_col = start_col + col_offset + 1
            local key = abs_lnum .. ":" .. abs_col .. ":" .. word

            if not seen[key] then
              seen[key] = true
              table.insert(errors, {
                word = word,
                lnum = abs_lnum,
                col = abs_col,
                type = err_type,
              })
            end
          end
        end
      end
    end
  end

  return errors
end

---Get spelling errors by iterating through buffer content
---@param bufnr integer
---@param start_row integer|nil 0-indexed
---@param start_col integer|nil 0-indexed
---@param end_row integer|nil 0-indexed
---@param end_col integer|nil 0-indexed
---@return spellwand.SpellingError[]
function M.get_spelling_errors_iter(bufnr, start_row, start_col, end_row, end_col)
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

  local errors = {}
  local seen = {}

  for n, line in ipairs(lines) do
    local line_errors = vim.spell.check(line)
    for _, err in ipairs(line_errors) do
      local word = err[1]
      local err_type = "spell" .. err[2]
      local col = err[3]

      -- Calculate absolute position
      local abs_lnum = start_row + n
      local abs_col = (n == 1 and start_col or 0) + col + 1
      local key = abs_lnum .. ":" .. abs_col .. ":" .. word

      if not seen[key] then
        seen[key] = true
        table.insert(errors, {
          word = word,
          lnum = abs_lnum,
          col = abs_col,
          type = err_type,
        })
      end
    end
  end

  return errors
end

---Main entry point for getting spelling errors
---Filetype filtering is handled by vim.lsp.config's filetypes field
---@param bufnr integer
---@param opts spellwand.Config
---@return spellwand.SpellingError[]
function M.get_spelling_errors(bufnr, opts)
  if not vim.wo.spell then
    return {}
  end

  -- Check max file size
  if opts.max_file_size then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count > opts.max_file_size then
      return {}
    end
  end

  -- Use treesitter method by default, fallback to iter if ts returns nil
  if opts.method == "ts" or opts.method == nil then
    local ts_errors = M.get_spelling_errors_ts(bufnr)
    if ts_errors ~= nil then
      return ts_errors
    end
  end
  return M.get_spelling_errors_iter(bufnr)
end

return M
