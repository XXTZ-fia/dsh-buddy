// 用户在对话框「助手」胶囊里为某个会话挑好的专家。
//
// 空对话（还没建会话）走 pendingNewChatModesProvider；已打开的会话用这里，
// 因为会话列表（SessionSummary）不带 agentPreset 字段、没有现成的回显来源。
// 选了之后由 client.selectAgentPreset 即时切换；这里只是让胶囊立刻显示新名字。

import 'package:dsh_client/dsh_client.dart' show EditorsApi;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart' show activeConnectionProvider;
import 'new_chat_modes.dart' show pendingNewChatModesProvider;

class SessionAgentPresetNotifier extends Notifier<String?> {
  SessionAgentPresetNotifier(this.id);

  final String id;

  @override
  String? build() => null;

  void select(String? preset) => state = preset;
}

/// Keyed by session id. Null = 用 Host 默认预设（胶囊的初始显示）。
final sessionAgentPresetProvider =
    NotifierProvider.autoDispose.family<SessionAgentPresetNotifier, String?, String>(SessionAgentPresetNotifier.new);

/// 把 [sessionId]（null = 还没建会话）的专家切到 [pick]。
///
/// 空对话记进 pending，首条消息建会话时应用；已打开的会话走
/// `agentPresets/select` 即时切换。返回是否已经切过去（没连上或切换失败为
/// false，由调用方决定怎么提示）。胶囊和 `@` 面板共用这一处。
Future<bool> applyAgentPreset(
  WidgetRef ref, {
  required String? sessionId,
  required String pick,
  String? defaultId,
}) async {
  // 选回默认预设时把覆盖清掉，让 Host 的默认继续生效（包括它以后变了）。
  final value = pick == defaultId ? null : pick;
  if (sessionId == null) {
    ref.read(pendingNewChatModesProvider.notifier).selectPreset(value);
    return true;
  }
  final client = ref.read(activeConnectionProvider).value?.client;
  if (client == null) return false;
  try {
    await client.selectAgentPreset(sessionId, pick);
    ref.read(sessionAgentPresetProvider(sessionId).notifier).select(value);
    return true;
  } on Object {
    return false;
  }
}
