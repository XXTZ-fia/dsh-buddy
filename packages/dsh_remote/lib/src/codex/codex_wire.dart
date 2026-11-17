// Wire contract of the Codex Remote domain (ds-harness-remote 0.6.x,
// `codex.app.*`): models and tolerant parsers shared by the client and the
// projection. Field names follow `codex app-server generate-json-schema`
// (verified against codex-cli 0.167).
library;

// -----------------------------------------------------------------------------
// Names and identifiers
// -----------------------------------------------------------------------------

/// Capability the Host must declare before the Codex domain is usable.
const String codexCapability = 'codex.appserver.v1';

/// Chunked request/response transfer for the Codex domain.
const String codexTransferCapability = 'codex.appserver.transfer.v1';

/// Session ids of projected Codex threads (`codex:<threadId>`).
const String codexSessionPrefix = 'codex:';

/// Workspace ids of Codex projects (`codex-workspace:project:<path>`).
const String codexWorkspacePrefix = 'codex-workspace:project:';

/// Largest history page the Host's `dsh/sessionHistory` policy accepts.
const int codexHistoryMaxMessages = 200;

/// Wire methods of the domain itself (tunnel level).
const String codexCallMethod = 'codex.app.call';
const String codexRespondMethod = 'codex.app.respond';
const String codexStreamOpenMethod = 'codex.app.stream.open';
const String codexStreamCloseMethod = 'codex.app.stream.close';
const String codexTransferOpenMethod = 'codex.app.transfer.open';
const String codexTransferChunkMethod = 'codex.app.transfer.chunk';
const String codexTransferCommitMethod = 'codex.app.transfer.commit';
const String codexTransferReadMethod = 'codex.app.transfer.read';
const String codexTransferCloseMethod = 'codex.app.transfer.close';

/// Events the Host publishes for a Codex stream.
const String codexFrameEvent = 'codex.app.frame';
const String codexStreamClosedEvent = 'codex.app.stream.closed';

/// `codex:<threadId>` for a native thread id.
String codexSessionId(String threadId) => '$codexSessionPrefix$threadId';

/// Native thread id of a projected session id, or `null` for another dialect.
String? codexThreadIdOf(String sessionId) =>
    sessionId.startsWith(codexSessionPrefix) && sessionId.length > codexSessionPrefix.length
    ? sessionId.substring(codexSessionPrefix.length)
    : null;

/// `codex-workspace:project:<path>` for a project root.
String codexWorkspaceId(String path) => '$codexWorkspacePrefix$path';

/// Project root of a projected workspace id, or `null` for another dialect.
String? codexWorkspacePathOf(String workspaceId) =>
    workspaceId.startsWith(codexWorkspacePrefix) && workspaceId.length > codexWorkspacePrefix.length
    ? workspaceId.substring(codexWorkspacePrefix.length)
    : null;

// -----------------------------------------------------------------------------
// Tolerant readers
// -----------------------------------------------------------------------------

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((key, v) => MapEntry(key.toString(), v));
  return const {};
}

List<Object?> _list(Object? value) => value is List ? value.cast<Object?>() : const [];

String? _str(Object? value) => value is String && value.isNotEmpty ? value : null;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.toInt();
  return null;
}

bool? _bool(Object? value) => value is bool ? value : null;

