// Projects ACP `session/update` notifications onto the DSH session-log shapes
// the App already renders (`event` records and `assistant-stream` frames).
//
// The Host's own history replay (`dsh/sessionHistory`) already speaks this
// vocabulary — it emits `turn/start`, `step/start`, `user/message`,
// `assistant/message`, `tool/call`, `tool/result` and `turn/end`. This file
// keeps live turns in exactly the same shapes so a replayed session and a live
// one are indistinguishable to the transcript.
//
// Deliberately dropped: reasoning deltas (the App would show an empty thinking
// bubble without a matching block), image content, and per-tool diffs beyond
// the text the backend reports.
library;

import 'acp_wire.dart';

/// Live projection of one ACP session.
class AcpSessionProjection {
  AcpSessionProjection({
    required this.sessionId,
    this.provider = 'acp',
    int cursor = -1,
    int nextTurn = 0,
    List<Map<String, Object?>> history = const [],
    this.cwd,
    this.title,
    this.model,
  }) : _seq = cursor,
       _turn = nextTurn,
       _history = history;

  /// Prefixed id (`claude:<native>`); what the App stores in `sessionId`.
  final String sessionId;

  /// Provider label in `assistant/message.source` (`claude`, `opencode`).
  final String provider;

  final String? cwd;
  String? title;
  String? model;

  final List<Map<String, Object?>> _history;

  int _seq;
  int _turn;
  int _step = 1;
  bool _turnOpen = false;

  String? _attemptId;
  int _revision = 0;
  int _chunkIndex = 0;
  bool _textOpen = false;

  final StringBuffer _assistantText = StringBuffer();
  final List<Map<String, Object?>> _assistantContent = [];

  final StringBuffer _userText = StringBuffer();
  String? _pendingRpcId;

  final Map<String, _ToolState> _tools = {};
  final Set<String> _closedTools = {};

  int get cursor => _seq;
  int get turn => _turn;

  /// Whether a turn is currently open (a prompt started and has not ended).
  bool get turnOpen => _turnOpen;

  /// Stream id the append-only snapshot cursor is based on.
  List<Map<String, Object?>> get history => _history;

  /// Snapshot item for `session/follow`.
  Map<String, Object?> snapshot({List<Map<String, Object?>>? records}) {
    final items = records ?? _history;
    return {
      'type': 'snapshot',
      'header': {
        'version': 1,
        'id': sessionId,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        if (cwd != null) 'cwd': cwd,
        if (model != null) 'model': model,
      },
      'cursor': _seq,
      'records': items,
      'hasMore': false,
      'projections': {
        'asOfSeq': _seq,
        'values': {
          'title': ?title,
          'sessionListMetadata': {'blank': _seq <= 0, 'lastPromptAt': null},
          if (model != null)
            'modelSelection': {
              'lastUsed': {'provider': provider, 'model': model},
            },
        },
      },
      'assistantStream': {'revision': 0},
    };
  }

  /// Ties the next user echo to the prompt the App sent, so its optimistic
  /// "sending" bubble is retired instead of duplicated.
  void expectPrompt(String? requestId) {
    _pendingRpcId = requestId;
  }

  /// Frames for one `session/update`.
  List<Map<String, Object?>> handle(AcpFrame frame) {
    final update = frame.update;
    if (update == null) return const [];
    switch (acpString(update['sessionUpdate'])) {
      case 'user_message_chunk':
        return _onUserChunk(update);
      case 'agent_message_chunk':
        return _onAssistantChunk(update, reasoning: false);
      case 'agent_thought_chunk':
        return const [];
      case 'tool_call':
      case 'tool_call_update':
        return _onTool(update);
      case 'prompt_completed':
        return _finishTurn(reason: _reasonFor(acpString(update['stopReason'])));
      case 'prompt_failed':
        // A backend can fail before producing any update; the App still needs
        // a turn boundary, otherwise the composer stays in "sending" forever.
        return _finishTurn(reason: 'error', code: acpString(update['code']), force: true);
      default:
        return const [];
    }
  }

  /// Waterfall item for a permission request, or null when it is not one.
  Map<String, Object?>? approval(AcpFrame frame) => approvalFor(frame, sessionId);

