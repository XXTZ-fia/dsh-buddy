import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../shell/page_frame.dart' show AppPage;
import '../theme/theme.dart' show DshColors;
import 'radar_client.dart';
import 'radar_settings_api.dart';

/// 论文推荐的规则设置：兴趣词、来源开关、显示条数。
///
/// 这三项都落在服务端的 settings 行里（`/radar/config`），论文接口按它取数与
/// 排序；改完保存后回到首页会自动重排一次。
class RadarPaperSettingsPage extends StatefulWidget {
  const RadarPaperSettingsPage({super.key, required this.client});

  final RadarClient client;

  @override
  State<RadarPaperSettingsPage> createState() => _RadarPaperSettingsPageState();
}

class _RadarPaperSettingsPageState extends State<RadarPaperSettingsPage> {
  static const _sourceLabels = {'hf': 'Hugging Face Daily', 'arxiv': 'arXiv'};
  static const _limits = [5, 12, 20];

  final _interest = TextEditingController();

  RadarSettingsApi get _api => RadarSettingsApi(widget.client);

  List<String> _interests = const [];
  Set<String> _sources = {'hf', 'arxiv'};
  int _limit = 12;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _interest.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await _api.read();
      if (!mounted) return;
      setState(() {
        _interests = [
          for (final raw in settings['interests'] as List? ?? const []) '$raw',
        ];
        final sources = {
          for (final raw in settings['paper_sources'] as List? ?? const []) '$raw',
        };
        _sources = sources.isEmpty ? {'hf', 'arxiv'} : sources;
        _limit = (settings['paper_limit'] as num?)?.toInt() ?? 12;
      });
    } on RadarApiException catch (error) {
      if (mounted) setState(() => _error = 'HTTP ${error.statusCode}');
    } on Object {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.patch({
        'interests': _interests,
        'paper_sources': [
          for (final id in _sourceLabels.keys)
            if (_sources.contains(id)) id,
        ],
        'paper_limit': _limit,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.radarPaperSaved)));
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop(true);
    } on RadarApiException catch (error) {
      if (mounted) setState(() => _error = 'HTTP ${error.statusCode}');
    } on Object {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addInterest([String? value]) {
    final word = (value ?? _interest.text).trim();
    if (word.isEmpty) return;
    if (_interests.contains(word) || _interests.length >= 50) {
      _interest.clear();
      return;
    }
    setState(() => _interests = [..._interests, word]);
    _interest.clear();
  }

  void _toggleSource(String id) {
    final next = {..._sources};
    // 一个都不剩就没有论文可取：最后一个来源不允许关掉。
    if (next.contains(id) && next.length == 1) return;
    if (!next.remove(id)) next.add(id);
    setState(() => _sources = next);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final colors = DshColors.of(context);
    return AppPage.list(
      title: t.radarPaperSettingsTitle,
      subtitle: Text(t.radarPaperSettingsSubtitle),
      actions: [
        TextButton(
          onPressed: _loading || _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.radarPaperSave),
        ),
      ],
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 0, ListPageRow.horizontal, 12),
            child: Text(
              '$_error · ${t.radarPaperSaveFailed}',
              style: TextStyle(fontSize: 12, color: colors.danger),
            ),
          ),
        ListPageCard(
          title: t.radarPaperInterestsTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 14, ListPageRow.horizontal, 6),
              child: Text(
                t.radarPaperInterestsNote,
                style: TextStyle(fontSize: 12, height: 1.5, color: colors.textTertiary),
              ),
            ),
            if (_interests.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 4, ListPageRow.horizontal, 8),
                child: Text(
                  t.radarPaperInterestsEmpty,
                  style: TextStyle(fontSize: 12, color: colors.textTertiary),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 6, ListPageRow.horizontal, 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    for (final word in _interests)
                      InputChip(
                        label: Text(word),
                        onDeleted: () => setState(() => _interests = [..._interests]..remove(word)),
                        deleteIcon: const Icon(Icons.close, size: 15),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 4, ListPageRow.horizontal, 14),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _interest,
                      textInputAction: TextInputAction.done,
                      onSubmitted: _addInterest,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: t.radarPaperInterestHint,
                        hintStyle: TextStyle(fontSize: 13, color: colors.textTertiary),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _loading ? null : () => _addInterest(),
                    child: Text(t.radarPaperInterestAdd),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ListPageCard(
          title: t.radarPaperSourcesTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 14, ListPageRow.horizontal, 2),
              child: Text(
                t.radarPaperSourcesNote,
                style: TextStyle(fontSize: 12, height: 1.5, color: colors.textTertiary),
              ),
            ),
            for (final entry in _sourceLabels.entries)
              ListPageRow(
                title: entry.value,
                titleNote: _sourceLabels[entry.key] == 'arXiv' ? t.radarPaperSourceArxivNote : null,
                onTap: () => _toggleSource(entry.key),
                trailing: Switch(
                  value: _sources.contains(entry.key),
                  onChanged: _loading ? null : (_) => _toggleSource(entry.key),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        ListPageCard(
          title: t.radarPaperCountTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 14, ListPageRow.horizontal, 10),
              child: Row(
                children: [
                  for (final value in _limits)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('$value'),
                        selected: _limit == value,
                        onSelected: _loading ? null : (_) => setState(() => _limit = value),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ListPageCard(
          title: t.radarPaperRankTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 14, ListPageRow.horizontal, 16),
              child: Text(
                t.radarPaperRankNote,
                style: TextStyle(fontSize: 12, height: 1.6, color: colors.textTertiary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
