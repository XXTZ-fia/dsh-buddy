// `DshCarrier` over the Host's ACP gateway: lets the existing App (session
// list, chat, streaming, approvals, stop) drive Claude Code / OpenCode
// sessions without a second UI.
//
// Mapping (DSH endpoint -> ACP):
//   session/list         -> dsh/workspaceList + dsh/sessionList
//   session/page         -> dsh/sessionHistory
//   session/follow       -> session/load + agent.acp.stream.open + agent.acp.frame
//   session/create       -> session/new
//   session/prompt       -> session/prompt (accepted immediately)
//   session/cancel       -> session/cancel
//   session/modelCatalog -> dsh/sessionModels
//   session/selectModel  -> dsh/selectModel
//   session/selectPermission -> dsh/selectPermission
//   workspace/follow     -> dsh/workspaceList
//   terminal/*           -> dsh/toolCall
//
// Deliberately unsupported (the App degrades to "unavailable"): plugins,
// skills, schedules, subagents, workspace file writes beyond ACP's own tools,
// and terminal follow streams (only unary terminal calls are proxied).
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../agent/agent_backend.dart';
import 'acp_client.dart';
import 'acp_projection.dart';
import 'acp_wire.dart';

/// Endpoints this carrier serves itself.
const Set<String> acpCarrierEndpoints = {
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
  'session/selectPermission',
  'session/projections',
  'workspace/follow',
  'workspace/create',
  'terminal/environment',
  'terminal/shells',
  'terminal/list',
  'terminal/create',
  'terminal/write',
  'terminal/resize',
  'terminal/rename',
  'terminal/close',
};

/// One ACP backend as a DSH host.
class AcpCarrier implements DshCarrier {
  AcpCarrier({
    required this.client,
    required this.agent,
    required this.backend,
    this.defaultCwd,
    this.lost,
    this.fallback,
  });

  final AcpClient client;

  /// The App-level backend (`claude`, `opencode`, `cursor`).
  final AgentBackend agent;

  /// Host-side backend id used in every ACP call.
  final String backend;

  /// Cwd used when the App creates a session without a workspace.
  final String? defaultCwd;

  /// Tunnel loss (the remote RPC's `done`); the mux then reconnects.
  final Stream<Object>? lost;

  /// Global read-only endpoints (settings, credentials, plugins) served by the
  /// real Harness carrier on the same tunnel. Session and workspace endpoints
  /// never reach it.
  final DshCarrier? fallback;

  final Map<String, AcpSessionSummary> _sessions = {};
  final Map<String, String> _sessionCwd = {};
  final Map<String, String> _titles = {};
  final Map<String, _ModelChoice> _models = {};
  _ModelChoice? _pendingModel;

  /// Model selection already pushed to the backend, per native session.
  ///
  /// Without this every prompt re-sends `dsh/selectModel`, which over a relay
  /// is an extra ~0.4 s round trip before the turn even starts.
  final Map<String, _ModelChoice> _syncedModel = {};

  /// Native ids with a turn currently open, so the list can mark them running.
  final Set<String> _liveTurns = {};

  /// Prompts this App sent, waiting for their `user_message_chunk` echo.
  ///
  /// OpenCode (and some Claude turns) never echo the user message, so the
  /// projection would otherwise never emit `user/message` and the App's
  /// optimistic bubble would stay unconfirmed forever.
  final Map<String, ({String text, String? rpcId})> _pendingPrompt = {};

  final StreamController<Map<String, Object?>> _hostEvents = StreamController.broadcast();
  bool _closed = false;

  @override
  String get kind => backend;

  @override
  String? get hostVersion => null;

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  Set<String>? get peerCapabilities => null;

