import 'dart:convert';

/// PowerShell's -EncodedCommand is UTF-16LE, including non-ASCII paths.
String powerShellCommand(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes.addAll([unit & 255, unit >> 8]);
  }
  return 'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ${base64Encode(bytes)}';
}

String psQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// WMI creates the child outside OpenSSH's job, so disconnect doesn't kill it.
/// PID + start time prevent killing an unrelated process after PID reuse.
class WindowsBootstrapScripts {
  const WindowsBootstrapScripts(this.command, this.cwd, this.seconds);
  final String command;
  final String? cwd;
  final int seconds;

  String get prelude => r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$stateDir = Join-Path $env:USERPROFILE '.dsh-app-remote'
$recordPath = Join-Path $stateDir 'windows.json'
$record = $null
$owned = $false
if (Test-Path -LiteralPath $recordPath) {
  $record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
  $proc = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
  $owned = $proc -and $proc.StartTime.ToUniversalTime().Ticks.ToString() -eq $record.started
}
Write-Output ('DSHAPP home ' + $env:USERPROFILE)
''';

  String probe() =>
      '$prelude\n'
      'if (\$owned) {\n'
      ' Write-Output ("DSHAPP alive " + \$record.pid)\n'
      ' if (\$record.command -ceq ${psQuote(command)} -and \$record.cwd -ceq ${psQuote(cwd ?? '')}) { Write-Output "DSHAPP samecmd" }\n'
      r''' if (Test-Path -LiteralPath (Join-Path $stateDir 'web.log')) {
  Get-Content -LiteralPath (Join-Path $stateDir 'web.log') | Select-String 'https?://\S*[?&]token=' | Select-Object -Last 1 | ForEach-Object { Write-Output ('DSHAPP url ' + $_.Line) }
 }
}
''';

  String stop() => '$prelude\n${_stop()}';
  String _stop() => r'''
if ($owned) {
  & taskkill.exe /PID $record.pid /T /F | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'managed process could not be stopped' }
}
if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath }
''';

  String start() {
    final inner = StringBuffer()
      ..writeln(r"$ErrorActionPreference = 'Stop'")
      ..writeln(r"$env:NO_COLOR = '1'")
      ..writeln(r"[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)");
    if (cwd != null && cwd!.trim().isNotEmpty) inner.writeln('Set-Location -LiteralPath ${psQuote(cwd!)}');
    final launch = command == 'dsh web' ? 'dsh.cmd web' : command;
    inner.writeln(
      '$launch --host 127.0.0.1 --port 0 --no-open *> (Join-Path \$env:USERPROFILE ".dsh-app-remote/web.log")',
    );
    return '$prelude\n'
        r'''New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$launchLock = [IO.File]::Open((Join-Path $stateDir 'launch.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $stateDir /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'cannot secure runtime directory' }
'''
        '${_stop()}\n'
        r"Set-Content -LiteralPath (Join-Path $stateDir 'web.log') -Value ''"
        '\n'
        '\$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ${psQuote(powerShellCommand(inner.toString()))} }\n'
        r'''if ($created.ReturnValue -ne 0) { throw 'detached process creation failed' }
$proc = Get-Process -Id $created.ProcessId
'''
        '@{pid=\$proc.Id; started=\$proc.StartTime.ToUniversalTime().Ticks.ToString(); command=${psQuote(command)}; cwd=${psQuote(cwd ?? '')}} | ConvertTo-Json | Set-Content -LiteralPath \$recordPath\n'
        r"Write-Output ('DSHAPP started ' + $proc.Id)"
        '\n'
        'for (\$attempt=0; \$attempt -lt $seconds; \$attempt++) {\n'
        r''' $line = Get-Content -LiteralPath (Join-Path $stateDir 'web.log') | Select-String 'https?://\S*[?&]token=' | Select-Object -Last 1
 if ($line) { Write-Output ('DSHAPP url ' + $line.Line); exit 0 }
 if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { Write-Output 'DSHAPP exited'; exit 1 }
 Start-Sleep -Seconds 1
}
Write-Output 'DSHAPP timeout'
exit 1
''';
  }
}
