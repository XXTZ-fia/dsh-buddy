// Codex as a DSH host: endpoint mapping and the synthesized mux link.
import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_codex_transport.dart';

Map<String, Object?> threadJson({String id = 't1', String model = 'gpt-6.1-sol'}) => {
  'id': id,
  'sessionId': 's-$id',
  'cwd': r'D:\whm\dsh-buddy',
  'model': model,
  'modelProvider': 'openai',
  'preview': '第一条消息',
  'updatedAt': 1700000000000,
  'status': {'type': 'idle'},
};

Map<String, Object?> historyJson({int cursor = 3, String? userText}) => {
  'header': {'version': 1, 'id': 'codex:t1', 'createdAt': 1700000000000, 'cwd': r'D:\whm\dsh-buddy'},
  'cursor': cursor,
  'nextTurn': 1,
  'hasMore': false,
  'records': [
    if (userText != null)
      {
        'type': 'event',
        'event': {
          'type': 'user/message',
          'seq': 1,
          'time': 1700000000000,
          'data': {
            'id': 'u-echo',
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userText},
            ],
            'source': {'kind': 'user'},
          },
        },
      },
    {
      'type': 'event',
      'event': {
        'type': 'turn/start',
        'seq': 0,
        'time': 1700000000000,
        'data': {'turn': 1},
      },
    },
    {
      'type': 'event',
      'event': {
        'type': 'assistant/message',
        'seq': 3,
        'time': 1700000000000,
        'data': {
          'turn': 1,
          'step': 1,
          'message': {
            'id': 'a1',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': '历史回复'},
            ],
            'source': {'kind': 'model'},
          },
        },
      },
    },
  ],
};

