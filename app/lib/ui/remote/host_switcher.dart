import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../common/status_chip.dart';
import '../companion/companion_page.dart';
import '../onboarding/local_install.dart';
import '../settings/settings_widgets.dart';
import '../terminal/cli_presets.dart';
import '../terminal/terminal_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'host_key_dialog.dart';
import 'host_status.dart';

/// Drawer-header chip: `● 本机 · 运行中 ⌄` / `● 电脑 · 已连接 ⌄`. Opens the
/// host sheet.
class HostChip extends ConsumerWidget {
  const HostChip({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final host = ref.watch(activeHostProvider);
    final name = ref.watch(hostNameProvider(host)) ?? (host.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);
    final view = watchHostStatus(ref, host);
    return Semantics(
      button: true,
      onTap: onTap,
      label: l10n.remoteHostSwitcherSemantics(name, view.label),
      child: ExcludeSemantics(
        child: GlassSurface(
          tier: GlassTier.pill,
          stadium: true,
          onTap: onTap,
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedStatusDot(tone: view.tone, size: 7),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '$name · ${view.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ),
              const SizedBox(width: 2),
              Icon(AppIcons.dropdown, size: 16, color: DshColors.of(context).textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// "切换主机": 本机, saved SSH hosts and the DSH Remote account's hosts, each
/// with its state; picking one makes it active. [onManage] opens the remote
/// page.
Future<void> showHostSheet(BuildContext context, {required VoidCallback onManage}) {
  return showAppSheet<void>(context, isScrollControlled: true, builder: (sheet) => HostSheet(onManage: onManage));
}

class HostSheet extends ConsumerWidget {
  const HostSheet({super.key, required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final active = ref.watch(activeHostProvider);
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh));
    final account = ref.watch(relayAccountProvider).value;
    final relayHosts = account?.signedIn == true ? account!.hosts : const <RelayHost>[];

    Future<void> pick(HostRef host) async {
      if (host == active) {
        Navigator.of(context).pop();
        return;
      }
      final navigator = Navigator.of(context);
      final ok = await activateHost(context, ref, host);
      if (ok && navigator.mounted) navigator.pop();
    }

    /// Waits for the rebuilt client after a host or carrier switch.
    Future<DshClient?> waitForClient() async {
      for (var attempt = 0; attempt < 40; attempt++) {
        final client = ref.read(activeConnectionProvider).value?.client;
        if (client != null) return client;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      return null;
    }

    /// "Terminal · <tool>": DSH sessions plus a PTY running that tool's CLI.
    ///
    /// The CLI rows are not a chat backend; they always drive the computer as
    /// DSH, then open a terminal with the tool's command typed in.
    Future<void> openCli(HostRef host, AgentBackend backend) async {
      final navigator = Navigator.of(context);
      final tool = backend.tool;
      if (tool == null) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      void failed() {
        messenger?.showSnackBar(SnackBar(content: Text(l10n.stateTerminalStartFailed)));
      }

      try {
        if (host != active || ref.read(agentBackendProvider(host)).kind != AgentKind.dsh) {
          await ref.read(agentBackendProvider(host).notifier).set(const AgentBackend.dsh());
          if (!context.mounted) return;
          if (host != active) await activateHost(context, ref, host);
        }
        // The sheet's own context dies with the pop; the navigator and the
        // scaffold messenger outlive it, so keep pushing through them.
        navigator.pop();
        final client = await waitForClient();
        if (client == null) {
          failed();
          return;
        }
        final created = await client.createSession();
        if (!navigator.mounted) return;
        await navigator.push(
          TerminalPage.route(created.sessionId, initialCommand: cliCommandFor(tool)),
        );
      } on Object {
        // A CLI row is a convenience: a refused session or an offline Host must
        // not surface as an unhandled async error behind a closed sheet.
        failed();
      }
    }

    /// One computer, one checked software. The choice belongs to the computer,
    /// not to the session: every backend drives the same tunnel.
    Future<void> choose(HostRef host, AgentBackend backend) async {
      final navigator = Navigator.of(context);
      final notifier = ref.read(agentBackendProvider(host).notifier);
      final current = ref.read(agentBackendProvider(host));
      if (backend.kind == AgentKind.cli) {
        await openCli(host, backend);
        return;
      }
      if (host == active && current == backend) {
        navigator.pop();
        return;
      }
      // The carrier under every screen is about to be swapped: leave the open
      // conversation first, exactly like a host switch does.
      ref.read(currentSessionProvider.notifier).select(null);
      if (host != active) {
        await notifier.set(backend);
        if (!context.mounted) return;
        final ok = await activateHost(context, ref, host);
        if (ok && navigator.mounted) navigator.pop();
        return;
      }
      navigator.pop();
      // Let the sheet finish closing before the client is rebuilt: rebuilding
      // during the route transition reparents widgets and trips a Flutter
      // assertion.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 350), () => notifier.set(backend)),
      );
    }

    // 本机 without its runtime: the row installs it, and switches to it once
    // installed (leaving the install page keeps the current host).
    final localMissing = ref.watch(localRuntimeProvider.select((s) => s.status.runtimeMissing));
    void installLocal() {
      final navigator = Navigator.of(context);
      navigator.pop();
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const LocalInstallPage(useWhenDone: true))));
    }

    const groupMargin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.remoteSwitchHost),
              SheetGroup(
                margin: groupMargin,
                children: [
                  _HostRow(
                    host: HostRef.local,
                    title: l10n.commonThisPhone,
                    subtitle: l10n.remoteThisPhoneDsh,
                    active: active.isLocal,
                    onTap: localMissing ? installLocal : () => pick(HostRef.local),
                  ),
                  for (final h in ssh)
                    _HostRow(
                      host: HostRef.ssh(h.id),
                      title: h.name,
                      subtitle: 'SSH · ${h.address}',
                      active: active == HostRef.ssh(h.id),
                      onTap: () => pick(HostRef.ssh(h.id)),
                    ),
                ],
              ),
              // Each remote computer is its own group: two software choices,
              // with a check on the one currently driven.
              for (final h in relayHosts)
                _RelayHostGroup(
                  host: HostRef.relay(h.id, name: h.name),
                  relay: h,
                  activeHost: active,
                  onChoose: choose,
                ),
              if (relayHosts.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                  child: Text(
                    l10n.remoteRelaySwitchWarning,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                  ),
                ),
              SheetGroup(
                margin: groupMargin,
                children: [
                  SettingsTile(
                    icon: AppIcons.pet,
                    tinted: false,
                    title: l10n.companionTitle,
                    subtitle: l10n.companionEntrySubtitle,
                    onTap: () {
                      final navigator = Navigator.of(context);
                      navigator.pop();
                      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const CompanionPage())));
                    },
                  ),
                  SettingsTile(
                    icon: ssh.isEmpty && relayHosts.isEmpty ? AppIcons.add : AppIcons.configure,
                    tinted: false,
                    title: ssh.isEmpty && relayHosts.isEmpty ? l10n.remoteConnectComputer : l10n.remoteManageHosts,
                    subtitle: ssh.isEmpty && relayHosts.isEmpty ? l10n.remoteConnectionMethods : null,
                    onTap: () {
                      Navigator.of(context).pop();
                      onManage();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// One remote computer: its own card, with the two pieces of software that can
/// be driven on it. Exactly one has a check when this computer is active.
class _RelayHostGroup extends ConsumerWidget {
  const _RelayHostGroup({
    required this.host,
    required this.relay,
    required this.activeHost,
    required this.onChoose,
  });

  final HostRef host;
  final RelayHost relay;
  final HostRef activeHost;
  final Future<void> Function(HostRef host, AgentBackend backend) onChoose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final isActive = activeHost == host;
    final selected = ref.watch(agentBackendProvider(host));
    final backends = ref.watch(agentBackendsProvider(host));
    // Terminals are not a chat backend: they belong in one compact row of
    // pills, not four full-width rows that bury the real choices.
    final chatBackends = [for (final backend in backends) if (backend.kind != AgentKind.cli) backend];
    final cliBackends = [for (final backend in backends) if (backend.kind == AgentKind.cli) backend];
    final view = isActive ? watchHostStatus(ref, host) : HostStatusView.ofRelayHost(relay);
    final diagnostics = isActive ? ref.watch(remoteDiagnosticsProvider(host)) : null;
    return SheetGroup(
      margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
      children: [
        SettingsTile(
          key: ValueKey('host-computer-${host.id}'),
          icon: hostKindIcon(HostKind.relay),
          tinted: false,
          title: relay.name,
          // Version only: the link facts live on their own line below, so the
          // subtitle never wraps into a dangling "· 建连 5.2s".
          subtitle: relay.subtitle,
          // Tapping the computer's name connects with the software it last used.
          onTap: () => unawaited(onChoose(host, selected)),
          value: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedStatusDot(tone: view.tone, size: 7),
              const SizedBox(width: 6),
              Text(view.label),
            ],
          ),
          trailing: const SizedBox(width: 20),
        ),
        if (diagnostics != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset + 34, 2, SettingsMetrics.inset, 4),
            child: Row(
              children: [
                Icon(AppIcons.link, size: 13, color: DshColors.of(context).textTertiary),
                const SizedBox(width: 5),
                Text(
                  _linkLine(l10n, diagnostics),
                  key: ValueKey('host-link-${host.id}'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                ),
              ],
            ),
          ),
        for (final backend in chatBackends)
          _SoftwareRow(
            key: ValueKey('host-software-${backend.id}-${host.id}'),
            icon: _agentIcon(backend),
            title: _agentTitle(l10n, backend),
            selected: isActive && selected == backend,
            onTap: () => unawaited(onChoose(host, backend)),
          ),
        if (cliBackends.isNotEmpty)
          _CliStrip(
            hostId: host.id,
            backends: cliBackends,
            onChoose: (backend) => unawaited(onChoose(host, backend)),
          ),
        if (!relay.online)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.info, size: 14, color: DshColors.of(context).warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.remoteHostOfflineHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: DshColors.of(context).textTertiary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}


String _linkLine(dynamic t, RemoteNetworkDiagnostics diagnostics) {
  final mode = switch (diagnostics.transportMode) {
    RemoteTransportMode.lan || RemoteTransportMode.p2p => t.remoteLinkDirect as String,
    RemoteTransportMode.turn => t.remoteLinkTurn as String,
    RemoteTransportMode.relay => t.remoteLinkRelay as String,
    null => t.remoteLinkUnknown as String,
  };
  final ms = diagnostics.connectionDuration?.inMilliseconds;
  return ms == null ? mode : '$mode · ${t.remoteLinkSetup} ${ms}ms';
}

/// One software choice under a computer: name only, one line, check when it is
/// the one being driven.
class _SoftwareRow extends StatelessWidget {
  const _SoftwareRow({
    super.key,
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    inMutuallyExclusiveGroup: true,
    child: Padding(
      padding: const EdgeInsets.only(left: 20),
      child: SettingsTile(
        icon: icon,
        tinted: false,
        title: title,
        onTap: onTap,
        trailing: selected
            ? Icon(AppIcons.selected, size: 20, color: Theme.of(context).colorScheme.primary)
            : const SizedBox(width: 20),
      ),
    ),
  );
}

/// The CLIs this computer can run in a terminal: one row of pills.
class _CliStrip extends StatelessWidget {
  const _CliStrip({required this.hostId, required this.backends, required this.onChoose});

  final String hostId;
  final List<AgentBackend> backends;
  final ValueChanged<AgentBackend> onChoose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    return SizedBox(
      // SheetGroup centres its children; a strip must stretch to keep its
      // label and pills aligned with the rows above.
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset + 22, 2, SettingsMetrics.inset, 10),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.terminal, size: 15, color: colors.textTertiary),
              const SizedBox(width: 6),
              Text(l10n.remoteCliSection, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final backend in backends)
                _CliPill(
                  key: ValueKey('host-software-${backend.id}-$hostId'),
                  label: backend.tool ?? backend.label,
                  onTap: () => onChoose(backend),
                ),
            ],
          ),
          ],
        ),
      ),
    );
  }
}

