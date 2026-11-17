// Commands the "Terminal · <tool>" rows type into a Host PTY.
//
// These are the tools' own CLIs, not the ACP/Codex structured domains: the
// phone shows the real terminal, which is the only interface every one of them
// is guaranteed to expose.
library;

/// One CLI a Host can run in a terminal.
class CliPreset {
  const CliPreset({required this.tool, required this.command, required this.note});

  final String tool;

  /// Typed into the shell without a trailing newline.
  final String command;

  /// What the person should expect, shown in the computer sheet.
  final String note;
}

/// Presets by tool name (`dsh`, `codex`, `claude`, `opencode`).
const Map<String, CliPreset> cliPresets = {
  'dsh': CliPreset(
    tool: 'dsh',
    command: 'dsh --help',
    // `dsh tui` only works once that profile exists; a fresh machine has no
    // `tui` profile, so typing it would only print "profile not found". The
    // help output names the next step and lists the installed profiles.
    note: 'Lists the dsh profiles installed here; the TUI needs `dsh tui` once that profile exists',
  ),
  'codex': CliPreset(
    tool: 'codex',
    command: 'codex',
    note: 'Codex CLI. If it reports command not found, add Codex to PATH on the computer',
  ),
  'claude': CliPreset(
    tool: 'claude',
    command: 'claude',
    note: 'Claude Code CLI; sign in on the computer first',
  ),
  'opencode': CliPreset(
    tool: 'opencode',
    command: 'opencode',
    note: 'OpenCode TUI',
  ),
};

/// The command for [tool], or the tool name itself when unknown.
String cliCommandFor(String tool) => cliPresets[tool]?.command ?? tool;
