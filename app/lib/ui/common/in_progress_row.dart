import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 「进行中」一行:六个点转一圈,后面跟一句正在做的事,右边可选一个箭头。
///
/// 为什么不是一行静态文字:启动引擎、连远程主机这类等待通常 0.3–3 秒,静
/// 态文案会让界面看起来卡住了。转动的点本身就在说"在动",字号和位置又和
/// 普通副标题一样,所以连上以后把这一行换成真内容时,版面不跳。
///
/// - [onTap] 给了才画箭头:箭头是"点开看卡在哪一步"的承诺,没东西可看就
///   不该画。
/// - 系统开了「减少动态效果」时不转,只留下那行字。
class InProgressRow extends StatefulWidget {
  const InProgressRow({super.key, required this.label, this.onTap, this.style, this.size = 20, this.compact = false});

  /// What is being waited on (「正在连接引擎…」).
  final String label;

  /// Opens the details behind the wait; null hides the chevron.
  final VoidCallback? onTap;

  /// Label style; defaults to the body style of the surrounding empty state.
  final TextStyle? style;

  /// Diameter of the spinner.
  final double size;

  /// Tighter spacing for cards and list rows.
  final bool compact;

  @override
  State<InProgressRow> createState() => _InProgressRowState();
}

class _InProgressRowState extends State<InProgressRow> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the platform's "remove animations" switch: no endless rotation.
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      if (_spin.isAnimating) _spin.stop();
      _spin.value = 0;
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final labelStyle =
        widget.style ??
        (widget.compact ? theme.textTheme.bodySmall : theme.textTheme.bodyLarge)?.copyWith(color: colors.textTertiary);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _spin,
            builder: (context, child) => CustomPaint(
              painter: _DotsPainter(progress: _spin.value, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        SizedBox(width: widget.compact ? 6 : 8),
        Flexible(child: Text(widget.label, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (widget.onTap != null) ...[
          const SizedBox(width: 2),
          Icon(AppIcons.disclosure, size: widget.compact ? 14 : 16, color: colors.textDisabled),
        ],
      ],
    );
    if (widget.onTap == null) return row;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 4 : 6, vertical: widget.compact ? 2 : 4),
          child: row,
        ),
      ),
    );
  }
}

/// Six dots on a circle, fading in turn: the tail chases itself round.
class _DotsPainter extends CustomPainter {
  const _DotsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  static const _count = 6;

  @override
  void paint(Canvas canvas, Size size) {
    // 点之间要留出空隙,否则六个点会糊成一个花/星形。
    final radius = size.shortestSide * 0.34;
    final dot = size.shortestSide * 0.105;
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < _count; i++) {
      // A dot is brightest just before the head passes it, then fades out.
      final phase = (progress + i / _count) % 1.0;
      final alpha = 0.20 + 0.75 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
      paint.color = color.withValues(alpha: alpha);
      // Start at 12 o'clock and go clockwise.
      final angle = i / _count * 2 * math.pi - math.pi / 2;
      canvas.drawCircle(center + Offset(math.cos(angle) * radius, math.sin(angle) * radius), dot, paint);
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.progress != progress || old.color != color;
}
