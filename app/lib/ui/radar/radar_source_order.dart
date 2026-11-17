import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/radar_prefs.dart';
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../shell/page_frame.dart' show AppPage;
import '../theme/app_icons.dart';
import '../theme/theme.dart' show DshColors;
import 'radar_hot_api.dart';
import 'radar_visuals.dart';

/// 榜单顺序：长按拖动决定「全部来源」里各站榜单的先后。
///
/// 顺序只存在这台手机上（`radarPrefs.hotSources`），和服务端的榜单集合无关——
/// 服务端只管每个源抓到什么，不关心用户怎么排。
class RadarSourceOrderPage extends StatefulWidget {
  const RadarSourceOrderPage({super.key, required this.catalog});

  final RadarHotCatalog catalog;

  @override
  State<RadarSourceOrderPage> createState() => _RadarSourceOrderPageState();
}

class _RadarSourceOrderPageState extends State<RadarSourceOrderPage> {
  @override
  void initState() {
    super.initState();
    radarPrefs.addListener(_onPrefs);
  }

  @override
  void dispose() {
    radarPrefs.removeListener(_onPrefs);
    super.dispose();
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final colors = DshColors.of(context);
    final dark = isDarkPalette(context);
    final ids = [
      for (final id in radarPrefs.value.hotSources)
        if (widget.catalog.byId(id) != null) id,
    ];
    return AppPage.list(
      title: t.radarSourcesOrderTitle,
      subtitle: Text(t.radarSourcesOrderNote),
      children: [
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 24, ListPageRow.horizontal, 24),
            child: Text(
              t.radarSourcesNoneAdded,
              style: TextStyle(fontSize: 13, color: colors.textTertiary),
            ),
          )
        else
          ListPageCard(
            children: [
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: ids.length,
                onReorder: (oldIndex, newIndex) {
                  unawaited(radarPrefs.reorderHotSources(oldIndex, newIndex));
                },
                itemBuilder: (context, index) {
                  final source = widget.catalog.byId(ids[index])!;
                  return ListPageRow(
                    key: ValueKey(source.id),
                    leading: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: hotSourceColor(source.id, dark: dark),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: source.name,
                    titleNote: source.title.isEmpty ? null : source.title,
                    trailing: ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Icon(AppIcons.dragHandle, size: 18, color: colors.textTertiary),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}
