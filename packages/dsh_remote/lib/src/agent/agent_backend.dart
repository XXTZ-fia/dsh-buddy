// Which software on a remote computer the App drives.
//
// One computer can expose several of them at once (DSH, Codex, Claude Code,
// OpenCode, and the CLIs each of those ships). The App keeps exactly one
// active per computer, because every backend owns the whole `DshClient`
// surface under it (session list, transcript, approvals) and two active
// carriers would fight over the same sessions.
//
// Visibility is derived from the Host's `harness.transport.describe`
// capabilities, never from a hard-coded list: a Host only advertises a
// backend once that backend is enabled and its executable exists.
library;

/// The software behind one connection.
enum AgentKind {
  /// The Host's own DeepSeek Harness (`harness.remote.v3`).
  dsh,

  /// Codex through its app-server (`codex.appserver.v1`).
  codex,

  /// Claude Code through the Host ACP gateway (`agent.acp.claude.v1`).
  claude,

  /// OpenCode through the Host ACP gateway (`agent.acp.opencode.v1`).
  opencode,

  /// Cursor through the Host ACP gateway (`agent.acp.cursor.v1`).
  cursor,

  /// A terminal running one tool's own CLI (`harness.terminal.v1`).
  ///
  /// Not a chat backend: [AgentBackend.tool] names the command to launch in
  /// the Host PTY (`dsh`, `codex`, `claude`, `opencode`).
  cli,
}

/// One selectable backend of one Host.
class AgentBackend {
  const AgentBackend(this.kind, {this.tool});

  const AgentBackend.dsh() : this(AgentKind.dsh);

  /// A chat backend (`codex`, `claude`, `opencode`, `cursor`).
  const AgentBackend.chat(AgentKind kind) : this(kind);

  /// A terminal backend for [tool]'s own CLI.
  const AgentBackend.terminal(String tool) : this(AgentKind.cli, tool: tool);

  final AgentKind kind;

  /// CLI command for [AgentKind.cli]; null otherwise.
  final String? tool;

  /// Stable id used in preferences and logs (`codex`, `cli:claude`).
  String get id => tool == null ? kind.name : '${kind.name}:$tool';

  /// Capability the Host must announce before this backend is selectable.
  String get capability => switch (kind) {
    AgentKind.dsh => 'harness.remote.v3',
    AgentKind.codex => 'codex.appserver.v1',
    AgentKind.claude => 'agent.acp.claude.v1',
    AgentKind.opencode => 'agent.acp.opencode.v1',
    AgentKind.cursor => 'agent.acp.cursor.v1',
    AgentKind.cli => 'harness.terminal.v1',
  };

  /// Whether sessions of this backend speak the ACP domain.
  bool get isAcp => kind == AgentKind.claude || kind == AgentKind.opencode || kind == AgentKind.cursor;

  /// Backend id on the Host's ACP gateway (`claude`, `opencode`, `cursor`).
  String? get acpBackend => isAcp ? kind.name : null;

  /// Session-id prefix that marks a session of this backend.
  String? get sessionPrefix => isAcp ? '${kind.name}:' : null;

  /// English label; the App maps [id] to localized text.
  String get label => switch (kind) {
    AgentKind.dsh => 'DSH',
    AgentKind.codex => 'Codex',
    AgentKind.claude => 'Claude Code',
    AgentKind.opencode => 'OpenCode',
    AgentKind.cursor => 'Cursor',
    AgentKind.cli => tool == null ? 'Terminal' : 'Terminal · $tool',
  };

  /// Whether a Host announcing [capabilities] offers this backend.
  bool isAvailableIn(Set<String> capabilities) => capabilities.contains(capability);

  static AgentBackend? tryParse(String? id) {
    if (id == null || id.isEmpty) return null;
    final separator = id.indexOf(':');
    if (separator < 0) {
      // A bare `cli` carries no tool: it can never launch a terminal, so it
      // must not be accepted from preferences.
      if (id == AgentKind.cli.name) return null;
      for (final kind in AgentKind.values) {
        if (kind.name == id) return AgentBackend(kind);
      }
      return null;
    }
    final kind = id.substring(0, separator);
    final tool = id.substring(separator + 1);
    if (kind != AgentKind.cli.name || tool.isEmpty) return null;
    return AgentBackend.terminal(tool);
  }

  @override
  bool operator ==(Object other) => other is AgentBackend && other.kind == kind && other.tool == tool;

  @override
  int get hashCode => Object.hash(kind, tool);

  @override
  String toString() => id;
}

/// CLI tools offered as terminal backends, in display order.
const List<String> terminalTools = ['dsh', 'codex', 'claude', 'opencode'];

/// Every backend this Host offers, in display order (DSH first, terminals last).
///
/// Reads only announced capabilities: a Host without `agent.acp.v1` yields no
/// ACP rows, and a Host with the terminal turned off yields no CLI rows.
List<AgentBackend> agentBackendsFromCapabilities(Iterable<String> capabilities) {
  final caps = capabilities.toSet();
  return [
    const AgentBackend.dsh(),
    if (caps.contains('codex.appserver.v1')) const AgentBackend.chat(AgentKind.codex),
    if (caps.contains('agent.acp.claude.v1')) const AgentBackend.chat(AgentKind.claude),
    if (caps.contains('agent.acp.opencode.v1')) const AgentBackend.chat(AgentKind.opencode),
    if (caps.contains('agent.acp.cursor.v1')) const AgentBackend.chat(AgentKind.cursor),
    if (caps.contains('harness.terminal.v1'))
      for (final tool in terminalTools) AgentBackend.terminal(tool),
  ];
}
