import 'package:dsh_app/state/radar_prefs.dart';
import 'package:dsh_app/ui/radar/radar_hot_api.dart';
import 'package:dsh_app/ui/radar/radar_links.dart';
import 'package:dsh_app/ui/radar/radar_source_picker.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts, testApp;
import 'package:shared_preferences/shared_preferences.dart';

RadarHotSource _source(String id, String name, {String title = '', String column = 'china'}) => RadarHotSource(
  id: id,
  name: name,
  title: title,
  column: column,
  columnLabel: column == 'china' ? '国内' : '财经',
  home: 'https://example.invalid',
  scheme: '',
);

void main() {
  setUpAll(loadTestFonts);

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await radarPrefs.load();
    await radarPrefs.setHotSources(['zhihu']);
  });

  test('starring a board adds it after the existing ones', () async {
    expect(await radarPrefs.toggleHotSource('douban'), isTrue);
    expect(radarPrefs.value.hotSources, ['zhihu', 'douban']);
    expect(await radarPrefs.toggleHotSource('zhihu'), isFalse);
    expect(radarPrefs.value.hotSources, ['douban']);
  });

  test('catalogue adoption drops unknown ids and rewrites the legacy alias', () async {
    await radarPrefs.setHotSources(['bili', 'gone', 'douyin']);
    await radarPrefs.adoptHotCatalog(['bilibili-hot-search', 'douyin', 'zhihu']);
    expect(radarPrefs.value.hotSources, ['bilibili-hot-search', 'douyin']);
  });

  test('an empty selection falls back to the default boards this server serves', () async {
    await radarPrefs.setHotSources(['gone']);
    await radarPrefs.adoptHotCatalog(['zhihu', 'weibo']);
    expect(radarPrefs.value.hotSources, ['zhihu', 'weibo']);
  });

  test('deep links follow the id in the item URL', () {
    expect(
      appLinkFor('bilibili-ranking', 'https://www.bilibili.com/video/BV1xx411c7mD'),
      'bilibili://video/BV1xx411c7mD',
    );
    expect(appLinkFor('zhihu', 'https://www.zhihu.com/question/123/answer/456'), 'zhihu://answers/456');
    expect(appLinkFor('zhihu', 'https://www.zhihu.com/question/123'), 'zhihu://questions/123');
    expect(appLinkFor('tieba', 'https://tieba.baidu.com/p/8765432109'), 'com.baidu.tieba://thread?tid=8765432109');
    expect(appLinkFor('douban', 'https://movie.douban.com/subject/1/'), isNull);
    expect(
      appLinkFor('steam', 'https://store.steampowered.com/app/730/'),
      'steam://openurl/https%3A%2F%2Fstore.steampowered.com%2Fapp%2F730%2F',
    );
  });

  test('a search word is read from the row URL before the title', () {
    expect(keywordOf('https://search.bilibili.com/all?keyword=AI'), 'AI');
    expect(keywordOf('https://s.weibo.com/weibo?q=AI'), 'AI');
    expect(keywordOf('https://www.baidu.com/s?wd=AI'), 'AI');
    expect(keywordOf('https://www.douyin.com/hot/1234'), '');
    expect(keywordOf('not a url'), '');
  });

  group('word-only boards land in the App search before the browser', () {
    test('bilibili hot search', () {
      expect(
        hotLinkCandidates(
          sourceId: 'bilibili-hot-search',
          itemUrl: 'https://search.bilibili.com/all?keyword=AI',
          scheme: 'bilibili://',
        ),
        ['bilibili://search?keyword=AI', 'bilibili://', 'https://search.bilibili.com/all?keyword=AI'],
      );
    });

    test('weibo hot search', () {
      expect(
        hotLinkCandidates(
          sourceId: 'weibo',
          itemUrl: 'https://s.weibo.com/weibo?q=AI',
          scheme: 'sinaweibo://',
        ),
        [
          'sinaweibo://searchall?containerid=100103type%3D1%26q%3DAI',
          'sinaweibo://',
          'https://s.weibo.com/weibo?q=AI',
        ],
      );
    });

    test('douyin hot topic searches its own title', () {
      expect(
        hotLinkCandidates(
          sourceId: 'douyin',
          itemUrl: 'https://www.douyin.com/hot/1234',
          scheme: 'snssdk1128://',
          keyword: '某个热搜',
        ).first,
        'snssdk1128://search?keyword=%E6%9F%90%E4%B8%AA%E7%83%AD%E6%90%9C',
      );
    });

    test('tieba hot topic, toutiao and kuaishou', () {
      expect(
        hotLinkCandidates(
          sourceId: 'tieba',
          itemUrl: 'https://tieba.baidu.com/hottopic/browse/hottopic?topic_id=9',
          scheme: 'com.baidu.tieba://',
          keyword: 'AI',
        ).first,
        'com.baidu.tieba://search?word=AI',
      );
      expect(
        hotLinkCandidates(
          sourceId: 'toutiao',
          itemUrl: 'https://www.toutiao.com/trending/7000/',
          scheme: 'snssdk143://',
          keyword: 'AI',
        ).first,
        'snssdk143://search?keyword=AI',
      );
      expect(
        hotLinkCandidates(
          sourceId: 'kuaishou',
          itemUrl: 'https://www.kuaishou.com/search/video?searchKey=AI',
          scheme: 'kwai://',
        ).first,
        'kwai://search?keyword=AI',
      );
    });

    test('an item id still wins over the search screen', () {
      expect(
        hotLinkCandidates(
          sourceId: 'bilibili-ranking',
          itemUrl: 'https://www.bilibili.com/video/BV1xx411c7mD',
          scheme: 'bilibili://',
          keyword: 'ignored',
        ).first,
        'bilibili://video/BV1xx411c7mD',
      );
    });

    test('a board with no App keeps the page last, without duplicates', () {
      expect(
        hotLinkCandidates(sourceId: 'hackernews', itemUrl: 'https://news.ycombinator.com/item?id=1'),
        ['https://news.ycombinator.com/item?id=1'],
      );
      expect(
        hotLinkCandidates(
          sourceId: 'hackernews',
          itemUrl: 'https://news.ycombinator.com/item?id=1',
          scheme: 'https://news.ycombinator.com/item?id=1',
        ),
        ['https://news.ycombinator.com/item?id=1'],
      );
    });
  });

  testWidgets('the picker toggles a board and shows the running count', (tester) async {
    final catalog = RadarHotCatalog(
      sources: [
        _source('zhihu', '知乎'),
        _source('douban', '豆瓣', title: '热门电影'),
      ],
      columns: const [('china', '国内')],
    );
    await tester.pumpWidget(testApp(RadarSourcePickerPage(catalog: catalog)));
    await tester.pumpAndSettle();

    expect(find.text('1/2 已添加'), findsOneWidget);
    expect(find.byIcon(AppIcons.favoriteActive), findsOneWidget);

    await tester.tap(find.textContaining('豆瓣'));
    await tester.pumpAndSettle();
    expect(radarPrefs.value.hotSources, ['zhihu', 'douban']);
    expect(find.text('2/2 已添加'), findsOneWidget);
    expect(find.byIcon(AppIcons.favoriteActive), findsNWidgets(2));
  });

  testWidgets('search filters the picker by name and board subtitle', (tester) async {
    final catalog = RadarHotCatalog(
      sources: [
        _source('zhihu', '知乎'),
        _source('douban', '豆瓣', title: '热门电影'),
      ],
      columns: const [('china', '国内')],
    );
    await tester.pumpWidget(testApp(RadarSourcePickerPage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '电影');
    await tester.pumpAndSettle();
    expect(find.textContaining('豆瓣'), findsOneWidget);
    expect(find.textContaining('知乎'), findsNothing);
  });
}
