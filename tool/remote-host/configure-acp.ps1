# Writes the ACP backend block into the remote host's DSH profile.
#
# Why this exists: the plugin spawns backend executables with
# `spawn(binary, args, { env })` — no shell. On Windows a `.cmd` shim or the
# extension-less sh script cannot be executed that way, and the failure is only
# logged at debug level; the whole ACP domain then reports
# `ACP Remote domain unavailable`. Absolute paths are the only reliable form:
#   claude  -> <node.exe> <claude-agent-acp>/dist/index.js
#   opencode-> <opencode.exe> acp
#
# The script rewrites only the `ds-harness-remote` entry of the profile patch;
# every other entry is preserved byte for byte, and a timestamped backup is
# written first.
#
# Usage:
#   powershell -File code\tool\remote-host\configure-acp.ps1
#   powershell -File code\tool\remote-host\configure-acp.ps1 -Profile web -WhatIf

[CmdletBinding()]
param(
    [string]$Profile = 'web',
    # Keep the current serverUrl; only the acp block is regenerated.
    [string]$ServerUrl,
    # Turn specific backends off (comma separated): claude,opencode
    [string[]]$Disable = @(),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Find-CommandPath([string]$name) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Find-Node {
    $node = Find-CommandPath 'node.exe'
    if ($node) { return $node }
    $candidates = @(
        (Join-Path $env:USERPROFILE '.workbuddy\binaries\node\versions'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
        (Join-Path $env:ProgramFiles 'nodejs')
    )
    foreach ($root in $candidates) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter 'node.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Find-ClaudeAcpEntry([string]$nodePath) {
    $roots = @()
    $npm = Find-CommandPath 'npm.cmd'
    if ($npm) {
        try {
            $prefix = (& $npm config get prefix 2>$null | Select-Object -First 1).Trim()
            if ($prefix) { $roots += (Join-Path $prefix 'node_modules') }
        } catch {}
    }
    if ($nodePath) { $roots += (Join-Path (Split-Path $nodePath -Parent) 'node_modules') }
    $roots += (Join-Path $env:APPDATA 'npm\node_modules')
    foreach ($root in $roots) {
        $entry = Join-Path $root '@agentclientprotocol\claude-agent-acp\dist\index.js'
        if (Test-Path $entry) { return $entry }
    }
    return $null
}

function Find-Opencode([string]$nodePath) {
    $shim = Find-CommandPath 'opencode.exe'
    if ($shim) { return $shim }
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\node_modules\@opencode\cli\bin\opencode.exe'),
        (Join-Path $env:USERPROFILE '.opencode\bin\opencode.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\opencode\opencode.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return (Find-CommandPath 'opencode.cmd')
}

function Find-Codex {
    $codex = Find-CommandPath 'codex.exe'
    if ($codex) { return $codex }
    $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path $root) {
        $found = Get-ChildItem -Path $root -Filter 'codex.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

$dshHome = Join-Path $env:USERPROFILE '.dsh'
$patchPath = Join-Path $dshHome (Join-Path 'profiles' (Join-Path $Profile 'cordis.patch.yml'))
if (-not (Test-Path $patchPath)) {
    throw "Profile patch not found: $patchPath (is DSH installed and the profile created?)"
}

$nodePath = Find-Node
$claudeEntry = Find-ClaudeAcpEntry $nodePath
$opencodePath = Find-Opencode $nodePath
$codexPath = Find-Codex

# Read explicitly as UTF-8 and split on either newline: the 5.1 host mis-splits
# a BOM-less UTF-8 file that only uses LF.
$text = [System.IO.File]::ReadAllText($patchPath)
$lines = $text -split "`r?`n"
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*-\s+id:\s*ds-harness-remote\s*$') { $start = $i; break }
}
if ($start -lt 0) {
    throw "No 'ds-harness-remote' entry in $patchPath. Install the plugin first."
}
$end = $lines.Count
for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^-\s') { $end = $i; break }
}

if (-not $ServerUrl) {
    $serverLine = $lines[$start..($end - 1)] | Where-Object { $_ -match '^\s+serverUrl:\s*(\S+)' } | Select-Object -First 1
    if ($serverLine -match '^\s+serverUrl:\s*(\S+)') { $ServerUrl = $Matches[1] }
}

$yamlServer = if ($ServerUrl) { "    serverUrl: $ServerUrl`n" } else { '' }
$yamlCodex = ''
if ($codexPath) {
    $yamlCodex = "    codex:`n      enabled: true`n      binary: '$($codexPath -replace '\\', '/')'`n"
}

$backendLines = @()
if ($claudeEntry -and $nodePath -and ($Disable -notcontains 'claude')) {
    $backendLines += @(
        '        - id: claude',
        '          enabled: true',
        "          command: '$($nodePath -replace '\\', '/')'",
        '          args:',
        "            - '$($claudeEntry -replace '\\', '/')'"
    )
}
if ($opencodePath -and ($Disable -notcontains 'opencode')) {
    $backendLines += @(
        '        - id: opencode',
        '          enabled: true',
        "          command: '$($opencodePath -replace '\\', '/')'",
        "          args: ['acp']"
    )
}
foreach ($id in @('pi', 'cursor', 'antigravity', 'hermes')) {
    $backendLines += @("        - id: $id", '          enabled: false')
}

if ($backendLines.Count -eq 0) {
    Write-Warning 'Neither claude-agent-acp nor opencode was found; writing acp.enabled: false.'
}

$block = @()
$block += '- id: ds-harness-remote'
$block += '  config:'
$block += '    enabled: true'
$block += '    role: host'
if ($yamlServer) { $block += ($yamlServer -split "`n" | Where-Object { $_ -ne '' }) }
$block += '    terminal:'
$block += '      enabled: true'
if ($yamlCodex) { $block += ($yamlCodex -split "`n" | Where-Object { $_ -ne '' }) }
$block += '    acp:'
$block += ("      enabled: " + $(if ($backendLines.Count -gt 0) { 'true' } else { 'false' }))
if ($backendLines.Count -gt 0) {
    $block += '      backends:'
    $block += $backendLines
}

$next = @()
if ($start -gt 0) { $next += $lines[0..($start - 1)] }
$next += $block
if ($end -lt $lines.Count) { $next += $lines[$end..($lines.Count - 1)] }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$patchPath.bak.$stamp"
# Two runs in the same second (or at the same time on different days) must not
# overwrite the previous backup.
$suffix = 1
while (Test-Path $backup) {
    $backup = "$patchPath.bak.$stamp-$suffix"
    $suffix++
}
if ($WhatIf) {
    Write-Host "--- would write to $patchPath (backup $backup) ---"
    $next | ForEach-Object { Write-Host $_ }
    return
}
Copy-Item -Path $patchPath -Destination $backup
[System.IO.File]::WriteAllText(
    $patchPath,
    (($next -join "`r`n") + "`r`n"),
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host "wrote $patchPath (backup $backup)"
Write-Host ("claude:   " + $(if ($claudeEntry) { $claudeEntry } else { 'not found' }))
Write-Host ("opencode: " + $(if ($opencodePath) { $opencodePath } else { 'not found' }))
Write-Host ("codex:    " + $(if ($codexPath) { $codexPath } else { 'not found' }))
Write-Host 'Restart the host: Stop the node process running --profile web, then Start-ScheduledTask -TaskName "DSH Remote Host".'
