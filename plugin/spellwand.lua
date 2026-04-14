vim.api.nvim_create_user_command("SpellwandRefresh", function(opts)
  local bufnr = opts.bang and nil or 0
  require("spellwand").refresh(bufnr)
end, {
  bang = true,
  desc = "Refresh spellwand diagnostics (bang = all buffers)",
})
