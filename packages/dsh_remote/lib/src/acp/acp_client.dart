// Typed facade over the Host's ACP gateway.
//
// The gateway is deliberately thin: it forwards `session/*` to one adapter
// process and projects a few DSH-shaped catalogs (`dsh/sessionList`,
// `dsh/workspaceList`, `dsh/sessionHistory`). All transcript shaping happens
// on this side, in `acp_projection.dart`.
library;

import 'dart:async';

import '../channel/rpc_client.dart';
import 'acp_transport.dart';
import 'acp_wire.dart';

/// One ACP backend on one Host.
class AcpClient {
  AcpClient(this.transport, {required this.backend});

  final AcpTransport transport;

  /// Host-side backend id (`claude`, `opencode`, `cursor`).
  final String backend;

  bool _closed = false;

  bool get supportsTransfer => transport.supportsTransfer;
  bool get isClosed => _closed;

  /// `initialize` (idempotent on the Host; the adapter is started lazily).
  Future<Map<String, Object?>> initialize({String clientName = 'dsh-app', String clientVersion = '1.0.0'}) async =>
      acpMap(
        await _call('initialize', {
          'protocolVersion': 1,
          'backend': backend,
          'clientInfo': {'name': clientName, 'version': clientVersion},
        }),
      );

  /// `session/new`: creates an idle session in [cwd]; returns its native id.
  Future<String> newSession(String cwd, {String? mode}) async {
    final result = acpMap(
      await _call('session/new', {'cwd': cwd, 'backend': backend, 'mode': ?mode, 'mcpServers': <Object?>[]}),
    );
    final id = acpString(result['sessionId']);
    if (id == null) throw const AcpException('ACP_INVALID_RESPONSE', 'session/new returned no session id.');
    return id;
  }

  /// `session/load`: makes this connection the session's owner and replays
  /// nothing (history comes from [history]).
  ///
  /// The Host's schema is strict and accepts **only** `sessionId` + `backend`;
  /// it injects the session's own `cwd`/`mcpServers` from its trusted catalog.
  /// Sending those two here is refused with `INVALID_MESSAGE`, which would make
  /// every Claude/OpenCode/Cursor session impossible to open.
  Future<String> loadSession(String nativeId) async {
    final result = acpMap(
      await _call('session/load', {'sessionId': nativeId, 'backend': backend}),
    );
    return acpString(result['sessionId']) ?? nativeId;
  }

  /// `session/prompt`: the Host accepts immediately and finishes through
  /// `session/update` frames, so this returns `{accepted: true}`.
  ///
  /// [prompt] is a list of ACP content blocks (`text`, `image`, ...), already
  /// translated by the caller; the adapter decides which kinds it accepts.
  Future<bool> prompt(String nativeId, List<Map<String, Object?>> prompt) async {
    final result = acpMap(
      await _call('session/prompt', {'sessionId': nativeId, 'backend': backend, 'prompt': prompt}),
    );
    return acpBool(result['accepted']) ?? true;
  }

  /// `session/cancel`: stops the running turn, if any.
  ///
  /// Strict schema: `{sessionId}` only. `backend` is not accepted and made
  /// every stop button answer `INVALID_MESSAGE`.
  Future<void> cancel(String nativeId) async {
    await _call('session/cancel', {'sessionId': nativeId});
  }

  /// `dsh/sessionHistory`: replayable events for one session.
  Future<AcpHistory> history(String nativeId) async =>
      AcpHistory.fromJson(await _call('dsh/sessionHistory', {'sessionId': nativeId, 'backend': backend}));

  /// `dsh/workspaceList`: directories this backend knows about.
  Future<List<AcpWorkspace>> listWorkspaces() async => [
    for (final item in acpList(await _call('dsh/workspaceList', {'backend': backend}))) ?AcpWorkspace.tryFromJson(item),
  ];

