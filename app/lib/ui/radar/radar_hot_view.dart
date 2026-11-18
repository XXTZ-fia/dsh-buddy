import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/radar_prefs.dart';
import 'radar_client.dart';
import 'radar_hot_api.dart';
import 'radar_snapshot_cache.dart';
import 'radar_links.dart';
import 'radar_ask.dart';
import 'radar_visuals.dart';
import '../theme/app_icons.dart';

/// 热榜数据：目录一次、每个已添加来源一份榜单。失败不清空旧数据，
/// 页面继续显示上一轮结果并在顶部提示。
class RadarHotController {
  RadarHotController();

  static const ttl = Duration(minutes: 5);

  RadarHotCatalog? catalog;
  List<RadarHotFeed> feeds = const [];
  bool loading = false;
  String? error;
  DateTime? loadedAt;

  /// 上一次真正拉取的来源集合；勾选变化时要重新请求，但不必绕过服务端缓存。
  List<String> _loadedIds = const [];

  bool get hasData => catalog != null;

  RadarHotFeed? feedFor(String sourceId) {
    for (final feed in feeds) {
      if (feed.source == sourceId) return feed;
    }
    return null;
  }

  RadarHotSource? sourceFor(String sourceId) => catalog?.byId(sourceId);

  /// 知乎在机房 IP 上必须有登录 Cookie；服务端会把原因写进 feed.error。
  bool get zhihuNeedsLogin {
    final feed = feedFor('zhihu');
    return feed?.error.contains('RADAR_ZHIHU_COOKIE') ?? false;
  }

  bool get isStale {
    final at = loadedAt;
    return at == null || DateTime.now().difference(at) > ttl;
  }

  /// Drops everything on disconnect so a new server never shows old boards.
  void reset() {
    catalog = null;
    feeds = const [];
    loading = false;
    error = null;
    loadedAt = null;
    _loadedIds = const [];
  }

  bool _sameIds(List<String> ids) =>
      ids.length == _loadedIds.length && Iterable<int>.generate(ids.length).every((i) => ids[i] == _loadedIds[i]);

  Future<void> load(RadarHotApi api, {bool force = false}) async {
    if (loading) return;
    final origin = api.client.base.toString();
    if (catalog == null && feeds.isEmpty) {
      final snapshot = await RadarSnapshotCache.readHot(origin);
      if (snapshot != null) {
        catalog = snapshot.catalog;
        feeds = snapshot.feeds;
        loadedAt = snapshot.at;
        _loadedIds = [for (final feed in feeds) feed.source];
      }
    }
    catalog ??= await api.catalog();
    // 本地偏好只做过滤，不参与等待：持久化慢或不可用时照样先出榜单。
    final known = {for (final source in catalog!.sources) source.id};
    final ids = [
      for (final id in radarPrefs.value.hotSources)
        if (known.contains(id)) id,
    ].take(60).toList();
    if (!force && !isStale && feeds.isNotEmpty && _sameIds(ids)) return;
    loading = true;
    error = null;
    try {
      unawaited(radarPrefs.adoptHotCatalog(known.toList()));
      feeds = ids.isEmpty ? const [] : await api.boards(ids, refresh: force);
      _loadedIds = ids;
      loadedAt = DateTime.now();
      if (feeds.isNotEmpty) unawaited(RadarSnapshotCache.writeHot(origin, catalog!, feeds));
    } on RadarApiException catch (failure) {
      error = 'HTTP ${failure.statusCode}';
    } on Object {
      error = 'offline';
    } finally {
      loading = false;
    }
  }
}

/// 顶部来源横条：「全部」、论文推荐、以及已添加的来源。星标来源排在最前。
///
/// 论文和各个站点在这里是平级的入口：它也是「收集来的一份内容」，
/// 不该在榜单上面单独占一块。
///
/// Text tabs, not pills: a 6px brand dot, the name, the count, and a 2px
/// underline on the active one. The row is a switcher, so it should read like
/// navigation — a strip of outlined capsules reads like a form.
class RadarHotRail extends StatelessWidget {
  const RadarHotRail({
    super.key,
    required this.catalog,
    required this.selected,
    required this.counts,
    required this.paperCount,
    required this.onSelect,
  });

  /// 「论文」这一栏的选中值：它不是来源 id，单独给一个哨兵值。
  static const papersId = '__papers';

  final RadarHotCatalog? catalog;
  final String? selected;
  final Map<String, int> counts;
  final int paperCount;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final prefs = radarPrefs.value;
    final sources = <RadarHotSource>[for (final id in prefs.hotSources) ?catalog?.byId(id)];
    if (catalog == null) return const SizedBox.shrink();
    final total = counts.values.fold<int>(0, (sum, value) => sum + value);
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: radarGutter),
        itemCount: sources.length + 2,
        separatorBuilder: (_, _) => const SizedBox(width: 20),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _RailTab(
              label: t.radarAllSources,
              count: total,
              selected: selected == null,
              color: p.accent,
              onTap: () => onSelect(null),
            );
          }
          if (index == 1) {
            return _RailTab(
              label: t.radarPapersTab,
              count: paperCount,
              selected: selected == papersId,
              color: p.success,
              onTap: () => onSelect(papersId),
            );
          }
          final source = sources[index - 2];
          return _RailTab(
            label: source.title.isEmpty ? source.name : '${source.name} ${source.title}',
            count: counts[source.id] ?? 0,
            selected: selected == source.id,
            color: hotSourceColor(source.id, dark: isDarkPalette(context)),
            onTap: () => onSelect(source.id),
          );
        },
      ),
    );
  }
}

