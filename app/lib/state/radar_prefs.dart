import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Platforms the AI briefing pipeline still collects. Mirrors newsnow.world's
/// Chinese hot-list sources; Zhihu and X were removed from the previous
/// six-platform list. Every id here has a collector in the radar backend.
const radarAvailablePlatforms = <String>['douyin', 'bili', 'weibo', 'xhs'];

/// Boards shown on the hot-list tab the first time it opens. Ids come from the
/// server catalogue (`/radar/hot/sources`); anything unknown is pruned when the
/// catalogue arrives, so this list is a starting point rather than a contract.
const radarDefaultHotSources = <String>[
  'zhihu',
  'weibo',
  'douyin',
  'tieba',
  'toutiao',
  'thepaper',
  'bilibili-hot-search',
  'baidu',
];

/// One-time aliases from the old briefing platforms to hot-list boards.
const radarLegacyHotAliases = <String, String>{'bili': 'bilibili-hot-search', 'xhs': 'douyin'};

/// Persisted, per-phone radar choices. [selected] is also pushed to the
/// server's /radar/config; [followed] and [hotSources] are purely local.
class RadarPrefs {
  const RadarPrefs({required this.selected, required this.followed, this.hotSources = radarDefaultHotSources});

  static const defaults = RadarPrefs(selected: radarAvailablePlatforms, followed: <String>[]);

  final List<String> selected;
  final List<String> followed;

  /// Boards the user starred on the hot-list tab, in the order they added them.
  final List<String> hotSources;

  bool isSelected(String platform) => selected.contains(platform);
  bool isFollowed(String platform) => followed.contains(platform);
  bool hasHotSource(String sourceId) => hotSources.contains(sourceId);

  RadarPrefs copyWith({List<String>? selected, List<String>? followed, List<String>? hotSources}) => RadarPrefs(
    selected: List.unmodifiable(selected ?? this.selected),
    followed: List.unmodifiable(followed ?? this.followed),
    hotSources: List.unmodifiable(hotSources ?? this.hotSources),
  );
}

/// A single source of truth that works with or without a ProviderScope: the
/// radar page, the platform sheet and the settings sheet all listen here.
class RadarPrefsStore extends ValueNotifier<RadarPrefs> {
  RadarPrefsStore() : super(RadarPrefs.defaults);

  static const selectedKey = 'radar.selectedPlatforms';
  static const followedKey = 'radar.followedPlatforms';
  static const hotKey = 'radar.hotSources';

  bool _loaded = false;
  Future<void>? _loading;

  List<String> _clean(Object? raw) {
    if (raw is! List) return <String>[];
    final kept = <String>[];
    for (final value in raw) {
      if (value is String && radarAvailablePlatforms.contains(value) && !kept.contains(value)) {
        kept.add(value);
      }
    }
    return kept;
  }

  /// Keeps the stored order but rewrites legacy ids and drops unknown ones.
  List<String> _cleanHot(Object? raw, {Set<String>? known}) {
    if (raw is! List) return <String>[];
    final kept = <String>[];
    for (final value in raw) {
      if (value is! String) continue;
      final id = radarLegacyHotAliases[value] ?? value;
      if (known != null && !known.contains(id)) continue;
      if (!kept.contains(id)) kept.add(id);
    }
    return kept;
  }

