// Wire contract of the Host's Agent ACP gateway (`agent.acp.*`,
// ds-harness-remote 0.6.x). Only the methods in [acpMethodAllowlist] are
// accepted by the Host; everything else is refused with INVALID_MESSAGE.
//
// The gateway is backend-neutral: Claude Code (`claude-agent-acp`), OpenCode
// (`opencode acp`), Cursor and Antigravity all speak the same method set and
// publish the same `session/update` notifications over `agent.acp.frame`.
library;

/// Capability the Host must announce before the ACP domain is usable.
const String acpCapability = 'agent.acp.v1';

/// Chunked request/response transfer for the ACP domain.
const String acpTransferCapability = 'agent.acp.transfer.v1';

/// Host-local workspace files and terminals for an ACP session.
const String acpWorkspaceFilesCapability = 'agent.acp.workspace-files.v1';
const String acpTerminalCapability = 'agent.acp.terminal.v1';

/// Tunnel methods of the domain itself.
const String acpCallMethod = 'agent.acp.call';
const String acpRespondMethod = 'agent.acp.respond';
const String acpStreamOpenMethod = 'agent.acp.stream.open';
const String acpStreamCloseMethod = 'agent.acp.stream.close';
const String acpTransferOpenMethod = 'agent.acp.transfer.open';
const String acpTransferChunkMethod = 'agent.acp.transfer.chunk';
const String acpTransferCommitMethod = 'agent.acp.transfer.commit';
const String acpTransferReadMethod = 'agent.acp.transfer.read';
const String acpTransferCloseMethod = 'agent.acp.transfer.close';

/// Events the Host publishes for an ACP session.
///
/// The Host addresses live frames by session, not by the stream that opened
/// them: `streamId` is always `session:<nativeId>`. That is what lets a
/// reconnected client resume without knowing the previous stream id.
const String acpFrameEvent = 'agent.acp.frame';
const String acpStreamClosedEvent = 'agent.acp.stream.closed';
const String acpCatalogChangedEvent = 'agent.acp.catalog.changed';

/// Prefix of a session-scoped frame's `streamId`.
const String acpSessionStreamPrefix = 'session:';

/// Methods the Host accepts inside `agent.acp.call`.
const Set<String> acpMethodAllowlist = {
  'initialize',
  'session/new',
  'session/load',
  'session/prompt',
  'session/cancel',
  'dsh/sessionList',
  'dsh/sessionHistory',
  'dsh/workspaceList',
  'dsh/sessionArchive',
  'dsh/sessionModels',
  'dsh/selectModel',
  'dsh/selectPermission',
  'dsh/directoryList',
  'dsh/toolCall',
};

/// Endpoints `dsh/toolCall` may carry (Host-side `ACP_TOOL_CALL_ENDPOINTS`).
const Set<String> acpToolCallEndpoints = {
  'workspaceFiles/list',
  'workspaceFiles/stat',
  'workspaceFiles/read',
  'workspaceFiles/readBytes',
  'workspaceFiles/readAll',
  'terminal/environment',
  'terminal/shells',
  'terminal/list',
  'terminal/create',
  'terminal/write',
  'terminal/resize',
  'terminal/rename',
  'terminal/close',
};

/// Endpoints that stream through `agent.acp.stream.open`'s `tool` argument.
const Set<String> acpToolStreamEndpoints = {
  'workspaceFiles/changes',
  'terminal/follow',
  'terminal/retain',
};

/// Session-id prefix of an ACP backend (`claude:`, `opencode:`, `cursor:`).
String acpSessionPrefix(String backend) => '$backend:';

/// `claude:<nativeId>` for a native ACP session id.
String acpSessionId(String backend, String nativeId) => '$backend:$nativeId';

/// Native id of a prefixed session id, or null for another dialect.
String? acpNativeSessionId(String backend, String sessionId) {
  final prefix = acpSessionPrefix(backend);
  return sessionId.startsWith(prefix) && sessionId.length > prefix.length ? sessionId.substring(prefix.length) : null;
}

/// Workspace-id prefix of an ACP backend (`claude:cwd:`).
String acpWorkspacePrefix(String backend) => '$backend:cwd:';

