// Bridges one remote connection into a second, synthetic `DshClient` speaking
// the ACP dialect — the same Host, the same Noise tunnel, no extra session.
//
// The Server allows one Host connection per client device, so an ACP backend
// must reuse the live connection instead of dialing again: [acpDshClient]
// wraps the tunnel's RPC client and returns a `DshClient` whose carrier owns
// nothing on the wire.
library;

import 'package:dsh_client/dsh_client.dart';

import '../agent/agent_backend.dart';
import '../agent/agent_carrier.dart';
import '../carrier/tunnel_carrier.dart';
import 'acp_carrier.dart';
import 'acp_client.dart';
import 'acp_transport.dart';
import 'acp_wire.dart';

/// The ACP domain of this connection for [backend], or null when the carrier
/// is local or the Host does not declare that backend.
AcpClient? acpClientOf(DshClient client, AgentBackend backend) {
  final hostBackend = backend.acpBackend;
  if (hostBackend == null) return null;
  final session = client.remoteCarrier?.session;
  if (session == null) return null;
  final capabilities = session.capabilities.toSet();
  if (!capabilities.contains(acpCapability)) return null;
  if (!capabilities.contains('agent.acp.$hostBackend.v1')) return null;
  return AcpClient(
    RemoteAcpTransport(session.rpc, capabilities: capabilities),
    backend: hostBackend,
  );
}

/// A ready `DshClient` for [backend]'s sessions on the same remote connection,
/// or null when this host does not offer that backend.
///
/// The result is a normal `DshClient`: session list, history, streaming,
/// approvals and stop all work, but only through [acpCarrierEndpoints] plus
/// the global endpoints the tunnel already serves.
DshClient? acpDshClient(DshClient remote, AgentBackend backend, {String? defaultCwd}) {
  final client = acpClientOf(remote, backend);
  if (client == null) return null;
  final session = remote.remoteCarrier?.session;
  final done = session?.rpc.done;
  final carrier = AcpCarrier(
    client: client,
    agent: backend,
    backend: backend.acpBackend!,
    defaultCwd: defaultCwd,
    lost: done == null ? null : Stream<Object>.fromFuture(done.then<Object>((reason) => reason)),
  );
  // Sessions and workspaces stay on the ACP backend; the global read-only
  // surfaces (settings, credentials, plugin inventory) are still served by the
  // real Harness on the same tunnel. Without this the settings and model pages
  // are empty for every ACP host.
  final tunnel = remote.remoteCarrier;
  if (tunnel == null) return DshClient.withCarrier(carrier);
  return DshClient.withCarrier(
    AgentCarrier(primary: carrier, fallback: tunnel, globalEndpoints: dialectGlobalFallbackEndpoints),
  );
}

/// Whether [client]'s Host offers [backend] at all (capability only).
bool acpAvailableOn(DshClient client, AgentBackend backend) {
  final hostBackend = backend.acpBackend;
  if (hostBackend == null) return false;
  final capabilities = client.remoteCarrier?.session?.capabilities;
  if (capabilities == null) return false;
  return capabilities.contains('agent.acp.$hostBackend.v1');
}
