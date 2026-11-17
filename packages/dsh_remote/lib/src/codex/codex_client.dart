// Typed client for the Codex Remote domain over a ds-harness-remote tunnel.
//
// Every call goes through `codex.app.call` with `{method, params}`, streams via
// `codex.app.stream.open|close`, approvals via `codex.app.respond`. The RPC
// surface is injected as a [CodexTransport] so the client is testable without a
// Server, and so the same code can later run over a fake Host.
library;

import 'dart:async';
import 'dart:convert';
import 'codex_wire.dart';

/// One authenticated tunnel that can carry the Codex domain.
abstract interface class CodexTransport {
  /// `codex.app.call`; returns the Host's `result` verbatim.
  Future<Object?> call(String method, Map<String, Object?> params);

  /// `codex.app.stream.open` / `stream.close`.
  Future<void> openStream(String streamId, String threadId);
  Future<void> closeStream(String streamId);

  /// `codex.app.respond` for an app-server request (approvals).
  Future<void> respond(Map<String, Object?> response);

  /// `codex.app.frame` payloads (`{streamId, frame}`) and
  /// `codex.app.stream.closed` payloads (`{streamId, reason}`), tagged by event.
  Stream<CodexTransportEvent> get events;

  /// Chunked responses (`codex.app.transfer.*`) are supported by this host.
  bool get supportsTransfer;

  /// Reads one chunk of a chunked response.
  Future<String> readTransferChunk(String transferId, int index);

  Future<void> close();
}

/// A Host-published event with its domain event name.
class CodexTransportEvent {
  const CodexTransportEvent(this.event, this.data);

  final String event;
  final Object? data;
}

/// One live thread subscription: a Host-side stream plus decoded frames.
class CodexSubscription {
  CodexSubscription._(this._client, this.streamId, this.threadId, this._frames);

  final CodexClient _client;
  final String streamId;
  final String threadId;
  final StreamController<CodexFrame> _frames;

  /// Notifications for this thread, committed to app-server order.
  Stream<CodexFrame> get frames => _frames.stream;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(_frames.close());
    await _client._transport.closeStream(streamId);
  }
}

/// Codex domain client: catalog reads, thread/turn mutations, history pages and
/// live frame subscriptions.
class CodexClient {
  CodexClient(this._transport);

  final CodexTransport _transport;

  final Map<String, StreamController<CodexFrame>> _subscriptions = {};
  StreamSubscription<CodexTransportEvent>? _events;
  int _streamSeq = 0;
  bool _closed = false;

  /// Capability this client needs from the Host.
  static bool hostSupports(Set<String>? capabilities) => capabilities?.contains(codexCapability) ?? false;

  /// `account/read`, sanitized by the Host (no tokens).
  Future<Map<String, Object?>> account() async => _asMap(await _call('account/read', const {}));

  /// One app-server method this client does not model (`thread/name/set`,
  /// `model/list`, ...). Transfer-aware like every other call.
  Future<Object?> callRaw(String method, Map<String, Object?> params) => _call(method, params);

  /// Projects the Host exposes as workspaces, newest first as the Host sorts.
  Future<CodexPage<CodexProject>> listProjects({int limit = 50, String? cursor}) async {
    final result = await _call('project/list', {'limit': limit, 'cursor': ?cursor});
    return CodexPage.parse(result, CodexProject.tryFromJson);
  }

  /// Threads of one workspace (by cwd).
  ///
  /// The Host's method policy is strict: it allows `cwd` but not `projectId`,
  /// so a project-scoped list has to go through its root path.
  Future<CodexPage<CodexThreadSummary>> listThreads({
    String? cwd,
    bool archived = false,
    int limit = 50,
    String? cursor,
    String? searchTerm,
  }) async {
    final result = await _call('thread/list', {
      'limit': limit,
      'archived': archived,
      'cwd': ?cwd,
      if (searchTerm != null && searchTerm.isNotEmpty) 'searchTerm': searchTerm,
      'cursor': ?cursor,
    });
    return CodexPage.parse(result, (json) => _nonEmptyId(json) ? CodexThreadSummary.fromJson(json) : null);
  }

  /// One thread, optionally with every turn and item (`thread/read`).
  Future<CodexThread> readThread(String threadId, {bool includeTurns = true}) async => CodexThread.fromJson(
    await _call('thread/read', {'threadId': threadId, 'includeTurns': includeTurns}),
  );

  /// A new thread in [cwd]. The Host only accepts `permissionPreset`, which is
  /// what keeps a phone turn from stalling on an approval prompt: the preset
  /// is sandboxed writes without interactive approvals.
  Future<CodexThreadSummary> startThread({
    required String cwd,
    String? model,
    String permissionPreset = 'workspace-write',
  }) async {
    final result = await _call('thread/start', {
      'cwd': cwd,
      'permissionPreset': permissionPreset,
      'model': ?model,
    });
    final thread = CodexThread.fromJson(result);
    if (thread.summary.id.isEmpty) {
      throw const CodexException('CODEX_INVALID_RESPONSE', 'Codex returned no thread id.');
    }
    return thread.summary;
  }

  /// Loads an existing thread for a new writer (defensive before every turn).
  Future<CodexThreadSummary> resumeThread(String threadId, {String? model}) async {
    final result = await _call('thread/resume', {'threadId': threadId, 'model': ?model});
    return CodexThread.fromJson(result).summary;
  }

