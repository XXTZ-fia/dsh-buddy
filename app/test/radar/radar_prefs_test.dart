import 'package:dsh_app/state/radar_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults select every available platform and follow none', () async {
    final store = RadarPrefsStore();
    await store.load();
    expect(store.value.selected, radarAvailablePlatforms);
    expect(store.value.followed, isEmpty);
  });

  test('selection drops removed platforms and never goes empty', () async {
    final store = RadarPrefsStore();
    await store.load();
    await store.setSelected(['bili', 'zhihu', 'x']);
    expect(store.value.selected, ['bili']);
    await store.toggleSelected('bili');
    expect(store.value.selected, ['bili'], reason: 'the last platform stays');
  });

  test('removing a platform also unfollows it', () async {
    final store = RadarPrefsStore();
    await store.load();
    await store.toggleFollowed('weibo');
    expect(store.value.isFollowed('weibo'), isTrue);
    await store.setSelected(['douyin', 'bili']);
    expect(store.value.isFollowed('weibo'), isFalse);
  });

  test('selection keeps the canonical platform order', () async {
    final store = RadarPrefsStore();
    await store.load();
    await store.setSelected(['xhs', 'douyin']);
    expect(store.value.selected, ['douyin', 'xhs']);
  });

  test('choices persist across store instances', () async {
    final first = RadarPrefsStore();
    await first.load();
    await first.setSelected(['xhs']);
    await first.toggleFollowed('xhs');
    final second = RadarPrefsStore();
    await second.load();
    expect(second.value.selected, ['xhs']);
    expect(second.value.followed, ['xhs']);
  });

  test('reordering boards keeps every id and saves the new order', () async {
    SharedPreferences.setMockInitialValues({});
    final store = RadarPrefsStore();
    await store.load();
    await store.setHotSources(['a', 'b', 'c']);

    // ReorderableListView 的语义：往下挪时 newIndex 是「移除前」的插入位。
    await store.reorderHotSources(0, 3);
    expect(store.value.hotSources, ['b', 'c', 'a']);

    await store.reorderHotSources(2, 0);
    expect(store.value.hotSources, ['a', 'b', 'c']);

    // 落盘了：新实例读到的是同一顺序。
    final again = RadarPrefsStore();
    await again.load();
    expect(again.value.hotSources, ['a', 'b', 'c']);
  });
}
