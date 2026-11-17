// The ACP domain over an already authenticated ds-harness-remote connection.
//
// One Noise channel carries three domains; this adapter binds the ACP one
// (`agent.acp.*`) without touching the Harness or Codex carriers, so a client
// can drive any of them on the same Host connection.
library;

import 'dart:async';

import '../channel/rpc_client.dart';
import 'acp_wire.dart';

/// What [AcpClient] needs from the wire. Tests swap in a fake.
abstract class AcpTransport {
  /// `agent.acp.call`: one gateway method with its params.
  Future<Object?> call(String method, Map<String, Object?> params);

  /// `agent.acp.stream.open`: subscribe to one session's live frames.
  Future<void> openStream(String streamId, String sessionId);

  /// `agent.acp.stream.close`.
  Future<void> closeStream(String streamId);

  /// `agent.acp.respond`: answer a permission request.
  Future<void> respond(Map<String, Object?> response);

  /// `agent.acp.frame` + `agent.acp.stream.closed`, in arrival order.
  Stream<AcpFrame> get frames;

  /// Stream ids the Host closed on its own (`failed`, `cancelled`, ...).
  Stream<String> get closedStreams;

  /// `agent.acp.catalog.changed`: another device archived a session.
  Stream<void> get catalogChanged;

  /// Chunked read of an oversized response (`agent.acp.transfer.*`).
  Future<String> readTransferChunk(String transferId, int index);

  /// Whether the Host announced `agent.acp.transfer.v1`.
  bool get supportsTransfer;

  /// Releases nothing when the tunnel is owned by the caller.
  Future<void> close();
}

/// [AcpTransport] on top of a connected [RemoteRpcClient].
class RemoteAcpTransport implements AcpTransport {
  RemoteAcpTransport(this._rpc, {Set<String>? capabilities}) : _capabilities = capabilities ?? const {};

  final RemoteRpcClient _rpc;
  final Set<String> _capabilities;
  bool _closed = false;

  @override
  bool get supportsTransfer => _capabilities.contains(acpTransferCapability);

  @override
  Future<Object?> call(String method, Map<String, Object?> params) {
    if (!acpMethodAllowlist.contains(method)) {
      throw AcpException('METHOD_NOT_ALLOWED', '$method is not part of the ACP gateway.');
    }
    return _rpc.call(acpCallMethod, {'method': method, 'params': params});
  }

  @override
  Future<void> openStream(String streamId, String sessionId) =>
      _rpc.call(acpStreamOpenMethod, {'streamId': streamId, 'sessionId': sessionId});

  @override
  Future<void> closeStream(String streamId) => _rpc.call(acpStreamCloseMethod, {'streamId': streamId});

  @override
  Future<void> respond(Map<String, Object?> response) => _rpc.call(acpRespondMethod, response);

  @override
  Stream<AcpFrame> get frames => _rpc.events
      .where((event) => event.event == acpFrameEvent)
      .map((event) => AcpFrame.fromJson(event.data))
      .where((frame) => frame.method.isNotEmpty);

  @override
  Stream<String> get closedStreams => _rpc.events
      .where((event) => event.event == acpStreamClosedEvent)
      .map((event) => acpString(acpMap(event.data)['streamId']))
      .where((id) => id != null)
      .cast<String>();

  @override
  Stream<void> get catalogChanged =>
      _rpc.events.where((event) => event.event == acpCatalogChangedEvent).map((_) {});

  @override
  Future<String> readTransferChunk(String transferId, int index) async {
    final result = await _rpc.call(acpTransferReadMethod, {'transferId': transferId, 'index': index});
    final data = acpString(acpMap(result)['data']);
    if (data == null) {
      throw const AcpException('ACP_INVALID_RESPONSE', 'The Host returned no transfer chunk.');
    }
    return data;
  }

  /// The tunnel belongs to the caller (account or Harness carrier), so closing
  /// an ACP client never tears down a live connection.
  @override
  Future<void> close() async {
    _closed = true;
  }

  /// Whether the Host declared the ACP domain at all.
  bool get available => _capabilities.contains(acpCapability) && !_closed;
}

/// Opens an ACP transport on a live tunnel session.
typedef AcpTransportFactory = AcpTransport Function(RemoteRpcClient rpc, Set<String>? capabilities);
