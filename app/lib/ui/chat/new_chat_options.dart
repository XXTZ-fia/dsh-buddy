// The new conversation's run settings (now opened from the empty state's
// "运行设置" sheet, run_settings_sheet.dart): the agent preset it starts with,
// its permissions and the drawer folder it is filed in. Picks are held in
// pendingNewChatModesProvider and applied when the first message creates the
// session (chat_screen.dart `_ensureSession`), before the prompt.
//
// This file keeps the small pure helpers the rest of the app shares
// (composer_agent_chip.dart, chat_screen.dart) and the permission picker used
// by the run-settings sheet.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/new_chat_modes.dart';
import '../../state/features_state.dart' show PermissionState, permissionStateProvider;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../../state/settings_state.dart';
import '../common/app_sheet.dart' show SheetGroup, showAppSheet;
import '../common/list_page_row.dart' show ListPageRow;
import '../common/sheet_title_bar.dart' show SheetTitleBar;
import '../features/feature_format.dart';
import '../features/permission_page.dart' show confirmPermission;
import '../theme/app_icons.dart';

/// Presets a new chat can start with, in the Host's order.
List<AgentPresetInfo> newChatPresets(List<AgentPresetInfo>? all) => [
  for (final preset in all ?? const <AgentPresetInfo>[])
    if (!hiddenNewChatPresets.contains(preset.id)) preset,
];

/// The Host's default preset among [presets] (the first when none is marked,
/// or when the marked one is hidden from new chats).
AgentPresetInfo? defaultPreset(List<AgentPresetInfo> presets) {
  for (final preset in presets) {
    if (preset.isDefault) return preset;
  }
  return presets.isEmpty ? null : presets.first;
}

/// The preset to apply to a new session for [picked] (null: the offered
/// default), given the Host's whole list [all]. A pick the Host no longer
/// offers falls back to the default, as its chip already shows. When the
/// Host's own default is a hidden preset, the offered default is applied
/// explicitly: the session would otherwise start in the hidden one. Null
/// keeps the Host default.
String? newChatPresetToApply(List<AgentPresetInfo>? all, String? picked) {
  if (all == null) return picked;
  final presets = newChatPresets(all);
  if (picked != null && presets.any((p) => p.id == picked && p.broken == null)) return picked;
  final hiddenDefault = all.any((p) => p.isDefault && hiddenNewChatPresets.contains(p.id));
  final fallback = defaultPreset(presets);
  return hiddenDefault && fallback != null && fallback.broken == null ? fallback.id : null;
}

/// The permission to apply to a new session for [picked]: null (keep the
/// effective default) when nothing is picked or the Host no longer offers it.
String? newChatPermissionToApply(PermissionState? state, String? picked) {
  if (picked == null || state == null) return picked;
  return state.options.any((o) => o.value == picked) ? picked : null;
}

IconData presetIcon(String id) => switch (id) {
  'standard' => AppIcons.presetStandard,
  'ptc' => AppIcons.presetPtc,
  'minimal' => AppIcons.presetMinimal,
  'cordis' => AppIcons.presetCordis,
  _ => AppIcons.configure,
};

/// The permission a new session gets without a pick: on this device with
/// 自动批准命令 on (and outside safe mode) session creation switches to full
/// access (sessions_state.dart `createForConnection`); elsewhere the Host's
/// default for new sessions.
String effectiveNewChatPermission(
  PermissionState state, {
  required bool local,
  required bool autoApprove,
  required bool safeMode,
}) => local && autoApprove && !safeMode ? 'danger-full-access' : state.hostDefault;

/// [effectiveNewChatPermission] for this screen, read once (callbacks).
String _readEffectivePermission(WidgetRef ref, PermissionState state) => effectiveNewChatPermission(
  state,
  local: ref.read(activeConnectionProvider).value?.isLocal ?? false,
  autoApprove: ref.read(settingsProvider).autoApproveCommands,
  safeMode: ref.read(localRuntimeProvider).status.inSafeMode,
);

/// Picks the permission mode a new conversation opens with. Mirrors the
/// permission picker the run-settings sheet opens for its "权限模式" row: a
/// short list, a check on the current one, and the usual full-access / auto
/// confirmations. The choice lands in [pendingNewChatModesProvider] unless a
/// session has since opened (the pick would no longer belong to a new chat).
Future<void> showNewChatPermissionSheet(BuildContext context, WidgetRef ref) async {
  final state = ref.read(permissionStateProvider(null)).value;
  if (state == null || state.options.isEmpty) return;
  final fallback = _readEffectivePermission(ref, state);
  final selected = ref.read(pendingNewChatModesProvider).permission ?? fallback;
  final l10n = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  final pick = await showAppSheet<String>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.viewNewChatPermissionTitle),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  for (final option in state.options)
                    ListPageRow(
                      icon: option.value == 'danger-full-access' || option.value == 'auto'
                          ? AppIcons.securityWarning
                          : AppIcons.permissions,
                      title: permissionName(option.value, option.name),
                      subtitle: permissionHint(option.value, option.description),
                      subtitleMaxLines: 2,
                      meta: option.value == fallback ? l10n.viewNewChatDefault : null,
                      trailing: option.value == selected
                          ? Icon(AppIcons.selected, size: 20, color: scheme.primary)
                          : const SizedBox(width: 20),
                      onTap: () => Navigator.of(sheet).pop(option.value),
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
  if (pick == null || pick == selected || !context.mounted) return;
  if (pick != fallback && !await confirmPermission(context, pick)) return;
  if (!context.mounted || ref.read(currentSessionProvider) != null) return;
  ref.read(pendingNewChatModesProvider.notifier).selectPermission(pick == fallback ? null : pick);
}
