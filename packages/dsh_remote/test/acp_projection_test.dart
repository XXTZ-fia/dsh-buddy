// ACP updates -> DSH session events, replayed from a real OpenCode capture.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

const _session = 'n1';
const _stream = 'session:n1';

/// Reads a captured JSON-RPC transcript and turns it into the frames the Host
/// publishes for a followed session.
List<AcpFrame> framesFromFixture(String path, {String stopReason = 'end_turn'}) {
  final frames = <AcpFrame>[];
  for (final line in File(path).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final message = jsonDecode(line) as Map<String, Object?>;
    if (message['method'] != 'session/update') continue;
    final params = (message['params'] as Map).cast<String, Object?>();
    frames.add(AcpFrame(streamId: _stream, method: 'session/update', params: params));
  }
  frames.add(
    AcpFrame(
      streamId: _stream,
      method: 'session/update',
      params: {
        'sessionId': _session,
        'update': {'sessionUpdate': 'prompt_completed', 'stopReason': stopReason},
      },
    ),
  );
  return frames;
}

List<Map<String, Object?>> eventsOf(List<Map<String, Object?>> items) => [
  for (final item in items)
    if (item['type'] == 'event') (item['event'] as Map).cast<String, Object?>(),
];

void main() {
  test('a real OpenCode turn projects to one turn with a tool call and a reply', () {
    final frames = framesFromFixture('test/fixtures/acp/opencode-tool.jsonl');
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode');
    final items = <Map<String, Object?>>[];
    for (final frame in frames) {
      items.addAll(projection.handle(frame));
    }

    final events = eventsOf(items);
    final types = events.map((e) => e['type']).toList();
    expect(types.first, 'turn/start');
    expect(types.last, 'turn/end');
    expect(types, contains('tool/call'));
    expect(types, contains('tool/result'));
    expect(types, contains('assistant/message'));
    expect(types.where((t) => t == 'turn/start'), hasLength(1));
    expect(types.where((t) => t == 'turn/end'), hasLength(1));

    final seqs = [for (final event in events) event['seq'] as int];
    // A fresh session starts at 0, exactly like replayed history.
    expect(seqs, orderedEquals(List.generate(seqs.length, (i) => i)));

    final tools = events.where((e) => e['type'] == 'tool/call').map((e) => (e['data'] as Map)['callId']).toList();
    final results = events.where((e) => e['type'] == 'tool/result').map((e) => (e['data'] as Map)['message']).toList();
    expect(results, hasLength(tools.length));
    expect(results.map((m) => (m as Map)['source']['callId']).toSet(), tools.toSet());

    final message = events.lastWhere((e) => e['type'] == 'assistant/message');
    final content = (message['data'] as Map)['message']['content'] as List;
    final text = content.where((part) => (part as Map)['type'] == 'text').map((part) => (part as Map)['text']).join();
    expect(text.trim(), isNotEmpty);

    final end = events.lastWhere((e) => e['type'] == 'turn/end');
    expect((end['data'] as Map)['reason'], containsPair('kind', 'completed'));
  });

  test('delta chunks stream before the committed message', () {
    final frames = framesFromFixture('test/fixtures/acp/opencode-turn.jsonl');
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode');
    final items = <Map<String, Object?>>[];
    for (final frame in frames) {
      items.addAll(projection.handle(frame));
    }
    final streamed = items.where((i) => i['type'] == 'assistant-stream').map((i) => i['frame'] as Map).toList();
    expect(streamed.first['type'], 'start');
    expect(streamed.where((f) => f['type'] == 'chunk' && (f['chunk'] as Map)['type'] == 'text-delta'), isNotEmpty);
    final end = streamed.last;
    expect(end['type'], 'end');
    expect((end['outcome'] as Map)['kind'], 'committed');
    expect(end['attemptId'], streamed.first['attemptId']);
  });

  test('an aborted turn ends as aborted, not completed', () {
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode');
    projection.handle(
      AcpFrame(
        streamId: _stream,
        method: 'session/update',
        params: {
          'sessionId': _session,
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'partial'},
          },
        },
      ),
    );
    final items = projection.handle(
      AcpFrame(
        streamId: _stream,
        method: 'session/update',
        params: {
          'sessionId': _session,
          'update': {'sessionUpdate': 'prompt_completed', 'stopReason': 'cancelled'},
        },
      ),
    );
    final end = eventsOf(items).lastWhere((e) => e['type'] == 'turn/end');
    expect((end['data'] as Map)['reason'], containsPair('kind', 'aborted'));
  });

  test('prompt_failed surfaces an error reason', () {
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode');
    final items = projection.handle(
      AcpFrame(
        streamId: _stream,
        method: 'session/update',
        params: {
          'sessionId': _session,
          'update': {'sessionUpdate': 'prompt_failed', 'code': 'AUTH_REQUIRED'},
        },
      ),
    );
    final end = eventsOf(items).lastWhere((e) => e['type'] == 'turn/end');
    expect((end['data'] as Map)['reason'], containsPair('kind', 'error'));
  });

  test('the tool card carries the command the skeleton frame did not have', () {
    final frames = framesFromFixture('test/fixtures/acp/opencode-tool.jsonl');
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode');
    final items = <Map<String, Object?>>[];
    for (final frame in frames) {
      items.addAll(projection.handle(frame));
    }
    final calls = eventsOf(items).where((event) => event['type'] == 'tool/call').toList();
    expect(calls, isNotEmpty);
    final arguments = calls.map((event) => (event['data'] as Map)['arguments'] as String).join('\n');
    expect(
      arguments,
      contains('command'),
      reason: 'opencode names the shell command only in the tool_call_update that follows',
    );
  });

  test('a user echo sent as a list of blocks is not dropped', () {
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode')
      ..expectPrompt('rpc-8');
    projection.handle(
      AcpFrame(
        streamId: _stream,
        method: 'session/update',
        params: {
          'sessionId': _session,
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': [
              {'type': 'text', 'text': '第一段'},
              {'type': 'text', 'text': '第二段'},
            ],
          },
        },
      ),
    );
    final items = projection.handle(
      AcpFrame(
        streamId: _stream,
        method: 'session/update',
        params: {
          'sessionId': _session,
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': '好'},
          },
        },
      ),
    );
    final user = eventsOf(items).firstWhere((event) => event['type'] == 'user/message');
    expect(((user['data'] as Map)['content'] as List).single, {'type': 'text', 'text': '第一段第二段'});
    expect(((user['data'] as Map)['source'] as Map)['rpcId'], 'rpc-8');
  });

  test('unknown updates are ignored without breaking the turn', () {
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode');
    final items = <Map<String, Object?>>[];
    for (final update in const [
      {'sessionUpdate': 'usage_update'},
      {'sessionUpdate': 'available_commands_update'},
    ]) {
      items.addAll(
        projection.handle(
          AcpFrame(
            streamId: _stream,
            method: 'session/update',
            params: {'sessionId': _session, 'update': update},
          ),
        ),
      );
    }
    expect(items, isEmpty);
    final closed = projection.handle(
      AcpFrame(
        streamId: _stream,
        method: 'session/update',
        params: {
          'sessionId': _session,
          'update': {'sessionUpdate': 'prompt_completed'},
        },
      ),
    );
    expect(closed, isEmpty, reason: 'no turn was opened, so nothing closes');
  });

  test('a permission request becomes an approval waterfall keyed by handle', () {
    final frame = AcpFrame(
      streamId: _stream,
      method: 'session/request_permission',
      params: {
        'sessionId': _session,
        'requestHandle': 'h-1',
        'toolCall': {'toolCallId': 'call-1', 'title': 'Write file', 'kind': 'edit'},
        'options': [
          {'optionId': 'allow', 'kind': 'allow_once'},
          {'optionId': 'reject', 'kind': 'reject_once'},
        ],
      },
    );
    final waterfall = AcpSessionProjection.approvalFor(frame, 'opencode:n1');
    expect(waterfall, isNotNull);
    expect(waterfall!['type'], 'waterfall');
    expect(waterfall['event'], 'approval/request');
    expect(waterfall['eventId'], 'h-1');
    expect(waterfall['agentId'], 'opencode:n1');
    expect((waterfall['request'] as Map)['toolName'], 'Write file');
    expect((waterfall['request'] as Map)['callId'], 'call-1');
  });

  test('the user echo carries the prompt rpcId so the optimistic bubble retires', () {
    final projection = AcpSessionProjection(sessionId: 'opencode:n1', provider: 'opencode')
      ..expectPrompt('rpc-7');
    final items = <Map<String, Object?>>[];
    items.addAll(
      projection.handle(
        AcpFrame(
          streamId: _stream,
          method: 'session/update',
          params: {
            'sessionId': _session,
            'update': {
              'sessionUpdate': 'user_message_chunk',
              'content': {'type': 'text', 'text': '你好'},
            },
          },
        ),
      ),
    );
    items.addAll(
      projection.handle(
        AcpFrame(
          streamId: _stream,
          method: 'session/update',
          params: {
            'sessionId': _session,
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'type': 'text', 'text': '在'},
            },
          },
        ),
      ),
    );
    final user = eventsOf(items).firstWhere((e) => e['type'] == 'user/message');
    expect(((user['data'] as Map)['source'] as Map)['rpcId'], 'rpc-7');
  });
}
