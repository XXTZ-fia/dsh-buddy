import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/in_progress_row.dart';
import '../theme/app_icons.dart';
import 'radar_client.dart';
import 'radar_links.dart';
import 'radar_papers_api.dart';
import 'radar_visuals.dart';

/// 首页论文流：服务端按兴趣词挑好的论文与摘要，30 分钟一份缓存。
///
/// 与热榜同一套降级：网络失败保留上一份，没有上一份就显示「稍后再试」，
/// 不用占位条目填充。
class RadarPapersController {
  RadarPapersController();

  static const ttl = Duration(minutes: 30);

  RadarPapers? data;
  bool loading = false;
  String? error;
  DateTime? loadedAt;

  bool get isStale {
    final at = loadedAt;
    return at == null || DateTime.now().difference(at) > ttl;
  }

  void reset() {
    data = null;
    loading = false;
    error = null;
    loadedAt = null;
  }

  Future<void> load(RadarPaperApi api, {bool force = false}) async {
    if (loading) return;
    if (!force && !isStale && data != null) return;
    loading = true;
    error = null;
    try {
      data = await api.fetch(refresh: force);
      loadedAt = DateTime.now();
    } on RadarApiException catch (e) {
      error = 'HTTP ${e.statusCode}';
    } catch (_) {
      error = 'offline';
    } finally {
      loading = false;
    }
  }
}

/// 「为你推荐的论文」整块：标题行 + 若干条论文。
class RadarPapersSection extends StatelessWidget {
  const RadarPapersSection({
    super.key,
    required this.controller,
    required this.onRetry,
    this.onSettings,
  });

  final RadarPapersController controller;
  final VoidCallback onRetry;

  /// 打开推荐规则设置（兴趣词、来源、条数）；热榜页之外可以不传。
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final papers = controller.data;
    final items = papers?.items ?? const <RadarPaper>[];
    return RadarBoardCard(
      gap: radarGapLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 6),
            child: Row(
              children: [
                Icon(AppIcons.school, size: 15, color: p.accent),
                const SizedBox(width: 8),
                Text(
                  t.radarPapersTitle,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: p.text),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _subtitle(context, papers, items.length),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: controller.error != null ? p.warning : p.faint),
                  ),
                ),
                if (controller.loading)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent),
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(AppIcons.refresh, size: 16, color: p.muted),
                    tooltip: t.commonRetry,
                    onPressed: onRetry,
                  ),
                if (onSettings != null)
                  IconButton(
                    icon: Icon(AppIcons.configure, size: 16, color: p.muted),
                    tooltip: t.radarPaperSettingsTitle,
                    onPressed: onSettings,
                  ),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
              // 取论文时给一行转着的点:接口慢的时候不至于看着像卡死。
              child: controller.loading && controller.error == null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: InProgressRow(
                        label: t.radarPapersLoading,
                        compact: true,
                        style: TextStyle(fontSize: 12.5, height: 1.45, color: p.muted),
                      ),
                    )
                  : Text(
                      controller.error != null ? _errorText(context) : t.radarPapersEmpty,
                      style: TextStyle(fontSize: 12.5, height: 1.45, color: p.muted),
                    ),
            )
          else
            for (var index = 0; index < items.length; index++) ...[
              if (index > 0) Divider(height: 1, thickness: 0.5, color: p.hairline, indent: 16, endIndent: 16),
              _PaperRow(paper: items[index]),
            ],
          if (items.isNotEmpty && papers != null && papers.interests.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                '${t.radarPapersInterestsLabel} ${papers.interests.take(3).join(' · ')}',
                style: TextStyle(fontSize: 11.5, color: p.muted),
              ),
            ),
        ],
      ),
    );
  }

  /// 失败原因分两种：服务端还是旧版本（重启才生效），和根本没有网络。
  /// 混成一句「取不到」等于让用户自己猜。
  String _errorText(BuildContext context) {
    final t = context.l10n;
    return switch (controller.error) {
      'HTTP 404' || 'HTTP 405' => t.radarPapersServerOld,
      'HTTP 401' || 'HTTP 403' => t.radarPapersUnauthorized,
      _ => t.radarPapersFailed,
    };
  }

  String _subtitle(BuildContext context, RadarPapers? papers, int count) {
    final t = context.l10n;
    if (controller.error != null) return _errorText(context);
    if (papers == null) return t.radarPapersNote;
    final degraded = papers.sources.where((source) => source.status == 'cached').length;
    final parts = [
      t.radarItemCount(count),
      if (degraded > 0) t.radarHotStale,
    ];
    return parts.join(' · ');
  }
}

/// 一条论文：标题 → 来源/投票/日期 → 命中兴趣 → 摘要（折叠两行，点开全文）。
class _PaperRow extends StatefulWidget {
  const _PaperRow({required this.paper});

  final RadarPaper paper;

  @override
  State<_PaperRow> createState() => _PaperRowState();
}

class _PaperRowState extends State<_PaperRow> {
  bool _open = false;

  /// 有中文摘要时默认显示中文；这个是「看原文」的开关。
  bool _original = false;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final paper = widget.paper;
    final authors = paper.authors.take(2).join(', ');
    final meta = [
      switch (paper.source) {
        'hf' => t.radarPapersSourceHf,
        'arxiv' => t.radarPapersSourceArxiv,
        _ => t.radarPapersSourceBoth,
      },
      if (paper.upvotes > 0) '▲ ${paper.upvotes}',
      if (paper.publishedAt.isNotEmpty) paper.publishedAt,
    ].join(' · ');
    final translated = paper.hasChineseAbstract;
    final body = _original || !translated ? paper.abstract : paper.abstractZh;
    return InkWell(
      onTap: () => unawaited(openHotLink(sourceId: paper.source == 'both' ? 'arxiv' : paper.source, itemUrl: paper.url)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // 标题也要中文：英文标题下面配中文摘要，读起来像两份材料拼在一起。
              _original ? paper.title : paper.displayTitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, height: 1.35, fontWeight: FontWeight.w600, color: p.text),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: Text(
                    authors.isEmpty ? meta : '$meta · $authors',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.faint),
                  ),
                ),
                if (paper.matched.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      paper.matched.first,
                      style: TextStyle(fontSize: 10.5, color: p.accent, fontWeight: FontWeight.w500),
                    ),
                  ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                body,
                maxLines: _open ? null : 2,
                overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.2, height: 1.5, color: p.muted),
              ),
              Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _open = !_open),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 5, right: 14),
                      child: Text(
                        _open ? t.radarPapersLess : t.radarPapersMore,
                        style: TextStyle(fontSize: 11, color: p.accent, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                  // 译文由服务端给：想核对原文时在这里切，不用另开页面。
                  if (translated)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _original = !_original),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          _original ? t.radarPapersTranslated : t.radarPapersOriginal,
                          style: TextStyle(fontSize: 11, color: p.muted, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
