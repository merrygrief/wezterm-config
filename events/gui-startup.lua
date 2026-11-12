local wezterm = require('wezterm')
local mux = wezterm.mux

local M = {}

M.setup = function()
   wezterm.on('gui-startup', function(cmd)
      -- local _, _, window = mux.spawn_window(cmd or {})
      -- window:gui_window():maximize()

      local screen = wezterm.gui.screens().main
      -- 估算窗口像素尺寸、
      local win_width = 1288
      local win_height = 875

      -- 计算居中坐标
      local x = (screen.width - win_width) / 2
      local y = (screen.height - win_height) / 2

      -- 通过 cmd 参数直接指定初始位置，避免窗口先出现在默认位置再跳过来
      local spawn_cmd = cmd or {}
      spawn_cmd.position = { x = x, y = y, origin = "MainScreen" }

      mux.spawn_window(spawn_cmd)
   end)
end

return M
