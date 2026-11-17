// `DshCarrier` over the Codex domain: lets the existing app (session list,
// chat, streaming, stop) drive Codex threads on a remote Host without a second
// UI.
//
// Mapping (DSH endpoint -> Codex):
//   session/list        -> thread/list
//   session/page        -> dsh/sessionHistory
//   session/follow      -> history page snapshot + codex.app.frame projection
//   session/create      -> thread/start
//   session/prompt      -> turn/start
//   session/cancel      -> turn/interrupt
//   session/rename      -> thread/name/set
//   session/modelCatalog-> model/list
//   session/projections -> thread summary hints
//   workspace/follow    -> project/list
//
// Deliberately unsupported (the app degrades to "unavailable"): subagents,
// plugins, skills, schedules, files and terminals. Their DSH semantics do not
// exist on a Codex host.
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'codex_client.dart';
import 'codex_projection.dart';
import 'codex_wire.dart';

/// Endpoints this carrier serves. Everything else answers `METHOD_NOT_ALLOWED`.
const Set<String> codexCarrierEndpoints = {
  r'$events',
  r'$events/result',
  'session/list',
  'session/page',
  'session/create',
  'session/prompt',
  'session/cancel',
  'session/rename',
  'session/modelCatalog',
  'session/selectModel',
  'session/projections',
  'workspace/follow',
};

/// Efforts the Host's strict `turn/start` policy accepts. Anything else is
/// dropped instead of sending a request the Host would reject.
const Set<String> codexAllowedEfforts = {
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra',
};

typedef _ModelChoice = ({String model, String? effort});

/// Codex as a DSH host.
class CodexCarrier implements DshCarrier {
  CodexCarrier({required this.client, this.defaultCwd, this.lost});

  final CodexClient client;

  /// Cwd used when the app creates a thread without a workspace.
  final String? defaultCwd;

  /// Tunnel loss (the remote RPC's `done`); the mux then reconnects.
  final Stream<Object>? lost;

  final Map<String, CodexThreadSummary> _threads = {};

  /// Model chosen in the app per thread. Codex has no "set thread model" call:
  /// the choice is applied to the next `turn/start` (and to `thread/start`
  /// when it was made before the thread existed).
  final Map<String, _ModelChoice> _modelByThread = {};
  _ModelChoice? _pendingModel;

  /// Prompts sent from this phone, waiting for their Codex echo. The app
  /// clears its optimistic "sending" bubble only when a `user/message` event
  /// carries the same `requestId` back in `source.rpcId`.
  final List<({String threadId, String requestId, String text})> _sentPrompts = [];

  /// Locally synthesized host events (e.g. a thread we just created).
  final StreamController<Map<String, Object?>> _hostEvents = StreamController.broadcast();
  bool _closed = false;

  @override
  String get kind => 'codex';

  /// Release identity of the Codex CLI is not part of the domain contract.
  @override
  String? get hostVersion => null;

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  Set<String>? get peerCapabilities => const {codexCapability};

  @override
  bool allowsEndpoint(String endpoint) => codexCarrierEndpoints.contains(endpoint);

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (_closed) {
      return const RpcError(DshRemoteException('CODEX_CLOSED', 'The Codex connection is closed.'));
    }
    try {
      return RpcOk(await _dispatch(endpoint, args));
    } on CodexException catch (error) {
      return RpcError(DshRemoteException(error.code, error.message));
    } on Object catch (error) {
      return RpcError(DshRemoteException('codex/internal', '$error'));
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => _CodexLink(this);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await client.close();
    await _hostEvents.close();
  }

  // ---------------------------------------------------------------------------

