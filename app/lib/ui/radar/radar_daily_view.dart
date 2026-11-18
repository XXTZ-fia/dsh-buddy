import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'radar_client.dart';
import 'radar_daily_api.dart';
import 'radar_snapshot_cache.dart';
import 'radar_visuals.dart' show RadarPalette, radarGutter;

/// 「简报」页的每日形态：一天一张卡片，先读总结，再读三件事，最后才是数据。
class RadarDailyView extends StatefulWidget {
  const RadarDailyView({
    super.key,
    required this.client,
    required this.onOpen,
    required this.onAsk,
  });

  final RadarClient client;
  final Future<void> Function(RadarDailyHighlight item) onOpen;
  final Future<void> Function(String prompt) onAsk;

  @override
  State<RadarDailyView> createState() => RadarDailyViewState();
}

class RadarDailyViewState extends State<RadarDailyView> {
  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  late DateTime _selected = DateTime.now();
  RadarDaily? _daily;
  List<RadarDailyCalendarDay> _calendar = const [];
  String? _error;
  bool _loading = true;
  bool _regenerating = false;
  bool _usageOpen = false;
  bool _fromCache = false;
  int _usageTab = 0;

  RadarDailyApi get _api => RadarDailyApi(widget.client);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> refresh() => _load();

  Future<void> _load({bool regenerate = false}) async {
    final day = _day(_selected);
    final origin = widget.client.base.toString();
    if (_daily != null && _daily!.date != day) {
      // 切到另一天时先把旧的收起来，避免新日期下短暂显示旧总结。
      setState(() => _daily = null);
    }
    if (!regenerate) {
      // 先读本地快照：切进雷达先看到上次的总结，网络回来再整块替换。
      final cached = await RadarSnapshotCache.readDaily(origin, day);
      if (cached != null && mounted) {
        setState(() {
          _daily = cached;
          _fromCache = true;
          _loading = false;
        });
      }
    }
    if (mounted) {
      setState(() {
        _loading = _daily == null;
        _error = null;
      });
    }
    try {
      final daily = regenerate ? await _api.refresh(day) : await _api.fetch(day);
      final days = await _api.calendar(_month(_selected));
      unawaited(RadarSnapshotCache.writeDaily(origin, daily));
      if (!mounted) return;
      setState(() {
        _daily = daily;
        _calendar = days;
        _fromCache = false;
        _loading = false;
        _regenerating = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
        _regenerating = false;
      });
    }
  }

  void _pick(DateTime day) {
    setState(() => _selected = DateTime(day.year, day.month, day.day));
    unawaited(_load());
  }

