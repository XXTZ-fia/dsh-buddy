import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import 'radar_brief_api.dart';
import 'radar_visuals.dart';

/// 简报链路还会出现热榜页没有的两个平台（X、知乎）。`radarSources` 只登记热榜
/// 过滤用的四个平台（有测试锁着），所以这里单独补名字，别去改那份表。
String briefPlatformName(String id) => switch (id) {
  'x' => 'X',
  'zhihu' => '知乎',
  _ => sourceMeta(id).name,
};

/// 来源色的圆点。`sourceMeta` 对未知平台是灰的，这里优先取站点品牌色。
class _PlatformDot extends StatelessWidget {
  const _PlatformDot({required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context) => Container(
    width: 5,
    height: 5,
    decoration: BoxDecoration(
      color: hotSourceColor(platform, dark: isDarkPalette(context)),
      shape: BoxShape.circle,
    ),
  );
}

/// 简报的取数状态：一页 20 条、按需追加。
class RadarBriefController extends ChangeNotifier {
  RadarBrief? brief;
  bool loading = false;
  bool loadingMore = false;
  String? error;
  DateTime? loadedAt;

  int _pageSize = 20;
  bool _lastPageFull = false;

  bool get hasData => brief != null;
  bool get canLoadMore => _lastPageFull && (brief?.items.length ?? 0) > 0;