class _RailTab extends StatelessWidget {
  const _RailTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final ink = selected ? p.text : p.muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Center(
        // IntrinsicWidth bounds the column under the rail's loose horizontal
        // constraints, so the underline spans exactly the label.
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: selected ? 1 : 0.55),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: ink,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '$count',
                    style: TextStyle(fontSize: 11, color: selected ? p.faint : p.faint.withValues(alpha: 0.75)),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 2,
                decoration: BoxDecoration(
                  color: selected ? p.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个来源的榜单：站点名 + 副标题 + 条数，下面直接是排名行。
///
/// No enclosure. The header is a quiet line, rows are separated by a hairline
/// indented to the title edge, and the block ends in whitespace.
class RadarHotBoardCard extends StatelessWidget {
  const RadarHotBoardCard({
    super.key,
    required this.source,
    required this.feed,
    required this.onOpen,
    required this.onRetry,
    this.onRemove,
  });

  final RadarHotSource source;
  final RadarHotFeed? feed;
  final ValueChanged<RadarHotItem> onOpen;
  final VoidCallback onRetry;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final dark = isDarkPalette(context);
    final brand = hotSourceColor(source.id, dark: dark);
    final items = feed?.items ?? const <RadarHotItem>[];
    final unavailable = feed != null && feed!.isEmpty;
    final meta = [
      if (source.title.isNotEmpty) source.title,
      if (feed != null) t.radarItemCount(items.length),
      if (feed != null && feed!.status == 'stale') t.radarHotStale,
      formatFreshness(feed?.updatedAt),
    ].where((part) => part.isNotEmpty).join(' · ');
    return RadarBoardCard(
      // 分组之间留够呼吸:14 太挤,两块面会黏在一起读成一张表。
      gap: radarGapLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: brand, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  source.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: p.text),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    unavailable ? t.radarHotUnavailable : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: unavailable ? p.warning : p.faint),
                  ),
                ),
                if (unavailable)
                  IconButton(
                    tooltip: t.radarRetry,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: onRetry,
                    icon: Icon(AppIcons.refresh, size: 18, color: p.muted),
                  ),
                if (onRemove != null)
                  IconButton(
                    tooltip: t.radarUnfollow,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: onRemove,
                    icon: Icon(AppIcons.favoriteActive, size: 17, color: p.accent),
                  ),
              ],
            ),
          ),
          // Rows are separated by space, not rules. At this density a line
          // between every item turns the feed back into a table of cells.
          for (var index = 0; index < items.length; index++)
            RadarHotRow(item: items[index], platform: source.id, onTap: () => onOpen(items[index])),
        ],
      ),
    );
  }
}

/// 一条热榜：序号、标题、以及一行内联的热度/时间。
///
/// The old row spent attention on three separate decorations — a tinted rank
/// tile, two rounded pills, a chevron. Same information, one quiet line.
class RadarHotRow extends StatelessWidget {
  const RadarHotRow({super.key, required this.item, required this.platform, required this.onTap});

  final RadarHotItem item;
  final String platform;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final time = formatRelative(item.time);
    final meta = [if (item.extra.isNotEmpty) item.extra, if (time.isNotEmpty) time].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadarRankBadge(rank: item.rank),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, height: 1.45, fontWeight: FontWeight.w500, color: p.text),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, height: 1.3, color: p.faint),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '问 AI',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: () => ProviderScope.containerOf(context, listen: false)
                  .read(radarAskProvider.notifier)
                  .ask(radarAskPrompt(platform: platform, title: item.title, url: item.url, summary: item.extra)),
              icon: Icon(AppIcons.askAi, size: 15, color: p.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开条目：条目深链 → 该 App 内搜索 → 来源 App → 浏览器。
///
/// 热搜类条目的 URL 只有一个搜索词，没有内容 id，所以第三档（App 内搜索）才是
/// 这些源的实际上限；标题作为搜索词兜底。
Future<bool> openHotItem(BuildContext context, RadarHotSource source, RadarHotItem item) async {
  final opened = await openHotLink(
    sourceId: source.id,
    itemUrl: item.url,
    scheme: source.scheme,
    keyword: item.title,
  );
  if (opened == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.radarHotOpenFailed)));
  }
  return opened != null;
}

/// 空态：一个来源都没添加时引导去来源管理。
class RadarHotEmpty extends StatelessWidget {
  const RadarHotEmpty({super.key, required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, 64, radarGutter, 48),
      child: Column(
        children: [
          Icon(AppIcons.navRadar, size: 30, color: p.faint),
          const SizedBox(height: 18),
          Text(
            t.radarHotEmpty,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.text, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            t.radarHotEmptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.6, color: p.muted),
          ),
          const SizedBox(height: 18),
          TextButton.icon(
            onPressed: onManage,
            icon: const Icon(AppIcons.add, size: 17),
            label: Text(t.radarSourcesTitle),
          ),
        ],
      ),
    );
  }
}
