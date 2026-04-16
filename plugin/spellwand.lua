vim.api.nvim_create_user_command("SpellwandRefresh", function(opts)
  if opts.bang then
    require("spellwand").refresh(nil)
  else
    require("spellwand").refresh(0)
  end
end, {
  bang = true,
  desc = "Refresh spellwand diagnostics (bang = all buffers)",
})
