import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/usage_state.dart';
import '../theme/theme.dart';
import 'usage_sheet.dart' show formatPercent, formatTokens;

/// 输入框下面的一行小字：这次对话的缓存命中与 token 消耗。
///
/// 总量来自 DSH 的 `tokenUsage` 投影；没有跑过一轮时整行不占位。
class ChatUsageLine extends ConsumerWidget {
  const ChatUsageLine({super.key, required this.sessionId, this.onTap});

  final String sessionId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(sessionUsageProvider(sessionId));
    if (!usage.hasTokens) return const SizedBox.shrink();
    final p = DshColors.of(context);
    final l10n = context.l10n;
    final hit = usage.cacheHitRate;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 2, 24, 6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Text(
          l10n.chatUsageLine(
            hit == null ? '—' : formatPercent(hit),
            formatTokens(usage.input),
            formatTokens(usage.output),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10.5, height: 1.2, color: p.textTertiary),
        ),
      ),
    );
  }
}
