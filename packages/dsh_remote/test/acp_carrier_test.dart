// ACP as a DSH host: endpoint mapping, prefixed ids, approvals and the link.
import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_acp_transport.dart';

Object? backendResponses(String method, Map<String, Object?> params) => switch (method) {
  'dsh/workspaceList' => [
    {'path': r'D:\work\demo', 'title': 'demo'},
    {'path': r'D:\work\other', 'title': 'other'},
  ],
  // The Host wraps the rows in `items`; a bare array is only for old Hosts.
  'dsh/sessionList' => {
    'items': [
      {'conversationId': 'n1', 'title': '第一条', 'updatedAt': 1700000000000},
      {'conversationId': 'n2', 'title': '第二条', 'updatedAt': 1800000000000},
    ],
  },
  'session/new' => {'sessionId': 'n9'},
  'session/load' => {'sessionId': 'n1'},
  'dsh/sessionHistory' => {
    'events': [
      {
        'type': 'event',
        'event': {
          'type': 'turn/start',
          'seq': 0,
          'time': 0,
          'data': {'turn': 1},
        },
      },
      {
        'type': 'event',
        'event': {
          'type': 'step/start',
          'seq': 1,
          'time': 0,
          'data': {'turn': 1, 'step': 1},
        },
      },
    ],
  },
  'session/prompt' => {'accepted': true, 'stopReason': 'in_progress'},
  'dsh/sessionModels' => {
    'configOptions': [
      {
        'id': 'model',
        'category': 'model',
        'currentValue': 'opencode/free',
        'options': [
          {'value': 'opencode/free', 'name': 'Free'},
          {'value': 'opencode/big', 'name': 'Big'},
        ],
      },
    ],
  },
  'terminal/write' => {'ok': true},
  _ => <String, Object?>{},
};

