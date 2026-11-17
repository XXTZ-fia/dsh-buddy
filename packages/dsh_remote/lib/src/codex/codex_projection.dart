// Projects Codex app-server frames into the DSH session-log shapes the app
// already renders (`{type: 'event'}` and `{type: 'assistant-stream'}`).
//
// Scope: one turn per prompt, text replies, tool cards and stop. Reasoning is
// dropped (the app would show an empty "thinking" bubble without deltas);
// approvals are not surfaced — the thread runs with `approvalPolicy: never`, so
// the sandbox refuses instead of waiting for a person.
library;

import 'codex_wire.dart';

/// Per-thread projection state. One instance per live follow; sequence numbers
/// continue after the history page the snapshot was built from.
class CodexThreadProjection {
  CodexThreadProjection({required int cursor, required int nextTurn, String? activeTurnId, this.sessionId = ''})
    : _seq = cursor,
      _turn = nextTurn,
      _turnOpen = activeTurnId != null,
      _activeTurnId = activeTurnId;

  /// `codex:<threadId>`; used in message sources and stream attempt ids.
  final String sessionId;

  int _seq;
  int _turn;
  bool _turnOpen;
  String? _activeTurnId;

  String? _attemptId;
  int _revision = 0;
  int _chunkIndex = 0;
  bool _textBlockOpen = false;

  int get cursor => _seq;
  int get turn => _turn;
  String? get activeTurnId => _activeTurnId;