  Future<Object?> _dispatch(String endpoint, Map<String, Object?> args) async {
    switch (endpoint) {
      case 'session/list':
        return _sessionList();
      case 'session/page':
        return _sessionPage(_request(args));
      case 'session/create':
        return _sessionCreate(_request(args));
      case 'session/prompt':
        return _sessionPrompt(_request(args));
      case 'session/cancel':
        return _sessionCancel(_request(args));
      case 'session/rename':
        final request = _request(args);
        final threadId = _threadIdOf(request['sessionId']);
        final name = request['title'] ?? request['name'];
        if (threadId != null && name is String) {
          await client.callRaw('thread/name/set', {'threadId': threadId, 'name': name});
          _threads.remove(threadId);
        }
        return const {};
      case 'session/modelCatalog':
        return _modelCatalog();
      case 'session/selectModel':
        return _selectModel(_request(args));
      case 'session/projections':
        return _projections(_request(args));
      case 'workspace/follow':
      case r'$events':
      case r'$events/result':
        return const {};
      default:
        throw CodexException('METHOD_NOT_ALLOWED', '$endpoint is not available on a Codex host.');
    }
  }

  Map<String, Object?> _request(Map<String, Object?> args) {
    final request = args['request'];
    if (request is Map) return request.map((key, value) => MapEntry('$key', value));
    final legacy = args[r'_request'];
    if (legacy is Map) return legacy.map((key, value) => MapEntry('$key', value));
    return args;
  }

  /// Events this carrier synthesizes for the app (currently: a thread we just
  /// created, so the drawer does not need an app restart to show it).
  Stream<Map<String, Object?>> get hostEvents => _hostEvents.stream;

  /// Remember an optimistic prompt until its Codex echo arrives.
  void _rememberPrompt(String threadId, String requestId, String text) {
    _sentPrompts.add((threadId: threadId, requestId: requestId, text: text.trim()));
    if (_sentPrompts.length > 24) _sentPrompts.removeAt(0);
  }

  /// Put `source.rpcId` on a projected `user/message` event that matches one
  /// of our prompts. The app uses it to retire its "sending" bubble; without
  /// it, the same message appears twice (pending + history) forever.
  Map<String, Object?> withRpcId(String threadId, Map<String, Object?> event) {
    if (event['type'] != 'user/message' || _sentPrompts.isEmpty) return event;
    final raw = event['data'];
    if (raw is! Map) return event;
    final data = raw.map((key, value) => MapEntry('$key', value));
    final original = data['source'];
    if (original is Map && original['rpcId'] != null) return event;
    final text = contentText(data['content']).trim();
    if (text.isEmpty) return event;
    var index = -1;
    for (var i = _sentPrompts.length - 1; i >= 0; i--) {
      final sent = _sentPrompts[i];
      if (sent.threadId == threadId && sent.text == text) {
        index = i;
        break;
      }
    }
    if (index < 0) return event;
    final requestId = _sentPrompts.removeAt(index).requestId;
    final source = <String, Object?>{};
    if (original is Map) source.addAll(original.map((key, value) => MapEntry('$key', value)));
    source['kind'] ??= 'user';
    source['rpcId'] = requestId;
    return {...event, 'data': {...data, 'source': source}};
  }

  Future<Object?> _sessionList() async {
    final page = await client.listThreads(limit: 50);
    // Codex 0.167 app-server repeats a thread in `thread/list` (the same
    // rollout shows up once per project root). Duplicate session ids would
    // create duplicate ValueKeys in the drawer's keyed ListView, which breaks
    // SliverMultiBoxAdaptor's strictly increasing child order. Keep the
    // freshest row for each id and the first-seen ordering.
    final unique = <String, CodexThreadSummary>{};
    for (final thread in page.items) {
      if (thread.id.isEmpty) continue;
      final current = unique[thread.id];
      if (current == null || _recency(thread) >= _recency(current)) {
        unique[thread.id] = thread;
      }
    }
    final items = unique.values.toList(growable: false);
    for (final thread in items) {
      _threads[thread.id] = thread;
    }
    return {
      'items': items.map(_sessionRow).toList(growable: false),
      'hasMore': page.hasMore,
    };
  }

  static int _recency(CodexThreadSummary thread) =>
      (thread.updatedAt ?? thread.createdAt)?.millisecondsSinceEpoch ?? 0;

