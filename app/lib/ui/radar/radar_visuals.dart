import 'package:flutter/material.dart';

import '../../state/radar_prefs.dart';
import '../theme/accent.dart';
import '../theme/app_icons.dart';
import '../theme/palette.dart';
import '../theme/semantic_colors.dart';
import '../theme/surfaces.dart';

/// Radar's palette.
///
/// 跟随全局主题:底色取页面渐变、面色取中性色阶、强调色取当前配色 ——
/// 换配色时雷达页跟着变,不会像早先那套独立调色板一样,别处都换了它还
/// 停在近黑 `#0A0B0D`(那是"背景显得纯黑"的来源)。
///
/// The look stays calm: one flat canvas, one accent, one warm colour for
/// heat, and hairline rules at low opacity. Grouping comes from spacing and
/// type weight, not from stacked boxes.
class RadarPalette {
  const RadarPalette({
    required this.canvas,
    required this.card,
    required this.text,
    required this.muted,
    required this.faint,
    required this.border,
    required this.hairline,
    required this.accent,
    required this.hot,
    required this.success,
    required this.warning,
    required this.chip,
  });

  factory RadarPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = theme.extension<DshSurfaces>();
    final colors = theme.extension<DshColors>();
    final dark = scheme.brightness == Brightness.dark;
    final n = NeutralTones.forAccent(surfaces?.accent ?? AppAccent.mist);
    return RadarPalette(
      canvas: surfaces?.backdropTop ?? (dark ? DshPalette.nightTop : DshPalette.mistTop),
      // 卡片面:比页面底亮一档的柔和面(深色约 1.17:1),不描边。
      card: dark ? n.nightLow : n.mistLowest,
      text: dark ? n.paper : n.ink,
      muted: dark ? n.paperMuted : n.inkMuted,
      // 三级:序号、分隔符、禁用字形。仍要能读,所以不用最暗那档。
      faint: dark ? n.outlineDark : n.inkFaint,
      // 输入框这类交互边界要 ≥ 3:1,走 outline 而不是发丝线。
      border: scheme.outline,
      hairline: scheme.outlineVariant,
      accent: scheme.primary,
      // 热度是"很多人在看"。暖橙只在热度数字上出现,不参与分组层级。
      hot: dark ? const Color(0xFFFF7A5C) : const Color(0xFFFF5A3C),
      success: colors?.success ?? (dark ? const Color(0xFF6FBF9B) : const Color(0xFF12A26B)),
      warning: colors?.warning ?? (dark ? const Color(0xFFE0A34C) : const Color(0xFFE08A00)),
      chip: dark ? n.nightContainer : n.mistContainer,
    );
  }

  /// Page background.
  final Color canvas;

  /// Raised fill for the few things that must read as a field or a panel
  /// (text inputs, the connect form). Not used for list rows.
  final Color card;

  /// Primary text.
  final Color text;

  /// Secondary text: metadata, counts, subtitles.
  final Color muted;

  /// Tertiary text: ranks, separators, disabled glyphs.
  final Color faint;

  /// Divider colour, already at hairline opacity.
  final Color border;

  /// Same as [border] but the named intent — a rule that separates runs of
  /// content without enclosing them.
  final Color hairline;

  final Color accent;
  final Color hot;
  final Color success;
  final Color warning;

  /// Legacy chip fill. Kept for callers that still need a faint wash; the
  /// redesigned surfaces prefer [card] or nothing at all.
  final Color chip;
}

/// Page gutter. One value everywhere so every screen shares the same edge.
const radarGutter = 20.0;

/// Corner radius of a grouped surface (a source's board, a form panel).
/// 18 是「看得出圆、又不至于像药丸」的那一档。
const radarCardRadius = 18.0;

/// Vertical rhythm for a run of content: 8-step scale, applied loosely.
const radarGapXs = 4.0;
const radarGapSm = 8.0;
const radarGapMd = 14.0;
const radarGapLg = 22.0;
const radarGapXl = 32.0;

class RadarSourceMeta {
  const RadarSourceMeta(this.name, this.board, this.color, this.icon);

  final String name;
  final String board;
  final Color color;
  final IconData icon;
}