class _CliPill extends StatelessWidget {
  const _CliPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(999);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: radius,
          ),
          child: Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

class _HostRow extends ConsumerWidget {
  const _HostRow({
    required this.host,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  final HostRef host;
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Live state for 本机 and the active host; nothing for idle SSH hosts
    // (connecting just to show a dot would cost a login).
    final view = host.isLocal || active ? watchHostStatus(ref, host) : null;
    return Semantics(
      key: ValueKey('host-row-${host.kind.name}-${host.id}'),
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(host.kind),
        tinted: false,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
        value: view == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedStatusDot(tone: view.tone, size: 7),
                  const SizedBox(width: 6),
                  Text(view.label),
                ],
              ),
        trailing: active ? Icon(AppIcons.selected, size: 20, color: scheme.primary) : const SizedBox(width: 20),
      ),
    );
  }
}

IconData _agentIcon(AgentBackend backend) => switch (backend.kind) {
  AgentKind.dsh => AppIcons.pet,
  AgentKind.codex => AppIcons.code,
  AgentKind.claude => AppIcons.chat,
  AgentKind.opencode => AppIcons.agentLoop,
  AgentKind.cursor => AppIcons.starProject,
  AgentKind.cli => AppIcons.terminal,
};

String _agentTitle(L10n l10n, AgentBackend backend) => switch (backend.kind) {
  AgentKind.dsh => l10n.remoteSoftwareDsh,
  AgentKind.codex => l10n.remoteSoftwareCodex,
  AgentKind.claude => l10n.remoteSoftwareClaude,
  AgentKind.opencode => l10n.remoteSoftwareOpencode,
  AgentKind.cursor => backend.label,
  AgentKind.cli => l10n.remoteSoftwareCli(backend.tool ?? ''),
};

