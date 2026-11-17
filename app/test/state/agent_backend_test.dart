// The per-computer agent choice: persistence and the Codex-flag migration.
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const host = HostRef.relay('h1', name: '电脑');

  test('a stored explicit choice wins over the legacy codex flag', () async {
    SharedPreferences.setMockInitialValues({
      'agent_backend_relay_h1': 'opencode',
      'codex_dialect_relay_h1': true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(agentBackendProvider(host).notifier).ready();
    expect(container.read(agentBackendProvider(host)), const AgentBackend.chat(AgentKind.opencode));
  });

  test('the old codex flag migrates to the Codex backend', () async {
    SharedPreferences.setMockInitialValues({'codex_dialect_relay_h1': true});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(agentBackendProvider(host).notifier).ready();
    expect(container.read(agentBackendProvider(host)), const AgentBackend.chat(AgentKind.codex));
  });

  test('an old false flag means DSH', () async {
    SharedPreferences.setMockInitialValues({'codex_dialect_relay_h1': false});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(agentBackendProvider(host).notifier).ready();
    expect(container.read(agentBackendProvider(host)), const AgentBackend.dsh());
  });

  test('choosing a backend persists its stable id', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(agentBackendProvider(host).notifier);
    await notifier.ready();
    await notifier.set(const AgentBackend.chat(AgentKind.claude));
    expect(container.read(agentBackendProvider(host)), const AgentBackend.chat(AgentKind.claude));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('agent_backend_relay_h1'), 'claude');
  });

  test('a CLI backend round-trips through preferences', () async {
    SharedPreferences.setMockInitialValues({'agent_backend_relay_h1': 'cli:opencode'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(agentBackendProvider(host).notifier).ready();
    final backend = container.read(agentBackendProvider(host));
    expect(backend.kind, AgentKind.cli);
    expect(backend.tool, 'opencode');
  });

  test('every HostRef kind gets its own key', () {
    expect(
      AgentBackendController.prefsKeyFor(const HostRef.relay('h1')),
      isNot(AgentBackendController.prefsKeyFor(const HostRef.ssh('h1'))),
    );
  });
}