/// Zhihu and X are intentionally gone: see [radarAvailablePlatforms].
const radarPlatformOrder = radarAvailablePlatforms;

const radarSources = <String, RadarSourceMeta>{
  'douyin': RadarSourceMeta('抖音', '热榜', Color(0xFF22242C), Icons.music_note_rounded),
  'bili': RadarSourceMeta('哔哩哔哩', '热榜', Color(0xFFFB7299), Icons.smart_display_rounded),
  'weibo': RadarSourceMeta('微博', '热搜', Color(0xFFE6162D), Icons.whatshot_rounded),
  'xhs': RadarSourceMeta('小红书', '热榜', Color(0xFFFF2442), Icons.menu_book_rounded),
};

RadarSourceMeta sourceMeta(String platform) =>
    radarSources[platform] ?? const RadarSourceMeta('其他', '来源', Color(0xFF6B7280), Icons.public_rounded);

/// Brand colours for the 52 hot-list boards. Keyed by catalogue id; boards of
/// the same site share one colour so the rail reads as a site switcher.
const _hotBrandColors = <String, Color>{
  'zhihu': Color(0xFF0066FF),
  'weibo': Color(0xFFE6162D),
  'douyin': Color(0xFF161823),
  'tieba': Color(0xFF3385FF),
  'toutiao': Color(0xFFF04142),
  'thepaper': Color(0xFFD7152A),
  'bilibili-hot-search': Color(0xFFFB7299),
  'bilibili-hot-video': Color(0xFFFB7299),
  'bilibili-ranking': Color(0xFFFB7299),
  'kuaishou': Color(0xFFFF6A00),
  'baidu': Color(0xFF2932E1),
  'nowcoder': Color(0xFF00B96B),
  'ifeng': Color(0xFFD5292B),
  'chongbuluo-latest': Color(0xFF2F7D5D),
  'chongbuluo-hot': Color(0xFF2F7D5D),
  'douban': Color(0xFF2E963D),
  'tencent-hot': Color(0xFF1E88E5),
  'freebuf': Color(0xFFE4312B),
  'qqvideo-tv-hotsearch': Color(0xFFFF7A00),
  'iqiyi-hot-ranklist': Color(0xFF00BE06),
  'zaobao': Color(0xFFC8102E),
  'sputniknewscn': Color(0xFFE2231A),
  'cankaoxiaoxi': Color(0xFFC8102E),
  'kaopu': Color(0xFF5B6B8C),
  'steam': Color(0xFF1B2838),
  'mktnews-flash': Color(0xFF1F3A93),
  'wallstreetcn-quick': Color(0xFFC0272D),
  'wallstreetcn-news': Color(0xFFC0272D),
  'wallstreetcn-hot': Color(0xFFC0272D),
  'cls-telegraph': Color(0xFFD0342C),
  'cls-depth': Color(0xFFD0342C),
  'cls-hot': Color(0xFFD0342C),
  'xueqiu-hotstock': Color(0xFF0B69C7),
  'gelonghui': Color(0xFFC9302C),
  'fastbull-express': Color(0xFF0D5EF4),
  'fastbull-news': Color(0xFF0D5EF4),
  'jin10': Color(0xFF0B0D17),
  'v2ex-share': Color(0xFF33383D),
  'coolapk': Color(0xFF0C8EE7),
  '36kr-quick': Color(0xFF4285F4),
  '36kr-renqi': Color(0xFF4285F4),
  'aihot': Color(0xFF6C5CE7),
  'ithome': Color(0xFFC8202F),
  'pcbeta-windows11': Color(0xFF0F6CBD),
  'solidot': Color(0xFF4B5563),
  'hackernews': Color(0xFFFF6600),
  'producthunt': Color(0xFFDA552F),
  'github-trending-today': Color(0xFF24292F),
  'sspai': Color(0xFFD71A1C),
  'juejin': Color(0xFF1E80FF),
  'hupu': Color(0xFFD7261E),
  'dongqiudi': Color(0xFF1A1A1A),
};