  /// Same, without needing a live projection (a frame may arrive before the
  /// follow stream is registered).
  static Map<String, Object?>? approvalFor(AcpFrame frame, String sessionId) {
    final request = AcpApproval.tryFrom(frame);
    if (request == null) return null;
    final toolCall = acpMap(request.params['toolCall']);
    return {
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': request.requestHandle,
      'agentId': sessionId,
      'request': {
        'toolName': acpString(toolCall['title']) ?? acpString(toolCall['kind']) ?? 'tool',
        if (acpString(toolCall['toolCallId']) != null) 'callId': acpString(toolCall['toolCallId']),
        'reason': request.subject,
        'displayReason': {'en': request.subject, 'zh': request.subject},
      },
    };
  }

  // ---------------------------------------------------------------------------

  List<Map<String, Object?>> _onUserChunk(Map<String, Object?> update) {
    final text = _contentText(update['content']);
    if (text.isEmpty) return const [];
    _userText.write(text);
    return const [];
  }

  List<Map<String, Object?>> _onAssistantChunk(Map<String, Object?> update, {required bool reasoning}) {
    if (reasoning) return const [];
    final text = _contentText(update['content']);
    if (text.isEmpty) return const [];
    final out = <Map<String, Object?>>[];
    out.addAll(_flushUser());
    out.addAll(_ensureTurn());
    if (!_textOpen) {
      _textOpen = true;
      _assistantContent.add({'type': 'text', 'text': ''});
      out.add(
        _stream({
          'type': 'chunk',
          'attemptId': _attemptId,
          'revision': _revision++,
          'index': _chunkIndex++,
          'time': DateTime.now().millisecondsSinceEpoch,
          'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'text'},
        }),
      );
    }
    _assistantText.write(text);
    final block = _assistantContent.isEmpty ? null : _assistantContent.last;
    if (block != null && block['type'] == 'text') block['text'] = '${block['text']}$text';
    out.add(
      _stream({
        'type': 'chunk',
        'attemptId': _attemptId,
        'revision': _revision++,
        'index': _chunkIndex++,
        'time': DateTime.now().millisecondsSinceEpoch,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': text},
      }),
    );
    return out;
  }

  List<Map<String, Object?>> _onTool(Map<String, Object?> update) {
    final id = acpString(update['toolCallId']);
    if (id == null) return const [];
    final out = <Map<String, Object?>>[];
    out.addAll(_flushUser());
    out.addAll(_ensureTurn());

    final status = acpString(update['status']);
    final rawInput = update['rawInput'];
    var tool = _tools[id];
    if (tool == null) {
      final title = acpString(update['title']);
      final kind = acpString(update['kind']);
      tool = _ToolState(
        id: id,
        name: title ?? kind ?? 'tool',
        arguments: _arguments(rawInput),
        genericName: title == null || (kind != null && title == kind),
      );
      _tools[id] = tool;
    } else if (rawInput != null) {
      // opencode (and Claude) send a skeleton first — `shell` with only a cwd —
      // and the real command in the `tool_call_update` that follows, so the
      // arguments must be refreshed, not only captured on creation.
      if (_hasArguments(rawInput)) tool.arguments = _arguments(rawInput);
      final title = acpString(update['title']);
      if (title != null && tool.genericName && title != acpString(update['kind'])) {
        tool.name = title;
        tool.genericName = false;
      }
    }

    final failed = status == 'failed' || acpBool(acpMap(update['rawOutput'])['isError']) == true;
    final output = _toolOutput(update);
    if (output != null && output.isNotEmpty) tool.output = output;
    if (status == 'completed' || status == 'failed') {
      tool.failed = tool.failed || failed;
      tool.finished = true;
    }
    // Announce once there is something to show. The App keys a card by call id
    // and never refreshes it, so a skeleton `tool/call` would leave the card
    // showing just the tool name for the rest of the turn.
    if (!tool.announced && (_hasArguments(rawInput) || tool.finished)) {
      tool.announced = true;
      out.add(_announcement(tool));
    }
    if (tool.finished && !_closedTools.contains(id)) {
      _closedTools.add(id);
      out.add(_toolResult(tool));
    }
    return out;
  }

  Map<String, Object?> _announcement(_ToolState tool) => _event('tool/call', {
    'turn': _turn,
    'step': _step,
    'callId': tool.id,
    'name': tool.name,
    'arguments': tool.arguments,
  });

