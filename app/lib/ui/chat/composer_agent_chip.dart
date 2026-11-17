// 输入卡顶部那枚身份胶囊：显示「谁在回答」，点开是专家选择器。
//
// 参考图里它是输入框最上面一行，头像是圆的，底是比卡片略亮一点点的淡色，没有描边。
// 名字取自当前对话实际用的专家：空对话取 pendingNewChatModes，已打开的会话取
// sessionAgentPresetProvider（会话列表不带 agentPreset 字段，没有现成回显来源）。
// 点胶囊弹出 _ChoiceSheet 风格的底部浮层，选中即切换：
//   · 空对话 → 写 pendingNewChatModesProvider（首条消息建会话时应用）
//   · 已打开会话 → client.selectAgentPreset(sessionId, id) 即时切换

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/chat_agent_preset_state.dart' show applyAgentPreset, sessionAgentPresetProvider;
import '../../state/features_state.dart' show agentPresetsProvider;
import '../../state/new_chat_modes.dart' show pendingNewChatModesProvider;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../chat/new_chat_options.dart' show defaultPreset, newChatPresets, presetIcon;
import '../common/app_sheet.dart' show SheetGroup, showAppSheet;
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart' show SheetTitleBar;
import '../features/feature_format.dart' show agentPresetDescription, agentPresetName;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class ComposerAgentChip extends ConsumerWidget {
  const ComposerAgentChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessionId = ref.watch(currentSessionProvider);
    final presets = ref.watch(agentPresetsProvider).value;
    final all = newChatPresets(presets);
    final fallback = defaultPreset(all);

    // 还在连（拿不到预设列表）:显示中性胶囊,不弹选择器。
    if (all.isEmpty || fallback == null) {
      return _Chip(label: l10n.chatAgentFallback, icon: AppIcons.bot, onTap: null);
    }

    // 当前选中的专家 id:空对话看 pending,已打开会话看本次挑的。
    final pendingPreset = ref.watch(pendingNewChatModesProvider).preset;
    final currentId = sessionId == null
        ? (pendingPreset != null && all.any((e) => e.id == pendingPreset) ? pendingPreset : fallback.id)
        : ref.watch(sessionAgentPresetProvider(sessionId)) ?? fallback.id;
    final chosen = all.firstWhere((e) => e.id == currentId, orElse: () => fallback);

    return _Chip(
      label: agentPresetName(chosen),
      icon: presetIcon(chosen.id),
      onTap: () => _pick(context, ref, sessionId, all, fallback, currentId),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    String? sessionId,
    List<AgentPresetInfo> all,
    AgentPresetInfo fallback,
    String currentId,
  ) async {
    final l10n = context.l10n;
    final pick = await showAppSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(l10n.chatPickExpert),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    for (final preset in all)
                      ListPageRow(
                        icon: presetIcon(preset.id),
                        title: agentPresetName(preset),
                        subtitle: preset.broken != null ? l10n.viewNewChatUnavailable : agentPresetDescription(preset),
                        subtitleMaxLines: 2,
                        meta: preset.id == fallback.id ? l10n.viewNewChatDefault : null,
                        trailing: preset.id == currentId
                            ? Icon(AppIcons.selected, size: 20, color: Theme.of(context).colorScheme.primary)
                            : const SizedBox(width: 20),
                        onTap: preset.broken == null ? () => Navigator.of(context).pop(preset.id) : null,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
    if (pick == null || pick == currentId || !context.mounted) return;
    final ok = await applyAgentPreset(ref, sessionId: sessionId, pick: pick, defaultId: fallback.id);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.chatAgentSwitchFailed)));
    }
  }
}

/// The chip itself: a soft, borderless pill, a round avatar + the expert name.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final surfaces = DshSurfaces.of(context);
    final enabled = onTap != null;
    return Semantics(
      button: enabled,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        key: const ValueKey('composer-agent'),
        onTap: onTap,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          height: 30,
          padding: const EdgeInsets.fromLTRB(3, 0, 12, 0),
          decoration: BoxDecoration(
            color: colors.onSurface.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: surfaces.glowPrimary.withValues(alpha: 0.55), shape: BoxShape.circle),
                child: Icon(icon, size: 14, color: colors.onSurface.withValues(alpha: 0.86)),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: colors.onSurface.withValues(alpha: 0.86),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
