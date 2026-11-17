import 'package:dsh_app/ui/radar/radar_visuals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('heat and delta are compact and keep their sign', () {
    expect(formatHeat(492937), '49.3万');
    expect(formatHeat(7732463), '773.2万');
    expect(formatHeat(120000000), '1.2亿');
    expect(formatHeat(0), '');
    expect(formatHeat(null), '');
    expect(formatDelta(936875), '+93.7万');
    expect(formatDelta('-6302651'), '-630.3万');
    expect(formatDelta('0'), '');
    expect(formatDelta(null), '');
  });

  test('relative time and freshness use the local clock', () {
    final now = DateTime(2026, 11, 14, 16, 0);
    final iso = DateTime(2026, 11, 14, 15, 40).toUtc().toIso8601String();
    expect(formatRelative(iso, now: now), '20 分钟前');
    expect(formatFreshness(iso, now: now), '20 分钟前更新');
    expect(formatRelative(null), '');
    expect(formatFreshness(null), '');
  });

  test('source metadata covers every platform the app filters on', () {
    for (final platform in radarPlatformOrder) {
      expect(radarSources.containsKey(platform), isTrue, reason: platform);
    }
    expect(sourceMeta('unknown').name, '其他');
  });

  test('zhihu and x are gone from the source list', () {
    expect(radarPlatformOrder, isNot(contains('zhihu')));
    expect(radarPlatformOrder, isNot(contains('x')));
    expect(radarSources.containsKey('zhihu'), isFalse);
    expect(radarSources.containsKey('x'), isFalse);
  });
}
