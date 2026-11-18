import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话列表的本地快照：冷启动先摆上次的行，再让网络列表整块替换。
///
/// 只存 `SessionSummary.raw`（服务端返回的字段），按机器分开，最多 40 条；
/// 写盘失败不影响使用，网络永远是真值。
class SessionListCache {
  SessionListCache._();

  static const _prefix = 'session_list_cache_v1.';
  static const _max = 40;

  static final _memo = <String, List<SessionSummary>>{};

  static Future<List<SessionSummary>> read(String hostId) async {
    final hit = _memo[hostId];
    if (hit != null) return hit;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$hostId');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final rows = <SessionSummary>[
        for (final item in decoded)
          if (item is Map)
            SessionSummary.fromJson(item),
      ].where((row) => row.sessionId.isNotEmpty && !row.isSubagent).toList();
      _memo[hostId] = rows;
      return rows;
    } on Object {
      return const [];
    }
  }

  static Future<void> write(String hostId, List<SessionSummary> rows) async {
    final keep = rows.where((row) => row.sessionId.isNotEmpty && !row.isSubagent).take(_max).toList();
    _memo[hostId] = keep;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_prefix$hostId',
        jsonEncode([for (final row in keep) row.raw]),
      );
    } on Object {
      // 缓存写失败只是下次冷启动慢一点。
    }
  }
}
