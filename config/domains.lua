local platform = require('utils.platform')

---@type Config
local options = {
   -- ref: https://wezfurlong.org/wezterm/config/lua/SshDomain.html
   ssh_domains = {},

   -- ref: https://wezfurlong.org/wezterm/multiplexing.html#unix-domains
   unix_domains = {},

   -- ref: https://wezfurlong.org/wezterm/config/lua/WslDomain.html
   wsl_domains = {},
}

if platform.is_win then
   options.ssh_domains = {
      {
         name = 'ssh:wsl',
         username = 'Administrator',
         remote_address = 'localhost',
         multiplexing = 'None',
         default_prog = { 'fish', '-l' },
         assume_shell = 'Posix',
      },
   }

   options.wsl_domains = {
      {
         name = 'wsl:openSUSE-fish',
         distribution = 'openSUSE-Tumbleweed',
         username = 'root',
         default_cwd = '/root',
         default_prog = { 'fish', '-l' },
      },
      {
         name = 'wsl:openSUSE-bash',
         distribution = 'openSUSE-Tumbleweed',
         username = 'root',
         default_cwd = '/root',
         default_prog = { 'bash', '-l' },
      },
   }
end

return options
