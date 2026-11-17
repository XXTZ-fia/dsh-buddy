// Frame projection: every produced item must parse with the app's own
// `SessionLogEvent.fromJson`, which is the contract the chat UI depends on.
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

List<SessionLogEvent> events(List<Map<String, Object?>> frames) => frames
    .where((frame) => frame['type'] == 'event')
    .map((frame) => SessionLogEvent.fromJson(frame['event']))
    .toList(growable: false);

List<Map<String, Object?>> streams(List<Map<String, Object?>> frames) => frames
    .where((frame) => frame['type'] == 'assistant-stream')
    .map((frame) => (frame['frame'] as Map).map((key, value) => MapEntry('$key', value)))
    .toList(growable: false);

CodexFrame frame(String method, Map<String, Object?> params) => CodexFrame(method, params);

void main() {
  late CodexThreadProjection projection;

  setUp(() => projection = CodexThreadProjection(cursor: 4, nextTurn: 1, sessionId: 'codex:t1'));

  test('turn/started opens a turn, a step and an assistant attempt', () {
    final frames = projection.handle(
      frame('turn/started', {
        'threadId': 't1',
        'turn': {'id': 'turn-2'},
      }),
    );
    final parsed = events(frames);
    expect(parsed.map((e) => e.type), ['turn/start', 'step/start']);
    expect(parsed.map((e) => e.seq), [5, 6]);

    final started = streams(frames).single;
    expect(started['type'], 'start');
    expect(started['turn'], 2);
    expect(started['startedAfterSeq'], 6);
  });

  test('a user item becomes a parseable user/message', () {
    final parsed = events(
      projection.handle(
        frame('item/started', {
          'item': {
            'type': 'userMessage',
            'id': 'i1',
            'content': [
              {'type': 'text', 'text': '跑一下测试'},
            ],
          },
        }),
      ),
    );

    final event = parsed.single as UserMessageEvent;
    expect(event.message.text, '跑一下测试');
    expect(event.message.role, MessageRole.user);
  });

  test('agent deltas stream as block-start then text deltas, then commit', () {
    projection.handle(
      frame('turn/started', {
        'turn': {'id': 'turn-2'},
      }),
    );
    final deltaFrames = projection.handle(frame('item/agentMessage/delta', {'itemId': 'a1', 'delta': '你好'}));
    final chunks = streams(deltaFrames);
    expect(chunks.map((c) => (c['chunk'] as Map)['type']), ['block-start', 'text-delta']);
    expect(chunks.map((c) => c['revision']), [0, 1]);

    final completed = projection.handle(
      frame('item/completed', {
        'item': {
          'type': 'agentMessage',
          'id': 'a1',
          'content': [
            {'type': 'text', 'text': '你好，已经跑完'},
          ],
        },
      }),
    );
    final parsed = events(completed).single as AssistantMessageEvent;
    expect(parsed.message.text, '你好，已经跑完');
    expect(parsed.turn, 2);

    final end = streams(completed).single;
    expect(end['type'], 'end');
    expect((end['outcome'] as Map)['kind'], 'committed');
    expect((end['outcome'] as Map)['seq'], parsed.seq);
  });

  test('a command item becomes tool/call and tool/result', () {
    final call = events(
      projection.handle(
        frame('item/started', {
          'item': {'type': 'commandExecution', 'id': 'c1', 'command': 'ls -la'},
        }),
      ),
    ).single as ToolCallEvent;
    expect(call.name, 'shell');
    expect(call.callId, 'c1');
    expect(call.arguments, contains('ls -la'));

    final result = events(
      projection.handle(
        frame('item/completed', {
          'item': {'type': 'commandExecution', 'id': 'c1', 'aggregatedOutput': 'total 0'},
        }),
      ),
    ).single as ToolResultEvent;
    expect(result.message.toolCallId, 'c1');
    expect(result.message.text, 'total 0');
  });

  test('turn/completed closes the step and the turn', () {
    projection.handle(
      frame('turn/started', {
        'turn': {'id': 'turn-2'},
      }),
    );
    final parsed = events(
      projection.handle(
        frame('turn/completed', {
          'turn': {'id': 'turn-2', 'status': 'completed'},
        }),
      ),
    );
    expect(parsed.map((e) => e.type), ['step/end', 'turn/end']);
    final end = parsed.last as TurnEndedEvent;
    expect(end.reason.kind, 'completed');
  });

  test('a failed turn ends with an error reason and unknown frames are ignored', () {
    projection.handle(
      frame('turn/started', {
        'turn': {'id': 'turn-3'},
      }),
    );
    expect(projection.handle(frame('item/plan/delta', {'delta': 'x'})), isEmpty);
    final parsed = events(
      projection.handle(
        frame('turn/completed', {
          'turn': {'id': 'turn-3', 'status': 'failed'},
        }),
      ),
    );
    expect((parsed.last as TurnEndedEvent).reason.kind, 'error');
  });

  test('a rename becomes session/title', () {
    final parsed = events(projection.handle(frame('thread/name/updated', {'threadName': '重构雷达'})));
    expect((parsed.single as TitleChangedEvent).title, '重构雷达');
  });

  test('sequences never repeat across handlers', () {
    final seen = <int>[];
    for (final f in <CodexFrame>[
      frame('turn/started', {
        'turn': {'id': 'turn-2'},
      }),
      frame('item/started', {
        'item': {'type': 'userMessage', 'id': 'i1', 'content': <Object?>[]},
      }),
      frame('item/completed', {
        'item': {
          'type': 'agentMessage',
          'id': 'a1',
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
        },
      }),
      frame('turn/completed', {
        'turn': {'id': 'turn-2', 'status': 'completed'},
      }),
    ]) {
      for (final event in events(projection.handle(f))) {
        seen.add(event.seq);
      }
    }
    expect(seen, seen.toSet().toList(), reason: 'seq must be dense and unique');
    expect(seen.first, 5);
  });
}
