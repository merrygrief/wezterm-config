local wezterm = require('wezterm')

local M = {}

function M.run(window, pane)
   local function sanitize_output(text)
      return (tostring(text):gsub('[%c]', function(char)
         if char == '\n' or char == '\t' then
            return char
         end

         return ''
      end))
   end

   local function inject_output(text)
      return pcall(function()
         pane:inject_output(text)
      end)
   end

   local function show_message(message)
      local safe_message = sanitize_output(message)
      wezterm.log_info('[Upload] ' .. safe_message)
      inject_output('[Upload] ' .. safe_message .. '\r\n')
   end

   local info = pane:get_foreground_process_info()
   local pid = info and info.pid

   if not pid then
      show_message('Failed: cannot identify the current pane process.')
      return
   end

   inject_output('\r\n[Upload] Executing SCP upload...\r\n')

   local script = wezterm.home_dir
      .. '/.config/wezterm/bin/wezterm-scp-upload.ps1'
   local completion_token = string.format(
      '%s-%s-%s',
      tostring(pane:pane_id()),
      tostring(os.time()),
      tostring(math.random(100000, 999999))
   )
   local completion_prefix = '__WEZTERM_UPLOAD_DONE__'
      .. completion_token
      .. ':'

   local success, upload_pane_or_error = pcall(function()
      local mux_window = window:mux_window()
      local original_tab = mux_window:active_tab()
      local _, upload_pane = mux_window:spawn_tab({
         cwd = wezterm.home_dir,
         args = {
            'powershell.exe',
            '-NoLogo',
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'RemoteSigned',
            '-File',
            script,
            '-PaneProcessId',
            tostring(pid),
            '-CompletionToken',
            completion_token,
         },
      })

      original_tab:activate()
      return upload_pane
   end)

   if not success then
      show_message('Failed to start PowerShell: ' .. tostring(upload_pane_or_error))
      return
   end

   local upload_pane = upload_pane_or_error
   local emitted_lines = 0
   local finished = false

   local function write_mirrored(text)
      local ok = inject_output(text)

      if not ok then
         finished = true
      end

      return ok
   end

   local function pump_output()
      if finished then
         return
      end

      local read_ok, snapshot = pcall(function()
         local dimensions = upload_pane:get_dimensions()
         local line_count = dimensions.scrollback_rows
            + dimensions.viewport_rows

         return upload_pane:get_lines_as_text(line_count)
      end)

      if not read_ok then
         show_message('Upload process ended before reporting completion.')
         finished = true
         pcall(function()
            pane:send_text('\x03')
         end)
         return
      end

      snapshot = sanitize_output(snapshot)
         :gsub('[ \t]+\n', '\n')
         :gsub('[\n \t]+$', '')

      local lines = {}

      if snapshot ~= '' then
         for line in (snapshot .. '\n'):gmatch('(.-)\n') do
            table.insert(lines, line)
         end
      end

      local marker_index = nil

      for index, line in ipairs(lines) do
         if line:find(completion_prefix, 1, true) then
            marker_index = index
            break
         end
      end

      local visible_count = marker_index and marker_index - 1 or #lines
      local complete_count = marker_index and visible_count
         or math.max(visible_count - 1, 0)

      for index = emitted_lines + 1, complete_count do
         if not write_mirrored(lines[index] .. '\r\n') then
            return
         end
      end

      emitted_lines = math.max(emitted_lines, complete_count)

      if marker_index then
         finished = true
         pcall(function()
            pane:send_text('\x03')
         end)
         return
      end

      wezterm.time.call_after(0.1, pump_output)
   end

   wezterm.time.call_after(0.1, pump_output)
end

M.action = wezterm.action_callback(M.run)

return M
