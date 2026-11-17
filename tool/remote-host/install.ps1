# Registers the Remote host supervisor to start at sign-in, hidden.
#
#   powershell -ExecutionPolicy Bypass -File tool\remote-host\install.ps1
#   powershell -ExecutionPolicy Bypass -File tool\remote-host\install.ps1 -Remove
#
# The task runs as the signed-in user (it needs your DSH identity and Codex
# login). It keeps running after the desktop app is closed, which is the point.

[CmdletBinding()]
param(
    [string]$TaskName = 'DSH Remote Host',
    [string]$Profile = 'web',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'remote-host.ps1'
$configureAcp = Join-Path $PSScriptRoot 'configure-acp.ps1'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    } else {
        Write-Host "No scheduled task named '$TaskName'."
    }
    return
}

if (-not (Test-Path $script)) { throw "remote-host.ps1 not found next to install.ps1." }

# ACP backends need absolute paths (the plugin spawns without a shell), so the
# installer regenerates that block instead of asking the user to hand-edit YAML.
if (Test-Path $configureAcp) {
    try {
        & $configureAcp -Profile $Profile
    } catch {
        Write-Warning "ACP configuration skipped: $($_.Exception.Message)"
    }
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Profile {1}' -f $script, $Profile)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description 'Keeps the DSH Remote host online when the DSH desktop app is closed.' -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Registered and started '$TaskName'."
Write-Host "Supervisor log: $env:USERPROFILE\.dsh\logs\remote-host\supervisor.log"
Write-Host "Remove it with: powershell -File `"$PSCommandPath`" -Remove"