/// `claude:cwd:<urlencoded path>` for an absolute Host directory.
String acpWorkspaceId(String backend, String path) => '${acpWorkspacePrefix(backend)}${Uri.encodeComponent(path)}';

/// Absolute path of a workspace id, or null for another dialect/backend.
String? acpWorkspacePath(String backend, String workspaceId) {
  final prefix = acpWorkspacePrefix(backend);
  if (!workspaceId.startsWith(prefix) || workspaceId.length == prefix.length) return null;
  return Uri.decodeComponent(workspaceId.substring(prefix.length));
}

/// `session:<nativeId>` for the frame stream of a session.
String acpSessionStream(String nativeId) => '$acpSessionStreamPrefix$nativeId';

/// Native id of a frame's `streamId`, or null when the Host used another form.
String? acpSessionStreamId(String? streamId) {
  if (streamId == null || !streamId.startsWith(acpSessionStreamPrefix)) return null;
  final id = streamId.substring(acpSessionStreamPrefix.length);
  return id.isEmpty ? null : id;
}

// -----------------------------------------------------------------------------
// Failures
// -----------------------------------------------------------------------------

/// A refusal from the ACP gateway or the adapter behind it.
class AcpException implements Exception {
  const AcpException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final Object? details;

  /// Login is missing; the person must run the tool's login on the Host.
  bool get needsLogin =>
      code.contains('AUTH') ||
      code.contains('UNAUTHENTICATED') ||
      code.contains('LOGIN') ||
      message.toLowerCase().contains('not logged in');

  /// The backend process is gone or was never started.
  bool get backendUnavailable => code.contains('UNAVAILABLE') || code.contains('CLOSED');

  @override
  String toString() => 'AcpException($code): $message';
}

// -----------------------------------------------------------------------------
// Tolerant readers (the gateway is versioned independently of this App)
// -----------------------------------------------------------------------------

Map<String, Object?> acpMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((key, v) => MapEntry('$key', v));
  return const {};
}

List<Object?> acpList(Object? value) => value is List ? value.cast<Object?>() : const [];

String? acpString(Object? value) => value is String && value.isNotEmpty ? value : null;

int? acpInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.toInt();
  return null;
}

bool? acpBool(Object? value) => value is bool ? value : null;

/// Text of one content block or a list of them (`session/update.content`).
///
/// Adapters send either a single block or an array of blocks. Both readers
/// (the carrier's prompt path and the projection's echo path) must agree on
/// this, otherwise a message the backend did echo vanishes on this side and
/// the App's optimistic bubble is never confirmed.
String acpContentText(Object? content) {
  if (content is String) return content;
  if (content is Map) return _blockText(acpMap(content));
  final buffer = StringBuffer();
  for (final part in acpList(content)) {
    buffer.write(_blockText(acpMap(part)));
  }
  return buffer.toString();
}

String _blockText(Map<String, Object?> block) {
  final type = block['type'];
  if (type != null && type != 'text') return '';
  final text = block['text'];
  return text is String ? text : '';
}

// -----------------------------------------------------------------------------
// Models
// -----------------------------------------------------------------------------

/// One `agent.acp.frame` payload.
class AcpFrame {
  const AcpFrame({required this.streamId, required this.method, required this.params});

  factory AcpFrame.fromJson(Object? json) {
    final map = acpMap(json);
    return AcpFrame(
      streamId: acpString(map['streamId']),
      method: acpString(map['frame'] is Map ? acpMap(map['frame'])['method'] : null) ?? '',
      params: acpMap(map['frame'] is Map ? acpMap(map['frame'])['params'] : null),
    );
  }

  final String? streamId;
  final String method;
  final Map<String, Object?> params;

  /// `session/update` payload of a live frame, or null for other methods.
  Map<String, Object?>? get update => method == 'session/update' ? acpMap(params['update']) : null;

  /// `sessionUpdate` discriminator (`agent_message_chunk`, `tool_call`, ...).
  String? get updateKind => acpString(update?['sessionUpdate']);

  String? get sessionId => acpString(params['sessionId']);

  /// True for the synthetic terminal frames the Host adds to a turn.
  bool get isTurnEnd => updateKind == 'prompt_completed' || updateKind == 'prompt_failed';

