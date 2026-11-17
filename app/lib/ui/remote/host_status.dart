import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/status_dot.dart';
import '../engine/engine_status.dart';
import '../theme/app_icons.dart';

/// Dot + words for a host's state. Colour is never the only signal.
class HostStatusView {
  const HostStatusView(this.tone, this.label);

  final StatusTone tone;
  final String label;

  static HostStatusView ofLink(HostLinkStatus status) => switch (status.phase) {
    HostLinkPhase.idle => HostStatusView(StatusTone.idle, appL10n.commonNotConnected),
    HostLinkPhase.connecting => HostStatusView(
      StatusTone.busy,
      status.step == null ? appL10n.remoteConnecting : '${status.step!.label}…',
    ),
    HostLinkPhase.connected => HostStatusView(StatusTone.ok, appL10n.remoteConnected),
    HostLinkPhase.reconnecting => HostStatusView(StatusTone.warn, appL10n.remoteReconnecting),
    HostLinkPhase.failed => HostStatusView(StatusTone.error, appL10n.commonConnectionFailed),
  };

  static HostStatusView ofRelayHost(RelayHost host) => host.online
      ? HostStatusView(StatusTone.ok, appL10n.remoteOnline)
      : HostStatusView(StatusTone.idle, appL10n.remoteOffline);
}

/// The state of the tunnel that actually carries frames under [host].
///
/// The link's own status is not enough: it lagged a whole night behind a dead
/// tunnel (the drawer kept saying 已连接 while the chat showed 对话同步中断)
/// and it also read 未连接 while the connection was alive. The mux owns the
/// socket, so its state is the one to show.
final hostMuxStateProvider = StreamProvider.autoDispose.family<DshConnectionState?, HostRef>((ref, host) {
  if (host.isLocal) return Stream<DshConnectionState?>.value(null);
  final client = ref.watch(remoteConnectionProvider(host)).value?.client;
  if (client == null) return Stream<DshConnectionState?>.value(null);
  return _muxStates(client.mux);
});

Stream<DshConnectionState?> _muxStates(DshMux mux) async* {
  yield mux.state;
  yield* mux.states;
}

/// Live status of [host]: the engine for 本机, the tunnel for remote hosts.
HostStatusView watchHostStatus(WidgetRef ref, HostRef host) {
  if (host.isLocal) {
    final view = EngineStatusView.of(ref.watch(localRuntimeProvider));
    return HostStatusView(view.tone, view.label);
  }
  final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
  final mux = ref.watch(hostMuxStateProvider(host)).value;
  if (mux != null) {
    if (mux == DshConnectionState.connected && status.phase != HostLinkPhase.connected) {
      // The link lost track of a live tunnel (or is a generation behind).
      return HostStatusView(StatusTone.ok, appL10n.remoteConnected);
    }
    if (status.phase == HostLinkPhase.connected &&
        mux != DshConnectionState.connected &&
        mux != DshConnectionState.connecting) {
      // The socket is gone even though the link has not noticed yet.
      return switch (mux) {
        DshConnectionState.reconnecting => HostStatusView(StatusTone.warn, appL10n.remoteReconnecting),
        _ => HostStatusView(StatusTone.idle, appL10n.commonNotConnected),
      };
    }
  }
  return HostStatusView.ofLink(status);
}

IconData hostKindIcon(HostKind kind) => switch (kind) {
  HostKind.local => AppIcons.thisPhone,
  HostKind.ssh => AppIcons.sshHost,
  HostKind.relay => AppIcons.computer,
};

/// Identity tint per kind (one of the 8 fixed pairs), so rows read as a set.
int hostKindTint(HostKind kind) => switch (kind) {
  HostKind.local => 0,
  HostKind.ssh => 6,
  HostKind.relay => 1,
};