  Future<void> load(RadarBriefApi api, {bool force = false}) async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      _pageSize = api.pageSize;
      final page = await api.page();
      brief = page;
      _lastPageFull = page.items.length >= _pageSize;
      loadedAt = DateTime.now();
    } catch (exc) {
      error = '$exc';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore(RadarBriefApi api) async {
    final current = brief;
    if (current == null || loadingMore) return;
    loadingMore = true;
    notifyListeners();
    try {
      final page = await api.page(offset: current.items.length);
      final known = {for (final item in current.items) item.id};
      brief = RadarBrief(
        generatedAt: page.generatedAt,
        health: page.health.isEmpty ? current.health : page.health,
        items: [...current.items, ...page.items.where((item) => !known.contains(item.id))],
      );
      _lastPageFull = page.items.length >= _pageSize;
    } on Object {
      // 追加失败保留已加载的内容，用户可以再点一次。
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }

  /// 已读只在本地先落地：服务端写入失败不该把整页打回错误态。
  void markReadLocally(String id) {
    final current = brief;
    if (current == null) return;
    final index = current.items.indexWhere((item) => item.id == id);
    if (index < 0 || current.items[index].read) return;
    final items = [...current.items];
    items[index] = items[index].copyWith(read: true);
    brief = RadarBrief(generatedAt: current.generatedAt, health: current.health, items: items);
    notifyListeners();
  }

  void reset() {
    brief = null;
    loading = false;
    loadingMore = false;
    error = null;
    loadedAt = null;
    _lastPageFull = false;
  }
}

/// 简报面板：服务端整理过的「今天值得看什么」。
class RadarBriefView extends StatelessWidget {
  const RadarBriefView({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onRefresh,
    required this.onLoadMore,
  });

  final RadarBriefController controller;
  final Future<void> Function(RadarBriefItem item) onOpen;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final brief = controller.brief;
    if (brief == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(radarGutter, 56, radarGutter, 0),
        child: Center(
          child: controller.loading
              ? CircularProgressIndicator(color: p.accent, strokeWidth: 2.2)
              : Text(
                  controller.error == null ? t.radarBriefEmpty : t.radarFailure,
                  style: TextStyle(fontSize: 13, color: p.muted),
                ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BriefOverview(brief: brief, busy: controller.loading, onRefresh: onRefresh),
        _HealthStrip(health: brief.health),
        if (brief.items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(radarGutter, 32, radarGutter, 8),
            child: Column(
              children: [
                Icon(AppIcons.article, size: 30, color: p.faint),
                const SizedBox(height: 14),
                Text(
                  t.radarBriefEmpty,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.text),
                ),
                const SizedBox(height: 6),
                Text(
                  t.radarBriefEmptyHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.6, color: p.muted),
                ),
              ],
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: radarGutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < brief.items.length; index++) ...[
                  if (index > 0) Container(height: 1, color: p.hairline),
                  _BriefRow(
                    item: brief.items[index],
                    rank: index + 1,
                    onTap: () => onOpen(brief.items[index]),
                  ),
                ],
              ],
            ),
          ),
          if (controller.canLoadMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: TextButton(
                  onPressed: controller.loadingMore ? null : () => onLoadMore(),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: controller.loadingMore
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
                        )
                      : Text(t.radarBriefMore, style: const TextStyle(fontSize: 12.5)),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// 顶部一行：已加载条数 + 未读数 + 生成时间。
class _BriefOverview extends StatelessWidget {
  const _BriefOverview({required this.brief, required this.busy, required this.onRefresh});

  final RadarBrief brief;
  final bool busy;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final unread = brief.unread;
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, radarGapMd, radarGutter, radarGapSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${brief.items.length}',
            style: TextStyle(
              fontSize: 38,
              height: 1,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.6,
              color: p.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 9),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              t.radarBriefUnit,
              style: TextStyle(fontSize: 11.5, color: p.faint, letterSpacing: 0.4),
            ),
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                unread == 0 ? t.radarBriefAllRead : t.radarBriefUnread(unread),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: unread == 0 ? p.muted : p.accent,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Text(
                    t.radarBriefGenerated(formatRelative(brief.generatedAt)),
                    style: TextStyle(fontSize: 11, color: p.muted),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => onRefresh(),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 24),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(t.radarBriefRefresh, style: const TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 来源健康：一行小字说明这轮谁在采、谁没启用，避免「为什么只有几条」的疑问。
class _HealthStrip extends StatelessWidget {
  const _HealthStrip({required this.health});

  final List<RadarBriefHealth> health;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    if (health.isEmpty) return const SizedBox.shrink();
    String label(RadarBriefHealth row) => switch (row.status) {
      'ok' => t.radarBriefHealthOk,
      'stale' => t.radarBriefHealthStale,
      _ => t.radarBriefHealthOff,
    };
    Color color(RadarBriefHealth row, RadarPalette palette) => switch (row.status) {
      'ok' => palette.accent,
      'stale' => palette.muted,
      _ => palette.faint,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, 0, radarGutter, radarGapSm),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          for (final row in health)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PlatformDot(platform: row.platform),
                const SizedBox(width: 5),
                Text(
                  '${briefPlatformName(row.platform)} ${label(row)}',
                  style: TextStyle(fontSize: 10.5, color: color(row, p)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 摘要这一行只放「新信息」：与标题相同、或是旧版离线占位句时整行不显示，
/// 否则一条 20 字的标题会在卡片里重复两遍。
String briefSummaryOf(RadarBriefItem item) {
  final text = item.summary.trim();
  if (text.isEmpty || text == item.title.trim()) return '';
  if (text.startsWith('【离线】')) return '';
  return text;
}

/// 展示用的入选理由：去掉服务端给 dry-run/离线模式加的实现细节前缀，
/// 历史条目也因此不用重新入库就能变干净。
String briefWhyOf(RadarBriefItem item) =>
    item.why.trim().replaceFirst(RegExp(r'^离线摘要（未调用模型）[，,]\s*'), '');

/// 单条简报：标题、摘要、理由与热度。
class _BriefRow extends StatelessWidget {
  const _BriefRow({required this.item, required this.rank, required this.onTap});

  final RadarBriefItem item;
  final int rank;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final read = item.read;
    final others = item.crossPlatform.where((id) => id != item.platform).length;
    // 服务端给的是原始差值（如 -9785425），这里按「万/亿」压缩，和自己算的其余热度一致。
    final delta = formatDelta(item.heatDelta);
    final summary = briefSummaryOf(item);
    return InkWell(
      onTap: () => onTap(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadarRankBadge(rank: rank),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _PlatformDot(platform: item.platform),
                      const SizedBox(width: 6),
                      Text(
                        briefPlatformName(item.platform),
                        style: TextStyle(fontSize: 10.5, color: p.faint, letterSpacing: 0.3),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          formatRelative(item.publishedAt),
                          style: TextStyle(fontSize: 10.5, color: p.faint),
                        ),
                      ),
                      if (read)
                        Text(
                          t.radarBriefReadMark,
                          style: TextStyle(fontSize: 10, color: p.faint, letterSpacing: 0.3),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.45,
                      fontWeight: read ? FontWeight.w500 : FontWeight.w600,
                      letterSpacing: -0.1,
                      color: read ? p.muted : p.text,
                    ),
                  ),
                  if (summary.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, height: 1.55, color: p.muted),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      if (item.heat > 0) ...[
                        Text(
                          formatHeat(item.heat),
                          style: TextStyle(fontSize: 10.5, color: p.faint),
                        ),
                        if (delta.isNotEmpty) ...[
                          const SizedBox(width: 5),
                          Text(
                            delta,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: delta.startsWith('-') ? p.muted : p.accent,
                            ),
                          ),
                        ],
                        const SizedBox(width: 10),
                      ],
                      if (others > 0) ...[
                        Text(
                          t.radarBriefCross(others),
                          style: TextStyle(fontSize: 10.5, color: p.accent),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          briefWhyOf(item).isEmpty ? '' : '${t.radarBriefWhy} · ${briefWhyOf(item)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: p.faint),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
