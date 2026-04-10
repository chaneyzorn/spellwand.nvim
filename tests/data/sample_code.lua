-- This is a commet with a typo
-- Neovim is a powerfull editor

local function calcualteSum(a, b)
  -- Retruns the sume of two numbers
  return a + b
end

--- Recieve a message and proccess it
--- @param msg string The messaeg to handle
local function handleMsg(msg)
  print("Recieved: " .. msg)
end

-- Some variable names with typos
local userNamee = "John"
local isValidd = true
local configg = {}

return {
  calcualteSum = calcualteSum,
  handleMsg = handleMsg,
}
