import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import 'radar_hot_api.dart';
import 'radar_visuals.dart';

/// 概览简报的状态：一条接口、一份 2 小时缓存。
class RadarDigestController extends ChangeNotifier {
  RadarDigest? digest;
  bool loading = false;
  String? error;
  DateTime? loadedAt;

  bool get hasData => digest != null;

  Future<void> load(RadarHotApi api, {bool force = false}) async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      digest = await api.digest(refresh: force);
      loadedAt = DateTime.now();
    } catch (exc) {
      error = '$exc';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void reset() {
    digest = null;
    loading = false;
    error = null;
    loadedAt = null;
  }
}

/// 概览面板：所有站点同时在讲的那几件事。
class RadarDigestView extends StatelessWidget {
  const RadarDigestView({
    super.key,
    required this.controller,
    required this.catalog,
    required this.onOpen,
    required this.onRefresh,
  });

  final RadarDigestController controller;
  final RadarHotCatalog? catalog;
  final Future<void> Function(RadarDigestItem item) onOpen;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final digest = controller.digest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (digest == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(radarGutter, 56, radarGutter, 0),
            child: Center(
              child: controller.loading
                  ? CircularProgressIndicator(color: p.accent, strokeWidth: 2.2)
                  : Text(
                      controller.error == null ? t.radarConsensusEmpty : t.radarFailure,
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
            ),
          )
        else ...[
          _DigestOverview(digest: digest, onRefresh: onRefresh, busy: controller.loading),
          if (digest.topics.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(radarGutter, 32, radarGutter, 8),
              child: Column(
                children: [
                  Icon(AppIcons.article, size: 30, color: p.faint),
                  const SizedBox(height: 14),
                  Text(
                    t.radarConsensusEmpty,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.text),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t.radarConsensusEmptyHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, height: 1.6, color: p.muted),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: radarGutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < digest.topics.length; index++) ...[
                    if (index > 0) Container(height: 1, color: p.hairline),
                    _TopicCard(
                      topic: digest.topics[index],
                      rank: index + 1,
                      catalog: catalog,
                      onOpen: onOpen,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// 摘要：一个大数字、右侧两行元信息、一条共识分布条。没有渐变、没有描边。
class _DigestOverview extends StatelessWidget {
  const _DigestOverview({required this.digest, required this.onRefresh, required this.busy});

  final RadarDigest digest;
  final Future<void> Function() onRefresh;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final counts = <int, int>{};
    for (final topic in digest.topics) {
      counts[topic.outlets] = (counts[topic.outlets] ?? 0) + 1;
    }
    final maxOutlets = counts.keys.isEmpty ? 1 : counts.keys.reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, radarGapMd, radarGutter, radarGapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${digest.topics.length}',
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
                  t.radarConsensusTopics,
                  style: TextStyle(fontSize: 11.5, color: p.faint, letterSpacing: 0.4),
                ),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _Meta(label: t.radarConsensusScanned(digest.scanned, digest.sources)),
                  const SizedBox(height: 3),
                  _Meta(
                    label: digest.model.isEmpty ? t.radarConsensusRule : t.radarConsensusModel,
                    strong: digest.model.isNotEmpty,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 分布条：每一段是「被 N 家同时报道」的话题数，越靠左越强共识。
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 4,
              child: Row(
                children: [
                  // 同一色相的深浅:越靠左(共同报道的站点越多)越实。
                  // 多色拼条在柔灰底上会变成装饰,反而看不清强弱。
                  for (var outlets = maxOutlets; outlets >= 1; outlets--)
                    if ((counts[outlets] ?? 0) > 0)
                      Expanded(
                        flex: counts[outlets]!,
                        child: Container(
                          margin: const EdgeInsets.only(right: 2),
                          color: p.accent.withValues(
                            alpha: (0.9 - (maxOutlets - outlets) * 0.22).clamp(0.2, 0.9),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  t.radarConsensusHint,
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: p.muted),
                ),
              ),
              TextButton(
                onPressed: busy ? null : () => onRefresh(),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(t.radarConsensusRefresh, style: const TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.label, this.strong = false});

  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        color: strong ? p.accent : p.muted,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}

/// 一条共识话题：标题、共同报道的站点、展开后的逐条来源。
class _TopicCard extends StatefulWidget {
  const _TopicCard({
    required this.topic,
    required this.rank,
    required this.catalog,
    required this.onOpen,
  });

  final RadarDigestTopic topic;
  final int rank;
  final RadarHotCatalog? catalog;
  final Future<void> Function(RadarDigestItem item) onOpen;

  @override
  State<_TopicCard> createState() => _TopicCardState();
}

class _TopicCardState extends State<_TopicCard> {
  bool _open = false;

  /// 来源名要占一个固定列宽，标题才能对齐成一条线。
  static const _outletWidth = 58.0;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    final dark = isDarkPalette(context);
    final topic = widget.topic;
    final colors = [for (final id in topic.sources.take(4)) hotSourceColor(id, dark: dark)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RadarRankBadge(rank: widget.rank),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            topic.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              height: 1.45,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              color: p.text,
                            ),
                          ),
                          if (topic.note.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              topic.note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: p.faint),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 170),
                      child: Icon(AppIcons.expand, size: 18, color: p.faint),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 38),
                  child: Row(
                    children: [
                      if (colors.isNotEmpty) ...[
                        _OutletDots(colors: colors),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        t.radarConsensusOutlets(topic.outlets),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: p.accent,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        t.radarConsensusCount(topic.count),
                        style: TextStyle(fontSize: 11.5, color: p.faint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 170),
          crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(38, 0, 0, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 1, color: p.hairline),
                const SizedBox(height: 10),
                Text(
                  t.radarConsensusRelated,
                  style: TextStyle(fontSize: 10.5, color: p.faint, letterSpacing: 0.5),
                ),
                for (final item in topic.items)
                  InkWell(
                    onTap: () => widget.onOpen(item),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.only(top: 6, right: 8),
                            decoration: BoxDecoration(
                              color: hotSourceColor(item.source, dark: dark),
                              shape: BoxShape.circle,
                            ),
                          ),
                          // 来源名单独占一列：展开后一眼能看出哪条是哪家的，
                          // 比一排只有颜色的圆点有用得多。
                          SizedBox(
                            width: _outletWidth,
                            child: Text(
                              item.outlet,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5, height: 1.8, color: p.faint),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, height: 1.5, color: p.muted),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 6, top: 2),
                            child: Icon(AppIcons.openLink, size: 12, color: p.faint),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OutletDots extends StatelessWidget {
  const _OutletDots({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    return SizedBox(
      height: 14,
      width: colors.isEmpty ? 0 : 10.0 + (colors.length - 1) * 8,
      child: Stack(
        children: [
          for (var index = 0; index < colors.length; index++)
            Positioned(
              left: index * 8.0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: colors[index],
                  shape: BoxShape.circle,
                  border: Border.all(color: p.canvas, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
