import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/radar/radar_client.dart';
import '../ui/radar/radar_daily_api.dart';
import 'usage_state.dart';

/// 把每个会话新增的 token 增量报给雷达服务器，按天/终端/后端/模型聚合。
///
/// 只报**本进程观察到的增量**：首个快照只记基线，不上传，避免每次启动把
/// 会话累计值重复记一遍。服务端失败不影响聊天，下一次增量继续尝试。
class UsageReporter {
  UsageReporter._();

  static final UsageReporter instance = UsageReporter._();

  final Map<String, _Checkpoint> _seen = {};
  final Map<String, List<RadarUsageRecord>> _pending = {};
  final Map<String, Timer> _timers = {};

  @visibleForTesting
  Future<void> flush() async {
    final batches = Map.of(_pending);
    _pending.clear();
    for (final batch in batches.values) {
      await _send(batch);
    }
  }

  Future<void> observe({
    required String sessionId,
    required SessionUsage usage,
    required String device,
    required String backend,
    required String model,
    DateTime? sessionCreatedAt,
  }) async {
    final now = _Checkpoint(
      input: usage.uncachedInput,
      output: usage.output,
      cacheRead: usage.cacheRead,
      cacheWrite: usage.cacheWrite,
      turns: usage.turns ?? 0,
    );
    final key = 'radar.usage.checkpoint.v2.$sessionId';
    final prefs = await SharedPreferences.getInstance();
    final previous = _seen[sessionId] ?? _Checkpoint.decode(prefs.getString(key));
    // 会话头还没加载出来时先不立基线：等 createdAt 到了再决定是否导入，
    // 否则会把老会话的历史量误记到今天。
    if (previous == null && sessionCreatedAt == null) return;
    _seen[sessionId] = now;
    await prefs.setString(key, now.encode());
    final day = _day(DateTime.now());
    // 第一次看到这个会话：只有它也是今天创建的，才把当前累计当作今天的基线。
    // 老会话不导入，否则打开一个历史对话会把过去几天的量算到今天。
    if (previous == null) {
      if (sessionCreatedAt != null && _day(sessionCreatedAt) == day) {
        _enqueue(day, now, device: device, backend: backend, model: model);
      }
      return;
    }
    final delta = now.minus(previous);
    if (delta.isEmpty) return;
    _enqueue(day, delta, device: device, backend: backend, model: model);
  }

  void _enqueue(
    String day,
    _Checkpoint delta, {
    required String device,
    required String backend,
    required String model,
  }) {
    (_pending[day] ??= []).add(
      RadarUsageRecord(
        day: day,
        device: device,
        backend: backend,
        model: model,
        input: delta.input,
        output: delta.output,
        cacheRead: delta.cacheRead,
        cacheWrite: delta.cacheWrite,
        turns: delta.turns,
      ),
    );
    _timers[day]?.cancel();
    _timers[day] = Timer(const Duration(seconds: 4), () {
      final batch = _pending.remove(day);
      _timers.remove(day);
      if (batch != null) unawaited(_send(batch));
    });
  }

  Future<void> _send(List<RadarUsageRecord> records) async {
    if (records.isEmpty) return;
    try {
      final client = await RadarClient.saved();
      await RadarDailyApi(client).sendUsage(records);
    } catch (error) {
      debugPrint('usage report failed: $error');
    }
  }

  static String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

class _Checkpoint {
  const _Checkpoint({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    required this.turns,
  });

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int turns;

  _Checkpoint minus(_Checkpoint other) => _Checkpoint(
    input: (input - other.input).clamp(0, 1 << 40),
    output: (output - other.output).clamp(0, 1 << 40),
    cacheRead: (cacheRead - other.cacheRead).clamp(0, 1 << 40),
    cacheWrite: (cacheWrite - other.cacheWrite).clamp(0, 1 << 40),
    turns: (turns - other.turns).clamp(0, 1 << 40),
  );

  bool get isEmpty => input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && turns == 0;

  String encode() => '$input,$output,$cacheRead,$cacheWrite,$turns';

  static _Checkpoint? decode(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(',');
    if (parts.length != 5) return null;
    final values = [for (final part in parts) int.tryParse(part) ?? 0];
    return _Checkpoint(
      input: values[0],
      output: values[1],
      cacheRead: values[2],
      cacheWrite: values[3],
      turns: values[4],
    );
  }
}