  /// The snapshot item for a `session/follow` stream: history already arrives
  /// in DSH event shape from the Host's `dsh/sessionHistory`.
  Map<String, Object?> snapshot(CodexHistoryPage page, {String? title, String? model, String? reasoningEffort}) => {
    'type': 'snapshot',
    'header': {
      'version': 1,
      'id': sessionId,
      'createdAt': page.header['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
      if (page.header['cwd'] != null) 'cwd': page.header['cwd'],
      if (page.header['model'] != null) 'model': page.header['model'],
    },
    'cursor': page.cursor,
    'records': page.records.map((record) => {'type': 'event', 'event': record.event}).toList(growable: false),
    'hasMore': page.hasMore,
    'projections': {
      'asOfSeq': page.cursor,
      'values': {
        'title': ?title,
        'sessionListMetadata': {'blank': page.cursor < 0, 'lastPromptAt': null},
        if (model != null)
          'modelSelection': {
            'lastUsed': {'provider': 'codex', 'model': model, 'reasoningEffort': ?reasoningEffort},
          },
      },
    },
    'assistantStream': {'revision': 0},
  };

  /// Frames for one app-server notification, in order. Unknown methods yield
  /// an empty list so a newer Codex never breaks the stream.
  List<Map<String, Object?>> handle(CodexFrame frame) {
    switch (frame.method) {
      case 'turn/started':
        return _onTurnStarted(frame);
      case 'item/started':
        return _onItemStarted(frame);
      case 'item/agentMessage/delta':
        return _onAgentDelta(frame);
      case 'item/reasoning/delta':
        return const [];
      case 'item/completed':
        return _onItemCompleted(frame);
      case 'turn/completed':
        return _onTurnCompleted(frame);
      case 'thread/name/updated':
        final name = frame.params['threadName'];
        return name is String && name.trim().isNotEmpty ? [_event('session/title', {'title': name.trim()})] : const [];
      case 'error':
        final message = frame.params['message'];
        return [
          _event('turn/end', {
            'turn': _turn,
            'reason': {
              'kind': 'error',
              'error': {'message': message is String ? message : 'Codex reported an error.', 'code': 'codex-error'},
            },
          }),
        ];
      default:
        return const [];
    }
  }

  // ---------------------------------------------------------------------------

  List<Map<String, Object?>> _onTurnStarted(CodexFrame frame) {
    final out = <Map<String, Object?>>[];
    if (_turnOpen) out.addAll(_closeTurn(reason: 'completed'));
    _turn += 1;
    _turnOpen = true;
    _activeTurnId = frame.turnId;
    out
      ..add(_event('turn/start', {'turn': _turn}))
      ..add(_event('step/start', {'turn': _turn, 'step': 1}));
    _attemptId = 'codex-attempt-${_activeTurnId ?? _turn}';
    _revision = 0;
    _chunkIndex = 0;
    _textBlockOpen = false;
    out.add(
      _stream({
        'type': 'start',
        'attemptId': _attemptId,
        'revision': _revision,
        'turn': _turn,
        'step': 1,
        'startedAfterSeq': _seq,
      }),
    );
    return out;
  }

  List<Map<String, Object?>> _onItemStarted(CodexFrame frame) {
    final item = frame.item;
    if (item == null) return const [];
    if (item.isUser) {
      return [
        _event('user/message', {
          'id': item.id,
          'role': 'user',
          'content': [
            {'type': 'text', 'text': item.text},
          ],
          'source': {'kind': 'user'},
        }),
      ];
    }
    if (item.isTool) {
      return [
        _event('tool/call', {
          'turn': _turn,
          'step': 1,
          'callId': item.id,
          'name': _toolName(item),
          'arguments': _toolArguments(item),
        }),
      ];
    }
    return const [];
  }

  List<Map<String, Object?>> _onAgentDelta(CodexFrame frame) {
    final delta = frame.delta;
    if (delta == null || delta.isEmpty) return const [];
    final out = <Map<String, Object?>>[];
    if (!_textBlockOpen) {
      _textBlockOpen = true;
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
    out.add(
      _stream({
        'type': 'chunk',
        'attemptId': _attemptId,
        'revision': _revision++,
        'index': _chunkIndex++,
        'time': DateTime.now().millisecondsSinceEpoch,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': delta},
      }),
    );
    return out;
  }

  List<Map<String, Object?>> _onItemCompleted(CodexFrame frame) {
    final item = frame.item;
    if (item == null) return const [];
    if (item.isAgent) {
      final text = item.text;
      if (text.trim().isEmpty) return const [];
      final event = _event('assistant/message', {
        'turn': _turn,
        'step': 1,
        'message': {
          'id': item.id,
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model'},
        },
        'interrupted': false,
      });
      final seq = (event['event'] as Map)['seq'];
      final out = <Map<String, Object?>>[event];
      if (_attemptId != null) {
        out.add(
          _stream({
            'type': 'end',
            'attemptId': _attemptId,
            'revision': _revision++,
            'index': _chunkIndex,
            'outcome': {'kind': 'committed', 'eventType': 'assistant/message', 'seq': seq},
          }),
        );
        _attemptId = null;
        _textBlockOpen = false;
      }
      return out;
    }
    if (item.isTool) {
      final output = _toolOutput(item);
      return [
        _event('tool/result', {
          'turn': _turn,
          'step': 1,
          'message': {
            'id': '${item.id}-result',
            'role': 'tool',
            'toolCallId': item.id,
            'content': [
              {'type': 'text', 'text': output},
            ],
            'source': {'kind': 'tool'},
          },
        }),
      ];
    }
    return const [];
  }

  List<Map<String, Object?>> _onTurnCompleted(CodexFrame frame) {
    final turn = frame.params['turn'];
    final status = turn is Map ? turn['status'] : null;
    return _closeTurn(reason: _turnReason(status));
  }

  List<Map<String, Object?>> _closeTurn({required String reason}) {
    if (!_turnOpen) return const [];
    _turnOpen = false;
    final out = <Map<String, Object?>>[];
    if (_attemptId != null) {
      out.add(
        _stream({
          'type': 'end',
          'attemptId': _attemptId,
          'revision': _revision++,
          'index': _chunkIndex,
          'outcome': {'kind': 'abandoned'},
        }),
      );
      _attemptId = null;
    }
    out
      ..add(_event('step/end', {'turn': _turn, 'step': 1}))
      ..add(_event('turn/end', {'turn': _turn, 'reason': {'kind': reason}}));
    _activeTurnId = null;
    return out;
  }

  static String _turnReason(Object? status) => switch (status) {
    'failed' => 'error',
    'interrupted' || 'cancelled' || 'canceled' || 'aborted' => 'aborted',
    _ => 'completed',
  };

  static String _toolName(CodexItem item) => switch (item.type) {
    'commandExecution' => 'shell',
    'fileChange' => 'apply_patch',
    'webSearch' => 'web_search',
    _ => item.type,
  };

  static String _toolArguments(CodexItem item) {
    final raw = item.raw;
    return switch (item.type) {
      'commandExecution' => '{"command": ${_jsonString(raw['command'] ?? raw['commandLine'] ?? '')}}',
      'fileChange' => '{"changes": ${(raw['changes'] is List) ? (raw['changes'] as List).length : 0}}',
      _ => '{}',
    };
  }

  static String _toolOutput(CodexItem item) {
    final raw = item.raw;
    for (final key in const ['aggregatedOutput', 'output', 'stdout', 'text']) {
      final value = raw[key];
      if (value is String && value.isNotEmpty) return value;
    }
    final error = raw['error'];
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return '';
  }

  static String _jsonString(Object? value) {
    final text = value is String ? value : '$value';
    return '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
  }

  Map<String, Object?> _event(String type, Map<String, Object?> data) => {
    'type': 'event',
    'event': {'type': type, 'seq': ++_seq, 'time': DateTime.now().millisecondsSinceEpoch, 'data': data},
  };

  Map<String, Object?> _stream(Map<String, Object?> frame) => {'type': 'assistant-stream', 'frame': frame};
}
