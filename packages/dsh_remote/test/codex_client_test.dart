// Codex domain client: envelope shapes, catalog parsing, history pages and
// stream routing, against a fake transport (no Server, no Host).
import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_codex_transport.dart';

void main() {
  group('identifiers', () {
    test('session and workspace ids round-trip', () {
      expect(codexSessionId('abc'), 'codex:abc');
      expect(codexThreadIdOf('codex:abc'), 'abc');
      expect(codexThreadIdOf('plain-session'), isNull);
      expect(codexWorkspaceId(r'C:/work'), r'codex-workspace:project:C:/work');
      expect(codexWorkspacePathOf(r'codex-workspace:project:C:/work'), r'C:/work');
      expect(codexWorkspacePathOf('other'), isNull);
    });
  });

  group('wire parsing', () {
    test('project page keeps absolute roots only', () {
      final page = CodexPage.parse<CodexProject>(
        {
          'data': [
            {
              'id': 'p1',
              'name': 'dsh 养鱼调研',
              'roots': [
                {'path': r'D:\whm\dsh-buddy'},
              ],
              'updatedAt': 1700000000000,
            },
            {'id': 'p2', 'name': 'no roots', 'roots': <Object?>[]},
            {'name': 'no id', 'roots': <Object?>[]},
          ],
          'nextCursor': 'c1',
        },
        CodexProject.tryFromJson,
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.name, 'dsh 养鱼调研');
      expect(page.items.single.path, r'D:\whm\dsh-buddy');
      expect(page.items.single.workspaceId, r'codex-workspace:project:D:\whm\dsh-buddy');
      expect(page.hasMore, isTrue);
    });

    test('thread summary prefers a rename, then the preview first line', () {
      final renamed = CodexThreadSummary.fromJson({'id': 't1', 'name': '固定标题', 'preview': 'first prompt'});
      expect(renamed.title, '固定标题');
      final preview = CodexThreadSummary.fromJson({'id': 't2', 'preview': 'first prompt\nsecond'});
      expect(preview.title, 'first prompt');
      final empty = CodexThreadSummary.fromJson({'id': 't3'});
      expect(empty.title, 't3');
      expect(empty.session, 'codex:t3');
    });

    test('thread/read accepts both envelope shapes and reads items', () {
      final bare = CodexThread.fromJson({
        'id': 't1',
        'turns': [
          {
            'id': 'turn-1',
            'status': 'completed',
            'items': [
              {
                'type': 'userMessage',
                'id': 'i1',
                'content': [
                  {'type': 'text', 'text': '你好'},
                ],
              },
              {'type': 'commandExecution', 'id': 'i2'},
            ],
          },
        ],
      });
      expect(bare.summary.id, 't1');
      expect(bare.turns.single.items.first.text, '你好');
      expect(bare.turns.single.items.last.isTool, isTrue);

      final wrapped = CodexThread.fromJson({'thread': {'id': 't2', 'turns': <Object?>[]}});
      expect(wrapped.summary.id, 't2');
      expect(wrapped.turns, isEmpty);
    });

    test('history page exposes the DSH-shaped event maps', () {
      final page = CodexHistoryPage.fromJson({
        'header': {'version': 1, 'id': 'codex:t1'},
        'cursor': 7,
        'nextTurn': 2,
        'hasMore': true,
        'activeTurnId': 'turn-2',
        'records': [
          {
            'type': 'event',
            'event': {
              'type': 'user/message',
              'seq': 6,
              'time': 1700000000000,
              'data': {'role': 'user'},
            },
          },
        ],
      });
      expect(page.cursor, 7);
      expect(page.hasMore, isTrue);
      expect(page.activeTurnId, 'turn-2');
      expect(page.events.single['type'], 'user/message');
      expect(page.records.single.seq, 6);
    });
  });

  group('client envelopes', () {
    late FakeCodexTransport transport;
    late CodexClient client;

    setUp(() {
      transport = FakeCodexTransport();
      client = CodexClient(transport);
    });

    test('project/list sends method and params through codex.app.call', () async {
      transport.handler = (method, params) => {'data': <Object?>[], 'nextCursor': null};
      await client.listProjects(limit: 20);
      expect(transport.calls.single.method, 'project/list');
      expect(transport.calls.single.params, {'limit': 20});
    });

    test('thread/list carries the workspace cwd, never the project id', () async {
      transport.handler = (_, _) => {'data': <Object?>[]};
      await client.listThreads(cwd: r'C://work', limit: 5);
      expect(transport.calls.single.method, 'thread/list');
      expect(transport.calls.single.params['cwd'], r'C://work');
      expect(transport.calls.single.params['limit'], 5);
      expect(transport.calls.single.params.containsKey('projectId'), isFalse);
    });

    test('turn/start sends the text input and returns the turn id', () async {
      transport.handler = (_, _) => {
        'turn': {'id': 'turn-9'},
      };
      final id = await client.startTurn(threadId: 't1', text: '跑一下测试');
      expect(id, 'turn-9');
      final params = transport.calls.single.params;
      expect(params['threadId'], 't1');
      expect(params['input'], [
        {'type': 'text', 'text': '跑一下测试'},
      ]);
    });

    test('thread/start sends only the policy preset, never raw app-server knobs', () async {
      transport.handler = (_, _) => {
        'thread': {'id': 't1', 'cwd': r'C:\work'},
      };
      final summary = await client.startThread(cwd: r'C:\work');
      expect(summary.id, 't1');
      expect(transport.calls.single.params, {'cwd': r'C:\work', 'permissionPreset': 'workspace-write'});
    });

    test('every call stays inside the Host method policy', () async {
      // The Host parses each `codex.app.call` with a strict schema and answers
      // INVALID_MESSAGE for one extra key, so the wire shape is part of the
      // contract: keys below mirror packages/plugin/src/codex/method-policy.ts.
      const allowed = <String, Set<String>>{
        'project/list': {'cursor', 'limit'},
        'thread/list': {
          'cursor',
          'limit',
          'sortKey',
          'sortDirection',
          'modelProviders',
          'sourceKinds',
          'archived',
          'isPinned',
          'cwd',
          'useStateDbOnly',
          'searchTerm',
        },
        'thread/read': {'threadId', 'includeTurns'},
        'thread/start': {'cwd', 'model', 'personality', 'permissionPreset'},
        'thread/resume': {'threadId', 'model', 'permissionPreset'},
        'turn/start': {'threadId', 'input', 'model', 'effort', 'summary', 'personality', 'permissionPreset'},
        'turn/interrupt': {'threadId', 'turnId'},
        'dsh/sessionHistory': {'threadId', 'beforeSeq', 'throughSeq', 'maxMessages'},
        'thread/name/set': {'threadId', 'name'},
        'model/list': {'cursor', 'limit', 'includeHidden'},
        'account/read': {'refreshToken'},
      };
      transport.handler = (method, _) => switch (method) {
        'thread/start' || 'thread/resume' => {
          'thread': {'id': 't1', 'cwd': r'C:\work'},
        },
        'turn/start' => {
          'turn': {'id': 'turn-1'},
        },
        'dsh/sessionHistory' => {'entries': <Object?>[]},
        _ => {'data': <Object?>[]},
      };
      await client.listProjects();
      await client.listThreads(cwd: r'C:\work', searchTerm: '养鱼');
      await client.readThread('t1');
      await client.startThread(cwd: r'C:\work');
      await client.resumeThread('t1');
      await client.startTurn(threadId: 't1', text: '你好');
      await client.interruptTurn(threadId: 't1', turnId: 'turn-1');
      await client.history(threadId: 't1', maxMessages: 5000, beforeSeq: -3, throughSeq: -9);
      await client.callRaw('thread/name/set', {'threadId': 't1', 'name': '改名'});
      await client.callRaw('model/list', const {});
      await client.account();

      expect(transport.calls, isNotEmpty);
      for (final call in transport.calls) {
        final permitted = allowed[call.method];
        expect(permitted, isNotNull, reason: '${call.method} is not allowlisted by the Host');
        final extra = call.params.keys.where((key) => !permitted!.contains(key)).toList();
        expect(extra, isEmpty, reason: '${call.method} would be rejected for $extra');
      }
      final history = transport.calls.firstWhere((call) => call.method == 'dsh/sessionHistory').params;
      expect(history['maxMessages'], 200, reason: 'the Host caps history pages at 200 messages');
      expect(history['beforeSeq'], 0, reason: 'beforeSeq must be non-negative');
      expect(history['throughSeq'], -1, reason: 'throughSeq is at least -1');
    });

    test('chunked responses are reassembled before decoding', () async {
      final payload = jsonEncode({
        'data': [
          {'id': 't1', 'preview': '中文'},
        ],
      });
      final bytes = utf8.encode(payload);
      final split = bytes.length ~/ 2;
      transport.supportsTransfer = true;
      transport.handler = (method, _) => method == 'thread/list'
          ? {'kind': 'chunked', 'transferId': 'tr1', 'totalBytes': bytes.length, 'totalChunks': 2}
          : {'data': 'x'};
      transport.chunk = (transferId, index) {
        expect(transferId, 'tr1');
        return base64Encode(index == 0 ? bytes.sublist(0, split) : bytes.sublist(split));
      };
      final page = await client.listThreads();
      expect(page.items.single.preview, '中文');
    });

    test('approvals pick the offered allow option, else decline', () async {
      await client.answer(
        const CodexServerRequest(
          requestId: 'r1',
          method: 'item/commandExecution/requestApproval',
          params: {
            'options': [
              {'optionId': 'no', 'kind': 'deny'},
              {'optionId': 'yes', 'kind': 'allow_once'},
            ],
          },
        ),
        approve: true,
      );
      expect(transport.responses.single, {
        'requestId': 'r1',
        'result': {'decision': 'yes'},
      });

      await client.answer(const CodexServerRequest(requestId: 'r2', method: 'x', params: {}));
      expect(transport.responses.last['result'], {'decision': 'decline'});
    });
  });

  group('stream subscriptions', () {
    test('frames are routed by stream id and closed streams end', () async {
      final transport = FakeCodexTransport();
      final client = CodexClient(transport);
      final subscription = await client.subscribe('t1');
      expect(transport.opened.single.threadId, 't1');

      final received = <String>[];
      var closed = false;
      subscription.frames.listen((frame) => received.add(frame.method), onDone: () => closed = true);
      transport.emit(
        CodexTransportEvent(codexFrameEvent, {
          'streamId': subscription.streamId,
          'frame': {'method': 'turn/started', 'params': {'threadId': 't1'}},
        }),
      );
      transport.emit(
        CodexTransportEvent(codexFrameEvent, {
          'streamId': 'another',
          'frame': {'method': 'turn/completed', 'params': {}},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, ['turn/started']);

      transport.emit(
        CodexTransportEvent(codexStreamClosedEvent, {'streamId': subscription.streamId, 'reason': 'peer-disconnected'}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(closed, isTrue, reason: 'a closed stream ends the subscription');
      expect(transport.closedStreams, isEmpty, reason: 'the Host closed it first');

      final second = await client.subscribe('t2');
      await second.close();
      expect(transport.closedStreams, contains(second.streamId));
      await client.close();
    });
  });
}