  Future<void> _openMonth() async {
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (context) => _MonthSheet(
        month: DateTime(_selected.year, _selected.month),
        selected: _selected,
        days: _calendar,
      ),
    );
    if (picked != null) _pick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final t = context.l10n;
    if (_loading && _daily == null) {
      return _DailySkeleton(palette: p);
    }
    if (_error != null && _daily == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(radarGutter, 48, radarGutter, 0),
        child: Column(
          children: [
            Text(t.radarFailure, style: TextStyle(fontSize: 13, color: p.muted)),
            const SizedBox(height: 10),
            TextButton(onPressed: _load, child: Text(t.radarRetry)),
          ],
        ),
      );
    }
    final daily = _daily;
    if (daily == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _hero(p, daily),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(radarGutter, 6, radarGutter, 0),
            child: Text(_error!, style: TextStyle(fontSize: 11, color: p.hot)),
          ),
        _weekStrip(p),
        if (daily.focus.isNotEmpty) _focus(p, daily),
        _stories(p, daily),
        _usage(p, daily.usage),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _hero(RadarPalette p, RadarDaily daily) {
    final today = _sameDay(_selected, DateTime.now());
    final weekday = _weekdays[_selected.weekday - 1];
    return Container(
      margin: const EdgeInsets.fromLTRB(radarGutter, 10, radarGutter, 0),
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.accent.withValues(alpha: 0.18), p.card],
        ),
        border: Border.all(color: p.accent.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${_selected.month} 月 ${_selected.day} 日 · 周$weekday',
                style: TextStyle(fontSize: 11.5, letterSpacing: 0.4, color: p.muted),
              ),
              if (today) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
                  child: Text('今天', style: TextStyle(fontSize: 9.5, color: p.accent)),
                ),
              ],
              if (_fromCache) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: p.text.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(6)),
                  child: Text('上次快照', style: TextStyle(fontSize: 9.5, color: p.muted)),
                ),
              ],
              const Spacer(),
              _IconAction(
                icon: AppIcons.refresh,
                busy: _regenerating,
                onTap: _regenerating
                    ? null
                    : () {
                        setState(() => _regenerating = true);
                        unawaited(_load(regenerate: true));
                      },
              ),
              _IconAction(icon: AppIcons.today, onTap: today ? null : () => _pick(DateTime.now())),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            today ? '今日概览' : '这一天',
            style: TextStyle(fontSize: 22, height: 1.1, fontWeight: FontWeight.w700, color: p.text),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _tokens(daily.usage.total.total),
                style: TextStyle(fontSize: 40, height: 0.95, fontWeight: FontWeight.w700, color: p.text),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('tokens', style: TextStyle(fontSize: 11, color: p.muted)),
                    const SizedBox(height: 2),
                    Text(
                      daily.usage.total.total == 0
                          ? '今天还没有记录'
                          : '今日已记录 · 缓存 ${daily.usage.total.cacheRate == null ? '—' : '${(daily.usage.total.cacheRate! * 100).round()}%'}',
                      style: TextStyle(fontSize: 10, color: p.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _statLine(p, '最关注', daily.focus.isEmpty ? '还没有命中兴趣词' : daily.focus.first.topic),
          _statLine(
            p,
            '用得多',
            daily.usage.byBackend.isEmpty ? '—' : _pretty(daily.usage.byBackend.first.name),
          ),
          _statLine(
            p,
            '常用模型',
            daily.usage.byModel.isEmpty ? '—' : _pretty(daily.usage.byModel.first.name),
          ),
          const SizedBox(height: 6),
          Text(
            daily.summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.55, color: p.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _meta(p, '${daily.itemCount} 条内容'),
              _meta(p, '${daily.sourceCount} 个来源'),
              if (daily.crossCount > 0) _meta(p, '${daily.crossCount} 条跨源'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meta(RadarPalette p, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: p.text.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8)),
    child: Text(text, style: TextStyle(fontSize: 10.5, color: p.muted)),
  );

  Widget _statLine(RadarPalette p, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(label, style: TextStyle(fontSize: 11, color: p.muted)),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.text),
          ),
        ),
      ],
    ),
  );

  Widget _weekStrip(RadarPalette p) {
    final start = _selected.subtract(Duration(days: _selected.weekday - 1));
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    final marked = {for (final day in _calendar) day.date};
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, 14, radarGutter, 0),
      child: Column(
        children: [
          Row(
            children: [
              for (final day in days)
                Expanded(
                  child: _DayCell(
                    day: day,
                    weekday: _weekdays[day.weekday - 1],
                    selected: _sameDay(day, _selected),
                    today: _sameDay(day, DateTime.now()),
                    marked: marked.contains(_day(day)),
                    onTap: () => _pick(day),
                  ),
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _openMonth,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                foregroundColor: p.muted,
              ),
              icon: Icon(AppIcons.today, size: 14, color: p.muted),
              label: Text('月历', style: TextStyle(fontSize: 11, color: p.muted)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _focus(RadarPalette p, RadarDaily daily) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, 4, radarGutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section(p, '今天最关注'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final topic in daily.focus)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(topic.topic, style: TextStyle(fontSize: 11.5, color: p.text)),
                      const SizedBox(width: 5),
                      Text('${topic.count}', style: TextStyle(fontSize: 10, color: p.accent)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stories(RadarPalette p, RadarDaily daily) {
    if (daily.highlights.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(radarGutter, 22, radarGutter, 0),
        child: Text('这一天还没有要闻。', style: TextStyle(fontSize: 12.5, color: p.muted)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, 20, radarGutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(p, '今日要闻'),
          for (var i = 0; i < daily.highlights.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _StoryCard(
                index: i,
                item: daily.highlights[i],
                onTap: () => widget.onOpen(daily.highlights[i]),
                onAsk: () => widget.onAsk(_askPrompt(daily.highlights[i])),
              ),
            ),
        ],
      ),
    );
  }

  Widget _usage(RadarPalette p, RadarUsage usage) {
    final total = usage.total;
    final hasUsage = total.total > 0;
    final tabs = ['终端', '软件', '模型'];
    final slices = switch (_usageTab) {
      0 => usage.byDevice,
      1 => usage.byBackend,
      _ => usage.byModel,
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(radarGutter, 14, radarGutter, 0),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(18)),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: hasUsage ? () => setState(() => _usageOpen = !_usageOpen) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Icon(AppIcons.running, size: 15, color: p.muted),
                  const SizedBox(width: 8),
                  Text('今日用量', style: TextStyle(fontSize: 12.5, color: p.text)),
                  const SizedBox(width: 8),
                  if (hasUsage) ...[
                    Text(
                      '${_tokens(total.total)} tokens',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.text),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '缓存 ${total.cacheRate == null ? '—' : '${(total.cacheRate! * 100).round()}%'}',
                      style: TextStyle(fontSize: 10.5, color: p.muted),
                    ),
                  ] else
                    Text('还没有记录', style: TextStyle(fontSize: 11, color: p.muted)),
                  const Spacer(),
                  if (hasUsage)
                    Icon(
                      _usageOpen ? AppIcons.collapse : AppIcons.expand,
                      size: 15,
                      color: p.muted,
                    ),
                ],
              ),
            ),
          ),
          if (hasUsage && _usageOpen) ...[
            Container(height: 1, color: p.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        _usageChip(p, tabs[i], i),
                      ],
                      const Spacer(),
                      Text(
                        '入 ${_tokens(total.billedInput)} · 出 ${_tokens(total.output)}',
                        style: TextStyle(fontSize: 10, color: p.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final slice in slices.take(8))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              slice.name.isEmpty ? '未标注' : _pretty(slice.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: p.text),
                            ),
                          ),
                          Text(
                            '${_tokens(slice.bucket.billedInput)} 入 · ${_tokens(slice.bucket.output)} 出',
                            style: TextStyle(fontSize: 10.5, color: p.muted),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _usageChip(RadarPalette p, String label, int index) => GestureDetector(
    onTap: () => setState(() => _usageTab = index),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: _usageTab == index ? p.accent.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          color: _usageTab == index ? p.accent : p.muted,
          fontWeight: _usageTab == index ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    ),
  );

  String _askPrompt(RadarDailyHighlight item) {
    final kind = item.platform.toLowerCase();
    if (kind.contains('github')) {
      return '请分析这个 GitHub 项目，重点看：\n1. 它解决什么问题、核心能力；\n2. 维护活跃度、issue/PR 情况、许可证；\n3. 工程上是否值得跟进或引入，有什么风险。\n\n项目：${item.title}\n链接：${item.url}\n${item.note.isEmpty ? '' : '简介：${item.note}'}';
    }
    if (kind.contains('arxiv') || kind.contains('paper') || kind.contains('hf')) {
      return '请解读这篇论文，重点看：\n1. 研究问题与动机；\n2. 方法核心；\n3. 主要实验结论；\n4. 局限与可复现性。\n\n论文：${item.title}\n链接：${item.url}\n${item.note.isEmpty ? '' : '摘要：${item.note}'}';
    }
    return '请分析这条信息的真实性、原始信源和关键事实，重点看：\n1. 最早出处与是否有一手来源；\n2. 哪些平台/媒体在报道，是否互相印证；\n3. 可能的偏差、旧闻重发或标题党；\n4. 给出可信度判断和需要核对的点。\n\n标题：${item.title}\n链接：${item.url}\n${item.note.isEmpty ? '' : '摘要：${item.note}'}';
  }

  Widget _section(RadarPalette p, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: p.muted),
    ),
  );

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  static String _month(DateTime value) => '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';

  static String _pretty(String value) => switch (value) {
    'dsh' => 'DSH',
    'codex' => 'Codex',
    'claude' => 'Claude Code',
    'opencode' => 'OpenCode',
    'cursor' => 'Cursor',
    'deepseek-flash' => 'V4 Flash',
    'deepseek-pro' => 'V4 Pro',
    'deepseek-v4-pro' => 'V4 Pro',
    'deepseek-v4-flash' => 'V4 Flash',
    _ => value,
  };

  static String _tokens(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }
}

