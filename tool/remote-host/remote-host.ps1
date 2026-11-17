# Keeps the DSH Remote host online with no DSH window open.
#
# ds-harness-remote is a plugin of the DSH host process, so closing the DSH
# desktop window used to take the Host offline. This supervisor boots a second,
# headless profile (`dsh --profile web --no-open`) that owns the one Host
# identity; the desktop profile has its remote plugin disabled so the phone sees
# a single computer and two connections never replace each other.
#
# Usage:
#   powershell -File tool\remote-host\remote-host.ps1            # run in a console
#   powershell -File tool\remote-host\remote-host.ps1 -Once      # status check
#   powershell -File tool\remote-host\remote-host.ps1 -Doctor    # agent backends
#   install.ps1                                                  # run at sign-in, hidden

[CmdletBinding()]
param(
    # Profile that hosts the Remote plugin (see tool/remote-host/README.md).
    [string]$Profile = 'web',
    # How often to check that the child is alive.
    [int]$PollSeconds = 10,
    # Old behaviour: stop the headless host while the desktop app runs. Only
    # useful when the desktop profile still hosts (two identities on purpose).
    [switch]$StopWhenDesktopRuns,
    # Process names of the desktop app, used by -StopWhenDesktopRuns.
    [string]$DesktopProcesses = 'DSH NEXT,DSH NEXT Helper,dsh-desktop',
    # Print the current state and exit; never starts or stops anything.
    [switch]$Once,
    # Print the agent backends (ACP / Codex) the host should expose, then exit.
    [switch]$Doctor
)

$ErrorActionPreference = 'Stop'

$dshHome = Join-Path $env:USERPROFILE '.dsh'
$logDir = Join-Path $dshHome 'logs\remote-host'
$null = New-Item -ItemType Directory -Force -Path $logDir
$log = Join-Path $logDir 'supervisor.log'

function Write-Log([string]$message) {
    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'), $message
    # A supervisor that runs for months must not fill the disk with its own log.
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) {
        Move-Item -Force -Path $log -Destination "$log.1"
    }
    Add-Content -Path $log -Value $line -Encoding utf8
}

# The headless host logs every session event; without rotation this reaches
# gigabytes and a full disk breaks DSH's own SQLite writes.
function Rotate-Log([string]$path, [int64]$maxBytes = 20MB) {
    if ((Test-Path $path) -and ((Get-Item $path).Length -gt $maxBytes)) {
        Move-Item -Force -Path $path -Destination "$path.1"
    }
}

