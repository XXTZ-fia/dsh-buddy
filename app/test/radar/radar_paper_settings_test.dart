import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/radar/radar_client.dart';
import 'package:dsh_app/ui/radar/radar_paper_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../chat/support/harness.dart' show testTheme;

/// 页面用了全站主题色（DshColors），所以测试也得把主题带上。
Widget _app(Widget home) => MaterialApp(
  theme: testTheme(Brightness.light),
  locale: const Locale('en'),
  supportedLocales: const [Locale('en')],
  localizationsDelegates: L10n.localizationsDelegates,
  home: home,
);

/// 论文推荐设置：读到现有规则、改完按「整份回传」的方式保存。
void main() {
  testWidgets('loads the saved rules and saves only the paper fields', (tester) async {
    final config = <String, dynamic>{
      'version': 3,
      'interests': ['AI Agent', 'RAG'],
      'platforms': ['douyin'],
      'max_items': 5,
      'summary_model': 'deepseek-chat',
      'paper_sources': ['hf', 'arxiv'],
      'paper_limit': 12,
    };
    Map<String, dynamic>? written;
    final client = RadarClient(
      baseUrl: 'https://example.com',
      token: 'test',
      transport: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode(config), 200, headers: {'content-type': 'application/json'});
        }
        written = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({...written!, 'version': 4}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    await tester.pumpWidget(_app(RadarPaperSettingsPage(client: client)));
    await tester.pumpAndSettle();

    // 现有兴趣词、来源、条数都从服务端带回来。
    expect(find.text('AI Agent'), findsOneWidget);
    expect(find.text('RAG'), findsOneWidget);

    // 关掉 arXiv，改成 20 条，再加一个兴趣词。
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    // 条数与兴趣词输入在下面：先把它们滚进视口再点。
    await tester.ensureVisible(find.text('20'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'embodied AI');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(written, isNotNull);
    expect(written!['paper_sources'], ['hf']);
    expect(written!['paper_limit'], 20);
    expect(written!['interests'], ['AI Agent', 'RAG', 'embodied AI']);
    // 别的设置原样回传，不能被这页顺手改掉。
    expect(written!['platforms'], ['douyin']);
    expect(written!['max_items'], 5);
  });

  testWidgets('the last source cannot be switched off', (tester) async {
    final config = <String, dynamic>{
      'version': 1,
      'interests': <String>[],
      'platforms': ['douyin'],
      'max_items': 5,
      'summary_model': '',
      'paper_sources': ['hf'],
      'paper_limit': 5,
    };
    final client = RadarClient(
      baseUrl: 'https://example.com',
      token: 'test',
      transport: MockClient((request) async => http.Response(
            jsonEncode(config),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );
    addTearDown(client.close);

    await tester.pumpWidget(_app(RadarPaperSettingsPage(client: client)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.first.value, isTrue, reason: 'at least one paper source must stay on');
  });
}