/// 每日总结的骨架屏：先给结构和呼吸感，别让人盯一个转圈。
class _DailySkeleton extends StatelessWidget {
  const _DailySkeleton({required this.palette});

  final RadarPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    Widget block(double height, {double radius = 16, double? width}) => Container(
      height: height,
      width: width,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(radius)),
    );
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(radarGutter, 18, radarGutter, 0),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: LinearGradient(colors: [p.accent.withValues(alpha: 0.10), p.card]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                block(10, radius: 5, width: 120),
                const SizedBox(height: 12),
                block(30, radius: 8, width: 150),
                const SizedBox(height: 12),
                block(12, radius: 6, width: double.infinity),
                const SizedBox(height: 6),
                block(12, radius: 6, width: 220),
              ],
            ),
          ),
          const SizedBox(height: 18),
          block(38, radius: 12),
          const SizedBox(height: 10),
          for (var i = 0; i < 3; i++) block(i == 0 ? 92 : 66),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, this.onTap, this.busy = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    return IconButton(
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      iconSize: 17,
      icon: busy
          ? SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent))
          : Icon(icon, color: onTap == null ? p.faint : p.muted),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.weekday,
    required this.selected,
    required this.today,
    required this.marked,
    required this.onTap,
  });

  final DateTime day;
  final String weekday;
  final bool selected;
  final bool today;
  final bool marked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Text(
            weekday,
            style: TextStyle(fontSize: 9.5, color: selected ? p.accent : p.faint),
          ),
          const SizedBox(height: 5),
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? p.accent : Colors.transparent,
              shape: BoxShape.circle,
              border: today && !selected ? Border.all(color: p.accent.withValues(alpha: 0.5)) : null,
            ),
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected ? Colors.white : (today ? p.accent : p.text),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 3.5,
            height: 3.5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: marked ? (selected ? p.accent : p.muted) : Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({required this.index, required this.item, required this.onTap, required this.onAsk});

  final int index;
  final RadarDailyHighlight item;
  final VoidCallback onTap;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final first = index == 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.fromLTRB(first ? 16 : 14, first ? 16 : 12, 14, first ? 16 : 12),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(16),
          border: first ? Border.all(color: p.accent.withValues(alpha: 0.18)) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${index + 1}'.padLeft(2, '0'),
                style: TextStyle(
                  fontSize: first ? 13 : 11.5,
                  fontWeight: FontWeight.w700,
                  color: first ? p.accent : p.faint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: first ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: first ? 15.5 : 13.5,
                      height: 1.45,
                      fontWeight: first ? FontWeight.w600 : FontWeight.w400,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.note.isNotEmpty ? item.note : '来自 ${item.platform} 的今日收录，点开查看原文。',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: p.muted),
                  ),
                  if (item.crossPlatform.length > 1) ...[
                    const SizedBox(height: 7),
                    Text(
                      item.crossPlatform.take(3).join(' · '),
                      style: TextStyle(fontSize: 10, color: p.accent),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  tooltip: '问 AI',
                  onPressed: onAsk,
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  icon: Icon(AppIcons.askAi, color: p.accent),
                ),
                Icon(AppIcons.disclosure, size: 14, color: p.faint),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthSheet extends StatefulWidget {
  const _MonthSheet({required this.month, required this.selected, required this.days});
  final DateTime month;
  final DateTime selected;
  final List<RadarDailyCalendarDay> days;

  @override
  State<_MonthSheet> createState() => _MonthSheetState();
}

class _MonthSheetState extends State<_MonthSheet> {
  late DateTime _month = widget.month;

  @override
  Widget build(BuildContext context) {
    final p = RadarPalette.of(context);
    final first = DateTime(_month.year, _month.month);
    final count = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = first.weekday % 7;
    final marked = {for (final day in widget.days) day.date};
    final cells = <Widget>[];
    for (var i = 0; i < lead; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var d = 1; d <= count; d++) {
      final value = DateTime(_month.year, _month.month, d);
      final key = RadarDailyViewState._day(value);
      final selected = RadarDailyViewState._sameDay(value, widget.selected);
      cells.add(
        GestureDetector(
          onTap: () => Navigator.of(context).pop(value),
          child: Container(
            margin: const EdgeInsets.all(2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? p.accent : null,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$d',
              style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : (marked.contains(key) ? p.text : p.faint),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(radarGutter, 4, radarGutter, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                  icon: Icon(AppIcons.back, size: 17, color: p.muted),
                ),
                Expanded(
                  child: Text(
                    '${_month.year} 年 ${_month.month} 月',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.text),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                  icon: Icon(AppIcons.forward, size: 17, color: p.muted),
                ),
              ],
            ),
            Row(
              children: [
                for (final label in const ['日', '一', '二', '三', '四', '五', '六'])
                  Expanded(child: Center(child: Text(label, style: TextStyle(fontSize: 10, color: p.faint)))),
              ],
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1,
              children: cells,
            ),
          ],
        ),
      ),
    );
  }
}