void main() {
  late FakeCodexTransport transport;
  late CodexClient client;
  late CodexCarrier carrier;

  setUp(() {
    transport = FakeCodexTransport();
    client = CodexClient(transport);
    carrier = CodexCarrier(client: client, defaultCwd: r'D:\whm\dsh-buddy');
    transport.handler = (method, params) => switch (method) {
      'thread/list' => {
        'data': [threadJson()],
        'nextCursor': null,
      },
      'thread/read' => {'thread': threadJson()},
      'dsh/sessionHistory' => historyJson(),
      'thread/start' => {
        'thread': threadJson(id: 't9'),
      },
      'turn/start' => {
        'turn': {'id': 'turn-9'},
      },
      'model/list' => {
        'data': [
          {
            'id': 'gpt-6.1-sol',
            'model': 'gpt-6.1-sol',
            'displayName': 'GPT-6.1-Sol',
            'hidden': false,
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'medium'},
            ],
          },
        ],
      },
      _ => <String, Object?>{},
    };
  });

  test('the carrier advertises only endpoints it can serve', () {
    expect(carrier.kind, 'codex');
    expect(carrier.supportsUplink, isFalse);
    expect(carrier.allowsEndpoint('session/prompt'), isTrue);
    expect(carrier.allowsEndpoint('subagents/prompt'), isFalse);
    expect(carrier.allowsEndpoint('skills/list'), isFalse);
  });

  test('session/list projects threads as sessions with titles', () async {
    final result = await carrier.call('session/list', const {});
    final value = (result as RpcOk).value as Map<String, Object?>;
    final items = value['items'] as List;
    expect(items, hasLength(1));
    final row = items.single as Map<String, Object?>;
    expect(row['sessionId'], 'codex:t1');
    expect(row['running'], isFalse);
    expect((row['projections'] as Map)['values'], containsPair('title', '第一条消息'));

    final parsed = SessionSummary.fromJson(row);
    expect(parsed.sessionId, 'codex:t1');
    expect(parsed.title, '第一条消息');
  });

  test('session/list deduplicates threads repeated by app-server', () async {
    // Codex 0.167 returns the same rollout once per project root. Duplicate
    // session ids would create duplicate ValueKeys in the drawer's ListView.
    transport.handler = (method, params) => switch (method) {
      'thread/list' => {
        'data': [
          threadJson(id: 't1'),
          threadJson(id: 't2'),
          threadJson(id: 't1'),
          {...threadJson(id: 't1'), 'preview': '更新的预览', 'updatedAt': 1800000000000},
          {...threadJson(), 'id': ''},
        ],
        'nextCursor': null,
      },
      _ => <String, Object?>{},
    };
    final result = await carrier.call('session/list', const {});
    final value = (result as RpcOk).value as Map<String, Object?>;
    final items = (value['items'] as List).cast<Map<String, Object?>>();
    expect(items, hasLength(2));
    expect(items.map((row) => row['sessionId']).toSet(), {'codex:t1', 'codex:t2'});
    final freshest = items.firstWhere((row) => row['sessionId'] == 'codex:t1');
    final projections = freshest['projections'] as Map<String, Object?>;
    expect((projections['values'] as Map)['title'], '更新的预览');
  });

  test('session/page returns DSH-shaped history records', () async {
    final result = await carrier.call('session/page', {
      'request': {
        'address': {'kind': 'session', 'sessionId': 'codex:t1'},
        'throughSeq': 3,
      },
    });
    final value = (result as RpcOk).value as Map<String, Object?>;
    final records = value['records'] as List;
    expect(records, hasLength(2));
    final second = SessionLogEvent.fromJson((records.last as Map)['event']);
    expect(second, isA<AssistantMessageEvent>());
    expect((second as AssistantMessageEvent).message.text, '历史回复');
  });

  test('session/prompt starts a turn with the prompt text', () async {
    await carrier.call('session/list', const {});
    await carrier.call('session/prompt', {
      'request': {
        'requestId': 'r1',
        'sessionId': 'codex:t1',
        'mode': 'queue',
        'content': [
          {'type': 'text', 'text': '帮我跑测试'},
        ],
      },
    });
    final call = transport.calls.lastWhere((c) => c.method == 'turn/start');
    expect(call.params['threadId'], 't1');
    expect((call.params['input'] as List).single, {'type': 'text', 'text': '帮我跑测试'});
  });

  test('session/cancel interrupts the running turn', () async {
    transport.handler = (method, params) => switch (method) {
      'thread/read' => {
        'thread': {
          ...threadJson(),
          'turns': [
            {'id': 'turn-7', 'status': 'active', 'items': <Object?>[]},
          ],
        },
      },
      _ => <String, Object?>{},
    };
    final result = await carrier.call('session/cancel', {
      'request': {
        'address': {'kind': 'session', 'sessionId': 'codex:t1'},
      },
    });
    expect((result as RpcOk).value, {'accepted': true});
    final call = transport.calls.lastWhere((c) => c.method == 'turn/interrupt');
    expect(call.params, {'threadId': 't1', 'turnId': 'turn-7'});
  });

  test('unknown endpoints fail with METHOD_NOT_ALLOWED instead of hanging', () async {
    final result = await carrier.call('skills/list', const {});
    final error = (result as RpcError).error;
    expect(error.code, 'METHOD_NOT_ALLOWED');
  });

  test('model catalog exposes the Codex models with efforts', () async {
    final result = await carrier.call('session/modelCatalog', const {});
    final value = (result as RpcOk).value as Map<String, Object?>;
    final catalog = ModelCatalog.fromJson(value);
    expect(catalog.groups.single.id, 'codex');
    expect(catalog.groups.single.models.single.id, 'gpt-6.1-sol');
    expect(catalog.groups.single.models.single.efforts.map((e) => e.id), ['medium']);
  });

  test('session/selectModel is acknowledged and applied to the next turn', () async {
    expect(carrier.allowsEndpoint('session/selectModel'), isTrue);
    final result = await carrier.call('session/selectModel', {
      'request': {
        'sessionId': 'codex:t1',
        'provider': 'codex',
        'model': 'gpt-6.1-sol',
        'reasoningEffort': 'high',
      },
    });
    final value = (result as RpcOk).value as Map<String, Object?>;
    final selected = ModelSelection.fromJson(value['selected']);
    expect(selected?.provider, 'codex');
    expect(selected?.model, 'gpt-6.1-sol');
    expect(selected?.reasoningEffort, 'high');
    expect((value['defaultSave'] as Map)['status'], 'skipped');

    await carrier.call('session/prompt', {
      'request': {
        'requestId': 'r1',
        'sessionId': 'codex:t1',
        'content': [
          {'type': 'text', 'text': '用新模型回复'},
        ],
      },
    });
    final call = transport.calls.lastWhere((c) => c.method == 'turn/start');
    expect(call.params['model'], 'gpt-6.1-sol');
    expect(call.params['effort'], 'high');
  });

  test('session/selectModel drops an effort the Host policy would reject', () async {
    final result = await carrier.call('session/selectModel', {
      'request': {
        'sessionId': 'codex:t1',
        'provider': 'codex',
        'model': 'gpt-6.1-sol',
        'reasoningEffort': 'extreme',
      },
    });
    final value = (result as RpcOk).value as Map<String, Object?>;
    expect((value['selected'] as Map).containsKey('reasoningEffort'), isFalse);
    await carrier.call('session/prompt', {
      'request': {
        'requestId': 'r2',
        'sessionId': 'codex:t1',
        'content': [
          {'type': 'text', 'text': '继续'},
        ],
      },
    });
    final call = transport.calls.lastWhere((c) => c.method == 'turn/start');
    expect(call.params.containsKey('effort'), isFalse);
  });

  test('a model picked before a thread exists is used by thread/start', () async {
    await carrier.call('session/selectModel', {
      'request': {
        'sessionId': 'new-chat',
        'provider': 'codex',
        'model': 'gpt-6.1-sol',
      },
    });
    final result = await carrier.call('session/create', {
      'request': {'cwd': r'D:\whm\dsh-buddy'},
    });
    expect(((result as RpcOk).value as Map)['sessionId'], 'codex:t9');
    final call = transport.calls.lastWhere((c) => c.method == 'thread/start');
    expect(call.params['model'], 'gpt-6.1-sol');
  });

  test('model catalog publishes a usable default selection', () async {
    final result = await carrier.call('session/modelCatalog', const {});
    final catalog = ModelCatalog.fromJson((result as RpcOk).value);
    final selection = catalog.defaultSelection;
    expect(selection, isNotNull);
    expect(selection!.provider, 'codex');
    expect(selection.model, 'gpt-6.1-sol');
    expect(selection.reasoningEffort, 'medium');
    // The composer uses this to seed the sheet; an invalid effort would make
    // tapping "中" a no-op and leave the user unable to continue.
    expect(catalog.groups.single.models.single.efforts.map((e) => e.id), contains(selection.reasoningEffort));
  });

  test('a prompt is matched to its echo exactly once', () async {
    await carrier.call('session/prompt', {
      'request': {
        'requestId': 'r-echo',
        'sessionId': 'codex:t1',
        'content': [
          {'type': 'text', 'text': '列一下目录'},
        ],
      },
    });
    final record = (historyJson(userText: '列一下目录')['records'] as List).first as Map;
    Map<String, Object?> eventOf() => (record['event'] as Map).map<String, Object?>((k, v) => MapEntry('$k', v));
    final first = carrier.withRpcId('t1', eventOf());
    expect(((first['data'] as Map)['source'] as Map)['rpcId'], 'r-echo');
    final second = carrier.withRpcId('t1', eventOf());
    expect(((second['data'] as Map)['source'] as Map)['rpcId'], isNull, reason: 'consumed once');
  });

  group('mux link', () {
    late List<Map<String, Object?>> frames;
    late DshMuxLink link;

    setUp(() async {
      frames = [];
      link = await carrier.openLink(const MuxOptions());
      link.start(onFrame: frames.add, onLost: (_, _) {});
    });

    Future<Map<String, Object?>> waitItem(String streamId, {String? type}) async {
      for (var attempt = 0; attempt < 200; attempt++) {
        for (final frame in frames) {
          if (frame['streamId'] != streamId || frame['type'] != 'item') continue;
          final value = frame['value'] as Map;
          if (type == null || value['type'] == type) return value.map((k, v) => MapEntry('$k', v));
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('no $type item for $streamId; frames: $frames');
    }

    test(r'$events answers with a ready handshake', () async {
      link.open('e1', r'$events', const {'args': <String, Object?>{}});
      final ready = await waitItem('e1', type: 'ready');
      expect(ready['type'], 'ready');
      expect((ready['host'] as Map)['home'], 'codex');
      expect(ready['clientId'], isNotEmpty);
    });

    test(r'$events announces a new thread so the drawer refreshes', () async {
      link.open('e1', r'$events', const {'args': <String, Object?>{}});
      await waitItem('e1', type: 'ready');
      await carrier.call('session/create', {
        'request': {'cwd': r'D:\whm\dsh-buddy'},
      });
      final added = await waitItem('e1', type: 'emit');
      expect(added['event'], 'api-session/added');
      final row = (added['args'] as List).single;
      expect(SessionSummary.fromJson(row).sessionId, 'codex:t9');
    });

    test('a prompt echo is delivered once with its rpcId', () async {
      transport.handler = (method, params) => switch (method) {
        'dsh/sessionHistory' => historyJson(userText: '列一下目录'),
        'thread/read' => {'thread': threadJson()},
        _ => <String, Object?>{},
      };
      await carrier.call('session/prompt', {
        'request': {
          'requestId': 'r-echo',
          'sessionId': 'codex:t1',
          'content': [
            {'type': 'text', 'text': '列一下目录'},
          ],
        },
      });
      link.open('s2', 'session/follow', {
        'args': {
          'request': {
            'address': {'sessionId': 'codex:t1'},
          },
        },
      });
      final snapshot = await waitItem('s2', type: 'snapshot');
      final records = (snapshot['records'] as List).cast<Map<String, Object?>>();
      final user = records.where((r) => (r['event'] as Map)['type'] == 'user/message').toList();
      expect(user, hasLength(1));
      final source = ((user.single['event'] as Map)['data'] as Map)['source'] as Map;
      expect(source['rpcId'], 'r-echo');

      final subscription = transport.opened.single;
      transport.emit(
        CodexTransportEvent(codexFrameEvent, {
          'streamId': subscription.streamId,
          'frame': {
            'method': 'item/started',
            'params': {
              'threadId': 't1',
              'item': {
                'type': 'userMessage',
                'id': 'u-echo',
                'content': [
                  {'type': 'text', 'text': '列一下目录'},
                ],
              },
            },
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final liveUser = frames
          .where(
            (f) => f['streamId'] == 's2' && f['type'] == 'item' && (f['value'] as Map)['type'] == 'user/message',
          )
          .toList();
      expect(liveUser, isEmpty, reason: 'the same echo must not be drawn twice');
    });

    test('session/follow sends a snapshot, then projected live events', () async {
      link.open('s1', 'session/follow', {
        'args': {
          'request': {
            'address': {'kind': 'session', 'sessionId': 'codex:t1'},
            'assistantStream': true,
          },
        },
      });
      final snapshot = await waitItem('s1', type: 'snapshot');
      final parsed = SessionSnapshotEvent.fromJson('codex:t1', snapshot);
      expect(parsed.cursor, 3);
      expect(parsed.events, hasLength(2));
      expect(parsed.projections.title, '第一条消息');

      final subscription = transport.opened.single;
      expect(subscription.threadId, 't1');
      transport.emit(
        CodexTransportEvent(codexFrameEvent, {
          'streamId': subscription.streamId,
          'frame': {
            'method': 'turn/started',
            'params': {
              'threadId': 't1',
              'turn': {'id': 'turn-2'},
            },
          },
        }),
      );
      final event = await waitItem('s1', type: 'event');
      final log = SessionLogEvent.fromJson((event['event'] as Map).map((k, v) => MapEntry('$k', v)));
      expect(log.type, 'turn/start');
      expect(log.seq, 4, reason: 'live seq continues after the history cursor');
    });

    test('workspace/follow lists Codex projects as workspaces', () async {
      transport.handler = (method, params) => switch (method) {
        'project/list' => {
          'data': [
            {
              'id': 'p1',
              'name': 'dsh 养鱼调研',
              'roots': [
                {'path': r'D:\whm\dsh-buddy'},
              ],
            },
          ],
        },
        _ => <String, Object?>{},
      };
      link.open('w1', 'workspace/follow', const {'args': <String, Object?>{}});
      final baseline = await waitItem('w1', type: 'baseline');
      final workspace = ((baseline['value'] as Map)['items'] as List).single as Map;
      final parsed = Workspace.fromJson(workspace);
      expect(parsed.workspaceId, r'codex-workspace:project:D:\whm\dsh-buddy');
      expect(parsed.title, 'dsh 养鱼调研');
      expect(parsed.path, r'D:\whm\dsh-buddy');
    });

    test('endpoints outside the mapping answer with an error frame', () async {
      link.open('x1', 'subagents/follow', const {'args': <String, Object?>{}});
      await Future<void>.delayed(Duration.zero);
      final error = frames.firstWhere((frame) => frame['streamId'] == 'x1');
      expect(error['type'], 'error');
      expect((error['error'] as Map)['code'], 'METHOD_NOT_ALLOWED');
    });
  });
}
