// The unified "run settings" of a new conversation: the device it runs on,
// the workspace it starts in, the permission mode it opens with, and (when
// there are folders) the drawer folder it is filed under. One sheet with one
// value row per setting; tapping a row opens that setting's own picker (the
// host sheet, the workspace sheet, the permission picker, the folder picker),
// whose choice reflects back here live.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/new_chat_modes.dart';
import '../../state/features_state.dart' show permissionStateProvider;
import '../../state/hosts_state.dart' show activeHostProvider;
import '../../state/settings_state.dart';
import '../../state/sessions_state.dart' show newChatInHostDefaultProvider, recentWorkspaceForNewChatProvider;
import '../../state/workspaces_state.dart' show selectedWorkspaceProvider, workspaceTitle;
import '../common/app_sheet.dart' show SheetGroup, showAppSheet;
import '../common/list_page_row.dart' show ListPageRow;
import '../common/sheet_title_bar.dart' show SheetTitleBar;
import '../features/feature_format.dart' show permissionName;
import '../remote/host_status.dart' show hostKindIcon, watchHostStatus;
import '../remote/host_switcher.dart' show showHostSheet;
import '../theme/app_icons.dart' show AppIcons;
import '../workspace/workspace_switcher.dart' show showWorkspaceSheet;
import 'new_chat_options.dart' show effectiveNewChatPermission, showNewChatPermissionSheet;

/// Opens the new-chat run-settings sheet. [onManageHost] / [onManageWorkspace]
/// push the host / workspace management pages from the respective sub-sheets;
/// [folderLabel] / [onFolder] are the drawer folder the new chat is filed in
/// (omitted when there are no folders).
Future<void> showRunSettingsSheet(
  BuildContext context, {
  required VoidCallback onManageHost,
  required VoidCallback onManageWorkspace,
  String? folderLabel,
  VoidCallback? onFolder,
}) => showAppSheet<void>(
  context,
  isScrollControlled: true,
  builder: (sheet) => RunSettingsSheet(
    onManageHost: onManageHost,
    onManageWorkspace: onManageWorkspace,
    folderLabel: folderLabel,
    onFolder: onFolder,
  ),
);

class RunSettingsSheet extends ConsumerWidget {
  const RunSettingsSheet({
    super.key,
    required this.onManageHost,
    required this.onManageWorkspace,
    this.folderLabel,
    this.onFolder,
  });

  final VoidCallback onManageHost;
  final VoidCallback onManageWorkspace;
  final String? folderLabel;
  final VoidCallback? onFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    // Device: the active host and how it is doing right now.
    final host = ref.watch(activeHostProvider);
    final hostName =
        ref.watch(hostNameProvider(host)) ?? (host.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);
    final hostView = watchHostStatus(ref, host);

    // Workspace: the new chat's starting workspace (the global selection, or
    // the remembered one for new chats), or the host default folder.
    final workspace =
        ref.watch(selectedWorkspaceProvider) ?? ref.watch(recentWorkspaceForNewChatProvider);
    final inHostDefault = workspace == null && ref.watch(newChatInHostDefaultProvider);
    final workspaceValue = workspace != null
        ? workspaceTitle(workspace)
        : inHostDefault
        ? l10n.viewEmptyHostDefaultDirectory
        : l10n.remoteWorkspaceAllChats;

    // Permission mode: the pending pick, else what a new chat opens with.
    final permissions = ref.watch(permissionStateProvider(null)).value;
    final hasPermissions = permissions != null && permissions.options.isNotEmpty;
    final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? false));
    final autoApprove = ref.watch(settingsProvider.select((s) => s.autoApproveCommands));
    final safeMode = ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode));
    final pending = ref.watch(pendingNewChatModesProvider);
    String? permissionValue;
    if (permissions != null) {
      final permission = pending.permission ??
          effectiveNewChatPermission(permissions, local: local, autoApprove: autoApprove, safeMode: safeMode);
      for (final option in permissions.options) {
        if (option.value == permission) permissionValue = permissionName(permission, option.name);
      }
    }

    const margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.viewRunSettings),
              SheetGroup(
                margin: margin,
                children: [
                  ListPageRow(
                    icon: hostKindIcon(host.kind),
                    title: l10n.viewRunSettingsDevice,
                    subtitle: hostView.label,
                    value: hostName,
                    onTap: () => showHostSheet(context, onManage: onManageHost),
                  ),
                  ListPageRow(
                    icon: AppIcons.workspace,
                    title: l10n.remoteWorkspace,
                    value: workspaceValue,
                    onTap: () => showWorkspaceSheet(context, onManage: onManageWorkspace),
                  ),
                  if (hasPermissions)
                    ListPageRow(
                      icon: AppIcons.permissions,
                      title: l10n.viewRunSettingsPermission,
                      value: permissionValue,
                      onTap: () => showNewChatPermissionSheet(context, ref),
                    ),
                  if (folderLabel != null && onFolder != null)
                    ListPageRow(
                      icon: AppIcons.folder,
                      title: l10n.shellFolders,
                      value: folderLabel,
                      onTap: onFolder,
                    ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