  Map<String, Object?> _sessionRow(CodexThreadSummary thread) => {
    'sessionId': thread.session,
    'updatedAt': (thread.updatedAt ?? thread.createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    'running': thread.isBusy,
    'blank': false,
    'agentAvailable': true,
    'cwd': ?thread.cwd,
    'projections': {
      'kind': 'cached',
      'asOfSeq': -1,
      'values': {
        'title': thread.title,
        'sessionListMetadata': {'blank': false, 'lastPromptAt': null},
        if (thread.model != null)
          'modelSelection': {
            'lastUsed': {'provider': 'codex', 'model': thread.model, 'reasoningEffort': ?thread.reasoningEffort},
          },
      },
    },
  };

  Future<Object?> _sessionPage(Map<String, Object?> request) async {
    final threadId = _threadIdOf(_addressSessionId(request['address']));
    if (threadId == null) {
      throw const CodexException('session/not-found', 'The request has no Codex session address.');
    }
    final page = await client.history(
      threadId: threadId,
      throughSeq: _int(request['throughSeq']),
      beforeSeq: _int(request['beforeSeq']),
      maxMessages: _int(request['maxMessages']),
    );
    return {
      'records': page.records
          .map((record) => {'type': 'event', 'event': withRpcId(threadId, record.event)})
          .toList(growable: false),
      'hasMore': page.hasMore,
    };
  }

  Future<Object?> _sessionCreate(Map<String, Object?> request) async {
    final workspaceId = request['workspaceId'];
    final cwd =
        (workspaceId is String ? codexWorkspacePathOf(workspaceId) : null) ??
        (request['cwd'] is String ? request['cwd'] as String : null) ??
        defaultCwd;
    if (cwd == null) {
      throw const CodexException('gateway/bad-request', 'A Codex thread needs a workspace or cwd.');
    }
    final pending = _pendingModel;
    final thread = await client.startThread(cwd: cwd, model: pending?.model);
    _threads[thread.id] = thread;
    if (pending != null) _modelByThread[thread.id] = pending;
    // Without this the drawer keeps showing the old list until the app is
    // restarted: `sessions_state` listens for `api-session/added`.
    if (!_hostEvents.isClosed) {
      _hostEvents.add({
        'type': 'emit',
        'event': 'api-session/added',
        'args': [_sessionRow(thread)],
      });
    }
    return {'sessionId': thread.session};
  }

  Future<Object?> _sessionPrompt(Map<String, Object?> request) async {
    final threadId = _threadIdOf(request['sessionId']);
    if (threadId == null) {
      throw const CodexException('session/not-found', 'The prompt has no Codex session address.');
    }
    final text = contentText(request['content']);
    if (text.trim().isEmpty) {
      throw const CodexException('gateway/bad-request', 'The prompt has no text content.');
    }
    // A model chosen in the composer wins over the one the thread used last
    // time (which is all `thread/list` tells us).
    final choice = _modelByThread[threadId];
    final thread = _threads[threadId];
    final requestId = request['requestId'];
    if (requestId is String && requestId.isNotEmpty) {
      _rememberPrompt(threadId, requestId, text);
    }
    await client.startTurn(
      threadId: threadId,
      text: text,
      model: choice?.model ?? thread?.model,
      effort: choice?.effort,
    );
    return {'ok': true};
  }

  Future<Object?> _sessionCancel(Map<String, Object?> request) async {
    final threadId = _threadIdOf(_addressSessionId(request['address']) ?? request['sessionId']);
    if (threadId == null) return {'accepted': false};
    final thread = await client.readThread(threadId, includeTurns: true);
    final turn = thread.activeTurn ?? (thread.turns.isEmpty ? null : thread.turns.last);
    if (turn == null) return {'accepted': true};
    await client.interruptTurn(threadId: threadId, turnId: turn.id);
    return {'accepted': true};
  }

  Future<Object?> _projections(Map<String, Object?> request) async {
    final threadId = _threadIdOf(request['sessionId']);
    if (threadId == null) return null;
    final cached = _threads[threadId];
    final thread = cached ?? (await client.readThread(threadId, includeTurns: false)).summary;
    _threads[threadId] = thread;
    return {
      'asOfSeq': -1,
      'values': {
        'title': thread.title,
        'agentPreset': null,
        'sessionListMetadata': {'blank': false, 'lastPromptAt': null},
        if (thread.model != null)
          'modelSelection': {
            'lastUsed': {'provider': 'codex', 'model': thread.model, 'reasoningEffort': ?thread.reasoningEffort},
          },
      },
    };
  }

  /// `session/selectModel`: Codex carries the model on each turn, so the
  /// selection is kept here and applied at the next `turn/start`. We still
  /// acknowledge it in DSH shape, so the composer shows the chosen model.
  Object? _selectModel(Map<String, Object?> request) {
    final model = request['model'];
    if (model is! String || model.isEmpty || model.length > 128) {
      throw const CodexException('gateway/bad-request', 'A Codex model id is required.');
    }
    final rawEffort = request['reasoningEffort'];
    final effort = rawEffort is String && codexAllowedEfforts.contains(rawEffort) ? rawEffort : null;
    final choice = (model: model, effort: effort);
    final threadId = _threadIdOf(request['sessionId']);
    if (threadId != null) {
      _modelByThread[threadId] = choice;
    } else {
      // The composer can pick a model before a thread has been created.
      _pendingModel = choice;
    }
    return {
      'selected': {'provider': 'codex', 'model': model, 'reasoningEffort': ?effort},
      // Codex has no "default model for next session" concept; saying skipped
      // avoids the app claiming a default was saved.
      'defaultSave': {'status': 'skipped'},
    };
  }

  Future<Object?> _modelCatalog() async {
    final raw = await client.callRaw('model/list', const {});
    final data = raw is Map ? raw['data'] : null;
    final models = <Map<String, Object?>>[];
    String? firstId;
    String? firstEffort;
    if (data is List) {
      for (final entry in data) {
        if (entry is! Map) continue;
        if (entry['hidden'] == true) continue;
        final id = entry['model'] ?? entry['id'];
        if (id is! String || id.isEmpty) continue;
        firstId ??= id;
        final efforts = <Map<String, Object?>>[];
        final supported = entry['supportedReasoningEfforts'];
        if (supported is List) {
          for (final effort in supported) {
            if (effort is! Map) continue;
            final effortId = effort['reasoningEffort'];
            if (effortId is String) efforts.add({'id': effortId, 'name': effortId});
          }
        }
        final effortIds = [for (final e in efforts) e['id'] as String?];
        final ownDefault = effortIds.contains('medium') ? 'medium' : (efforts.isEmpty ? null : effortIds.first);
        if (firstId == id && firstEffort == null) firstEffort = ownDefault;
        models.add({
          'id': id,
          'name': entry['displayName'] ?? id,
          'description': ?(entry['description'] as String?),
          if (efforts.isNotEmpty)
            'reasoning': {
              'efforts': efforts,
              'defaultEffort': ?ownDefault,
            },
        });
      }
    }
    return {
      // `ModelCatalog.fromJson` reads the `default` key, not `defaultSelection`.
      // Without it the composer has no current selection, so tapping an effort
      // in the model sheet does nothing and the user cannot proceed.
      'default': {'provider': 'codex', 'model': ?firstId, 'reasoningEffort': ?firstEffort},
      'routableProviders': ['codex'],
      'groups': [
        {'id': 'codex', 'name': 'Codex', 'models': models},
      ],
      'failures': <Object?>[],
    };
  }

  /// Thread summary for a live follow (title/model in the snapshot).
  CodexThreadSummary? thread(String threadId) => _threads[threadId];

  void remember(CodexThreadSummary thread) => _threads[thread.id] = thread;

  bool get isClosed => _closed;

  static String? _threadIdOf(Object? sessionId) => sessionId is String ? codexThreadIdOf(sessionId) : null;

  static String? _addressSessionId(Object? address) {
    if (address is Map) {
      final id = address['sessionId'];
      return id is String ? id : null;
    }
    return null;
  }

  static String contentText(Object? content) {
    if (content is! List) return '';
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is Map && part['type'] == 'text' && part['text'] is String) {
        buffer.write(part['text'] as String);
      }
    }
    return buffer.toString();
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite) return value.toInt();
    return null;
  }
}

