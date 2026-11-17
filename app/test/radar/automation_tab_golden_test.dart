// Goldens (light + dark) of the Automation tab: the app frame's large title,
// one line of context, then two cards of rows — the same anatomy as every
// other list page, so the tab no longer has its own theme.
// Regenerate with
// `flutter test --update-goldens test/radar/automation_tab_golden_test.dart`.

import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/radar/radar_management.dart';
import 'package:dsh_app/ui/shell/personal_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts, pumpFrames, testApp, usePhoneView;

const _storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _runtime = EventChannel('dsh/runtime/events');

class _NoSession extends CurrentSessionController {
  @override
  String? build() => null;
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _storage,
      (call) async => null,
    );
    // The shell subscribes to the engine's event stream; nothing answers it
    // outside the phone app, so answer with an idle stream.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      _runtime,
      MockStreamHandler.inline(onListen: (_, sink) {}, onCancel: (_) {}),
    );
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _storage,
      null,
    ),
  );

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(_runtime, null),
  );

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('automation tab ($mode)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PersonalHome(work: Scaffold(body: SizedBox.shrink())),
          brightness: brightness,
          overrides: [currentSessionProvider.overrideWith(_NoSession.new)],
        ),
      );
      await pumpFrames(tester, 6);
      await tester.tap(find.text('自动化'));
      await pumpFrames(tester, 8);
      expect(tester.takeException(), isNull);

      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/automation_tab_$mode.png'));
    });

    testWidgets('radar section without a server ($mode)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const RadarManagementPage(section: RadarSection.schedules),
          brightness: brightness,
          overrides: [currentSessionProvider.overrideWith(_NoSession.new)],
        ),
      );
      await pumpFrames(tester, 8);
      expect(tester.takeException(), isNull);
      expect(find.text('重试'), findsOneWidget);

      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/radar_section_$mode.png'));
    });
  }
}
