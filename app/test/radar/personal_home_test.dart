import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/personal_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts, pumpFrames, testApp;

class _Session extends CurrentSessionController {
  @override
  String? build() => null;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('five destinations keep the work draft alive across tab changes', (tester) async {
    await tester.pumpWidget(
      testApp(
        const PersonalHome(work: Scaffold(body: TextField())),
        overrides: [currentSessionProvider.overrideWith(_Session.new)],
      ),
    );
    await tester.enterText(find.byType(TextField), 'unfinished research');
    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester, 6);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    await tester.tap(find.text('自动化'));
    await pumpFrames(tester, 6);
    expect(find.text('服务器雷达调度'), findsOneWidget);
    await tester.tap(find.text('工作'));
    await pumpFrames(tester, 6);
    expect(find.text('unfinished research'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
