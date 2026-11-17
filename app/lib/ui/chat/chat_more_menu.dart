// 顶栏最右边的 ⋯ 菜单:一个浮起来的圆角面,四行「图标 + 文字」,没有分隔线。
//
// 参考的是 WorkBuddy 那个菜单的样子 —— 大圆角、实心面色、行距宽松 ——
// 而不是 Material 默认那种带小箭头、带描边、行高 40 的列表。
//
// 每一项都对应这个 App 里真实存在的能力,不做占位:
//   全部产物  SessionArtifactsPage(这个对话写出来的文件)
//   远程控制  RemoteScreen(连着的电脑 / 服务器)
//   对话详情  SessionDetailPage(上下文、用量、权限)
//   置顶      会话置顶 / 取消置顶(和工作区抽屉里那份是同一个状态)

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// What the ⋯ menu can do.
enum ChatMenuAction { artifacts, remote, details, pin }

/// The menu's width: wide enough for 「全部产物」 plus its icon, narrow enough
/// that it reads as a small sheet, not a page.
const _menuWidth = 216.0;

/// Rows are taller than Material's default 48: the tap target is the whole
/// row, and the air is what makes the menu look calm.
const _rowHeight = 54.0;

/// Opens the menu under [anchor] (the ⋯ key), right edges aligned.
///
/// [pinned] flips the last row to 「取消置顶」; without a conversation
/// ([hasSession] false) the rows that need one are not offered.
Future<ChatMenuAction?> showChatMenu(
  BuildContext context, {
  required bool pinned,
  required bool hasSession,
}) async {
  final anchor = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (anchor == null || overlay == null) return null;
  final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
  final right = (overlay.size.width - origin.dx - anchor.size.width).clamp(0.0, double.infinity);
  // The menu hangs off the key's bottom-right; a narrow phone where that would
  // push it off the left edge just gets it flush with the screen.
  final left = (origin.dx + anchor.size.width - _menuWidth).clamp(8.0, double.infinity);
  final l10n = context.l10n;
  final surfaces = DshSurfaces.of(context);
  final colors = Theme.of(context).colorScheme;
  final icon = colors.onSurface.withValues(alpha: 0.72);
  final text = colors.onSurface;

  return showMenu<ChatMenuAction>(
    context: context,
    // Flush with the right edge, a few dp under the key.
    position: RelativeRect.fromLTRB(left, origin.dy + anchor.size.height + 6, right, 0),
    color: surfaces.sheet.fallbackFill,
    surfaceTintColor: Colors.transparent,
    elevation: 18,
    // No hairline: the panel's own face separates it from the page.
    shape: const RoundedRectangleBorder(borderRadius: AppShape.radiusLg),
    constraints: const BoxConstraints.tightFor(width: _menuWidth),
    clipBehavior: Clip.antiAlias,
    items: [
      if (hasSession) _item(ChatMenuAction.artifacts, AppIcons.artifacts, l10n.chatMenuArtifacts, icon, text),
      _item(ChatMenuAction.remote, AppIcons.remoteHosts, l10n.chatMenuRemote, icon, text),
      if (hasSession) _item(ChatMenuAction.details, AppIcons.info, l10n.chatMenuDetails, icon, text),
      if (hasSession)
        _item(
          ChatMenuAction.pin,
          pinned ? AppIcons.pinActive : AppIcons.pin,
          pinned ? l10n.shellUnpin : l10n.commonPin,
          icon,
          text,
        ),
    ],
  );
}

/// One row: icon, gap, label — nothing else. The icon carries the meaning, so
/// the label stays one weight and one colour.
PopupMenuItem<ChatMenuAction> _item(
  ChatMenuAction action,
  IconData icon,
  String label,
  Color iconColor,
  Color textColor,
) {
  return PopupMenuItem<ChatMenuAction>(
    value: action,
    height: _rowHeight,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 15),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, height: 1.2, fontWeight: FontWeight.w500, color: textColor),
          ),
        ),
      ],
    ),
  );
}
