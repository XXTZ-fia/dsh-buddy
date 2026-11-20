import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/relay/relay_backend.dart';
import '../../state/hosts_state.dart';
import '../remote/host_key_dialog.dart';
import '../theme/theme.dart';

/// 让远程插件脱离 DSH 桌面端常驻。
///
/// 插件是 DSH 的进程内插件，关掉桌面窗口就下线。这里给出一段自包含的命令：
/// 它创建/复用一个无头 `web` profile、把插件装进去、写好 `role: host` 与中继
/// 地址，并注册登录自启的计划任务。用户只需复制、在命令行里跑一次；App 负责
/// 在跑完后检测新主机并切换过去。
class KeepOnlinePage extends ConsumerStatefulWidget {
  const KeepOnlinePage({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const KeepOnlinePage());

  @override
  ConsumerState<KeepOnlinePage> createState() => _KeepOnlinePageState();
}

class _KeepOnlinePageState extends ConsumerState<KeepOnlinePage> {
  Set<String>? _initialIds;
  List<RelayHost> _found = const [];
  bool _checking = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _initialIds = ref.read(relayAccountProvider).value?.hosts.map((h) => h.id).toSet();
  }

  String get _command {
    final server = ref.read(relayServerProvider) ?? defaultRelayServer;
    return keepOnlineCommand.replaceAll('__SERVER__', server);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _command));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.commonCopied)));
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checked = false;
      _found = const [];
    });
    try {
      ref.invalidate(relayAccountProvider);
      final state = await ref.read(relayAccountProvider.future);
      final initial = _initialIds ?? const <String>{};
      final found = state.hosts.where((h) => !initial.contains(h.id)).toList();
      if (!mounted) return;
      setState(() {
        _found = found;
        _checked = true;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _switch(RelayHost host) async {
    final ok = await activateHost(context, ref, HostRef.relay(host.id, name: host.name));
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: Text(t.remoteKeepOnline)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            t.remoteKeepOnlineIntro,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6, color: muted),
          ),
          const SizedBox(height: 20),
          _Step(title: t.remoteKeepOnlineStep1, body: t.remoteKeepOnlineStep1Body),
          _Step(title: t.remoteKeepOnlineStep2, body: t.remoteKeepOnlineStep2Body),
          _CommandBlock(command: _command),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _copy,
              icon: const Icon(Icons.copy, size: 18),
              label: Text(t.remoteKeepOnlineCopy),
            ),
          ),
          const SizedBox(height: 24),
          _Step(title: t.remoteKeepOnlineStep3, body: t.remoteKeepOnlineStep3Body),
          const SizedBox(height: 16),
          _AutoStartNotice(title: t.remoteKeepOnlineAutoStartTitle, body: t.remoteKeepOnlineAutoStartBody),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
              label: Text(_checking ? t.remoteKeepOnlineChecking : t.remoteKeepOnlineCheck),
            ),
          ),
          if (_checked) ...[
            const SizedBox(height: 18),
            if (_found.isEmpty)
              Text(t.remoteKeepOnlineNone, style: theme.textTheme.bodySmall?.copyWith(color: muted))
            else ...[
              Text(t.remoteKeepOnlineFound, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final host in _found)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${host.name} · ${host.online ? t.radarConnected : t.radarNotConnected}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: () => unawaited(_switch(host)),
                        child: Text(t.remoteKeepOnlineSwitch),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _AutoStartNotice extends StatelessWidget {
  const _AutoStartNotice({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_repeat, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(body, style: theme.textTheme.bodySmall?.copyWith(height: 1.55)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.55,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: SelectableText(
        command,
        style: AppType.mono(size: 11.5, color: theme.colorScheme.onSurface, height: 1.5),
      ),
    );
  }
}

/// 自包含的 Windows 常驻命令；`__SERVER__` 由当前中继地址替换。
const keepOnlineCommand = r'''$ErrorActionPreference = 'Stop'
$dsh = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dsh) { $dsh = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
if (-not $dsh) { throw 'dsh not found on PATH' }
$root = Join-Path $env:USERPROFILE '.dsh'
$web = Join-Path $root 'profiles\web'
& $dsh --profile web --dump-config | Out-Null
$plugin = Join-Path $web 'node_modules\ds-harness-remote\package.json'
if (-not (Test-Path $plugin)) { & $dsh plugin --profile web add ds-harness-remote@0.6.5 }
$patch = Join-Path $web 'cordis.patch.yml'
$raw = if (Test-Path $patch) { Get-Content -Raw $patch } else { '' }
$raw = "$raw".Trim()
if (-not $raw.Contains('id: ds-harness-remote')) {
  $entry = @'
- id: ds-harness-remote
  config:
    enabled: true
    role: host
    serverUrl: __SERVER__
'@
  if ($raw -eq '[]' -or $raw -eq '') { Set-Content -Path $patch -Value $entry -Encoding utf8 }
  else { Add-Content -Path $patch -Value $entry -Encoding utf8 }
}
$log = Join-Path $root 'logs\remote-host'
New-Item -ItemType Directory -Force -Path $log | Out-Null
# npm 的 dsh.cmd 会另开一个 cmd 窗口；能直接找到 node 与 bin.js 就绕开它，
# 计划任务里只留一个隐藏的控制台进程。
$dshDir = Split-Path -Parent $dsh
$node = Join-Path $dshDir 'node.exe'
$bin = Join-Path $dshDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$run = if ((Test-Path $node) -and (Test-Path $bin)) {
  '& "' + $node + '" "' + $bin + '" --profile web --no-open'
} else {
  '& "' + $dsh + '" --profile web --no-open'
}
$runner = Join-Path $web 'keep-online.ps1'
# 先探测 3080：已有 DSH 时不再启动第二份，避免 EADDRINUSE 循环和日志刷屏。
$line = 'while ($true) { $up = $false; try { $c = New-Object Net.Sockets.TcpClient; $c.Connect(''127.0.0.1'', 3080); $up = $true; $c.Dispose() } catch {}; if (-not $up) { ' + $run + ' *>> "' + (Join-Path $log 'headless.log') + '" }; Start-Sleep -Seconds 10 }'
Set-Content -Path $runner -Value $line -Encoding utf8
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $runner + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'DSH Remote Host' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'DSH Remote Host'
Write-Host ''
Write-Host '已注册登录自启：DSH Remote Host' -ForegroundColor Green
Write-Host '可在“任务计划程序”确认状态与“登录时”触发器；结束该任务会导致手机远程下线。'
# 等主机打印出带一次令牌的地址，直接把配对页在默认浏览器里打开。否则普通
# 用户根本不知道该访问 http://127.0.0.1:3080/?token=... 这个地址。
$logFile = Join-Path $log 'headless.log'
for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Path $logFile) {
    $m = Select-String -Path $logFile -Pattern 'dsh web: (http://\S+)' | Select-Object -Last 1
    if ($m) { Start-Process $m.Matches[0].Groups[1].Value; break }
  }
}
'Keep-online host installed. The pairing page is opening in your browser.' ''';