  /// Whether [rawInput] says more than where the tool runs.
  ///
  /// A first frame whose only field is `cwd` is a skeleton; waiting for the
  /// update costs one frame and gives the card its real command.
  static bool _hasArguments(Object? rawInput) {
    if (rawInput is String) {
      final trimmed = rawInput.trim();
      return trimmed.isNotEmpty && trimmed != '{}';
    }
    if (rawInput is Map) return rawInput.keys.any((key) => '$key' != 'cwd');
    if (rawInput is List) return rawInput.isNotEmpty;
    return false;
  }

  List<Map<String, Object?>> _flushUser() {
    final rpcId = _pendingRpcId;
    // An image-only prompt has no text to echo, but its request id still has to
    // reach the App or the optimistic bubble stays "sending" forever.
    if (_userText.isEmpty && rpcId == null) return const [];
    final text = _userText.toString();
    _userText.clear();
    _pendingRpcId = null;
    return [
      _event('user/message', {
        'id': 'acp-user-${_seq + 1}',
        'role': 'user',
        'content': [if (text.isNotEmpty) {'type': 'text', 'text': text}],
        'source': {'kind': 'user', 'rpcId': ?rpcId},
      }),
    ];
  }

  List<Map<String, Object?>> _ensureTurn() {
    if (_turnOpen) return const [];
    if (_turn == 0) _turn = 1;
    _turnOpen = true;
    _step = 1;
    _assistantText.clear();
    _assistantContent.clear();
    _textOpen = false;
    _attemptId = 'acp-attempt-$turn-${DateTime.now().microsecondsSinceEpoch}';
    _revision = 0;
    _chunkIndex = 0;
    return [
      _event('turn/start', {'turn': _turn}),
      _event('step/start', {'turn': _turn, 'step': _step}),
      _stream({
        'type': 'start',
        'attemptId': _attemptId,
        'revision': _revision,
        'turn': _turn,
        'step': _step,
        'startedAfterSeq': _seq,
      }),
    ];
  }

  /// Closes the turn for a terminal frame.
  ///
  /// A cancelled prompt can end before the backend emitted a single update
  /// (the person hit stop right after sending). No turn is open then, and
  /// closing nothing left the App stuck on a "sending" bubble with a dead
  /// stop button — so a pending user echo still opens and closes a turn.
  List<Map<String, Object?>> _finishTurn({required String reason, String? code, bool force = false}) {
    if (!_turnOpen) {
      // Nothing to close when no echo is waiting: a stray terminal frame must
      // not invent a turn. A failure is different — the App needs the boundary
      // to leave "sending" even when the backend died before any update.
      if (!force && _userText.isEmpty && _pendingRpcId == null) return const [];
      return [..._ensureTurn(), ..._closeTurn(reason: reason, code: code)];
    }
    return _closeTurn(reason: reason, code: code);
  }

  List<Map<String, Object?>> _closeTurn({required String reason, String? code}) {
    if (!_turnOpen) return const [];
    _turnOpen = false;
    final out = <Map<String, Object?>>[];
    out.addAll(_flushUser());

    final text = _assistantText.toString();
    Map<String, Object?>? committed;
    if (text.trim().isNotEmpty) {
      committed = _event('assistant/message', {
        'turn': _turn,
        'step': _step,
        'message': {
          'id': 'acp-assistant-$turn-$_step',
          'role': 'assistant',
          'content': _assistantContent,
          'source': {'kind': 'model', 'provider': provider, 'model': model ?? ''},
        },
        'stream': const <Object?>[],
      });
    }
    if (_attemptId != null) {
      if (committed != null) {
        out.add(committed);
        final seq = (committed['event'] as Map)['seq'];
        out.add(
          _stream({
            'type': 'end',
            'attemptId': _attemptId,
            'revision': _revision++,
            'index': _chunkIndex,
            'outcome': {'kind': 'committed', 'eventType': 'assistant/message', 'seq': seq},
          }),
        );
      } else {
        out.add(
          _stream({
            'type': 'end',
            'attemptId': _attemptId,
            'revision': _revision++,
            'index': _chunkIndex,
            'outcome': {'kind': 'abandoned'},
          }),
        );
      }
      _attemptId = null;
    }
    for (final tool in _tools.values) {
      if (!_closedTools.contains(tool.id)) {
        _closedTools.add(tool.id);
        if (!tool.announced) {
          tool.announced = true;
          out.add(_announcement(tool));
        }
        out.add(_toolResult(tool));
      }
    }
    out
      ..add(_event('step/end', {'turn': _turn, 'step': _step}))
      ..add(
        _event('turn/end', {
          'turn': _turn,
          'reason': {'kind': reason, if (code != null) 'error': {'code': code, 'message': code}},
        }),
      );
    _turn += 1;
    _step = 1;
    return out;
  }