function Resolve-Dsh {
    $cmd = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $plain = Get-Command dsh -ErrorAction SilentlyContinue
    if ($plain) { return $plain.Source }
    # A scheduled task does not inherit the interactive PATH that `dsh` came
    # from, so look where the CLI installs live before giving up.
    $candidates = @(
        (Join-Path $env:USERPROFILE '.workbuddy\binaries\node\versions'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
        (Join-Path $env:ProgramFiles 'nodejs')
    )
    foreach ($root in $candidates) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter 'dsh.cmd' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    throw 'dsh was not found on PATH or in the usual install locations.'
}

function Test-DesktopRunning {
    foreach ($name in $DesktopProcesses.Split(',')) {
        $trimmed = $name.Trim()
        if (-not $trimmed) { continue }
        if (Get-Process -Name $trimmed -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# The headless host is a node process whose command line carries the profile.
function Get-HeadlessHost([string]$needle) {
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) } |
        Select-Object -First 1
}

# Logged before anything can throw: a scheduled task that dies silently is the
# hardest failure to diagnose.
Write-Log "supervisor invoked (profile=$Profile, once=$($Once.IsPresent))"

try {
    $dsh = Resolve-Dsh
} catch {
    Write-Log "fatal: $($_.Exception.Message)"
    throw
}
$needle = "--profile $Profile"

if ($Doctor) {
    $patch = Join-Path $dshHome (Join-Path 'profiles' (Join-Path $Profile 'cordis.patch.yml'))
    $plugin = Join-Path $dshHome (Join-Path 'profiles' (Join-Path $Profile 'node_modules\ds-harness-remote\package.json'))
    Write-Host "profile:  $Profile"
    if (Test-Path $plugin) {
        $version = (Get-Content $plugin -Raw | ConvertFrom-Json).version
        Write-Host "plugin:   ds-harness-remote $version"
    } else {
        Write-Host 'plugin:   not installed in this profile'
    }
    $hostProcess = Get-HeadlessHost $needle
    if ($hostProcess) {
        Write-Host "host:     running (pid $($hostProcess.ProcessId))"
    } else {
        Write-Host 'host:     not running'
    }
    Write-Host ''
    Write-Host 'backends (absolute paths are required: the plugin spawns without a shell):'
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($node) { Write-Host "  node          $($node.Source)" } else { Write-Host '  node          MISSING' }
    $claude = Get-Command claude-agent-acp -ErrorAction SilentlyContinue
    if ($claude) { Write-Host "  claude acp    $($claude.Source)" } else { Write-Host '  claude acp    MISSING' }
    $opencode = Get-Command opencode -ErrorAction SilentlyContinue
    if ($opencode) { Write-Host "  opencode      $($opencode.Source)" } else { Write-Host '  opencode      MISSING' }
    $codex = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($codex) { Write-Host "  codex         $($codex.Source)" } else { Write-Host '  codex         not on PATH (the profile pins an absolute binary)' }
    Write-Host ''
    if (Test-Path $patch) {
        Write-Host 'profile acp block:'
        $acpLines = Select-String -Path $patch -Pattern 'acp:|id: claude|id: opencode|command:|enabled:' |
            ForEach-Object { '  ' + $_.Line.TrimEnd() }
        if ($acpLines) { $acpLines | Select-Object -First 20 | ForEach-Object { Write-Host $_ } } else { Write-Host '  (none): run configure-acp.ps1' }
    } else {
        Write-Host "profile patch missing: $patch"
    }
    Write-Host ''
    Write-Host 'recent ACP / Codex log lines:'
    $logs = @(
        (Join-Path $logDir 'headless.out.log'),
        (Join-Path $logDir 'headless.err.log')
    ) | Where-Object { Test-Path $_ }
    if ($logs) {
        Select-String -Path $logs -Pattern 'ACP|Codex Remote|Codex App Server' |
            Select-Object -Last 10 | ForEach-Object { '  ' + $_.Line.TrimEnd() }
    } else {
        Write-Host '  (no host log yet)'
    }
    return
}

if ($Once) {
    $hostProcess = Get-HeadlessHost $needle
    $desktop = Test-DesktopRunning
    if ($hostProcess) {
        Write-Host "headless host: running (pid $($hostProcess.ProcessId))"
    } else {
        Write-Host 'headless host: not running'
    }
    if ($desktop) {
        Write-Host 'desktop app:   running (its remote plugin is disabled)'
    } else {
        Write-Host 'desktop app:   closed'
    }
    if (Test-Path $log) { Get-Content $log -Tail 3 }
    return
}

# One supervisor per session: a second one would start a second host. A
# session-local name, because creating a Global\ object needs a privilege a
# normal user does not have (that made the scheduled task fail with 0x1).
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'DshRemoteHostSupervisor')
    if (-not $mutex.WaitOne(0)) {
        Write-Log 'another supervisor already holds the mutex: exiting'
        return
    }
} catch {
    Write-Log "mutex unavailable ($($_.Exception.Message)); continuing without it"
    $mutex = $null
}

$child = $null
$childStarted = $null
$failures = 0
try {
    # A host left over from a previous run would fight this one for the identity.
    $stale = Get-HeadlessHost $needle
    if ($stale) {
        Stop-Process -Id $stale.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log "stopped a leftover headless host (pid $($stale.ProcessId))"
        Start-Sleep -Seconds 2
    }
    Write-Log "supervisor starting (profile=$Profile, dsh=$dsh, stopWhenDesktopRuns=$($StopWhenDesktopRuns.IsPresent))"

    while ($true) {
        if ($StopWhenDesktopRuns -and (Test-DesktopRunning)) {
            if ($child -and -not $child.HasExited) {
                Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
                Write-Log 'desktop app is running: stopped the headless host'
            }
            $child = $null
        }
        elseif (-not $child -or $child.HasExited) {
            if ($child -and $child.HasExited) {
                $ranFor = if ($childStarted) { (Get-Date) - $childStarted } else { [TimeSpan]::Zero }
                Write-Log "headless host exited (code $($child.ExitCode)) after $([int]$ranFor.TotalSeconds)s"
                # A run that lasted a while is healthy: reset the backoff, otherwise a
                # single crash would pin every later restart to the maximum delay.
                if ($ranFor.TotalSeconds -ge 60) { $failures = 0 } else { $failures++ }
            }
            $stdout = Join-Path $logDir 'headless.out.log'
            $stderr = Join-Path $logDir 'headless.err.log'
            Rotate-Log $stdout
            Rotate-Log $stderr
            # Port 0: the OS picks one, so a desktop build holding the default
            # cannot make this one fail to bind.
            $child = Start-Process -FilePath $dsh `
                -ArgumentList @('--profile', $Profile, '--no-open', '--host', '127.0.0.1', '--port', '0') `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
                -WindowStyle Hidden -PassThru
            $childStarted = Get-Date
            Write-Log "started the headless host (pid $($child.Id))"
            if ($failures -gt 0) {
                # 5 s, 10 s, 20 s, 40 s, then a minute: a broken profile must not
                # turn into a restart loop that floods the log.
                $backoff = [Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min($failures - 1, 4)))
                Start-Sleep -Seconds $backoff
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($child -and -not $child.HasExited) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        Write-Log 'supervisor stopping: stopped the headless host'
    }
    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
