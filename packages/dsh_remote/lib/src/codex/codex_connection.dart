// Bridges one remote connection into a second, synthetic `DshClient` speaking
// the Codex dialect — the same Host, the same Noise tunnel, no extra session.
//
// The Server allows one Host connection per client device, so a Codex host must
// reuse the live connection instead of dialing again: [codexDshClient] wraps
// the tunnel's RPC client and returns a `DshClient` whose carrier owns nothing
// on the wire.
library;

import 'package:dsh_client/dsh_client.dart';

import '../agent/agent_carrier.dart';
import '../carrier/tunnel_carrier.dart';
import 'codex_carrier.dart';
import 'codex_client.dart';
import 'codex_transport.dart';
import 'codex_wire.dart';

/// The Codex domain of this connection, or `null` when the carrier is local or
/// the Host does not declare `codex.appserver.v1`.
CodexClient? codexClientOf(DshClient client) {
  final session = client.remoteCarrier?.session;
  if (session == null) return null;
  final capabilities = session.capabilities.toSet();
  if (!capabilities.contains(codexCapability)) return null;
  return CodexClient(RemoteCodexTransport(session.rpc, capabilities: capabilities));
}

/// A ready `DshClient` for Codex threads on the same remote connection, or
/// `null` when this host has no Codex domain.
///
/// The result is a normal `DshClient`: session list, history, streaming and
/// prompts all work, but only through [codexCarrierEndpoints].
DshClient? codexDshClient(DshClient remote, {String? defaultCwd}) {
  final codex = codexClientOf(remote);
  if (codex == null) return null;
  final done = remote.remoteCarrier?.session?.rpc.done;
  final carrier = CodexCarrier(
    client: codex,
    defaultCwd: defaultCwd,
    lost: done == null ? null : Stream<Object>.fromFuture(done.then<Object>((reason) => reason)),
  );
  // Settings, credentials and plugin inventory belong to the Harness on the
  // same tunnel, not to the Codex domain; without this fallback those pages
  // are empty for every Codex host (the same composition the ACP dialect uses).
  final tunnel = remote.remoteCarrier;
  if (tunnel == null) return DshClient.withCarrier(carrier);
  return DshClient.withCarrier(
    AgentCarrier(primary: carrier, fallback: tunnel, globalEndpoints: dialectGlobalFallbackEndpoints),
  );
}
