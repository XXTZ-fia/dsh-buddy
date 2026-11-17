// Goldens (light + dark) of the new-chat run settings: one sheet with a value
// row per setting — device, workspace, permission mode, drawer folder —
// instead of three separate chips on the empty state.
// Regenerate with
// `flutter test --update-goldens test/chat/run_settings_sheet_golden_test.dart`.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart' show FakeRpcCarrier;
import 'support/harness.dart';

const _workspace = Workspace(
  workspaceId: 'w1',
  path: '/root/workspace/dsh-app',
  title: 'dsh-app',
  sessionIds: [],
);

/// A Host that offers three permission modes and one preset.
class _Host {
  late final carrier = FakeRpcCarrier({
    'agentPresets/list': (_) => {
      'presets': [
        {'id': 'standard', 'isDefault': true},
        {'id': 'minimal'},
      ],
    },
    'permissionPresets/catalog': (_) => {
      'options': [
        {'value': 'read-only', 'name': 'Read only'},
        {'value': 'workspace-write', 'name': 'Workspace write'},
        {'value': 'danger-full-access', 'name': 'Full access'},
      ],
      'defaultPreset': 'workspace-write',
    },
    'settings/describe': (_) => {'namespaces': <Object?>[]},
  });

  late final connection = HostConnection(client: DshClient.withCarrier(carrier), isLocal: true);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('run settings ($mode)', (tester) async {
      usePhoneView(tester);
      final host = _Host();
      final harness = ChatHarness(connected: true, newChatCatalogs: true);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          brightness: brightness,
          overrides: [
            activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(host.connection)),
            selectedWorkspaceProvider.overrideWithValue(_workspace),
            ...harness.overrides.skip(1),
          ],
        ),
      );
      await pumpFrames(tester, 8);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('run-settings')));
      await pumpFrames(tester, 8);
      expect(find.text('运行设置'), findsWidgets);

      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run_settings_$mode.png'));
    });
  }
}
