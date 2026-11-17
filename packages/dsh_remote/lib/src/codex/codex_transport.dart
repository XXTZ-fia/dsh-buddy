// Codex domain over an already authenticated ds-harness-remote connection.
//
// The tunnel multiplexes three domains on one Noise channel; this adapter binds
// the Codex one (`codex.app.*`) to [CodexTransport] without touching the
// Harness carrier, so a client can drive either domain (or both) per host.
library;

import 'dart:async';

import '../channel/rpc_client.dart';
import 'codex_client.dart';
import 'codex_wire.dart';

/// [CodexTransport] on top of a connected [RemoteRpcClient].
class RemoteCodexTransport implements CodexTransport {
  RemoteCodexTransport(this._rpc, {Set<String>? capabilities}) : _capabilities = capabilities ?? const {};

  final RemoteRpcClient _rpc;
  final Set<String> _capabilities;
  bool _closed = false;

  @override
  bool get supportsTransfer => _capabilities.contains(codexTransferCapability);

  @override
  Future<Object?> call(String method, Map<String, Object?> params) =>
      _rpc.call(codexCallMethod, {'method': method, 'params': params});

  @override
  Future<void> openStream(String streamId, String threadId) =>
      _rpc.call(codexStreamOpenMethod, {'streamId': streamId, 'threadId': threadId});

  @override
  Future<void> closeStream(String streamId) => _rpc.call(codexStreamCloseMethod, {'streamId': streamId});

  @override
  Future<void> respond(Map<String, Object?> response) => _rpc.call(codexRespondMethod, response);

  @override
  Future<String> readTransferChunk(String transferId, int index) async {
    final result = await _rpc.call(codexTransferReadMethod, {'transferId': transferId, 'index': index});
    final data = result is Map ? result['data'] : null;
    if (data is! String) {
      throw const CodexException('CODEX_INVALID_RESPONSE', 'The Host returned no transfer chunk.');
    }
    return data;
  }

  @override
  Stream<CodexTransportEvent> get events => _rpc.events
      .where((event) => event.event == codexFrameEvent || event.event == codexStreamClosedEvent)
      .map((event) => CodexTransportEvent(event.event, event.data));

  /// Releases nothing: the tunnel connection is owned by the caller (the
  /// Harness carrier or the account), so closing a Codex client never tears
  /// down a live DSH connection.
  @override
  Future<void> close() async {
    _closed = true;
  }

  /// Whether the Host declared the Codex domain at all.
  bool get available => _capabilities.contains(codexCapability) && !_closed;
}

/// Opens a Codex transport on a live tunnel session.
typedef CodexTransportFactory = CodexTransport Function(RemoteRpcClient rpc, Set<String>? capabilities);
