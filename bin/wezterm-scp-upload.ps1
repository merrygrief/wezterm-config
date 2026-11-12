param(
    [int]$PaneProcessId = 0,
    [string]$HostTarget = "",
    [string]$RemoteDir = "",
    [string]$CompletionToken = ""
)

$ErrorActionPreference = "Stop"
$RemotePort = 22
$UploadSucceeded = $false

function Write-Step {
    param([string]$Message)

    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
}

Add-Type -AssemblyName System.Windows.Forms

# Reject unsupported clipboard content before doing any SSH work.
$files = @()
$folders = @()

if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
    $dropList = [System.Windows.Forms.Clipboard]::GetFileDropList()

    foreach ($item in $dropList) {
        if (Test-Path -LiteralPath $item -PathType Leaf) {
            $files += [string]$item
        }
        elseif (Test-Path -LiteralPath $item -PathType Container) {
            $folders += [string]$item
        }
    }
}

try {
    if ($folders.Count -gt 0) {
        throw "Folder upload is not supported. Copy files only."
    }

    if ($files.Count -eq 0) {
        throw "No copied files found in the clipboard. Copy one or more files in Explorer, then retry."
    }

    $Host.UI.RawUI.WindowTitle = 'upload'

    Write-Host ""
    Write-Host "========== WezTerm SCP Upload =========="

    $scp = (Get-Command scp.exe -ErrorAction Stop).Source
    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source

    # Identify the SSH process associated with the original pane.
    if ([string]::IsNullOrWhiteSpace($HostTarget)) {
        if ($PaneProcessId -le 0) {
            throw "Missing PaneProcessId; cannot identify the SSH session."
        }

        Write-Step "Detecting SSH session for pane PID $PaneProcessId ..."

        $all = @(Get-CimInstance Win32_Process)
        $byPid = @{}
        $children = @{}

        foreach ($process in $all) {
            $processId = [int]$process.ProcessId
            $byPid[$processId] = $process

            $parentId = [int]$process.ParentProcessId

            if (-not $children.ContainsKey($parentId)) {
                $children[$parentId] = @()
            }

            $children[$parentId] += $process
        }

        $related = @{}
        $currentId = $PaneProcessId

        # Include the pane process and its ancestors.
        while ($currentId -gt 0 -and $byPid.ContainsKey($currentId)) {
            $process = $byPid[$currentId]
            $related[[int]$process.ProcessId] = $process
            $currentId = [int]$process.ParentProcessId
        }

        # Include descendants of the pane process.
        $queue = [System.Collections.Queue]::new()
        $queue.Enqueue($PaneProcessId)

        while ($queue.Count -gt 0) {
            $parentId = [int]$queue.Dequeue()

            if ($children.ContainsKey($parentId)) {
                foreach ($child in $children[$parentId]) {
                    $childId = [int]$child.ProcessId

                    if (-not $related.ContainsKey($childId)) {
                        $related[$childId] = $child
                        $queue.Enqueue($childId)
                    }
                }
            }
        }

        $sshCandidates = @(
            $related.Values |
                Where-Object { $_.Name -ieq 'ssh.exe' }
        )

        if ($sshCandidates.Count -ne 1) {
            $details = ($sshCandidates | ForEach-Object {
                "PID=$($_.ProcessId); CommandLine=$($_.CommandLine)"
            }) -join "`n"

            throw @"
Cannot uniquely identify the SSH process for pane PID $PaneProcessId.
Number of SSH processes found: $($sshCandidates.Count)
$details
Check the pane PID and the SSH process tree.
"@
        }

        $sshProcess = $sshCandidates[0]
        $commandLine = [string]$sshProcess.CommandLine

        # Parse the usual user@host destination.
        $targetMatch = [regex]::Match(
            $commandLine,
            '(?:"(?<target>[^"]+@[^"]+)"|(?<!\S)(?<target>[^\s"]+@[^\s"]+))'
        )

        if (-not $targetMatch.Success) {
            throw "Cannot parse user@host from SSH command line: $commandLine"
        }

        $HostTarget = $targetMatch.Groups['target'].Value

        # Parse the SSH port if -p was specified.
        $portMatch = [regex]::Match(
            $commandLine,
            '(?i)(?:^|\s)-p\s+"?(?<port>\d+)'
        )

        if ($portMatch.Success) {
            $RemotePort = [int]$portMatch.Groups['port'].Value
        }

        Write-Step "Detected SSH PID: $($sshProcess.ProcessId)"

        # The pane's TCP client port uniquely identifies its session in the
        # remote SSH_CONNECTION environment variable.
        $tcpConn = Get-NetTCPConnection `
            -OwningProcess ([int]$sshProcess.ProcessId) `
            -State Established `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.RemotePort -eq $RemotePort } |
            Select-Object -First 1

        if (-not $tcpConn) {
            throw "Cannot determine the TCP port of the pane's SSH connection for PID $($sshProcess.ProcessId)."
        }

        $sshLocalPort = $tcpConn.LocalPort
    }

    if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
        Write-Step "Locating the pane's remote working directory ..."

        # Match the remote shell process via SSH_CONNECTION (client ip + pane's
        # client port), then read its /proc/<pid>/cwd.
        # No double quotes allowed: PowerShell 5.1 passes embedded " to native
        # commands unescaped, fragmenting the argument. Field comparison uses
        # positional parameters instead of case patterns (unquoted spaces end
        # a pattern token, and the ip follows '=' so *" $ip $port "* never
        # matches the real SSH_CONNECTION value).
        $remoteCwdQuery = @'
export LC_ALL=C
set -- $SSH_CLIENT
cip=$1
for p in /proc/[0-9]*; do
    e=$(tr '\0' '\n' < $p/environ 2>/dev/null | grep '^SSH_CONNECTION=') || continue
    set -- $e
    [ x$1 = xSSH_CONNECTION=$cip ] || continue
    case $2 in
        {PORT})
            ;;
        *)
            continue
            ;;
    esac
    exe=$(basename $(readlink $p/exe 2>/dev/null))
    case $exe in
        bash|sh|zsh|fish|ksh)
            readlink $p/cwd
            break
            ;;
    esac
done
'@

        # The here-string inherits the script file's line endings; the remote
        # shell only accepts LF.
        $remoteCwdQuery = $remoteCwdQuery.Replace("`r`n", "`n")
        $remoteCwdQuery = $remoteCwdQuery.Replace('{PORT}', [string]$sshLocalPort)

        $remoteDirQuery = & $ssh -p $RemotePort $HostTarget $remoteCwdQuery | Out-String
        $remoteDirQueryExit = $LASTEXITCODE

        if ($remoteDirQueryExit -ne 0) {
            throw "The remote working directory query failed. Check the SSH connection and remote shell."
        }

        $RemoteDir = ($remoteDirQuery -split "`r?`n")[0].Trim()

        if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
            throw "Cannot locate the pane's remote shell on the server; the working directory could not be determined."
        }
    }

    $RemoteDir = $RemoteDir.Trim()

    # Accept only absolute Linux paths.
    if ($RemoteDir -notmatch '^/' -or
        $RemoteDir -match '^/[A-Za-z]:/' -or
        $RemoteDir -match '^//[A-Za-z]:/' -or
        $RemoteDir -match '^file://' -or
        $RemoteDir -match '[\r\n]') {
        throw "Invalid remote directory: '$RemoteDir'. Expected a Linux absolute path such as /usr/local/workspace/jars."
    }

    if ($RemoteDir.Length -gt 1) {
        $RemoteDir = $RemoteDir.TrimEnd('/')
    }

    Write-Step "Found $($files.Count) file(s) to upload."
    Write-Step "Remote host: $HostTarget"
    Write-Step "Remote port: $RemotePort"
    Write-Step "Upload destination directory: $RemoteDir"

    # Create the remote destination directory.
    Write-Step "Connecting to the server and checking the destination ..."

    # Escape single quotes for the remote shell command.
    $quotedRemoteDir = $RemoteDir.Replace("'", "'\''")
    $remoteCommand = "mkdir -p '$quotedRemoteDir'"

    & $ssh -p $RemotePort $HostTarget $remoteCommand

    if ($LASTEXITCODE -ne 0) {
        throw "SSH connection failed or the remote directory could not be created: $RemoteDir"
    }

    $uploadedPaths = @()
    $index = 0

    foreach ($file in $files) {
        $index++

        $name = [IO.Path]::GetFileName($file)

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Cannot determine the file name: $file"
        }

        if ($RemoteDir -eq '/') {
            $remotePath = "/$name"
        }
        else {
            $remotePath = "$RemoteDir/$name"
        }

        Write-Host ""
        Write-Step "Uploading file $index of $($files.Count)"
        Write-Host "  Source:      $file"
        Write-Host "  Destination: ${HostTarget}:$remotePath"
        Write-Host "  SCP transfer progress follows:"

        & $scp -P $RemotePort -- $file "${HostTarget}:$remotePath"

        if ($LASTEXITCODE -ne 0) {
            throw "SCP upload failed for file: $file"
        }

        $uploadedPaths += $remotePath

        Write-Step "File $index of $($files.Count) uploaded successfully: ${HostTarget}:$remotePath"
    }

    Write-Host ""
    Write-Host "========== Upload Successful =========="
    Write-Host "Uploaded $($uploadedPaths.Count) file(s)."
    Write-Host "Uploaded remote paths:"

    foreach ($path in $uploadedPaths) {
        Write-Host "  ${HostTarget}:$path"
    }

    $UploadSucceeded = $true
}
catch {
    Write-Host ""
    Write-Host "========== UPLOAD FAILED ==========" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    $status = if ($UploadSucceeded) { "SUCCESS" } else { "FAILED" }

    if (-not [string]::IsNullOrWhiteSpace($CompletionToken)) {
        Write-Host ("__WEZTERM_UPLOAD_DONE__{0}:{1}" -f $CompletionToken, $status)
    }

    Start-Sleep -Milliseconds 750
}