// The best-effort radar inbox: the switch that turns it on, and the poller it
// feeds. The storage flag used to have a reader and a host but no writer, so
// notifications could never be enabled; these tests pin the whole path
// (switch → storage + epoch → poller → `/events` → durable cursor).

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/personal_server.dart';
import 'package:dsh_app/state/radar_prefs.dart' show radarAutoRefresh;
import 'package:dsh_app/ui/radar/radar_inbox_host.dart';
import 'package:dsh_app/ui/radar/radar_management.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show pumpFrames, testApp, usePhoneView;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const origin = 'https://radar.example';
  const cursorKey = 'radarCursor:$origin';

  final storage = <String, String>{};
  final writes = <String, String>{};
  final requests = <Uri>[];

  String credentials() => jsonEncode({'url': origin, 'token': 'token'});

  void mockStorage() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, Object?>.from(call.arguments as Map);
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return storage[key];
        case 'write':
          final value = args['value'] as String?;
          if (value == null) {
            storage.remove(key);
          } else {
            storage[key!] = value;
            writes[key] = value;
          }
          return null;
        case 'delete':
          storage.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(storage);
        case 'containsKey':
          return storage.containsKey(key);
        case 'deleteAll':
          storage.clear();
          return null;
      }
      return null;
    });
  }

  MockClient server() => MockClient((request) async {
    requests.add(request.url);
    return http.Response(
      jsonEncode({
        'events': [
          {'id': 'evt-1', 'seq': 4, 'read': true},
        ],
        'cursor': 4,
      }),
      200,
    );
  });

  Widget host(http.Client transport) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: RadarInboxHost(transport: transport, child: const Scaffold(body: SizedBox.shrink())),
  );

  /// Secure storage answers on the real event loop, so a poll's await chain
  /// only advances outside the fake clock.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await pumpFrames(tester, 3);
  }

  setUp(() async {
    storage.clear();
    writes.clear();
    requests.clear();
    mockStorage();
    SharedPreferences.setMockInitialValues({});
    // load() memoises, so this also stops the widget's own load from clearing
    // the value set below.
    await radarAutoRefresh.load();
    radarAutoRefresh.value = true;
  });

  tearDown(() {
    radarAutoRefresh.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('flipping the switch notifies whatever is already listening', () async {
    final before = radarConnectionEpoch.value;
    await const RadarCredentialStore().setPolling(true);
    expect(radarConnectionEpoch.value, before + 1);
    expect(await const RadarCredentialStore().pollingEnabled(), isTrue);

    await const RadarCredentialStore().setPolling(false);
    expect(await const RadarCredentialStore().pollingEnabled(), isFalse);
  });

  testWidgets('an inbox the user never enabled makes no request', (tester) async {
    storage[radarConnectionKey] = credentials();
    await tester.pumpWidget(host(server()));
    await settle(tester);
    // Two timer ticks later, still nothing: the switch is the gate.
    await tester.pump(const Duration(minutes: 5));
    await settle(tester);

    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an enabled inbox reads after the saved cursor and advances it', (tester) async {
    storage[radarConnectionKey] = credentials();
    storage[radarPollingKey] = 'true';
    storage[cursorKey] = '7';

    await tester.pumpWidget(host(server()));
    await settle(tester);

    expect(requests, hasLength(1));
    expect(requests.single.path, '/events');
    expect(requests.single.queryParameters['after'], '7');
    expect(writes[cursorKey], '4');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the next tick continues from the cursor the last poll saved', (tester) async {
    storage[radarConnectionKey] = credentials();
    storage[radarPollingKey] = 'true';

    await tester.pumpWidget(host(server()));
    await settle(tester);
    await tester.pump(const Duration(minutes: 2));
    await settle(tester);

    expect(requests, hasLength(2));
    expect(requests.first.queryParameters['after'], '0');
    // The cursor kept in memory after the previous poll, not the durable value
    // read again from secure storage.
    expect(requests.last.queryParameters['after'], '4');
  });

  testWidgets('turning the switch on reaches a host that is already running', (tester) async {
    storage[radarConnectionKey] = credentials();
    await tester.pumpWidget(host(server()));
    await settle(tester);
    expect(requests, isEmpty);

    // Exactly what the events page switch does.
    await const RadarCredentialStore().setPolling(true);
    await settle(tester);

    expect(requests, hasLength(1));
  });

  testWidgets('the events page carries the switch', (tester) async {
    usePhoneView(tester);
    storage[radarConnectionKey] = credentials();
    storage[radarPollingKey] = 'true';

    await tester.pumpWidget(testApp(const RadarManagementPage(section: RadarSection.events)));
    await settle(tester);

    final toggle = find.byKey(const ValueKey('radar-polling'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await settle(tester);

    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(writes[radarPollingKey], 'false');
  });
}