  /// Starts one turn and returns its id. [text] is the only required input;
  /// images are added in a later slice.
  Future<String?> startTurn({required String threadId, required String text, String? model, String? effort}) async {
    final result = await _call('turn/start', {
      'threadId': threadId,
      'input': [
        {'type': 'text', 'text': text},
      ],
      'model': ?model,
      'effort': ?effort,
    });
    return _asMap(result)['turn'] is Map ? _str(_asMap(_asMap(result)['turn'])['id']) : _str(_asMap(result)['turnId']);
  }

  /// `turn/interrupt` — best effort, the Host maps it to the native cancel.
  Future<void> interruptTurn({required String threadId, required String turnId}) =>
      _call('turn/interrupt', {'threadId': threadId, 'turnId': turnId});

  /// Host-projected DSH history for a thread (`dsh/sessionHistory`).
  ///
  /// The Host validates these numbers (`maxMessages` is capped at
  /// [codexHistoryMaxMessages], `beforeSeq` is non-negative, `throughSeq` is
  /// at least -1), and the App asks for windows far larger than that: clamp
  /// instead of letting a strict schema reject the whole page.
  Future<CodexHistoryPage> history({
    required String threadId,
    int? throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async => CodexHistoryPage.fromJson(
    await _call('dsh/sessionHistory', {
      'threadId': threadId,
      if (throughSeq != null) 'throughSeq': throughSeq < -1 ? -1 : throughSeq,
      if (beforeSeq != null) 'beforeSeq': beforeSeq < 0 ? 0 : beforeSeq,
      if (maxMessages != null && maxMessages > 0)
        'maxMessages': maxMessages > codexHistoryMaxMessages ? codexHistoryMaxMessages : maxMessages,
    }),
  );

  /// Opens a live frame subscription for [threadId]. Frames arrive in
  /// app-server order; history is read separately by the caller.
  Future<CodexSubscription> subscribe(String threadId) async {
    _ensureEvents();
    final streamId = 'codex-${_streamSeq++}-${DateTime.now().microsecondsSinceEpoch}';
    final controller = StreamController<CodexFrame>.broadcast();
    _subscriptions[streamId] = controller;
    try {
      await _transport.openStream(streamId, threadId);
    } on Object {
      _subscriptions.remove(streamId);
      await controller.close();
      rethrow;
    }
    return CodexSubscription._(this, streamId, threadId, controller);
  }

  /// Answers an app-server request. Approvals accept through the option the
  /// request offered; everything else is declined.
  Future<void> answer(CodexServerRequest request, {bool approve = false}) async {
    final decision = approve ? _allowOption(request.params) : 'decline';
    await _transport.respond({
      'requestId': request.requestId,
      'result': {'decision': decision},
    });
  }

  void _ensureEvents() {
    _events ??= _transport.events.listen((event) {
      final data = _asMap(event.data);
      final streamId = _str(data['streamId']);
      if (streamId == null) return;
      final controller = _subscriptions[streamId];
      if (controller == null || controller.isClosed) return;
      if (event.event == codexStreamClosedEvent) {
        _subscriptions.remove(streamId);
        unawaited(controller.close());
        return;
      }
      if (event.event != codexFrameEvent) return;
      controller.add(CodexFrame.fromJson(data['frame']));
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final entry in _subscriptions.entries.toList()) {
      unawaited(entry.value.close());
    }
    _subscriptions.clear();
    await _events?.cancel();
    await _transport.close();
  }

  // ---------------------------------------------------------------------------

  /// One domain call, unwrapping chunked responses.
  Future<Object?> _call(String method, Map<String, Object?> params) async {
    if (_closed) throw const CodexException('CODEX_CLOSED', 'The Codex client is closed.');
    final result = await _transport.call(method, params);
    final map = _asMap(result);
    if (map['kind'] != 'chunked') return result;
    final transferId = _str(map['transferId']);
    final total = _asInt(map['totalChunks']);
    if (!_transport.supportsTransfer || transferId == null || total == null) {
      throw CodexException('CODEX_UNSUPPORTED', 'The Host returned an unreadable transfer for $method.');
    }
    // Chunks split raw UTF-8 bytes, so they are joined before decoding.
    final bytes = <int>[];
    for (var index = 0; index < total; index++) {
      bytes.addAll(base64Decode(await _transport.readTransferChunk(transferId, index)));
    }
    return jsonDecode(utf8.decode(bytes));
  }

  /// The first `allow_once` / `allow` option id the request offered, else a
  /// plain accept so the turn can proceed.
  static String _allowOption(Map<String, Object?> params) {
    final options = _asList(params['options']);
    for (final raw in options) {
      final option = _asMap(raw);
      final kind = _str(option['kind']);
      if (kind == 'allow_once' || kind == 'allow_always' || kind == 'allow') {
        final id = _str(option['optionId']) ?? _str(option['id']);
        if (id != null) return id;
      }
    }
    return 'accept';
  }

  static bool _nonEmptyId(Map<String, Object?> json) => _str(json['id']) != null;
}

/// Domain failure with the Host's code.
class CodexException implements Exception {
  const CodexException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CodexException($code): $message';
}

// Local tolerant readers: the wire is JSON produced by a newer Host.
Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((key, v) => MapEntry(key.toString(), v));
  return const {};
}

List<Object?> _asList(Object? value) => value is List ? value.cast<Object?>() : const [];

String? _str(Object? value) => value is String && value.isNotEmpty ? value : null;

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.toInt();
  return null;
}
