// Agent backends: capability-driven visibility and stable ids.
import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

void main() {
  test('a Host without agent capabilities offers only DSH and terminals', () {
    final backends = agentBackendsFromCapabilities(const ['harness.remote.v3']);
    expect(backends.map((b) => b.id), ['dsh']);
  });

  test('capabilities add chat backends and CLI rows in display order', () {
    final backends = agentBackendsFromCapabilities(const [
      'harness.remote.v3',
      'harness.terminal.v1',
      'codex.appserver.v1',
      'agent.acp.opencode.v1',
      'agent.acp.claude.v1',
    ]);
    expect(backends.map((b) => b.id), [
      'dsh',
      'codex',
      'claude',
      'opencode',
      'cli:dsh',
      'cli:codex',
      'cli:claude',
      'cli:opencode',
    ]);
  });

  test('a Host that only speaks harness.remote.v1 still offers DSH', () {
    final backends = agentBackendsFromCapabilities(const ['harness.remote.v1']);
    expect(backends.map((b) => b.id), ['dsh']);
  });

  test('terminal rows disappear when the Host turned the terminal off', () {
    final backends = agentBackendsFromCapabilities(const ['harness.remote.v3', 'agent.acp.claude.v1']);
    expect(backends.map((b) => b.id), ['dsh', 'claude']);
  });

  test('ids round-trip through tryParse', () {
    for (final backend in const [
      AgentBackend.dsh(),
      AgentBackend.chat(AgentKind.codex),
      AgentBackend.chat(AgentKind.claude),
      AgentBackend.chat(AgentKind.opencode),
      AgentBackend.terminal('opencode'),
    ]) {
      expect(AgentBackend.tryParse(backend.id), backend);
    }
    expect(AgentBackend.tryParse('nope'), isNull);
    expect(AgentBackend.tryParse('cli:'), isNull);
    expect(AgentBackend.tryParse('cli'), isNull, reason: 'a CLI backend without a tool cannot launch anything');
    expect(AgentBackend.tryParse(null), isNull);
  });

  test('ACP backends expose a host backend id and session prefix', () {
    const claude = AgentBackend.chat(AgentKind.claude);
    expect(claude.isAcp, isTrue);
    expect(claude.acpBackend, 'claude');
    expect(claude.sessionPrefix, 'claude:');
    expect(const AgentBackend.dsh().isAcp, isFalse);
    expect(AgentBackend.terminal('claude').acpBackend, isNull);
  });

  test('capability per backend matches the Host declarations', () {
    expect(const AgentBackend.dsh().capability, 'harness.remote.v3');
    expect(const AgentBackend.chat(AgentKind.codex).capability, 'codex.appserver.v1');
    expect(const AgentBackend.chat(AgentKind.claude).capability, 'agent.acp.claude.v1');
    expect(const AgentBackend.chat(AgentKind.opencode).capability, 'agent.acp.opencode.v1');
    expect(AgentBackend.terminal('dsh').capability, 'harness.terminal.v1');
  });
}
