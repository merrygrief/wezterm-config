local wezterm = require('wezterm')

local M = {}

M.setup = function()
   wezterm.on('mux-is-process-stateful', function()
      return false
   end)
end

return M