const _hotFallbackColors = <Color>[
  Color(0xFF4C6FFF),
  Color(0xFF12A26B),
  Color(0xFFE0672B),
  Color(0xFF8E5CF7),
  Color(0xFF2B9EB3),
  Color(0xFFD9548C),
];

/// [dark] 时把几乎全黑的品牌色（抖音、懂球帝、金十）提亮，否则深色卡片上
/// 只剩一个看不见的色块。
Color hotSourceColor(String sourceId, {bool dark = false}) {
  final base =
      _hotBrandColors[sourceId] ??
      _hotFallbackColors[sourceId.codeUnits.fold<int>(0, (sum, unit) => sum + unit) % _hotFallbackColors.length];
  if (!dark || base.computeLuminance() >= 0.10) return base;
  return Color.lerp(base, Colors.white, 0.62)!;
}

bool isDarkPalette(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// 来源图标的两种画法：浅色品牌用淡底彩字，深色品牌用实底色白字，
/// 保证深色主题下每个图标都有足够对比度。
class HotIconStyle {
  const HotIconStyle(this.fill, this.foreground);
  final Color fill;
  final Color foreground;
}

HotIconStyle hotIconStyle(String sourceId, {required bool dark}) {
  final base = hotSourceColor(sourceId, dark: dark);
  final brand = hotSourceColor(sourceId);
  if (brand.computeLuminance() >= 0.25) {
    return HotIconStyle(brand.withValues(alpha: dark ? 0.20 : 0.14), base);
  }
  // 近乎全黑的品牌色在深色卡片上仍然偏暗，抬一档再铺白字。
  final fill = dark && brand.computeLuminance() < 0.06 ? Color.lerp(brand, Colors.white, 0.24)! : brand;
  return HotIconStyle(fill, Colors.white);
}

/// 「知乎」→「知」,「Hacker News」→「H」: a brand-less icon that still reads.
String hotSourceInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final first = trimmed.substring(0, 1);
  return RegExp(r'[a-zA-Z]').hasMatch(first) ? first.toUpperCase() : first;
}

String formatHeat(Object? raw) {
  final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (value == null || value <= 0) return '';
  if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
  return value.toStringAsFixed(0);
}

String formatDelta(Object? raw) {
  final text = '$raw';
  if (text.isEmpty || text == 'null') return '';
  final value = num.tryParse(text);
  if (value == null) return text;
  if (value == 0) return '';
  return '${value > 0 ? '+' : '-'}${formatHeat(value.abs())}';
}

DateTime? parseTime(Object? raw) => DateTime.tryParse('${raw ?? ''}');

/// Compact relative time for a row; card headers use [formatFreshness].
String formatRelative(Object? raw, {DateTime? now}) {
  final time = parseTime(raw)?.toLocal();
  if (time == null) return '';
  final current = now ?? DateTime.now();
  final diff = current.difference(time);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}

String formatFreshness(Object? raw, {DateTime? now}) {
  final label = formatRelative(raw, now: now);
  if (label.isEmpty) return '';
  return label == '刚刚' ? '刚刚更新' : '$label更新';
}

String formatDay(Object? raw) {
  final time = parseTime(raw)?.toLocal();
  if (time == null) return '';
  final today = DateTime.now();
  if (time.year == today.year && time.month == today.month && time.day == today.day) return '今天';
  return '${time.month}月${time.day}日';
}

/// A run of the page, not a card.
///
/// Name kept for source compatibility with every caller that already groups
/// content with it. What changed is the drawing: no fill, no radius, no shadow,
/// no outline. A 1px hairline above the run and a generous gap between runs is
/// all the separation a dense feed needs.
class RadarBoardCard extends StatelessWidget {
  const RadarBoardCard({super.key, required this.child, this.gap = radarGapLg});

  final Widget child;

  /// Space between this run and the previous one.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    const radius = BorderRadius.all(Radius.circular(radarCardRadius));
    return Padding(
      padding: EdgeInsets.fromLTRB(radarGutter, gap, radarGutter, 0),
      // 一块柔和的面:无描边、大圆角,靠面色比页面底亮一档分出层次。
      // 原先靠发丝线分段,一片"平"的观感更接近表格;现在既分得开组,
      // 也不出现硬边。
      child: DecoratedBox(
        decoration: BoxDecoration(color: p.card, borderRadius: radius),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// The one place a real panel is allowed: the connect form and similar
/// standalone blocks, where a fill carries meaning ("this is a form") instead
/// of decorating a list.
class RadarSurfaceCard extends StatelessWidget {
  const RadarSurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(18)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: radarGutter),
      padding: padding,
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(16)),
      child: child,
    );
  }
}

