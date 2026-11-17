// 自建服务器登录弹层：点输入框应当拿到焦点（弹出键盘的前提）。
//
// 真机上曾出现「点邮箱/密码框没有任何反应、输入法不弹」，先在 widget 层
// 判定这是布局/焦点问题还是平台侧问题。

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping the email field inside the self-hosted sheet focuses it', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          relayBackendProvider.overrideWithValue(FakeRelayBackend(user: null)),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
        ],
      ),
    );
    await _frames(tester);
    await tester.tap(find.text('自建服务器 · 邮箱登录'));
    await _frames(tester);

    expect(find.byType(TextField), findsNWidgets(3));
    final email = find.byType(TextField).at(1);
    await tester.tap(email);
    await tester.pump();

    final editable = tester.widget<EditableText>(
      find.descendant(of: email, matching: find.byType(EditableText)),
    );
    expect(
      editable.focusNode.hasFocus,
      isTrue,
      reason: '点击邮箱框后焦点应当在输入框里，否则真机上输入法不会弹出',
    );
    expect(tester.testTextInput.isVisible, isTrue, reason: '聚焦后应当向平台请求显示输入法');
  });
}