  Map<String, Object?> _toolResult(_ToolState tool) => _event('tool/result', {
    'turn': _turn,
    'step': _step,
    'message': {
      'id': '${tool.id}-result',
      'role': 'user',
      'source': {'kind': 'tool', 'callId': tool.id},
      'content': [
        {
          'type': 'tool-result',
          'toolCallId': tool.id,
          'content': tool.output.isEmpty ? '' : tool.output,
          if (tool.failed) 'isError': true,
        },
      ],
    },
  });

  static String _reasonFor(String? stopReason) => switch (stopReason) {
    'cancelled' || 'canceled' || 'aborted' => 'aborted',
    'error' || 'failed' => 'error',
    // ACP's `max_tokens` means the reply was cut off; the App renders
    // `max-tokens` as such instead of pretending the turn finished.
    'max_tokens' || 'max-tokens' || 'max_turn_requests' => 'max-tokens',
    _ => 'completed',
  };

  String _arguments(Object? rawInput) {
    if (rawInput is String) return rawInput;
    if (rawInput == null) return '{}';
    try {
      return const _JsonEncoder().convert(rawInput);
    } on Object {
      return '{}';
    }
  }

  String? _toolOutput(Map<String, Object?> update) {
    final buffer = StringBuffer();
    for (final item in acpList(update['content'])) {
      final map = acpMap(item);
      if (map['type'] == 'content') {
        final inner = acpMap(map['content']);
        if (inner['type'] == 'text' && inner['text'] is String) buffer.write(inner['text']);
      } else if (map['type'] == 'text' && map['text'] is String) {
        buffer.write(map['text']);
      }
    }
    if (buffer.isNotEmpty) return buffer.toString();
    final raw = update['rawOutput'];
    if (raw is String) return raw;
    if (raw is Map) {
      final text = acpString(raw['text']) ?? acpString(raw['output']);
      if (text != null) return text;
    }
    return null;
  }

  static String _contentText(Object? content) => acpContentText(content);

  Map<String, Object?> _event(String type, Map<String, Object?> data) => {
    'type': 'event',
    'event': {'type': type, 'seq': ++_seq, 'time': DateTime.now().millisecondsSinceEpoch, 'data': data},
  };

  Map<String, Object?> _stream(Map<String, Object?> frame) => {'type': 'assistant-stream', 'frame': frame};
}

class _ToolState {
  _ToolState({required this.id, required this.name, required this.arguments, this.genericName = false});

  final String id;

  /// Title shown on the card; may be refined once the backend names the call.
  String name;

  String arguments;

  /// Whether [name] is only a kind synonym (`shell`, `write`) that a real title
  /// may replace without the heading flickering.
  bool genericName;

  /// Whether a `tool/call` event has been emitted for this id.
  bool announced = false;

  String output = '';
  bool failed = false;
  bool finished = false;
}

/// Minimal JSON encoder: `dart:convert` is not imported here to keep the
/// projection dependency-free in tests that feed raw maps.
class _JsonEncoder {
  const _JsonEncoder();

  String convert(Object? value) {
    final buffer = StringBuffer();
    _write(value, buffer);
    return buffer.toString();
  }

  void _write(Object? value, StringBuffer out) {
    if (value == null) {
      out.write('null');
    } else if (value is String) {
      out
        ..write('"')
        ..write(value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n'))
        ..write('"');
    } else if (value is num || value is bool) {
      out.write(value);
    } else if (value is List) {
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(',');
        _write(value[i], out);
      }
      out.write(']');
    } else if (value is Map) {
      out.write('{');
      var first = true;
      for (final entry in value.entries) {
        if (!first) out.write(',');
        first = false;
        _write('${entry.key}', out);
        out.write(':');
        _write(entry.value, out);
      }
      out.write('}');
    } else {
      _write('$value', out);
    }
  }
}