/// One mux link: `$events` ready is synthesized locally, `session/follow` and
/// `workspace/follow` are served from the Codex domain.
class _CodexLink implements DshMuxLink {
  _CodexLink(this._carrier);

  final CodexCarrier _carrier;
  final Map<String, _FollowState> _follows = {};
  final String _clientId = 'codex-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  DshMuxFrameHandler? _onFrame;
  StreamSubscription<Object>? _lostSub;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  String? _eventsStreamId;

  /// User messages already delivered on one follow stream. Codex echoes a
  /// prompt both in `dsh/sessionHistory` and in a live `item/started` frame;
  /// without this the same bubble is drawn twice.
  final Map<String, Set<String>> _userKeys = {};
  bool _closed = false;

  CodexClient get _client => _carrier.client;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _eventsSub = _carrier.hostEvents.listen((frame) {
      final streamId = _eventsStreamId;
      if (!_closed && streamId != null) {
        _emit({'type': 'item', 'streamId': streamId, 'value': frame});
      }
    });
    _lostSub = _carrier.lost?.listen((error) {
      if (_closed) return;
      _closed = true;
      onLost(DshCarrierLostException('codex link lost'), error);
    });
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (_closed) return;
    final args = payload['args'];
    final argsMap = args is Map ? args.map((key, value) => MapEntry('$key', value)) : const <String, Object?>{};
    switch (endpoint) {
      case r'$events':
        _eventsStreamId = streamId;
        _emit({
          'type': 'item',
          'streamId': streamId,
          'value': {
            'type': 'ready',
            'clientId': _clientId,
            'host': {'home': 'codex'},
          },
        });
      case 'session/follow':
        unawaited(_openFollow(streamId, argsMap));
      case 'workspace/follow':
        unawaited(_openWorkspaces(streamId));
      default:
        _emitError(streamId, 'METHOD_NOT_ALLOWED', '$endpoint is not available on a Codex host.');
    }
  }

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) {
    _userKeys.remove(streamId);
    final follow = _follows.remove(streamId);
    if (follow != null) {
      unawaited(follow.close());
      return;
    }
    _emit({'type': 'end', 'streamId': streamId});
  }

  @override
  Future<void> close(int code, String reason) async {
    if (_closed) return;
    _closed = true;
    await _lostSub?.cancel();
    await _eventsSub?.cancel();
    _userKeys.clear();
    final follows = _follows.values.toList(growable: false);
    _follows.clear();
    for (final follow in follows) {
      await follow.close();
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _openFollow(String streamId, Map<String, Object?> args) async {
    final request = args['request'];
    final requestMap = request is Map ? request.map((key, value) => MapEntry('$key', value)) : const <String, Object?>{};
    final address = requestMap['address'];
    final sessionId = address is Map ? address['sessionId'] : null;
    final threadId = sessionId is String ? codexThreadIdOf(sessionId) : null;
    if (threadId == null) {
      _emitError(streamId, 'gateway/bad-request', 'The follow request has no Codex session address.');
      return;
    }
    CodexSubscription? subscription;
    try {
      final page = await _client.history(threadId: threadId, maxMessages: CodexCarrier._int(requestMap['maxMessages']));
      final thread = _carrier.thread(threadId) ?? (await _client.readThread(threadId, includeTurns: false)).summary;
      _carrier.remember(thread);
      final projection = CodexThreadProjection(
        cursor: page.cursor,
        nextTurn: page.nextTurn,
        activeTurnId: page.activeTurnId,
        sessionId: thread.session,
      );
      subscription = await _client.subscribe(threadId);
      if (_closed) {
        await subscription.close();
        return;
      }
      final snapshot = projection.snapshot(
        page,
        title: thread.title,
        model: thread.model,
        reasoningEffort: thread.reasoningEffort,
      );
      final records = snapshot['records'];
      if (records is List) {
        final decorated = <Map<String, Object?>>[];
        for (final record in records) {
          if (record is! Map) continue;
          final out = _decorateRecord(streamId, threadId, record.map((key, value) => MapEntry('$key', value)));
          if (out != null) decorated.add(out);
        }
        snapshot['records'] = decorated;
      }
      _emit({'type': 'item', 'streamId': streamId, 'value': snapshot});
      final state = _FollowState(subscription, projection, streamId);
      _follows[streamId] = state;
      state.listen(this);
    } on Object catch (error) {
      await subscription?.close();
      _emitError(streamId, 'codex/stream', 'Could not open the Codex thread stream: $error');
    }
  }

  Future<void> _openWorkspaces(String streamId) async {
    try {
      final page = await _client.listProjects(limit: 50);
      final items = <Map<String, Object?>>[];
      for (final project in page.items) {
        final path = project.path;
        if (path == null) continue;
        items.add({
          'workspaceId': project.workspaceId,
          'path': path,
          'title': project.name,
          'sessionIds': <String>[],
        });
      }
      _emit({
        'type': 'item',
        'streamId': streamId,
        'value': {
          'type': 'baseline',
          'value': {'items': items, 'archivedSessionIds': <String>[], 'pinnedSessionIds': <String>[]},
        },
      });
    } on Object catch (error) {
      _emitError(streamId, 'codex/workspaces', 'Could not read Codex projects: $error');
    }
  }

  /// Retire duplicate user echoes and attach our prompt's `rpcId` to the first
  /// one, on both the history snapshot and the live frame stream.
  Map<String, Object?>? _userEvent(String streamId, String threadId, Map<String, Object?> event) {
    if (event['type'] != 'user/message') return event;
    final raw = event['data'];
    final data = raw is Map ? raw.map((key, value) => MapEntry('$key', value)) : const <String, Object?>{};
    final text = CodexCarrier.contentText(data['content']).trim();
    final id = data['id'];
    final key = id is String && id.isNotEmpty ? 'id:$id' : 'text:$text';
    if (!_userKeys.putIfAbsent(streamId, () => <String>{}).add(key)) return null;
    return _carrier.withRpcId(threadId, event);
  }

  Map<String, Object?>? _decorateRecord(String streamId, String threadId, Map<String, Object?> record) {
    final event = record['event'];
    if (event is! Map) return record;
    final decorated = _userEvent(streamId, threadId, event.map((key, value) => MapEntry('$key', value)));
    if (decorated == null) return null;
    return {...record, 'event': decorated};
  }

  void _emitFrame(Map<String, Object?> frame) {
    if (!_closed) _onFrame?.call(frame);
  }

  void _emit(Map<String, Object?> frame) => _emitFrame(frame);

  void _emitError(String streamId, String code, String message) => _emit({
    'type': 'error',
    'streamId': streamId,
    'error': {'code': code, 'message': message},
  });

}

/// Live frames of one followed thread.
final class _FollowState {
  _FollowState(this.subscription, this.projection, this.streamId);

  final CodexSubscription subscription;
  final CodexThreadProjection projection;
  final String streamId;
  StreamSubscription<CodexFrame>? _frames;

  void listen(_CodexLink link) {
    _frames = subscription.frames.listen(
      (frame) {
        if (link._follows[streamId] != this) return;
        final threadId = codexThreadIdOf(projection.sessionId) ?? '';
        for (final item in projection.handle(frame)) {
          final event = link._userEvent(streamId, threadId, item);
          if (event != null) link._emit({'type': 'item', 'streamId': streamId, 'value': event});
        }
      },
      onError: (Object error) => link._emitError(streamId, 'codex/stream', '$error'),
      onDone: () {
        link._follows.remove(streamId);
        link._emit({'type': 'end', 'streamId': streamId});
      },
    );
  }

  Future<void> close() async {
    await _frames?.cancel();
    await subscription.close();
  }
}
