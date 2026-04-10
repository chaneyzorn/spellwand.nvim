---@module 'spellwand'

local M = {}

---Refresh spellwand diagnostics for a buffer
---Triggers re-check by sending textDocument/didChange notification
---@param bufnr integer|nil Buffer number (nil for current buffer)
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local clients = vim.lsp.get_clients({ name = "spellwand", bufnr = bufnr })
  for _, client in ipairs(clients) do
    -- Use empty contentChanges for incremental sync to trigger re-check
    client:notify(vim.lsp.protocol.Methods.textDocument_didChange, {
      textDocument = {
        uri = vim.uri_from_bufnr(bufnr),
        version = vim.lsp.util.buf_versions[bufnr] or 0,
      },
      contentChanges = {},
    })
  end
end

return M
