---@module 'spellwand'

local M = {}

---Refresh spellwand diagnostics
---Triggers re-check by sending textDocument/didChange notification.
---@param bufnr integer? Buffer number: nil = all buffers, 0 = current buffer
function M.refresh(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if bufnr then
    local clients = vim.lsp.get_clients({ name = "spellwand", bufnr = bufnr })
    for _, client in ipairs(clients) do
      client:notify(vim.lsp.protocol.Methods.textDocument_didChange, {
        textDocument = {
          uri = vim.uri_from_bufnr(bufnr),
          version = vim.lsp.util.buf_versions[bufnr] or 0,
        },
        contentChanges = {},
      })
    end
    return
  end

  -- Refresh all attached buffers
  local seen = {}
  local clients = vim.lsp.get_clients({ name = "spellwand" })
  for _, client in ipairs(clients) do
    for attached_bufnr, _ in pairs(client.attached_buffers or {}) do
      if not seen[attached_bufnr] then
        seen[attached_bufnr] = true
        client:notify(vim.lsp.protocol.Methods.textDocument_didChange, {
          textDocument = {
            uri = vim.uri_from_bufnr(attached_bufnr),
            version = vim.lsp.util.buf_versions[attached_bufnr] or 0,
          },
          contentChanges = {},
        })
      end
    end
  end
end

return M
