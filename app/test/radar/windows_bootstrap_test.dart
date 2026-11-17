import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/remote/ssh/windows_bootstrap.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';

void main() {
  test('PowerShell encoding preserves Chinese, quotes, dollar signs and surrogate pairs', () {
    const script =
        r"Write-Output '养鱼😀 $value; ` "
        '"';
    final encoded = powerShellCommand(script).split(' ').last;
    final bytes = base64Decode(encoded);
    final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
    expect(String.fromCharCodes(units), script);
    expect(psQuote("a'b"), "'a''b'");
  });
  test('Windows config persists and changes transport identity', () {
    const linux = SshHostConfig(id: 'test', name: 'test', host: 'localhost', user: 'u');
    final windows = linux.copyWith(windows: true, workingDirectory: () => r'C:\工作');
    expect(SshHostConfig.fromJson(windows.toJson()), windows);
    expect(linux.connectionKey, isNot(windows.connectionKey));
    expect(SshConnectParams.of(windows, const SshSecrets(password: 'test')).windows, isTrue);
    expect(SshHostConfig.fromJson(linux.toJson())!.windows, isFalse);
  });
  test('PowerShell parses all generated scripts without executing them', () async {
    if (!Platform.isWindows) return;
    const scripts = WindowsBootstrapScripts('dsh web', r"C:\养鱼\O'Brien", 60);
    for (final script in [scripts.probe(), scripts.start(), scripts.stop()]) {
      final parser =
          r'$errors = $null; $tokens = $null; [void][Management.Automation.Language.Parser]::ParseInput('
          '${psQuote(script)}, [ref]\$tokens, [ref]\$errors); '
          r'if ($errors.Count) { $errors | ForEach-Object { $_.Message }; exit 1 }';
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        powerShellCommand(parser).split(' ').last,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
    }
  });
}