  /// `dsh/sessionList`: sessions under one directory.
  ///
  /// The Host answers `{items: [...]}` (with `conversationId` per row), not a
  /// bare array — reading a list here made every Claude/OpenCode workspace
  /// look empty. A bare array is still accepted for older Hosts.
  Future<List<AcpSessionSummary>> listSessions(String path, {int limit = 50}) async {
    final result = await _call('dsh/sessionList', {'path': path, 'backend': backend, 'limit': limit});
    final rows = result is List ? result : acpList(acpMap(result)['items']);
    return [
      for (final item in rows) ?AcpSessionSummary.tryFromJson(item),
    ];
  }

  /// `dsh/directoryList`: Host directories, for the workspace picker.
  Future<Object?> listDirectory(String path) => _call('dsh/directoryList', {'path': path});

  /// `dsh/sessionModels`: the model catalog of one live session.
  Future<Map<String, Object?>> sessionModels(String nativeId) async =>
      acpMap(await _call('dsh/sessionModels', {'sessionId': nativeId, 'backend': backend}));

  /// `dsh/selectModel`.
  Future<Object?> selectModel(String nativeId, String model, {String? reasoningEffort}) => _call('dsh/selectModel', {
    'sessionId': nativeId,
    'backend': backend,
    'model': model,
    'reasoningEffort': ?reasoningEffort,
  });

  /// `dsh/selectPermission`: `workspace-write` or `danger-full-access`.
  Future<Object?> selectPermission(String nativeId, String preset) =>
      _call('dsh/selectPermission', {'sessionId': nativeId, 'backend': backend, 'preset': preset});

  /// `dsh/toolCall`: workspace files and terminals scoped to one session.
  Future<Object?> toolCall(String nativeId, String endpoint, Map<String, Object?> args) {
    if (!acpToolCallEndpoints.contains(endpoint)) {
      throw AcpException('METHOD_NOT_ALLOWED', '$endpoint is not an ACP tool endpoint.');
    }
    return _call('dsh/toolCall', {'sessionId': nativeId, 'backend': backend, 'endpoint': endpoint, 'args': args});
  }

  /// `dsh/sessionArchive` (OpenCode only; the Host refuses it for others).
  Future<Object?> archiveSession(String nativeId) =>
      _call('dsh/sessionArchive', {'sessionId': nativeId, 'backend': backend});

  /// `agent.acp.respond`: answer one permission request.
  Future<void> respond(String requestHandle, AcpDecision decision) async {
    await transport.respond({'requestHandle': requestHandle, 'decision': decision.wire});
  }

  /// Opens the live frame stream of one session.
  ///
  /// The Host addresses frames by session, but a stream still has to be open
  /// before the gateway will deliver them (it proves this connection owns the
  /// session).
  Future<String> openStream(String nativeId) async {
    final streamId = 'acp-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    await transport.openStream(streamId, nativeId);
    return streamId;
  }

  Future<void> closeStream(String streamId) async {
    try {
      await transport.closeStream(streamId);
    } on Object {
      // The Host may have closed it already; closing twice is harmless.
    }
  }

  /// Live frames of every followed session, including catch-up frames.
  Stream<AcpFrame> get frames => transport.frames;

  /// Streams the Host closed on its own.
  Stream<String> get closedStreams => transport.closedStreams;

  Stream<void> get catalogChanged => transport.catalogChanged;

  Future<Object?> _call(String method, Map<String, Object?> params) async {
    if (_closed) throw AcpException('ACP_CLOSED', 'The $backend connection is closed.');
    try {
      return await transport.call(method, params);
    } on AcpException {
      rethrow;
    } on RemoteRpcException catch (error) {
      // Keep the Host's own code (`ACP_SESSION_BUSY`, `METHOD_NOT_ALLOWED`,
      // `CURSOR_APPROVAL_NOT_FOUND`, ...): rewriting it to `acp/internal` made
      // every actionable refusal look like an unknown failure in the App.
      throw AcpException(error.code, error.message, details: error.details);
    } on Object catch (error) {
      throw AcpException('acp/internal', '$error');
    }
  }

  Future<void> close() async {
    _closed = true;
    await transport.close();
  }
}

/// Decisions `agent.acp.respond` accepts.
enum AcpDecision {
  allowOnce('allow-once'),
  rejectOnce('reject-once'),
  cancel('cancel');

  const AcpDecision(this.wire);

  final String wire;
}