  String? get stopReason => acpString(update?['stopReason']);

  /// Frames the Host buffered while the client was reconnecting.
  List<AcpFrame> get catchUp => [
    for (final item in acpList(update?['catchUp']))
      AcpFrame(
        streamId: streamId,
        method: acpString(acpMap(item)['method']) ?? 'session/update',
        params: acpMap(acpMap(item)['params']),
      ),
  ];
}

/// One workspace directory the ACP backend reports (`dsh/workspaceList`).
class AcpWorkspace {
  const AcpWorkspace({required this.path, required this.title, this.sessionCount});

  static AcpWorkspace? tryFromJson(Object? json) {
    final map = acpMap(json);
    final path = acpString(map['path']);
    if (path == null) return null;
    return AcpWorkspace(
      path: path,
      title: acpString(map['title']) ?? path,
      sessionCount: acpInt(map['sessionCount']),
    );
  }

  final String path;
  final String title;
  final int? sessionCount;
}

/// One session row the ACP backend reports (`dsh/sessionList`).
class AcpSessionSummary {
  const AcpSessionSummary({
    required this.id,
    required this.title,
    this.createdAt,
    this.updatedAt,
  });

  static AcpSessionSummary? tryFromJson(Object? json) {
    final map = acpMap(json);
    final id = acpString(map['conversationId']) ?? acpString(map['id']);
    if (id == null) return null;
    return AcpSessionSummary(
      id: id,
      title: acpString(map['title']) ?? '',
      createdAt: acpInt(map['createdAt']),
      updatedAt: acpInt(map['updatedAt']),
    );
  }

  final String id;
  final String title;
  final int? createdAt;
  final int? updatedAt;

  DateTime? get updated => updatedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(updatedAt!);
}

/// `dsh/sessionHistory` payload: replayable events plus the session's preset.
class AcpHistory {
  const AcpHistory(this.events, {this.permissionPreset, this.cwd});

  static AcpHistory fromJson(Object? json) {
    final map = acpMap(json);
    return AcpHistory(
      [for (final event in acpList(map['events'])) acpMap(event)],
      permissionPreset: acpString(map['permissionPreset']),
      // Newer Hosts report the directory a session belongs to; it saves a
      // reverse lookup when a stored session is reopened on a cold start.
      cwd: acpString(map['cwd']),
    );
  }

  final List<Map<String, Object?>> events;
  final String? permissionPreset;
  final String? cwd;
}

/// A permission request the Host forwarded from the backend.
class AcpApproval {
  const AcpApproval({
    required this.requestHandle,
    required this.sessionId,
    required this.method,
    required this.params,
  });

  static AcpApproval? tryFrom(AcpFrame frame) {
    if (frame.method != 'session/request_permission') return null;
    final handle = acpString(frame.params['requestHandle']);
    final sessionId = acpString(frame.params['sessionId']);
    if (handle == null || sessionId == null) return null;
    return AcpApproval(
      requestHandle: handle,
      sessionId: sessionId,
      method: frame.method,
      params: frame.params,
    );
  }

  final String requestHandle;
  final String sessionId;
  final String method;
  final Map<String, Object?> params;

  /// Human-readable subject of the request (tool title, command, path).
  String get subject {
    final toolCall = acpMap(params['toolCall']);
    final title = acpString(toolCall['title']);
    if (title != null) return title;
    final kind = acpString(toolCall['kind']);
    if (kind != null) return kind;
    return acpString(params['upstreamMethod']) ?? 'Permission request';
  }

  /// Options the backend offered, if it named them.
  List<Map<String, Object?>> get options => [for (final option in acpList(params['options'])) acpMap(option)];

  /// Whether an option of [kind] (`allow_once`, `reject_once`) exists.
  bool hasOption(String kind) => options.any((option) => option['kind'] == kind);
}

/// `session/update` kinds the projection understands. Anything else is ignored
/// so a newer Host can add kinds without breaking the transcript.
const Set<String> acpAssistantChunks = {
  'agent_message_chunk',
  'agent_thought_chunk',
  'agent_message',
  'agent_thought',
};

const Set<String> acpToolUpdates = {'tool_call', 'tool_call_update'};
