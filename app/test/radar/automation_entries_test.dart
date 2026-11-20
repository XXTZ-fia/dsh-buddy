// The Automation tab's six entries: each one opens its own page, and each
// page survives being opened with nothing configured — the radar pages say
// what to connect and offer a retry, the host pages say they need a host.
// Nothing is disabled or silently dead.

import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/agents/team_page.dart';
import 'package:dsh_app/ui/features/agent_presets_page.dart';
import 'package:dsh_app/ui/features/schedules_page.dart';
import 'package:dsh_app/ui/radar/radar_management.dart';
import 'package:dsh_app/ui/shell/personal_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts, pumpFrames, testApp;

const _storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

class _NoSession extends CurrentSessionController {
  @override
  String? build() => null;
}

Future<void> _openAutomation(WidgetTester tester) async {
  await tester.pumpWidget(
    testApp(
      const PersonalHome(work: Scaffold(body: SizedBox.shrink())),
      overrides: [currentSessionProvider.overrideWith(_NoSession.new)],
    ),
  );
  await pumpFrames(tester, 6);
  await tester.tap(find.text('自动化'));
  await pumpFrames(tester, 6);
}

/// Pops whatever the entry pushed, whatever shape its back key is.
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await pumpFrames(tester, 6);
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    // No saved radar credential: the pages must say so rather than hang.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _storage,
      (call) async => null,
    );
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _storage,
      null,
    ),
  );

  testWidgets('the six entries each open their page', (tester) async {
    await _openAutomation(tester);
    expect(tester.takeException(), isNull);

    // The radar server's own records: three sections of one page.
    for (final (label, section) in [
      ('服务器雷达调度', RadarSection.schedules),
      ('采集运行记录', RadarSection.runs),
      ('事件收件箱', RadarSection.events),
    ]) {
      await tester.ensureVisible(find.text(label));
      await pumpFrames(tester, 2);
      await tester.tap(find.text(label));
      await pumpFrames(tester, 8);
      final page = tester.widget<RadarManagementPage>(find.byType(RadarManagementPage));
      expect(page.section, section, reason: label);
      expect(tester.takeException(), isNull, reason: label);
      // Nothing configured: it says so and offers a retry instead of a blank list.
      expect(find.text('重试'), findsOneWidget, reason: label);
      await _back(tester);
    }

    // The host's own task list, agent team and experts.
    for (final (label, type) in [
      ('当前岸宝主机任务', SchedulesPage),
      ('智能体团队', TeamPage),
      ('专家与角色配置', AgentPresetsPage),
    ]) {
      await tester.ensureVisible(find.text(label));
      await pumpFrames(tester, 2);
      await tester.tap(find.text(label));
      await pumpFrames(tester, 8);
      expect(find.byType(type), findsOneWidget, reason: label);
      expect(tester.takeException(), isNull, reason: label);
      await _back(tester);
    }

    expect(find.text('服务器雷达调度'), findsOneWidget, reason: 'back on the tab');
  });
}