void main() {
  late FakeAcpTransport transport;
  late AcpClient client;
  late AcpCarrier carrier;

  setUp(() {
    transport = FakeAcpTransport();
    client = AcpClient(transport, backend: 'opencode');
    carrier = AcpCarrier(
      client: client,
      agent: const AgentBackend.chat(AgentKind.opencode),
      backend: 'opencode',
      defaultCwd: r'D:\work\demo',
    );
    transport.handler = backendResponses;
  });

  test('advertises its own endpoints and delegates only global ones', () {
    expect(carrier.kind, 'opencode');
    expect(carrier.supportsUplink, isFalse);
    expect(carrier.allowsEndpoint('session/prompt'), isTrue);
    expect(carrier.allowsEndpoint('terminal/write'), isTrue);
    expect(carrier.allowsEndpoint('plugins/list'), isFalse);
    expect(carrier.allowsEndpoint('settings/describe'), isFalse, reason: 'no fallback carrier configured');
  });

  test('terminal unary calls are served but the streaming pair is not advertised', () {
    expect(carrier.allowsEndpoint('terminal/write'), isTrue);
    expect(carrier.allowsEndpoint('terminal/create'), isTrue);
    expect(carrier.allowsEndpoint('terminal/follow'), isFalse);
    expect(carrier.allowsEndpoint('terminal/retain'), isFalse);
  });

  test('closing a follow releases the Host ACP stream', () async {
    final link = await carrier.openLink(const MuxOptions());
    link.start(onFrame: (_) {}, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
        },
      },
    });
    await pumpEventQueue();
    final acpStreamId = transport.opened.single.streamId;
    link.cancel('f1');
    await pumpEventQueue();
    expect(transport.closedStreamIds, contains(acpStreamId));
  });

  test('a Host-closed ACP stream ends the mux stream', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
        },
      },
    });
    await pumpEventQueue();
    transport.emitClosed(transport.opened.single.streamId);
    await pumpEventQueue();
    expect(frames.any((f) => f['type'] == 'end' && f['streamId'] == 'f1'), isTrue);
  });

  test('a Host refusal keeps its code instead of becoming acp/internal', () async {
    transport.handler = (method, params) => throw const RemoteRpcException('ACP_SESSION_BUSY', 'stop it first');
    await expectLater(
      client.cancel('n1'),
      throwsA(isA<AcpException>().having((error) => error.code, 'code', 'ACP_SESSION_BUSY')),
    );
  });

  test('session/load sends only the fields the Host accepts', () async {
    final link = await carrier.openLink(const MuxOptions());
    link.start(onFrame: (_) {}, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
        },
      },
    });
    await pumpEventQueue();
    final load = transport.calls.firstWhere((call) => call.method == 'session/load');
    expect(
      load.params.keys.toSet(),
      {'sessionId', 'backend'},
      reason: 'the Host schema is strict: cwd/mcpServers make it INVALID_MESSAGE',
    );
    expect(load.params['sessionId'], 'n1');
  });

  test('session/cancel does not send a backend', () async {
    final result = await carrier.call('session/cancel', const {
      'request': {'sessionId': 'opencode:n1'},
    });
    expect(result, isA<RpcOk>());
    final cancel = transport.calls.firstWhere((call) => call.method == 'session/cancel');
    expect(cancel.params.keys.toSet(), {'sessionId'});
  });

  test('a second follow of the same session does not load it again', () async {
    final link = await carrier.openLink(const MuxOptions());
    link.start(onFrame: (_) {}, onLost: (_, _) {});
    for (final id in ['f1', 'f2']) {
      link.open(id, 'session/follow', const {
        'args': {
          'request': {
            'address': {'sessionId': 'opencode:n1'},
          },
        },
      });
      await pumpEventQueue();
    }
    expect(
      transport.methods.where((method) => method == 'session/load').length,
      1,
      reason: 'reloading while a reply runs is refused for Claude (PROMPT_IN_PROGRESS)',
    );
  });

  test('an image prompt is refused before the turn starts', () async {
    final result = await carrier.call('session/prompt', const {
      'request': {
        'requestId': 'r-1',
        'sessionId': 'opencode:n1',
        'content': [
          {'type': 'text', 'text': '看图'},
          {
            'type': 'image',
            'mediaType': 'image/png',
            'data': 'AAAA',
          },
        ],
      },
    });
    expect((result as RpcError).error.code, 'ACP_ATTACHMENT_UNSUPPORTED');
    expect(transport.methods, isNot(contains('session/prompt')));
  });

  test('session/list merges workspaces, sorts by recency and prefixes ids', () async {
    final result = await carrier.call('session/list', const {});
    final items = ((result as RpcOk).value as Map)['items'] as List;
    expect(items, hasLength(2), reason: 'the same two sessions appear under both workspaces and dedupe by id');
    final ids = items.map((row) => (row as Map)['sessionId']).toList();
    expect(ids.first, 'opencode:n2', reason: 'newest first');
    expect(ids.toSet(), {'opencode:n1', 'opencode:n2'});
    final summary = SessionSummary.fromJson((items.first as Map).cast<String, Object?>());
    expect(summary.sessionId, 'opencode:n2');
    expect(summary.title, '第二条');
  });

  test('session/create returns a prefixed id and remembers the workspace', () async {
    final result = await carrier.call('session/create', const {
      'request': {'workspaceId': r'opencode:cwd:D%3A%5Cwork%5Cdemo'},
    });
    final value = (result as RpcOk).value as Map;
    expect(value['sessionId'], 'opencode:n9');
    final call = transport.calls.lastWhere((c) => c.method == 'session/new');
    expect(call.params['cwd'], r'D:\work\demo');
    expect(call.params['backend'], 'opencode');
  });

  test('session/prompt forwards text and remembers the request id', () async {
    await carrier.call('session/create', const {
      'request': {'cwd': r'D:\work\demo'},
    });
    final result = await carrier.call('session/prompt', const {
      'request': {
        'requestId': 'r-1',
        'sessionId': 'opencode:n9',
        'content': [
          {'type': 'text', 'text': '跑一下测试'},
        ],
      },
    });
    expect(result, isA<RpcOk>());
    final call = transport.calls.lastWhere((c) => c.method == 'session/prompt');
    expect(call.params['sessionId'], 'n9');
    expect(call.params['backend'], 'opencode');
    expect((call.params['prompt'] as List).single, {'type': 'text', 'text': '跑一下测试'});
    expect(carrier.takePendingPrompt('n9'), (text: '跑一下测试', rpcId: 'r-1'));
    expect(carrier.takePendingPrompt('n9'), isNull);
  });

  test('session/cancel targets the native session id', () async {
    await carrier.call('session/cancel', const {
      'request': {
        'address': {'sessionId': 'opencode:n1'},
      },
    });
    expect(transport.calls.lastWhere((c) => c.method == 'session/cancel').params['sessionId'], 'n1');
  });

  test('an approval result becomes agent.acp.respond', () async {
    await carrier.call(r'$events/result', const {
      'clientId': 'c1',
      'eventId': 'h-1',
      'outcome': {'kind': 'result', 'value': 'allowed-once'},
    });
    expect(transport.responses.single, {'requestHandle': 'h-1', 'decision': 'allow-once'});

    await carrier.call(r'$events/result', const {
      'clientId': 'c1',
      'eventId': 'h-2',
      'outcome': {'kind': 'result', 'value': 'rejected'},
    });
    expect(transport.responses.last, {'requestHandle': 'h-2', 'decision': 'reject-once'});
  });

  test('a pass answer becomes a refusal (ACP has no second answerer)', () async {
    await carrier.call(r'$events/result', const {
      'clientId': 'c1',
      'eventId': 'h-3',
      'outcome': {'kind': 'next'},
    });
    // Leaving it unanswered left the Host's permission request pending until
    // the whole turn was cancelled.
    expect(transport.responses.single, {'requestHandle': 'h-3', 'decision': 'reject-once'});
  });

  test('terminal calls are proxied through dsh/toolCall with native ids', () async {
    await carrier.call('terminal/write', const {
      'agentId': 'opencode:n1',
      'request': {'id': 't1', 'data': 'ls\r'},
    });
    final call = transport.calls.lastWhere((c) => c.method == 'dsh/toolCall');
    expect(call.params['sessionId'], 'n1', reason: 'the RPC param is the native session id');
    expect(call.params['endpoint'], 'terminal/write');
    expect(
      (call.params['args'] as Map)['agentId'],
      'opencode:n1',
      reason: 'the Host compares scope ids against <backend>:<native>',
    );
  });

  test('session/page returns the Host history records', () async {
    final result = await carrier.call('session/page', const {
      'request': {
        'address': {'sessionId': 'opencode:n1'},
      },
    });
    final value = (result as RpcOk).value as Map;
    expect((value['records'] as List), hasLength(2));
    expect(value['cursor'], 1);
  });

  test('workspace/create accepts an absolute directory and binds it', () async {
    const path = 'D:/work/new';
    final result = await carrier.call('workspace/create', const {
      'request': {'path': path},
    });
    final value = (result as RpcOk).value as Map;
    final workspace = value['workspace'] as Map;
    expect(workspace['path'], path);
    expect(workspace['workspaceId'], acpWorkspaceId('opencode', path));
    expect(workspace['title'], 'new');
    expect(value['created'], isTrue);
  });

  test('workspace/create refuses a relative directory', () async {
    final result = await carrier.call('workspace/create', const {
      'request': {'path': 'relative/dir'},
    });
    expect((result as RpcError).error.code, 'gateway/bad-request');
  });

  test('the model catalog is read from configOptions', () async {
    final result = await carrier.call('session/modelCatalog', const {
      'request': {'sessionId': 'opencode:n1'},
    });
    final value = (result as RpcOk).value as Map;
    final group = (value['groups'] as List).single as Map;
    expect((group['models'] as List).map((m) => (m as Map)['id']), ['opencode/free', 'opencode/big']);
    expect((value['default'] as Map)['model'], 'opencode/free');
  });

  test('a follow stream emits a snapshot and then live projection frames', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('e1', r'$events', const {'args': <String, Object?>{}});
    expect((frames.single['value'] as Map)['type'], 'ready');

    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
          'assistantStream': true,
        },
      },
    });
    await pumpEventQueue();

    final snapshot = frames.firstWhere((f) => (f['value'] as Map?)?['type'] == 'snapshot');
    expect(((snapshot['value'] as Map)['header'] as Map)['id'], 'opencode:n1');
    expect(transport.opened.single.sessionId, 'n1');

    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/update',
        params: {
          'sessionId': 'n1',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'hi'},
          },
        },
      ),
    );
    await pumpEventQueue();
    final streamed = frames.where((f) => (f['value'] as Map?)?['type'] == 'assistant-stream').toList();
    expect(streamed, isNotEmpty);
    expect(streamed.first['streamId'], 'f1');
  });

  test('a backend that never echoes the prompt still yields a user message', () async {
    await carrier.call('session/prompt', const {
      'request': {
        'requestId': 'r-9',
        'sessionId': 'opencode:n1',
        'content': [
          {'type': 'text', 'text': '你好'},
        ],
      },
    });
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
        },
      },
    });
    await pumpEventQueue();
    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/update',
        params: {
          'sessionId': 'n1',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'hi'},
          },
        },
      ),
    );
    await pumpEventQueue();
    final values = frames.map((frame) => frame['value']).whereType<Map<String, Object?>>();
    final user = values.firstWhere(
      (value) => value['type'] == 'event' && (value['event'] as Map)['type'] == 'user/message',
    );
    expect(((user['event'] as Map)['data'] as Map)['source'], containsPair('rpcId', 'r-9'));
    expect(((user['event'] as Map)['data'] as Map)['content'], [
      {'type': 'text', 'text': '你好'},
    ]);
  });

  test('a permission frame reaches the \$events stream as a waterfall', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('e1', r'$events', const {'args': <String, Object?>{}});
    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/request_permission',
        params: {
          'sessionId': 'n1',
          'requestHandle': 'h-9',
          'toolCall': {'toolCallId': 'c9', 'title': 'Run shell'},
        },
      ),
    );
    await pumpEventQueue();
    final waterfall = frames.firstWhere((f) => (f['value'] as Map?)?['type'] == 'waterfall');
    expect((waterfall['value'] as Map)['eventId'], 'h-9');
    expect((waterfall['value'] as Map)['agentId'], 'opencode:n1');
  });

  // ---------------------------------------------------------------------------
  // The workspace a stored session lives in, and the prompts sent into it.

  test('a follow without a known workspace asks the Host instead of failing', () async {
    // Production builds the carrier without a default cwd: a cold start
    // restores a stored session id before `session/list` has run.
    final coldCarrier = AcpCarrier(
      client: client,
      agent: const AgentBackend.chat(AgentKind.opencode),
      backend: 'opencode',
    );
    final link = await coldCarrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n2'},
        },
      },
    });
    await pumpEventQueue();

    expect(frames.where((f) => f['type'] == 'error'), isEmpty);
    final snapshot = frames.firstWhere((f) => (f['value'] as Map?)?['type'] == 'snapshot');
    expect(((snapshot['value'] as Map)['header'] as Map)['cwd'], r'D:\work\demo');
    final load = transport.calls.lastWhere((call) => call.method == 'session/load');
    expect(
      load.params.containsKey('cwd'),
      isFalse,
      reason: 'the Host injects cwd from its own catalog; sending it is INVALID_MESSAGE',
    );
  });

  test('an image is refused up front for backends the Host will not take it', () async {
    // The Host refuses inline images for everything except antigravity/hermes,
    // so the whole prompt would come back METHOD_NOT_ALLOWED and the person's
    // text would be lost. Refuse here instead, before any round trip.
    final sent = await carrier.call('session/prompt', const {
      'request': {
        'requestId': 'r-img',
        'sessionId': 'opencode:n1',
        'content': [
          {'type': 'text', 'text': '看图'},
          {'type': 'image', 'mediaType': 'image/png', 'data': 'AAA'},
        ],
      },
    });
    expect((sent as RpcError).error.code, 'ACP_ATTACHMENT_UNSUPPORTED');
    expect(transport.methods, isNot(contains('session/prompt')));

    final refused = await carrier.call('session/prompt', const {
      'request': {
        'requestId': 'r-file',
        'sessionId': 'opencode:n1',
        'content': [
          {'type': 'text', 'text': '看这个文件'},
          {'type': 'file', 'receiptId': 'rec-1'},
        ],
      },
    });
    expect((refused as RpcError).error.code, 'ACP_ATTACHMENT_UNSUPPORTED');
    expect(
      transport.methods.where((method) => method == 'session/prompt'),
      isEmpty,
      reason: 'the prompt must not go out with the attachment silently missing',
    );
  });

  test('stopping before the first update still yields a user message and a turn end', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
          'assistantStream': true,
        },
      },
    });
    await pumpEventQueue();

    await carrier.call('session/prompt', const {
      'request': {
        'requestId': 'r-stop',
        'sessionId': 'opencode:n1',
        'content': [
          {'type': 'text', 'text': '跑一下'},
        ],
      },
    });
    await carrier.call('session/cancel', const {
      'request': {
        'address': {'sessionId': 'opencode:n1'},
      },
    });
    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/update',
        params: {
          'sessionId': 'n1',
          'update': {'sessionUpdate': 'prompt_completed', 'stopReason': 'cancelled'},
        },
      ),
    );
    await pumpEventQueue();

    final values = frames.map((frame) => frame['value']).whereType<Map<String, Object?>>();
    final events = [
      for (final value in values)
        if (value['type'] == 'event') value['event'] as Map,
    ];
    final user = events.firstWhere((event) => event['type'] == 'user/message');
    expect((user['data'] as Map)['source'], containsPair('rpcId', 'r-stop'));
    final end = events.lastWhere((event) => event['type'] == 'turn/end');
    expect((end['data'] as Map)['reason'], containsPair('kind', 'aborted'));
  });

  test('the model is pushed to the backend once, not before every prompt', () async {
    await carrier.call('session/selectModel', const {
      'request': {'sessionId': 'opencode:n1', 'model': 'opencode/big'},
    });
    for (final id in ['r-a', 'r-b']) {
      await carrier.call('session/prompt', {
        'request': {
          'requestId': id,
          'sessionId': 'opencode:n1',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
      });
    }
    expect(
      transport.methods.where((method) => method == 'dsh/selectModel'),
      hasLength(1),
      reason: 'an unchanged selection must not add a round trip to every send',
    );
  });

  test('a failing workspace is reported and keeps the sessions it already listed', () async {
    await carrier.call('session/list', const {});
    expect(carrier.cwdOf('n1'), r'D:\work\demo');

    transport.handler = (method, params) => switch (method) {
      'dsh/workspaceList' => [
        {'path': r'D:\work\demo', 'title': 'demo'},
      ],
      'dsh/sessionList' => throw const RemoteRpcException('ACP_UNAVAILABLE', 'backend is starting'),
      _ => <String, Object?>{},
    };
    final result = await carrier.call('session/list', const {});
    final value = (result as RpcOk).value as Map;
    final failures = value['failures'] as List;
    expect(failures.single, {'workspace': r'D:\work\demo', 'code': 'ACP_UNAVAILABLE'});
    final ids = (value['items'] as List).map((row) => (row as Map)['sessionId']).toList();
    expect(ids, containsAll(['opencode:n1', 'opencode:n2']), reason: 'reported sessions must not vanish');
  });

  test('a follow without assistantStream skips deltas but keeps the turn events', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
        },
      },
    });
    await pumpEventQueue();
    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/update',
        params: {
          'sessionId': 'n1',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'hi'},
          },
        },
      ),
    );
    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/update',
        params: {
          'sessionId': 'n1',
          'update': {'sessionUpdate': 'prompt_completed', 'stopReason': 'end_turn'},
        },
      ),
    );
    await pumpEventQueue();

    final values = frames.map((frame) => frame['value']).whereType<Map<String, Object?>>();
    expect(values.where((value) => value['type'] == 'assistant-stream'), isEmpty);
    final events = [
      for (final value in values)
        if (value['type'] == 'event') (value['event'] as Map)['type'],
    ];
    expect(events, containsAll(['turn/start', 'assistant/message', 'turn/end']));
  });

  test('two follows of one session both receive its frames', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    for (final id in ['f1', 'f2']) {
      link.open(id, 'session/follow', const {
        'args': {
          'request': {
            'address': {'sessionId': 'opencode:n1'},
            'assistantStream': true,
          },
        },
      });
    }
    await pumpEventQueue();
    transport.emit(
      AcpFrame(
        streamId: 'session:n1',
        method: 'session/update',
        params: {
          'sessionId': 'n1',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'hi'},
          },
        },
      ),
    );
    await pumpEventQueue();
    expect(frames.where((frame) => frame['streamId'] == 'f1'), isNotEmpty);
    expect(frames.where((frame) => frame['streamId'] == 'f2'), isNotEmpty);
  });

  test('session/page honours beforeSeq and reports hasMore', () async {
    final older = await carrier.call('session/page', const {
      'request': {
        'address': {'sessionId': 'opencode:n1'},
        'beforeSeq': 1,
      },
    });
    final olderValue = (older as RpcOk).value as Map;
    expect((olderValue['records'] as List), hasLength(1));
    expect(olderValue['hasMore'], isFalse);

    final limited = await carrier.call('session/page', const {
      'request': {
        'address': {'sessionId': 'opencode:n1'},
        'beforeSeq': 2,
        'maxMessages': 1,
      },
    });
    final limitedValue = (limited as RpcOk).value as Map;
    expect((limitedValue['records'] as List), hasLength(1));
    expect(limitedValue['hasMore'], isTrue);
  });

  test('a live turn publishes the running edges the App listens for', () async {
    final link = await carrier.openLink(const MuxOptions());
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) {});
    link.open('e1', r'$events', const {'args': <String, Object?>{}});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
          'assistantStream': true,
        },
      },
    });
    await pumpEventQueue();
    for (final update in [
      {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'hi'},
      },
      {'sessionUpdate': 'prompt_completed', 'stopReason': 'end_turn'},
    ]) {
      transport.emit(
        AcpFrame(
          streamId: 'session:n1',
          method: 'session/update',
          params: {'sessionId': 'n1', 'update': update},
        ),
      );
      await pumpEventQueue();
    }
    final statuses = [
      for (final frame in frames)
        if ((frame['value'] as Map?)?['event'] == 'api-session/status') (frame['value'] as Map)['args'],
    ];
    expect(statuses, [
      ['opencode:n1', true],
      ['opencode:n1', false],
    ]);
  });

  test('losing the link closes the follow streams it still owns', () async {
    final lost = StreamController<Object>();
    final carrierWithLoss = AcpCarrier(
      client: client,
      agent: const AgentBackend.chat(AgentKind.opencode),
      backend: 'opencode',
      defaultCwd: r'D:\work\demo',
      lost: lost.stream,
    );
    final link = await carrierWithLoss.openLink(const MuxOptions());
    link.start(onFrame: (_) {}, onLost: (_, _) {});
    link.open('f1', 'session/follow', const {
      'args': {
        'request': {
          'address': {'sessionId': 'opencode:n1'},
        },
      },
    });
    await pumpEventQueue();
    final acpStreamId = transport.opened.single.streamId;
    lost.add('gone');
    await pumpEventQueue();
    expect(transport.closedStreamIds, contains(acpStreamId));
    await lost.close();
  });
}