  @override
  bool allowsEndpoint(String endpoint) {
    // Unary terminal calls (`create`/`write`/`resize`/...) go through
    // `dsh/toolCall`; the streaming pair does not, so claiming them would make
    // the App show a terminal that can never attach.
    if (endpoint == 'terminal/follow' || endpoint == 'terminal/retain') return false;
    if (acpCarrierEndpoints.contains(endpoint)) return true;
    return fallback?.allowsEndpoint(endpoint) ?? false;
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (_closed) {
      return RpcError(DshRemoteException('ACP_CLOSED', 'The $backend connection is closed.'));
    }
    if (!acpCarrierEndpoints.contains(endpoint)) {
      final other = fallback;
      if (other != null && other.allowsEndpoint(endpoint)) return other.call(endpoint, args, timeout: timeout);
      return RpcError(DshRemoteException('METHOD_NOT_ALLOWED', '$endpoint is not available on a $backend host.'));
    }
    try {
      return RpcOk(await _dispatch(endpoint, args));
    } on AcpException catch (error) {
      return RpcError(DshRemoteException(error.code, error.message));
    } on Object catch (error) {
      return RpcError(DshRemoteException('acp/internal', '$error'));
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => _AcpLink(this);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _loaded.clear();
    await client.close();
    await _hostEvents.close();
  }

  Stream<Map<String, Object?>> get hostEvents => _hostEvents.stream;

  /// Publishes the same `api-session/status` edge a DSH Host sends, so the App's
  /// running markers, idle notifications and schedules see ACP turns too.
  void publishRunning(String native, bool running) {
    if (_hostEvents.isClosed) return;
    _hostEvents.add({
      'type': 'emit',
      'event': 'api-session/status',
      'args': [acpSessionId(backend, native), running],
    });
  }

  // ---------------------------------------------------------------------------

  Future<Object?> _dispatch(String endpoint, Map<String, Object?> args) async {
    switch (endpoint) {
      case r'$events':
      case r'$events/result':
        return _respond(args);
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
        return _sessionRename(_request(args));
      case 'session/modelCatalog':
        return _modelCatalog(_request(args));
      case 'session/selectModel':
        return _selectModel(_request(args));
      case 'session/selectPermission':
        return _selectPermission(_request(args));
      case 'session/projections':
        return _projections(_request(args));
      case 'workspace/follow':
        return const {};
      case 'workspace/create':
        return _workspaceCreate(_request(args));
      default:
        if (endpoint.startsWith('terminal/')) return _tool(endpoint, args);
        throw AcpException('METHOD_NOT_ALLOWED', '$endpoint is not available on a $backend host.');
    }
  }

  Map<String, Object?> _request(Map<String, Object?> args) {
    final request = args['request'];
    if (request is Map) return request.map((key, value) => MapEntry('$key', value));
    final legacy = args[r'_request'];
    if (legacy is Map) return legacy.map((key, value) => MapEntry('$key', value));
    return args;
  }

  Future<Object?> _respond(Map<String, Object?> args) async {
    final eventId = acpString(args['eventId']);
    final outcome = acpMap(args['outcome']);
    if (eventId == null) return const {};
    // ACP has no second answerer: "let another client answer" would leave the
    // Host's permission request pending until the turn is cancelled, so the
    // refusal is the honest translation (and the tool call fails visibly).
    final next = outcome['kind'] == 'next';
    final value = next
        ? 'rejected'
        : acpString(outcome['value']) ?? acpString(acpMap(outcome['value'])['decision']);
    final decision = switch (value) {
      'allowed-once' || 'allow-once' => AcpDecision.allowOnce,
      'rejected' || 'reject-once' => AcpDecision.rejectOnce,
      'cancel' || 'cancelled' => AcpDecision.cancel,
      _ => null,
    };
    if (decision == null) return const {};
    await client.respond(eventId, decision);
    return const {};
  }

  Future<Object?> _sessionList() async {
    // An adapter that cannot enumerate its catalog (not installed, not signed
    // in, first start) must not turn the whole drawer into an error: fall back
    // to the one directory this carrier knows, and let each row carry on.
    late final List<AcpWorkspace> workspaces;
    try {
      workspaces = await client.listWorkspaces();
    } on Object {
      final cwd = defaultCwd;
      if (cwd == null) rethrow;
      workspaces = [AcpWorkspace(path: cwd, title: cwd.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? cwd)];
    }
    final rows = <String, Map<String, Object?>>{};
    final failures = <Map<String, Object?>>[];
    final failedPaths = <String>{};
    // One round trip per workspace; over a relay that is 0.4 s each, so ask in
    // parallel and merge. A failing workspace must not hide the others.
    final listings = await Future.wait(workspaces.map((workspace) => _listWorkspace(workspace, failures, failedPaths)));
    final listed = <String>{};
    for (final (workspace, sessions) in listings) {
      for (final session in sessions) {
        _sessions[session.id] = session;
        // First answer wins: a Host that lists one session under two
        // directories must not move it around between refreshes.
        _sessionCwd[session.id] ??= workspace.path;
        listed.add(session.id);
        final prefixed = acpSessionId(backend, session.id);
        rows[prefixed] = _rowOf(session, _sessionCwd[session.id] ?? workspace.path);
      }
    }
    // A workspace that failed this time keeps whatever it already taught us:
    // dropping its rows reads as "those sessions were deleted".
    for (final entry in _sessions.entries) {
      if (listed.contains(entry.key)) continue;
      final cwd = _sessionCwd[entry.key];
      if (cwd == null || !failedPaths.contains(cwd)) continue;
      rows[acpSessionId(backend, entry.key)] = _rowOf(entry.value, cwd);
    }
    final items = rows.values.toList(growable: false)
      ..sort((a, b) => (b['updatedAt'] as int).compareTo(a['updatedAt'] as int));
    return {
      'items': items,
      'hasMore': false,
      // Directories that could not be read, so a caller can say so instead of
      // showing an empty list. Ignored by older clients.
      'failures': failures,
    };
  }

  /// `dsh/sessionList` for one workspace, retried once.
  ///
  /// A relay round trip can fail on its own; retrying keeps a transient blip
  /// from emptying a whole directory. When it still fails the path is reported
  /// in [failures] and collected in [failedPaths].
  Future<(AcpWorkspace, List<AcpSessionSummary>)> _listWorkspace(
    AcpWorkspace workspace,
    List<Map<String, Object?>> failures,
    Set<String> failedPaths,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return (workspace, await client.listSessions(workspace.path));
      } on Object catch (error) {
        if (attempt == 0) continue;
        failedPaths.add(workspace.path);
        failures.add({
          'workspace': workspace.path,
          'code': error is AcpException ? error.code : 'acp/internal',
        });
      }
    }
    return (workspace, const <AcpSessionSummary>[]);
  }

  /// One `session/list` row for [session], in [cwd].
  Map<String, Object?> _rowOf(AcpSessionSummary session, String cwd) {
    final prefixed = acpSessionId(backend, session.id);
    final title = _titles[session.id] ?? session.title;
    return {
      'sessionId': prefixed,
      'updatedAt': session.updatedAt ?? session.createdAt ?? DateTime.now().millisecondsSinceEpoch,
      'running': _liveTurns.contains(session.id),
      // Always false: the App hides `blank` rows from the drawer, and ACP has
      // no stored "never prompted" flag to tell a fresh session from one an
      // adapter simply never titled. Hiding a real conversation is worse than
      // showing an untitled one.
      'blank': false,
      'agentAvailable': true,
      'cwd': cwd,
      'projections': {
        'kind': 'cached',
        'asOfSeq': -1,
        'values': {
          'title': title,
          'sessionListMetadata': {'blank': false, 'lastPromptAt': null},
          'modelSelection': ?_modelSelectionOf(session.id),
        },
      },
    };
  }

  Future<Object?> _sessionPage(Map<String, Object?> request) async {
    final native = _nativeId(request['address'] is Map ? acpMap(request['address'])['sessionId'] : request['sessionId']);
    if (native == null) throw AcpException('session/not-found', 'The request has no $backend session address.');
    final history = await client.history(native);
    // Knowing the directory here saves the reverse lookup when this session is
    // followed next (the history endpoint reports it on newer Hosts).
    final reported = history.cwd;
    if (reported != null) _sessionCwd[native] ??= reported;
    if (history.permissionPreset != null) _permissions[native] = history.permissionPreset!;
    final all = history.events;
    final beforeSeq = acpInt(request['beforeSeq']);
    final throughSeq = acpInt(request['throughSeq']);
    var records = all;
    if (beforeSeq != null || throughSeq != null) {
      // `beforeSeq`: everything strictly older (load earlier); `throughSeq`:
      // the tail page ending at the newest seq the caller holds.
      records = [
        for (final record in all)
          if (_seqWithin(record, beforeSeq: beforeSeq, throughSeq: throughSeq)) record,
      ];
    }
    var hasMore = false;
    final maxMessages = acpInt(request['maxMessages']);
    if (beforeSeq != null && maxMessages != null && maxMessages > 0 && records.length > maxMessages) {
      records = records.sublist(records.length - maxMessages);
      hasMore = true;
    }
    var maxSeq = -1;
    for (final record in records) {
      final seq = acpInt(acpMap(record['event'])['seq']);
      if (seq != null && seq > maxSeq) maxSeq = seq;
    }
    return {
      'records': records,
      'hasMore': hasMore,
      'cursor': maxSeq,
    };
  }

  static bool _seqWithin(Map<String, Object?> record, {required int? beforeSeq, required int? throughSeq}) {
    final seq = acpInt(acpMap(record['event'])['seq']);
    if (seq == null) return false;
    if (beforeSeq != null) return seq < beforeSeq;
    return throughSeq == null || seq <= throughSeq;
  }

  final Map<String, String> _permissions = {};

  /// ACP has no workspace registry: a workspace is just a directory a session
  /// was created in. The App still needs one to bind a new session, so accept
  /// any absolute directory and hand back a view for it.
  Future<Object?> _workspaceCreate(Map<String, Object?> request) async {
    final path = acpString(request['path']);
    if (path == null || !(path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path))) {
      throw const AcpException('gateway/bad-request', 'An absolute directory is required.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'workspace': {
        'workspaceId': acpWorkspaceId(backend, path),
        'path': path,
        'title': path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).lastOrNull ?? path,
        'sessionIds': <String>[],
        'sessionCount': 0,
        'createdAt': now,
        'updatedAt': now,
      },
      'created': true,
    };
  }

  Future<Object?> _sessionCreate(Map<String, Object?> request) async {
    final workspaceId = request['workspaceId'];
    final cwd =
        (workspaceId is String ? acpWorkspacePath(backend, workspaceId) : null) ??
        (request['cwd'] is String ? request['cwd'] as String : null) ??
        defaultCwd;
    if (cwd == null) throw AcpException('gateway/bad-request', 'A $backend session needs a workspace or cwd.');
    final native = await client.newSession(cwd, mode: acpString(request['mode']));
    _sessionCwd[native] = cwd;
    final pending = _pendingModel;
    if (pending != null) _models[native] = pending;
    final prefixed = acpSessionId(backend, native);
    if (!_hostEvents.isClosed) {
      _hostEvents.add({
        'type': 'emit',
        'event': 'api-session/added',
        'args': [
          {
            'sessionId': prefixed,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'running': false,
            'blank': true,
            'agentAvailable': true,
            'cwd': cwd,
            'projections': {
              'kind': 'cached',
              'asOfSeq': -1,
              'values': {
                'title': '',
                'sessionListMetadata': {'blank': true, 'lastPromptAt': null},
              },
            },
          },
        ],
      });
    }
    return {'sessionId': prefixed};
  }

  Future<Object?> _sessionPrompt(Map<String, Object?> request) async {
    final native = _nativeId(request['sessionId']);
    if (native == null) throw AcpException('session/not-found', 'The prompt has no $backend session address.');
    // Translation happens before anything is sent: a part the backend cannot
    // take becomes a visible refusal instead of a prompt that silently lost
    // the attachment the person thought they had sent.
    final prompt = _promptBlocks(request['content']);
    if (prompt.isEmpty) throw const AcpException('gateway/bad-request', 'The prompt has no text content.');
    final text = acpContentText(request['content']);
    final requestId = acpString(request['requestId']);
    _pendingPrompt[native] = (text: text, rpcId: requestId);
    final choice = _models[native] ?? _pendingModel;
    if (choice != null && _syncedModel[native] != choice) {
      try {
        await client.selectModel(native, choice.model, reasoningEffort: choice.effort);
      } on Object {
        // A model the backend no longer offers must not block the prompt, and
        // must not be retried before every message (each retry is a round trip
        // that delays the turn for no benefit).
      }
      _syncedModel[native] = choice;
    }
    try {
      await client.prompt(native, prompt);
    } on Object {
      // A refused prompt never produces a turn; a later frame must not pick up
      // this text as its user echo.
      _pendingPrompt.remove(native);
      rethrow;
    }
    return {'ok': true};
  }

  Future<Object?> _sessionCancel(Map<String, Object?> request) async {
    final native = _nativeId(request['address'] is Map ? acpMap(request['address'])['sessionId'] : request['sessionId']);
    if (native == null) return {'accepted': false};
    await client.cancel(native);
    // The pending prompt stays until the terminal frame arrives: it is the
    // only copy of the text, and the echo synthesized from it is what retires
    // the App's "sending" bubble when a turn ends before any update.
    return {'accepted': true};
  }

  Future<Object?> _sessionRename(Map<String, Object?> request) async {
    final native = _nativeId(request['sessionId']);
    final title = acpString(request['title']) ?? acpString(request['name']);
    if (native != null && title != null) {
      _titles[native] = title;
      if (!_hostEvents.isClosed) {
        _hostEvents.add({
          'type': 'emit',
          'event': 'api-session/renamed',
          'args': [acpSessionId(backend, native), title],
        });
      }
    }
    return const {};
  }

  Future<Object?> _modelCatalog(Map<String, Object?> request) async {
    final native = _nativeId(request['sessionId']);
    final models = <Map<String, Object?>>[];
    String? current;
    if (native != null) {
      try {
        final raw = await client.sessionModels(native);
        current = _readModels(raw, models) ?? _models[native]?.model;
      } on Object {
        // A session without a live backend still shows the composer; the
        // catalog then falls back to the last known selection.
      }
    }
    return {
      'default': {'provider': backend, 'model': ?current},
      'routableProviders': [backend],
      'groups': [
        {'id': backend, 'name': agent.label, 'models': models},
      ],
      'failures': <Object?>[],
    };
  }

  /// Reads `sessionModels` tolerantly: adapters report either a flat `models`
  /// list or ACP `configOptions` with a `model` category.
  String? _readModels(Map<String, Object?> raw, List<Map<String, Object?>> out) {
    String? first;
    for (final item in acpList(raw['models'])) {
      final map = acpMap(item);
      final id = acpString(map['id']) ?? acpString(map['model']) ?? acpString(map['value']);
      if (id == null) continue;
      first ??= id;
      out.add({'id': id, 'name': acpString(map['name']) ?? acpString(map['displayName']) ?? id});
    }
    for (final option in acpList(raw['configOptions'])) {
      final map = acpMap(option);
      if (map['category'] != 'model' && map['id'] != 'model') continue;
      for (final choice in acpList(map['options'])) {
        final choiceMap = acpMap(choice);
        final id = acpString(choiceMap['value']);
        if (id == null) continue;
        first ??= id;
        out.add({'id': id, 'name': acpString(choiceMap['name']) ?? id});
      }
      final current = acpString(map['currentValue']);
      if (current != null) first ??= current;
    }
    return first;
  }

  Future<Object?> _selectModel(Map<String, Object?> request) async {
    final model = acpString(request['model']);
    if (model == null || model.length > 128) {
      throw const AcpException('gateway/bad-request', 'A model id is required.');
    }
    final effort = acpString(request['reasoningEffort']);
    final choice = (model: model, effort: effort);
    final native = _nativeId(request['sessionId']);
    if (native != null) {
      _models[native] = choice;
      await client.selectModel(native, model, reasoningEffort: effort);
      _syncedModel[native] = choice;
    } else {
      _pendingModel = choice;
    }
    return {
      'selected': {'provider': backend, 'model': model, 'reasoningEffort': ?effort},
      'defaultSave': {'status': 'skipped'},
    };
  }

  Future<Object?> _selectPermission(Map<String, Object?> request) async {
    final preset = acpString(request['preset']);
    if (preset == null || (preset != 'workspace-write' && preset != 'danger-full-access')) {
      throw const AcpException('gateway/bad-request', 'Unknown permission preset.');
    }
    final native = _nativeId(request['sessionId']);
    if (native != null) {
      _permissions[native] = preset;
      await client.selectPermission(native, preset);
    }
    return {'preset': preset};
  }

  Future<Object?> _projections(Map<String, Object?> request) async {
    final native = _nativeId(request['sessionId']);
    if (native == null) return null;
    final cached = _sessions[native];
    return {
      'asOfSeq': -1,
      'values': {
        'title': _titles[native] ?? cached?.title ?? '',
        'agentPreset': null,
        // Never `blank`: the App hides blank rows, and ACP cannot prove a
        // stored session was never prompted (see `_rowOf`).
        'sessionListMetadata': {'blank': false, 'lastPromptAt': null},
        if (_models[native] != null)
          'modelSelection': {
            'lastUsed': {'provider': backend, 'model': _models[native]!.model},
          },
      },
    };
  }

  Future<Object?> _tool(String endpoint, Map<String, Object?> args) async {
    final rawId = acpString(args['agentId']) ?? acpString(args['sessionId']);
    final native = _nativeId(rawId ?? '');
    if (native == null) throw AcpException('session/not-found', '$endpoint has no $backend session address.');
    // The Host validates every scope id against `<backend>:<native>`
    // (`AcpWorkspaceTools.payload`); sending the bare native id is refused
    // with PERMISSION_DENIED. The RPC parameter stays native, the args keep
    // the prefixed scope.
    final scoped = acpSessionId(backend, native);
    final forwarded = <String, Object?>{...args};
    for (final key in const ['agentId', 'sessionId', 'workspaceFileScopeId']) {
      if (forwarded.containsKey(key)) forwarded[key] = scoped;
    }
    return client.toolCall(native, endpoint, forwarded);
  }

  String? _nativeId(Object? sessionId) {
    if (sessionId is! String || sessionId.isEmpty) return null;
    return acpNativeSessionId(backend, sessionId) ?? sessionId;
  }

  /// ACP content blocks for one `session/prompt`.
  ///
  /// Text and inline images map one-to-one. A `file` part carries an upload
  /// receipt that only the Harness can resolve, so it is refused: sending the
  /// prompt anyway would drop the file without telling anyone.
  List<Map<String, Object?>> _promptBlocks(Object? content) {
    final blocks = <Map<String, Object?>>[];
    for (final part in acpList(content)) {
      final map = acpMap(part);
      switch (acpString(map['type'])) {
        case 'text':
          final text = acpString(map['text']);
          if (text != null) blocks.add({'type': 'text', 'text': text});
        case 'image':
          // The Host's prompt policy refuses inline images for every backend
          // this App exposes (only antigravity and hermes accept them), so the
          // whole turn would come back as `METHOD_NOT_ALLOWED`. Refusing here
          // keeps the person's text out of a turn that can never start and
          // gives a sentence they can act on.
          if (backend != 'antigravity' && backend != 'hermes') {
            throw AcpException(
              'ACP_ATTACHMENT_UNSUPPORTED',
              '$backend sessions cannot take images; send the text on its own.',
            );
          }
          final data = acpString(map['data']);
          final mediaType = acpString(map['mediaType']) ?? acpString(map['mimeType']);
          if (data == null || mediaType == null) {
            throw const AcpException('gateway/bad-request', 'An image attachment arrived without its data.');
          }
          // ACP names the type `mimeType`; the App calls the same field mediaType.
          blocks.add({'type': 'image', 'mimeType': mediaType, 'data': data});
        case 'file':
          throw AcpException(
            'ACP_ATTACHMENT_UNSUPPORTED',
            'A $backend session cannot take file attachments; images and text still work.',
          );
        default:
          final text = acpString(map['text']);
          if (text != null) blocks.add({'type': 'text', 'text': text});
      }
    }
    return blocks;
  }

  /// Native ids this connection already loaded (`session/load`).
  ///
  /// Loading twice is not harmless: for Claude the Host refuses while a reply
  /// is running (`PROMPT_IN_PROGRESS`), so a second screen or a rotation would
  /// lose the live stream of a running turn. Cleared when the tunnel drops,
  /// because ownership dies with the connection.
  final Set<String> _loaded = {};

  bool isLoaded(String native) => _loaded.contains(native);

  void markLoaded(String native) => _loaded.add(native);

  void clearLoaded() => _loaded.clear();

  /// Waterfall item for a permission request of [frame], if it is one.
  Map<String, Object?>? projectionApproval(AcpFrame frame) {
    final native = acpSessionStreamId(frame.streamId) ?? frame.sessionId;
    if (native == null) return null;
    return AcpSessionProjection.approvalFor(frame, acpSessionId(backend, native));
  }

  Map<String, Object?>? _modelSelectionOf(String native) {
    final choice = _models[native];
    return choice == null ? null : {'lastUsed': {'provider': backend, 'model': choice.model}};
  }

  ({String text, String? rpcId})? takePendingPrompt(String native) => _pendingPrompt.remove(native);

  String? cwdOf(String native) => _sessionCwd[native] ?? defaultCwd;

  /// Directory of [native], asking the Host when this carrier has never listed
  /// the workspace it lives in.
  ///
  /// A cold start restores a stored session id before `session/list` has run,
  /// so refusing here made every restored Claude/OpenCode session fail to open
  /// until the list happened to finish. The reverse lookup fills the cache for
  /// every session of the workspaces it walks, so it is paid at most once.
  Future<String?> resolveCwd(String native) async {
    final known = _sessionCwd[native];
    if (known != null) return known;
    try {
      final workspaces = await client.listWorkspaces();
      for (final workspace in workspaces) {
        try {
          final sessions = await client.listSessions(workspace.path);
          for (final session in sessions) {
            _sessionCwd[session.id] ??= workspace.path;
            _sessions[session.id] = session;
          }
        } on Object {
          // Another workspace may still know this session.
          continue;
        }
        final found = _sessionCwd[native];
        if (found != null) return found;
      }
    } on Object {
      // Fall through: the caller reports the missing workspace.
    }
    return _sessionCwd[native] ?? defaultCwd;
  }

  bool get isClosed => _closed;
}