  Future<void> load() {
    final pending = _loading;
    if (pending != null) return pending;
    final future = _read();
    _loading = future;
    return future;
  }

  Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedSelected = prefs.getStringList(selectedKey);
      final storedFollowed = prefs.getStringList(followedKey);
      final storedHot = prefs.getStringList(hotKey);
      final selected = storedSelected == null ? radarAvailablePlatforms : _clean(storedSelected);
      final hot = storedHot == null ? radarDefaultHotSources : _cleanHot(storedHot);
      value = RadarPrefs(
        // An empty selection is rejected by the server, so never restore it.
        selected: selected.isEmpty ? radarAvailablePlatforms : selected,
        followed: storedFollowed == null ? const <String>[] : _clean(storedFollowed),
        hotSources: hot,
      );
    } catch (_) {
      // No preferences backend: defaults for this run.
    } finally {
      _loaded = true;
    }
  }

  Future<void> _write(List<String> selected, List<String> followed, [List<String>? hotSources]) async {
    final hot = hotSources ?? value.hotSources;
    value = RadarPrefs(selected: selected, followed: followed, hotSources: hot);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(selectedKey, selected);
      await prefs.setStringList(followedKey, followed);
      await prefs.setStringList(hotKey, hot);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> setSelected(List<String> platforms) async {
    if (!_loaded) await load();
    final kept = _clean(platforms);
    if (kept.isEmpty) return;
    final ordered = [
      for (final id in radarAvailablePlatforms)
        if (kept.contains(id)) id,
    ];
    await _write(ordered, [
      for (final id in value.followed)
        if (ordered.contains(id)) id,
    ]);
  }

  Future<void> setFollowed(List<String> platforms) async {
    if (!_loaded) await load();
    await _write(value.selected, _clean(platforms));
  }

  Future<void> toggleSelected(String platform) async {
    final next = [...value.selected];
    if (!next.remove(platform)) {
      next.add(platform);
    } else if (next.isEmpty) {
      return;
    }
    await setSelected(next);
  }

  Future<void> toggleFollowed(String platform) async {
    final next = [...value.followed];
    if (!next.remove(platform)) next.add(platform);
    await setFollowed(next);
  }

  /// Add or remove one board from the hot-list tab.
  Future<bool> toggleHotSource(String sourceId) async {
    if (!_loaded) await load();
    final next = [...value.hotSources];
    final added = !next.remove(sourceId);
    if (added) next.add(sourceId);
    await setHotSources(next);
    return added;
  }

  Future<void> setHotSources(List<String> sourceIds) async {
    if (!_loaded) await load();
    await _write(value.selected, value.followed, List<String>.from(sourceIds));
  }

  /// 拖拽排序：顺序就是「全部来源」里各榜单的先后。
  ///
  /// [newIndex] 是 ReorderableListView 给的「移除之前」的插入位，所以往下挪时
  /// 要减一，否则会多挪一格。
  Future<void> reorderHotSources(int oldIndex, int newIndex) async {
    if (!_loaded) await load();
    final next = List<String>.from(value.hotSources);
    if (oldIndex < 0 || oldIndex >= next.length) return;
    final target = (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, next.length - 1);
    if (target == oldIndex) return;
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);
    await setHotSources(next);
  }

  /// Called once the server catalogue is in hand: drop ids this server does not
  /// serve (e.g. after an upgrade) and keep the rest in the user's own order.
  Future<void> adoptHotCatalog(List<String> knownIds) async {
    if (!_loaded) await load();
    final known = knownIds.toSet();
    final kept = _cleanHot(value.hotSources, known: known);
    if (kept.length == value.hotSources.length) return;
    final fallback = [
      for (final id in radarDefaultHotSources)
        if (known.contains(id)) id,
    ];
    await setHotSources(kept.isEmpty ? fallback : kept);
  }
}

final radarPrefs = RadarPrefsStore();

/// Whether the radar fetches anything on its own when the app starts or comes
/// back to the foreground. Off by default: an automatic digest/hot-list fetch
/// on every cold start makes the app feel slow, and the radar page still has a
/// manual refresh button. Turning this on restores the old auto-refresh.
class RadarAutoRefreshStore extends ValueNotifier<bool> {
  RadarAutoRefreshStore() : super(false);

  static const key = 'radar.autoRefreshOnLaunch';

  Future<void>? _loading;

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      value = prefs.getBool(key) ?? false;
    } on Object {
      value = false;
    }
  }

  Future<void> set(bool enabled) async {
    value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, enabled);
    } on Object {
      // Kept for this run only.
    }
  }
}

final radarAutoRefresh = RadarAutoRefreshStore();
