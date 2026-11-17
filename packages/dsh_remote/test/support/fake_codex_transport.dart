// Shared fake for the Codex domain tests: no Server, no Host.
import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart';

class FakeCodexTransport implements CodexTransport {
  final List<({String method, Map<String, Object?> params})> calls = [];
  final StreamController<CodexTransportEvent> _events = StreamController.broadcast();
  final List<({String streamId, String threadId})> opened = [];
  final List<String> closedStreams = [];
  final List<Map<String, Object?>> responses = [];

  Map<String, Object?> Function(String method, Map<String, Object?> params)? handler;

  @override
  bool supportsTransfer = false;

  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    calls.add((method: method, params: params));
    return handler?.call(method, params);
  }

  @override
  Future<void> openStream(String streamId, String threadId) async => opened.add((streamId: streamId, threadId: threadId));

  @override
  Future<void> closeStream(String streamId) async => closedStreams.add(streamId);

  @override
  Future<void> respond(Map<String, Object?> response) async => responses.add(response);

  @override
  Stream<CodexTransportEvent> get events => _events.stream;

  void emit(CodexTransportEvent event) => _events.add(event);

  @override
  Future<String> readTransferChunk(String transferId, int index) async => chunk(transferId, index);

  String Function(String transferId, int index) chunk = (_, _) => '';

  @override
  Future<void> close() async {}
}
