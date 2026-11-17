import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 信息雷达是**可选功能**：默认关闭。
///
/// 关闭时：底部不出现「信息雷达」页签、自动化页不出现服务/运行/收件箱入口、
/// 设置里不出现雷达连接与自动刷新项、后台不轮询 `/events`，也不接受雷达通知点击。
/// 开启后才会出现上述入口，并在连接卡片里给出「自建服务器」教程。
///
/// 用全局 ValueNotifier 而不是 Provider：外壳（PersonalHome）、设置页、通知宿主
/// 都要监听它，而外壳在 ProviderScope 之外也可能被测试直接挂载。
class RadarFeatureStore extends ValueNotifier<bool> {
  RadarFeatureStore() : super(false);

  static const key = 'radar.enabled';

  bool _loaded = false;
  Future<void>? _loading;

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      value = prefs.getBool(key) ?? false;
    } on Object {
      value = false;
    } finally {
      _loaded = true;
    }
  }

  bool get loaded => _loaded;

  Future<void> set(bool enabled) async {
    value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, enabled);
    } on Object {
      // 写不进去只影响下次启动，本次仍然生效。
    }
  }

  /// 测试专用：重置成「已加载」的确定状态，避免单例把上一个用例的值带过来。
  @visibleForTesting
  void resetForTest({bool enabled = false}) {
    _loaded = true;
    // 让下一次 load() 重新读一遍 mock 的 SharedPreferences。
    _loading = null;
    value = enabled;
  }
}

final radarFeature = RadarFeatureStore();
