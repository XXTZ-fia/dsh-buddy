import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/radar_prefs.dart';
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../common/search_capsule.dart' show SearchCapsule;
import '../shell/page_frame.dart' show AppPage;
import '../theme/app_icons.dart';
import '../theme/theme.dart' show DshColors;
import 'radar_hot_api.dart';
import 'radar_source_order.dart';
import 'radar_visuals.dart';

/// 来源管理页：按栏目分组列出服务器上的全部榜单，星标即「添加到热榜」。
/// 与 newsnow.world 的来源面板一致——分组、副标题、右侧星标。
///
/// 用的是全站同一套页面框架：大标题 + 一句说明、搜索胶囊、每个栏目一张卡片。
class RadarSourcePickerPage extends StatefulWidget {
  const RadarSourcePickerPage({super.key, required this.catalog, this.unavailable = const <String>{}});

  final RadarHotCatalog catalog;

  /// 服务端确认抓不到的源：仍可添加，但行尾标出「暂不可用」。
  final Set<String> unavailable;

  @override
  State<RadarSourcePickerPage> createState() => _RadarSourcePickerPageState();
}

class _RadarSourcePickerPageState extends State<RadarSourcePickerPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    radarPrefs.addListener(_onPrefs);
    radarPrefs.adoptHotCatalog([for (final source in widget.catalog.sources) source.id]);
  }

  @override
  void dispose() {
    radarPrefs.removeListener(_onPrefs);
    _search.dispose();
    super.dispose();
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  List<RadarHotSource> _visible() {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.catalog.sources;
    return [
      for (final source in widget.catalog.sources)
        if (source.label.toLowerCase().contains(query) || source.columnLabel.toLowerCase().contains(query)) source,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final colors = DshColors.of(context);
    final visible = _visible();
    final added = radarPrefs.value.hotSources.length;

    // 每个栏目一张卡片，空栏目(搜索后没命中)直接不出现。
    final groups = <Widget>[];
    for (final (id, label) in widget.catalog.columns) {
      final rows = [
        for (final source in visible)
          if (source.column == id) source,
      ];
      if (rows.isEmpty) continue;
      groups.add(
        ListPageCard(
          title: label,
          children: [
            for (final source in rows)
              ListPageRow(
                leading: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: hotSourceColor(source.id, dark: isDarkPalette(context)),
                    shape: BoxShape.circle,
                  ),
                ),
                title: source.name,
                titleNote: source.title.isEmpty ? null : source.title,
                badge: widget.unavailable.contains(source.id)
                    ? Text(
                        t.radarHotUnavailableShort,
                        style: TextStyle(fontSize: 11, color: colors.warning),
                      )
                    : null,
                trailing: IconButton(
                  tooltip: radarPrefs.value.hasHotSource(source.id) ? t.radarSourcesRemove : t.radarSourcesAdd,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    radarPrefs.toggleHotSource(source.id);
                    setState(() {});
                  },
                  icon: Icon(
                    radarPrefs.value.hasHotSource(source.id) ? AppIcons.favoriteActive : AppIcons.favorite,
                    size: 20,
                    color: radarPrefs.value.hasHotSource(source.id) ? colors.warning : colors.textTertiary,
                  ),
                ),
                onTap: () {
                  radarPrefs.toggleHotSource(source.id);
                  setState(() {});
                },
              ),
          ],
        ),
      );
    }

    return AppPage.list(
      title: t.radarSourcesTitle,
      subtitle: Text(t.radarSourcesAdded(added, widget.catalog.sources.length)),
      children: [
        // 排序是「已添加的那几栏」的事，和下面「有哪些榜单可选」分开：
        // 一个改顺序，一个改集合，混在一张列表里容易点错。
        if (added > 1)
          ListPageCard(
            children: [
              ListPageRow(
                icon: AppIcons.swap,
                title: t.radarSourcesOrderTitle,
                subtitle: t.radarSourcesOrderNote,
                chevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RadarSourceOrderPage(catalog: widget.catalog),
                  ),
                ),
              ),
            ],
          ),
        if (added > 1) const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 0, ListPageRow.horizontal, 12),
          child: SearchCapsule(
            controller: _search,
            hint: t.radarSourcesSearch,
            onChanged: (value) => setState(() => _query = value),
            onClear: () {
              _search.clear();
              setState(() => _query = '');
            },
          ),
        ),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 24, ListPageRow.horizontal, 24),
            child: Text(
              t.radarSourcesNoMatch,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
            ),
          )
        else
          ...groups,
        const SizedBox(height: 16),
      ],
    );
  }
}
