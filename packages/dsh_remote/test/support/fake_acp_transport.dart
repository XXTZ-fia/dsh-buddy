// Shared fake for the ACP domain tests: no Server, no Host, no backend.
import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart';

class FakeAcpTransport implements AcpTransport {
  final List<({String method, Map<String, Object?> params})> calls = [];
  final List<Map<String, Object?>> responses = [];
  final List<({String streamId, String sessionId})> opened = [];
  final List<String> closedStreamIds = [];

  final StreamController<AcpFrame> _frames = StreamController.broadcast();
  final StreamController<String> _closed = StreamController.broadcast();
  final StreamController<void> _catalog = StreamController.broadcast();

  Object? Function(String method, Map<String, Object?> params)? handler;

  @override
  bool supportsTransfer = false;

  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    calls.add((method: method, params: params));
    return handler?.call(method, params);
  }

  @override
  Future<void> openStream(String streamId, String sessionId) async => opened.add((streamId: streamId, sessionId: sessionId));

  @override
  Future<void> closeStream(String streamId) async => closedStreamIds.add(streamId);

  @override
  Future<void> respond(Map<String, Object?> response) async => responses.add(response);

  @override
  Stream<AcpFrame> get frames => _frames.stream;

  @override
  Stream<String> get closedStreams => _closed.stream;

  @override
  Stream<void> get catalogChanged => _catalog.stream;

  @override
  Future<String> readTransferChunk(String transferId, int index) async => '';

  @override
  Future<void> close() async {}

  void emit(AcpFrame frame) => _frames.add(frame);

  void emitClosed(String streamId) => _closed.add(streamId);

  void emitCatalogChanged() => _catalog.add(null);

  List<String> get methods => [for (final call in calls) call.method];
}