/// Quiet group label — the only thing that needs to sit above a run.
class RadarSectionLabel extends StatelessWidget {
  const RadarSectionLabel(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, radarGapLg, radarGutter, radarGapSm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: p.faint),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A brand dot. Six pixels of colour identifies a source; a filled tile with a
/// letter in it competes with the headline for the same attention.
class RadarSourceAvatar extends StatelessWidget {
  const RadarSourceAvatar({super.key, required this.platform, this.size = 6});

  final String platform;
  final double size;

  @override
  Widget build(BuildContext context) {
    final meta = sourceMeta(platform);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: meta.color, shape: BoxShape.circle),
    );
  }
}

/// Rank as a number, right-aligned in a fixed column so titles share one edge.
/// Top three carry colour and weight; the rest are quiet.
class RadarRankBadge extends StatelessWidget {
  const RadarRankBadge({super.key, required this.rank, this.width = 24});

  final int rank;
  final double width;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final top = rank <= 3;
    return SizedBox(
      width: width,
      child: Text(
        '$rank',
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          // Only the leader gets colour; 2–3 lean on weight, the rest go quiet.
          // Three differently tinted ranks read as decoration, not information.
          fontWeight: top ? FontWeight.w700 : FontWeight.w500,
          color: rank == 1 ? p.hot : (top ? p.muted : p.faint),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Inline metadata. Never a chip: no background, no border, no radius. An
/// optional 5px dot or 12px glyph carries the colour, the text stays legible.
class RadarPill extends StatelessWidget {
  const RadarPill({super.key, required this.label, this.icon, this.color, this.dot = false});

  final String label;
  final IconData? icon;
  final Color? color;

  /// Lead with a small filled dot instead of a glyph — quieter in a text run.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final tint = color ?? p.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
        ],
        if (icon != null) ...[Icon(icon, size: 12, color: tint), const SizedBox(width: 4)],
        Text(
          label,
          style: TextStyle(fontSize: 11.5, height: 1.25, color: tint, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// Board header: source name, board kind, freshness and count on one quiet
/// line. When [onToggleFollow] is given, a star toggles the followed state;
/// followed sources are pinned to the top of the feed by the page.
class RadarBoardHeader extends StatelessWidget {
  const RadarBoardHeader({
    super.key,
    required this.platform,
    required this.countLabel,
    required this.freshness,
    required this.status,
    this.followed = false,
    this.onToggleFollow,
    this.followTooltip,
    this.unfollowTooltip,
    this.onTap,
  });

  final String platform;
  final String countLabel;
  final String freshness;
  final String status;
  final bool followed;
  final VoidCallback? onToggleFollow;
  final String? followTooltip;
  final String? unfollowTooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final meta = sourceMeta(platform);
    final healthy = status == 'ok';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, radarGapMd, 0, radarGapSm),
        child: Row(
          children: [
            RadarSourceAvatar(platform: platform),
            const SizedBox(width: 8),
            Text(
              meta.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: p.text),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  meta.board,
                  if (freshness.isNotEmpty) freshness,
                  countLabel,
                  if (!healthy) '需要登录或暂不可用',
                ].where((part) => part.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: healthy ? p.faint : p.warning),
              ),
            ),
            if (onToggleFollow != null)
              IconButton(
                tooltip: followed ? unfollowTooltip : followTooltip,
                visualDensity: VisualDensity.compact,
                onPressed: onToggleFollow,
                icon: Icon(
                  followed ? AppIcons.favoriteActive : AppIcons.favorite,
                  size: 19,
                  color: followed ? p.warning : p.faint,
                ),
              ),
            if (onTap != null) Icon(AppIcons.disclosure, color: p.faint, size: 18),
          ],
        ),
      ),
    );
  }
}
