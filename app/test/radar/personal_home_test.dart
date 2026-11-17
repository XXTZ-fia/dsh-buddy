import 'package:dsh_app/state/radar_feature.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/personal_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show loadTestFonts, pumpFrames, testApp;

class _Session extends CurrentSessionController {
  @override
  String? build() => null;
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    radarFeature.resetForTest();
  });

  testWidgets('radar is off by default: four destinations and no radar entries', (tester) async {
    await tester.pumpWidget(
      testApp(
        const PersonalHome(work: Scaffold(body: TextField())),
        overrides: [currentSessionProvider.overrideWith(_Session.new)],
      ),
    );
    await tester.enterText(find.byType(TextField), 'unfinished research');
    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester, 6);

    // 工作 / 自动化 / 资料 / 我的；没有信息雷达。
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('信息雷达'), findsNothing);

    await tester.tap(find.text('自动化'));
    await pumpFrames(tester, 6);
    // 雷达关闭时，自动化里的服务/运行/收件箱整组不出现。
    expect(find.text('服务器雷达调度'), findsNothing);

    await tester.tap(find.text('工作'));
    await pumpFrames(tester, 6);
    expect(find.text('unfinished research'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('enabling radar adds the tab and the automation entries', (tester) async {
    SharedPreferences.setMockInitialValues({RadarFeatureStore.key: true});
    radarFeature.resetForTest();

    await tester.pumpWidget(
      testApp(
        const PersonalHome(work: Scaffold(body: TextField())),
        overrides: [currentSessionProvider.overrideWith(_Session.new)],
      ),
    );
    await pumpFrames(tester, 6);

    expect(radarFeature.value, isTrue);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('信息雷达'), findsOneWidget);

    await tester.tap(find.text('自动化'));
    await pumpFrames(tester, 6);
    expect(find.text('服务器雷达调度'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