DateTime? _time(Object? value) {
  final ms = _int(value);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

// -----------------------------------------------------------------------------
// Catalog
// -----------------------------------------------------------------------------

/// One page of a Codex listing (`project/list`, `thread/list`).
class CodexPage<T> {
  const CodexPage(this.items, {this.nextCursor});

  final List<T> items;

  /// Opaque cursor for the next page; `null` when the listing is exhausted.
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  static CodexPage<T> parse<T>(Object? json, T? Function(Map<String, Object?>) item) {
    final map = _map(json);
    final items = _list(map['data']).map(_map).map(item).whereType<T>().toList(growable: false);
    return CodexPage(items, nextCursor: _str(map['nextCursor']));
  }
}

/// A Codex project: the unit the app presents as a workspace.
class CodexProject {
  const CodexProject({required this.id, required this.name, required this.roots, this.position, this.updatedAt});

  factory CodexProject.fromJson(Map<String, Object?> json) => CodexProject(
    id: _str(json['id']) ?? '',
    name: _str(json['name']) ?? '',
    roots: _list(json['roots']).map(_map).map((root) => _str(root['path'])).whereType<String>().toList(growable: false),
    position: _int(json['position']),
    updatedAt: _time(json['updatedAt']),
  );

  /// A usable project needs an id, a name and at least one absolute root — the
  /// same rule the Host applies before publishing the catalog.
  static CodexProject? tryFromJson(Map<String, Object?> json) {
    final project = CodexProject.fromJson(json);
    if (project.id.isEmpty || project.name.isEmpty || project.roots.isEmpty) return null;
    return project;
  }

  final String id;
  final String name;

  /// Absolute roots; the first one is the project's workspace path.
  final List<String> roots;
  final int? position;
  final DateTime? updatedAt;

  String? get path => roots.isEmpty ? null : roots.first;

  /// Workspace id the app uses for this project.
  String get workspaceId => codexWorkspaceId(path ?? id);
}

/// A thread as listed by `thread/list` (no turns).
class CodexThreadSummary {
  const CodexThreadSummary({
    required this.id,
    this.sessionId,
    this.projectId,
    this.name,
    this.preview,
    this.cwd,
    this.model,
    this.modelProvider,
    this.reasoningEffort,
    this.createdAt,
    this.updatedAt,
    this.archived = false,
    this.pinned = false,
    this.status,
  });

  factory CodexThreadSummary.fromJson(Map<String, Object?> json) => CodexThreadSummary(
    id: _str(json['id']) ?? '',
    sessionId: _str(json['sessionId']),
    projectId: _str(json['projectId']),
    name: _str(json['name']),
    preview: _str(json['preview']),
    cwd: _str(json['cwd']),
    model: _str(json['model']),
    modelProvider: _str(json['modelProvider']),
    reasoningEffort: _str(json['reasoningEffort']),
    createdAt: _time(json['createdAt']),
    updatedAt: _time(json['updatedAt']),
    archived: _bool(json['archived']) ?? false,
    pinned: _bool(json['isPinned']) ?? false,
    status: _str(_map(json['status'])['type']) ?? _str(json['status']),
  );

  final String id;
  final String? sessionId;
  final String? projectId;
  final String? name;
  final String? preview;
  final String? cwd;
  final String? model;
  final String? modelProvider;
  final String? reasoningEffort;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool archived;
  final bool pinned;
  final String? status;

  /// Projected session id.
  String get session => codexSessionId(id);

  /// Title shown in session lists: the user rename wins over the preview.
  String get title {
    final renamed = name?.trim();
    if (renamed != null && renamed.isNotEmpty) return renamed;
    final firstLine = preview?.trim().split('\n').first.trim();
    if (firstLine != null && firstLine.isNotEmpty) return firstLine;
    return id;
  }

  bool get isBusy => status == 'active' || status == 'running' || status == 'inProgress';
}

/// One turn item (`userMessage`, `agentMessage`, `reasoning`, `commandExecution`,
/// `fileChange`, `mcpToolCall`, ...). Kept raw: the projection reads the fields
/// it understands and ignores the rest.
class CodexItem {
  const CodexItem(this.raw);

  final Map<String, Object?> raw;

  String get type => _str(raw['type']) ?? '';
  String get id => _str(raw['id']) ?? '';
  DateTime? get createdAt => _time(raw['startedAtMs'] ?? raw['createdAtMs']);

  /// Concatenated text of `content: [{type: 'text', text}]` blocks.
  String get text => _list(
    raw['content'],
  ).map(_map).map((block) => _str(block['text'])).whereType<String>().join();

  bool get isUser => type == 'userMessage';
  bool get isAgent => type == 'agentMessage';
  bool get isReasoning => type == 'reasoning';

  /// Tool-like items the app renders as cards.
  bool get isTool =>
      type == 'commandExecution' || type == 'fileChange' || type == 'mcpToolCall' || type == 'webSearch';
}

/// One turn with its items, as returned by `thread/read(includeTurns: true)`.
class CodexTurn {
  const CodexTurn({
    required this.id,
    required this.items,
    this.status,
    this.startedAt,
    this.completedAt,
    this.error,
  });

  factory CodexTurn.fromJson(Map<String, Object?> json) => CodexTurn(
    id: _str(json['id']) ?? '',
    items: _list(json['items']).map(_map).map(CodexItem.new).toList(growable: false),
    status: _str(json['status']),
    startedAt: _time(json['startedAt']),
    completedAt: _time(json['completedAt']),
    error: json['error'] == null ? null : _map(json['error']),
  );

  final String id;
  final List<CodexItem> items;
  final String? status;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final Map<String, Object?>? error;

  bool get isActive => status == 'active' || status == 'running' || status == 'inProgress';
  bool get failed => status == 'failed' || error != null;
  bool get interrupted => status == 'interrupted' || status == 'cancelled' || status == 'aborted';
}

/// A thread with its turns.
class CodexThread {
  const CodexThread({required this.summary, required this.turns});

  /// Accepts both `thread/read` shapes: `{thread: {...}}` and the bare thread.
  factory CodexThread.fromJson(Object? json) {
    final outer = _map(json);
    final thread = outer['thread'] is Map ? _map(outer['thread']) : outer;
    return CodexThread(
      summary: CodexThreadSummary.fromJson(thread),
      turns: _list(thread['turns']).map(_map).map(CodexTurn.fromJson).toList(growable: false),
    );
  }

  final CodexThreadSummary summary;
  final List<CodexTurn> turns;

  CodexTurn? get activeTurn {
    for (final turn in turns.reversed) {
      if (turn.isActive) return turn;
    }
    return null;
  }
}

// -----------------------------------------------------------------------------
// History (Host-projected, already DSH shaped)
// -----------------------------------------------------------------------------

/// One record of a `dsh/sessionHistory` page: a DSH session-log event and its
/// optional projection view. The event map is fed to
/// `SessionLogEvent.fromJson` unchanged.
class CodexHistoryRecord {
  const CodexHistoryRecord({required this.type, required this.event, this.view = const {}});

  factory CodexHistoryRecord.fromJson(Map<String, Object?> json) =>
      CodexHistoryRecord(type: _str(json['type']) ?? 'event', event: _map(json['event']), view: _map(json['view']));

  final String type;
  final Map<String, Object?> event;
  final Map<String, Object?> view;

  int get seq => _int(event['seq']) ?? -1;
  String get eventType => _str(event['type']) ?? '';
}

/// A page of projected history. Sequence numbers are dense and start at 0 for an
/// empty thread, so [cursor] is the newest seq the page ends at.
class CodexHistoryPage {
  const CodexHistoryPage({
    required this.header,
    required this.cursor,
    required this.nextTurn,
    required this.records,
    required this.hasMore,
    this.activeTurnId,
    this.permissionPreset,
  });

  factory CodexHistoryPage.fromJson(Object? json) {
    final map = _map(json);
    return CodexHistoryPage(
      header: _map(map['header']),
      cursor: _int(map['cursor']) ?? -1,
      nextTurn: _int(map['nextTurn']) ?? 0,
      records: _list(map['records']).map(_map).map(CodexHistoryRecord.fromJson).toList(growable: false),
      hasMore: _bool(map['hasMore']) ?? false,
      activeTurnId: _str(map['activeTurnId']),
      permissionPreset: _str(map['permissionPreset']),
    );
  }

  final Map<String, Object?> header;
  final int cursor;
  final int nextTurn;
  final List<CodexHistoryRecord> records;
  final bool hasMore;
  final String? activeTurnId;
  final String? permissionPreset;

  /// Events only, in wire order (what `DshClient.history` returns).
  List<Map<String, Object?>> get events => records.map((record) => record.event).toList(growable: false);
}

// -----------------------------------------------------------------------------
// Live frames and errors
// -----------------------------------------------------------------------------

/// One app-server notification forwarded by the Host inside a Codex stream.
class CodexFrame {
  const CodexFrame(this.method, this.params);

  factory CodexFrame.fromJson(Object? json) {
    final map = _map(json);
    return CodexFrame(_str(map['method']) ?? '', _map(map['params']));
  }

  final String method;
  final Map<String, Object?> params;

  /// Native thread the frame belongs to, when the payload carries one.
  String? get threadId => _str(params['threadId']) ?? _str(_map(params['thread'])['id']);

  String? get turnId => _str(_map(params['turn'])['id']) ?? _str(params['turnId']);

  CodexItem? get item => params['item'] is Map ? CodexItem(_map(params['item'])) : null;

  String? get itemId => _str(params['itemId']) ?? item?.id;

  String? get delta => _str(params['delta']);
}

/// An app-server request the client must answer (`codex.app.respond`).
class CodexServerRequest {
  const CodexServerRequest({required this.requestId, required this.method, required this.params});

  factory CodexServerRequest.fromJson(Object? json) {
    final map = _map(json);
    final id = map['id'];
    return CodexServerRequest(
      requestId: id is String ? id : '${_int(id) ?? ''}',
      method: _str(map['method']) ?? '',
      params: _map(map['params']),
    );
  }

  final String requestId;
  final String method;
  final Map<String, Object?> params;

  bool get isApproval =>
      method == 'item/commandExecution/requestApproval' ||
      method == 'item/fileChange/requestApproval' ||
      method == 'execCommandApproval' ||
      method == 'applyPatchApproval' ||
      method.endsWith('/requestApproval');
}
