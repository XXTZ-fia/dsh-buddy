import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'radar_daily_api.dart';
import 'radar_hot_api.dart';

/// 雷达每日总结的首屏快照：按服务器 + 日期存一份，先画出来再让网络覆盖。
///
/// 只存展示用的摘要、正文和用量，不含令牌；服务器地址只做缓存键，不写进内容。
class RadarSnapshotCache {
  RadarSnapshotCache._();

  static const _prefix = 'radar.daily.snapshot.v1.';
  static const _keepDays = 3;

  static String _key(String origin, String day) => '$_prefix${base64Url.encode(utf8.encode(origin))}::$day';

  static Future<RadarDaily?> readDaily(String origin, String day) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(origin, day));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return RadarDaily.fromJson(decoded);
    } on Object {
      return null;
    }
  }

  static const _hotPrefix = 'radar.hot.snapshot.v1.';

  static String _hotKey(String origin) => '$_hotPrefix${base64Url.encode(utf8.encode(origin))}';

  static Future<({RadarHotCatalog catalog, List<RadarHotFeed> feeds, DateTime at})?> readHot(String origin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_hotKey(origin));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final catalogRaw = decoded['catalog'];
      final feedsRaw = decoded['feeds'];
      if (catalogRaw is! Map || feedsRaw is! List) return null;
      return (
        catalog: RadarHotCatalog(
          sources: [
            for (final item in catalogRaw['sources'] as List? ?? const [])
              if (item is Map<String, dynamic>) RadarHotSource.fromJson(item),
          ],
          columns: [
            for (final item in catalogRaw['columns'] as List? ?? const [])
              if (item is Map<String, dynamic>) ('${item['id']}', '${item['label']}'),
          ],
        ),
        feeds: [
          for (final item in feedsRaw)
            if (item is Map<String, dynamic>) RadarHotFeed.fromJson(item),
        ],
        at: DateTime.tryParse('${decoded['at']}') ?? DateTime.now(),
      );
    } on Object {
      return null;
    }
  }

  static Future<void> writeHot(String origin, RadarHotCatalog catalog, List<RadarHotFeed> feeds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _hotKey(origin),
        jsonEncode({'at': DateTime.now().toIso8601String(), 'catalog': catalog.toJson(), 'feeds': [for (final feed in feeds) feed.toJson()]}),
      );
    } on Object {
      // 快照失败不影响正常请求。
    }
  }

  static Future<void> writeDaily(String origin, RadarDaily daily) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(origin, daily.date);
      await prefs.setString(key, jsonEncode(daily.toJson()));
      // 只保留近几天，避免按日期无限增长。
      final all = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      if (all.length > _keepDays * 4) {
        for (final stale in all.take(all.length - _keepDays * 4)) {
          await prefs.remove(stale);
        }
      }
    } on Object {
      // 快照写失败不影响正常请求。
    }
  }
}