typedef _ModelChoice = ({String model, String? effort});

/// One mux link: `$events` is synthesized locally; `session/follow` and
/// `workspace/follow` are served from the ACP domain.
class _AcpLink implements DshMuxLink {
  _AcpLink(this._carrier);

  final AcpCarrier _carrier;
  final Map<String, _Follow> _follows = {};

  /// Stream ids the App cancelled while `_openFollow` was still awaiting the
  /// Host. A follow takes several round trips to open, so leaving this out let
  /// a page switch orphan an ACP stream slot that nothing would ever close.
  final Set<String> _cancelled = {};

  /// Follows being set up right now; only these can receive a cancel.
  final Set<String> _opening = {};
  final String _clientId = 'acp-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  DshMuxFrameHandler? _frameHandler;
  StreamSubscription<Object>? _lostSub;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  StreamSubscription<AcpFrame>? _framesSub;
  StreamSubscription<String>? _closedSub;
  StreamSubscription<void>? _catalogSub;
  String? _eventsStreamId;
  bool _closed = false;

  AcpClient get _client => _carrier.client;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _frameHandler = onFrame;
    _eventsSub = _carrier.hostEvents.listen((frame) {
      final streamId = _eventsStreamId;
      if (!_closed && streamId != null) _emit({'type': 'item', 'streamId': streamId, 'value': frame});
    });
    _framesSub = _client.frames.listen(_handleFrame);
    _closedSub = _client.closedStreams.listen((acpStreamId) {
      // The Host names the ACP stream it closed; the mux stream the App opened
      // has a different id, so match on the ACP one.
      String? muxStreamId;
      for (final entry in _follows.entries) {
        if (entry.value.acpStreamId == acpStreamId) {
          muxStreamId = entry.key;
          break;
        }
      }
      if (muxStreamId == null) return;
      final follow = _follows.remove(muxStreamId);
      _forgetTurn(follow);
      unawaited(follow?.close() ?? Future<void>.value());
      _emit({'type': 'end', 'streamId': muxStreamId});
    });
    _catalogSub = _client.catalogChanged.listen((_) {
      // Another device archived a session; the App refreshes its own list on
      // the next open, so nothing is synthesized here.
    });
    _lostSub = _carrier.lost?.listen((error) {
      if (_closed) return;
      _closed = true;
      // Session ownership lives on the Host connection that claimed it, so a
      // new tunnel must load every session again.
      _carrier.clearLoaded();
      // Every open follow owns a Host-side ACP stream slot (16 per
      // connection). The Host does not report their loss, so drop them here:
      // otherwise each reconnect leaves a slot behind until new sessions are
      // refused with RATE_LIMITED.
      final follows = _follows.values.toList(growable: false);
      _follows.clear();
      for (final native in _carrier._liveTurns.toList(growable: false)) {
        _carrier.publishRunning(native, false);
      }
      _carrier._liveTurns.clear();
      for (final follow in follows) {
        unawaited(follow.close());
      }
      onLost(DshCarrierLostException('acp link lost'), error);
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
            // `home` is a directory on the Host, never a product name: the App
            // shows it as the place new work starts.
            'host': {'home': _carrier.defaultCwd ?? ''},
          },
        });
      case 'session/follow':
        _cancelled.remove(streamId);
        unawaited(_openFollow(streamId, argsMap));
      case 'workspace/follow':
        unawaited(_openWorkspaces(streamId));
      default:
        _emitError(streamId, 'METHOD_NOT_ALLOWED', '$endpoint is not available on a ${_carrier.backend} host.');
    }
  }

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) {
    final follow = _follows.remove(streamId);
    if (follow != null) {
      _forgetTurn(follow);
      unawaited(follow.close());
      return;
    }
    // The follow may still be opening; remember it so the open path releases
    // the ACP stream it is about to own.
    if (_opening.contains(streamId)) _cancelled.add(streamId);
    _emit({'type': 'end', 'streamId': streamId});
  }

  @override
  Future<void> close(int code, String reason) async {
    if (_closed) return;
    _closed = true;
    await _lostSub?.cancel();
    await _eventsSub?.cancel();
    await _framesSub?.cancel();
    await _closedSub?.cancel();
    await _catalogSub?.cancel();
    final follows = _follows.values.toList(growable: false);
    _follows.clear();
    _cancelled.clear();
    for (final follow in follows) {
      await follow.close();
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _openFollow(String streamId, Map<String, Object?> args) async {
    _opening.add(streamId);
    try {
      await _openFollowStream(streamId, args);
    } finally {
      _opening.remove(streamId);
      _cancelled.remove(streamId);
    }
  }

  Future<void> _openFollowStream(String streamId, Map<String, Object?> args) async {
    final request = acpMap(args['request']);
    final sessionId = acpString(acpMap(request['address'])['sessionId']);
    final native = sessionId == null ? null : acpNativeSessionId(_carrier.backend, sessionId);
    if (native == null) {
      _emitError(streamId, 'gateway/bad-request', 'The follow request has no ${_carrier.backend} session address.');
      return;
    }
    // Absent means "no deltas requested" (the App omits it off-screen), so the
    // stream can skip assistant-stream frames and save the downlink.
    final assistantStream = request['assistantStream'] == true;
    final cwd = await _carrier.resolveCwd(native);
    if (_abandoned(streamId)) return;
    if (cwd == null) {
      _emitError(
        streamId,
        'ACP_UNKNOWN_WORKSPACE',
        'The ${_carrier.backend} backend did not report a directory for this session; '
            'open it from the session list once so its workspace is known.',
        // The Host may still be building its workspace index; let the App
        // reopen (it re-runs the lookup) instead of showing a terminal error.
        retryable: true,
      );
      return;
    }
    try {
      // Ownership is per connection: only the first follow of a session has to
      // claim it. Re-loading while a reply runs is refused by the Host for
      // Claude, which would strand a second screen on a dead stream.
      if (!_carrier.isLoaded(native)) {
        await _client.loadSession(native);
        _carrier.markLoaded(native);
      }
      _carrier._sessionCwd[native] = cwd;
      if (_abandoned(streamId)) return;
      final history = await _client.history(native);
      final maxSeq = history.events.fold<int>(-1, (max, record) {
        final seq = acpInt(acpMap(record['event'])['seq']);
        return seq != null && seq > max ? seq : max;
      });
      // Live turns continue the replayed numbering; restarting at 1 would make
      // the transcript merge the new turn into the last stored one.
      var nextTurn = 1;
      for (final record in history.events) {
        final event = acpMap(record['event']);
        if (event['type'] != 'turn/start') continue;
        final turn = acpInt(acpMap(event['data'])['turn']);
        if (turn != null && turn >= nextTurn) nextTurn = turn + 1;
      }
      final live = AcpSessionProjection(
        sessionId: acpSessionId(_carrier.backend, native),
        provider: _carrier.backend,
        cwd: cwd,
        title: _carrier._titles[native] ?? _carrier._sessions[native]?.title,
        model: _carrier._models[native]?.model,
        // The first live event takes the next free sequence number, so history
        // and live records stay contiguous.
        cursor: maxSeq,
        nextTurn: nextTurn,
      );
      final snapshot = live.snapshot(records: history.events);
      if (_abandoned(streamId)) return;
      _emit({'type': 'item', 'streamId': streamId, 'value': snapshot});
      final acpStreamId = await _client.openStream(native);
      if (_abandoned(streamId)) {
        await _client.closeStream(acpStreamId);
        return;
      }
      final follow = _Follow(native, streamId, acpStreamId, live, assistantStream: assistantStream)..bind(_client);
      _follows[streamId] = follow;
      // A cancel that landed while the stream was opening never saw the follow.
      if (_abandoned(streamId)) {
        _follows.remove(streamId);
        _forgetTurn(follow);
        await follow.close();
      }
    } on AcpException catch (error) {
      _emitError(streamId, error.code, error.message);
    } on Object catch (error) {
      _emitError(streamId, 'acp/stream', 'Could not open the ${_carrier.backend} session: $error');
    }
  }

  /// Whether this open must stop: the link closed, or the App cancelled the
  /// stream while the follow was still being set up.
  ///
  /// Consumes the cancellation mark, so the caller aborts exactly once.
  bool _abandoned(String streamId) => _closed || _cancelled.remove(streamId);

  Future<void> _openWorkspaces(String streamId) async {
    try {
      final workspaces = await _client.listWorkspaces();
      final items = <Map<String, Object?>>[];
      for (final workspace in workspaces) {
        items.add({
          'workspaceId': acpWorkspaceId(_carrier.backend, workspace.path),
          'path': workspace.path,
          'title': workspace.title,
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
      _emitError(streamId, 'acp/workspaces', 'Could not read ${_carrier.backend} workspaces: $error');
    }
  }

  void _handleFrame(AcpFrame frame) {
    if (_closed) return;
    final approval = _carrier.projectionApproval(frame);
    if (approval != null) {
      final streamId = _eventsStreamId;
      if (streamId != null) _emit({'type': 'item', 'streamId': streamId, 'value': approval});
      return;
    }
    final native = acpSessionStreamId(frame.streamId) ?? frame.sessionId;
    if (native == null) return;
    // Two screens can follow the same session, and a replacement follow can
    // overlap the one it replaced; every live projection needs the frame or
    // one of them silently stops updating.
    final follows = [
      for (final candidate in _follows.values)
        if (candidate.native == native) candidate,
    ];
    if (follows.isEmpty) return;
    // The Host buffers frames while the client reconnects and re-delivers them
    // as `catchUp` on the terminal frame; replay them in order.
    final replay = frame.isTurnEnd ? frame.catchUp : const <AcpFrame>[];
    // A catch-up may already carry the backend's own echo; synthesizing
    // another one would show the message twice.
    final echoed = replay.any((item) => item.updateKind == 'user_message_chunk');
    final pending = _carrier.takePendingPrompt(native);
    for (final follow in follows) {
      final projection = follow.projection;
      if (pending != null) {
        // Bind the App's request id to the next user message, so its optimistic
        // bubble retires.
        projection.expectPrompt(pending.rpcId);
        if (!echoed && frame.updateKind != 'user_message_chunk') {
          final echo = AcpFrame(
            streamId: frame.streamId,
            method: 'session/update',
            params: {
              'sessionId': native,
              'update': {
                'sessionUpdate': 'user_message_chunk',
                'content': {'type': 'text', 'text': pending.text},
              },
            },
          );
          _emitValues(follow, projection.handle(echo));
        }
      }
      for (final item in replay) {
        _emitValues(follow, projection.handle(item));
      }
      _emitValues(follow, projection.handle(frame));
      _trackTurn(native);
    }
  }

  /// Mirrors the live turn state into the carrier so `session/list` can mark a
  /// running session instead of always saying `running: false`.
  void _trackTurn(String native) {
    final open = _follows.values.any((follow) => follow.native == native && follow.projection.turnOpen);
    final was = _carrier._liveTurns.contains(native);
    if (open) {
      _carrier._liveTurns.add(native);
    } else {
      _carrier._liveTurns.remove(native);
    }
    if (open != was) _carrier.publishRunning(native, open);
  }

  void _forgetTurn(_Follow? follow) {
    if (follow == null) return;
    final native = follow.native;
    final stillOpen = _follows.values.any((other) => other.native == native && other.projection.turnOpen);
    if (stillOpen) return;
    if (_carrier._liveTurns.remove(native)) _carrier.publishRunning(native, false);
  }

  /// Emits projected values to one follow, honouring its `assistantStream`
  /// choice: a follow opened without it (the App does this off-screen) gets
  /// durable events only, which is what makes the bandwidth saving real.
  void _emitValues(_Follow follow, List<Map<String, Object?>> values) {
    for (final value in values) {
      if (!follow.assistantStream && value['type'] == 'assistant-stream') continue;
      _emit({'type': 'item', 'streamId': follow.streamId, 'value': value});
    }
  }

  void _emit(Map<String, Object?> frame) {
    if (!_closed) _frameHandler?.call(frame);
  }

  void _emitError(String streamId, String code, String message, {bool retryable = false}) => _emit({
    'type': 'error',
    'streamId': streamId,
    'error': {'code': code, 'message': message, if (retryable) 'details': {'retryable': true}},
  });
}

class _Follow {
  _Follow(this.native, this.streamId, this.acpStreamId, this.projection, {this.assistantStream = true});

  final String native;

  /// Mux stream id the App opened.
  final String streamId;

  /// Whether this follow asked for live token deltas.
  final bool assistantStream;

  /// Host-side ACP stream this follow owns (`agent.acp.stream.open`).
  ///
  /// The Host caps concurrent ACP streams per connection (16); a follow that
  /// is never closed therefore leaks one slot per tab switch until every
  /// further open answers RATE_LIMITED.
  final String acpStreamId;

  final AcpSessionProjection projection;

  AcpClient? _client;

  void bind(AcpClient client) => _client = client;

  Future<void> close() async {
    final client = _client;
    _client = null;
    if (client != null) await client.closeStream(acpStreamId);
  }
}
