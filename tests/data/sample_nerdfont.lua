-- This file contains nerdfont icons to test spellwand diagnostic ranges
-- The nerdfont characters are in Unicode Private Use Area (PUA)

-- Status:  (check) and  (cross) icons mixed with text
-- These icons should trigger SpellBad diagnostics because they are not in dictionary

local status_icons = {
  success = "",
  failure = "",
  warning = "",
  info = "",
}

-- Function with typo near nerdfont icon: calcualte
local function calcualteScore()
  return 42
end

-- Variable with typo: messaeg
local messaeg = "Hello with icons:   "

-- Return a table with nerdfont filetype icons
return {
  lua = "",
  python = "",
  rust = "",
  javascript = "",
  go = "",
  calcualteScore = calcualteScore,
  messaeg = messaeg,
}
