import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/personal_server.dart';
import 'package:dsh_app/ui/radar/radar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

const _hotCatalog = <Map<String, String>>[
  {'id': 'zhihu', 'name': '知乎', 'title': '', 'column': 'china'},
  {'id': 'weibo', 'name': '微博', 'title': '实时热搜', 'column': 'china'},
  {'id': 'douyin', 'name': '抖音', 'title': '', 'column': 'china'},
  {'id': 'tieba', 'name': '百度贴吧', 'title': '热议', 'column': 'china'},
  {'id': 'toutiao', 'name': '今日头条', 'title': '', 'column': 'china'},
  {'id': 'thepaper', 'name': '澎湃新闻', 'title': '热榜', 'column': 'china'},
  {'id': 'bilibili-hot-search', 'name': '哔哩哔哩', 'title': '热搜', 'column': 'china'},
  {'id': 'baidu', 'name': '百度热搜', 'title': '', 'column': 'china'},
];

Map<String, dynamic> _hotFeed(String id) {
  final source = _hotCatalog.firstWhere((row) => row['id'] == id);
  return {
    'source': id,
    'name': source['name'],
    'title': source['title'],
    'column': source['column'],
    'home': 'https://example.invalid',
    'scheme': '',
    'status': 'ok',
    'origin': 'native',
    'updated_at': DateTime.now().toUtc().toIso8601String(),
    'items': [
      {
        'rank': 1,
        'title': '${source['name']} 热榜第一条',
        'url': 'https://example.invalid/1',
        'extra': '100 万',
        'time': '',
      },
      {
        'rank': 2,
        'title': '${source['name']} 热榜第二条',
        'url': 'https://example.invalid/2',
        'extra': '',
        'time': '',
      },
    ],
  };
}

/// 六平台简报：服务端采集并摘要后的快照，带已读标记。
Map<String, dynamic> _brief() => {
  'generated_at': DateTime.now().toUtc().toIso8601String(),
  'health': [
    {'platform': 'douyin', 'status': 'ok', 'checked_at': '', 'note': '采集 20 条'},
    {'platform': 'x', 'status': 'unavailable', 'checked_at': '', 'note': '本轮未启用'},
  ],
  'items': [
    {
      'id': 'douyin:a',
      'platform': 'douyin',
      'title': '国足对阵马来西亚门票售罄',
      'summary': '门票在开售三分钟后售罄，主办方加开看台。',
      'why': '按热度与兴趣词入选',
      'url': 'https://example.invalid/a',
      'author': '',
      'published_at': DateTime.now().toUtc().toIso8601String(),
      'heat': {'value': 8027417, 'delta': '+12%'},
      'cross_platform': ['douyin', 'weibo', 'baidu'],
      'read': false,
    },
    {
      'id': 'weibo:b',
      'platform': 'weibo',
      'title': '新能源补贴退坡',
      'summary': '补贴退坡首日，多家车企宣布限时保价。',
      'why': '按热度与兴趣词入选',
      'url': 'https://example.invalid/b',
      'author': '',
      'published_at': DateTime.now().toUtc().toIso8601String(),
      'heat': {'value': 3027417, 'delta': '-3%'},
      'cross_platform': ['weibo'],
      'read': true,
    },
  ],
};

/// 跨源共识：两个来源同时在讲同一件事。
Map<String, dynamic> _digest() => {
  'generated_at': DateTime.now().toUtc().toIso8601String(),
  'model': '',
  'sources': 8,
  'scanned': 160,
  'topics': [
    {
      'title': '国足对阵马来西亚',
      'note': '百度热搜、抖音',
      'sources': ['baidu', 'douyin'],
      'outlets': 2,
      'count': 3,
      'items': [
        {
          'title': '国足vs马来西亚 门票售罄',
          'url': 'https://example.invalid/a',
          'source': 'douyin',
          'source_name': '抖音',
        },
        {
          'title': '国足比赛门票售罄',
          'url': 'https://example.invalid/b',
          'source': 'baidu',
          'source_name': '百度热搜',
        },
      ],
    },
    {
      'title': '英伟达财报登场',
      'note': '微博',
      'sources': ['weibo'],
      'outlets': 1,
      'count': 2,
      'items': [
        {'title': '英伟达财报登场', 'url': 'https://example.invalid/c', 'source': 'weibo'},
      ],
    },
  ],
};

/// 论文一节的桩：标题与摘要都带服务端译文，用来验证首页显示中文。
Map<String, dynamic> _papers() => {
  'generated_at': DateTime.now().toUtc().toIso8601String(),
  'interests': ['agent'],
  'translation': {'engine': 'mt', 'translated': 1},
  'sources': [
    {
      'source': 'hf',
      'label': 'Hugging Face Daily',
      'status': 'fresh',
      'count': 100,
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
    },
  ],
  'items': [
    {
      'id': '2601.00001',
      'title': 'SparseRead: Token-Efficient Sparse Reading of External Content',
      'title_zh': 'SparseRead：省令牌的稀疏阅读',
      'abstract': 'We propose a sparse reading layer that gates external content.',
      'abstract_zh': '我们提出了一层稀疏阅读，在内容进入模型之前先做准入控制。',
      'authors': ['Wei Zhang'],
      'url': 'https://example.invalid/p1',
      'pdf_url': '',
      'source': 'both',
      'published_at': '2026-11-15',
      'upvotes': 138,
      'matched': ['agent'],
    },
  ],
};

MockClient _api() => MockClient((request) async {
  final body = switch (request.url.path) {
    '/radar/hot/sources' => jsonEncode({
      'columns': [
        {'id': 'china', 'label': '国内'},
      ],
      'sources': [
        for (final row in _hotCatalog)
          {
            ...row,
            'column_label': '国内',
            'home': 'https://example.invalid',
            'scheme': '',
            'native': row['id'] != 'baidu',
          },
      ],
    }),
    '/radar/hot/boards' => jsonEncode({
      'feeds': [
        for (final id in (request.url.queryParameters['sources'] ?? '').split(','))
          if (id.isNotEmpty) _hotFeed(id),
      ],
    }),
    '/radar/hot/digest' => jsonEncode(_digest()),
    '/radar/items' => jsonEncode(_brief()),
    '/radar/papers' => jsonEncode(_papers()),
    _ => '{}',
  };
  return http.Response(body, 200, headers: {'content-type': 'application/json'});
});

void _mockStorage({bool signedIn = true}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    _channel,
    (call) async {
      if (call.method == 'read' && signedIn) {
        final args = call.arguments as Map?;
        if (args?['key'] == radarConnectionKey) {
          return jsonEncode({'url': 'https://radar.example.com', 'token': 'test-token'});
        }
      }
      return null;
    },
  );
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  locale: const Locale('en'),
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );

  testWidgets('the brief tab shows collected items with their read state', (tester) async {
    _mockStorage();
    await tester.pumpWidget(_app(RadarPage(transport: _api())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Brief'));
    await tester.pumpAndSettle();

    expect(find.text('国足对阵马来西亚门票售罄'), findsOneWidget);
    expect(find.text('新能源补贴退坡'), findsOneWidget);
    // 两条里只有第一条未读。
    expect(find.text('1 unread'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    // 跨源共识：第一条还与另外两家同报。
    expect(find.text('2 more outlets'), findsOneWidget);
    // 来源健康：抖音在采、X 本轮未启用。
    expect(find.text('抖音 OK'), findsOneWidget);
    expect(find.text('X Off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved sign-in restores the hot board', (tester) async {
    _mockStorage();
    await tester.pumpWidget(_app(RadarPage(transport: _api())));
    await tester.pumpAndSettle();

    expect(find.text('Information radar'), findsOneWidget);
    expect(find.text('Hot lists'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('All sources'), findsOneWidget);
    expect(find.text('知乎 热榜第一条'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);

    // 论文和各个来源在切换条里是平级的，不再单独占榜单上面那一块。
    expect(find.text('SparseRead：省令牌的稀疏阅读'), findsNothing);

    // 8 个来源是懒加载的卡片列表，第二个来源要滚动才进视口。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(find.text('抖音 热榜第一条'), findsOneWidget);
    // 切换条吸顶：翻到下面也能直接换信源，不用先滚回顶部。
    expect(find.text('All sources'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the papers tab sits beside the sources', (tester) async {
    _mockStorage();
    await tester.pumpWidget(_app(RadarPage(transport: _api())));
    await tester.pumpAndSettle();

    // 切换条上「论文」与「全部来源」并列。
    expect(find.text('Papers'), findsOneWidget);
    await tester.tap(find.text('Papers'));
    await tester.pumpAndSettle();

    // 选中后整屏就是论文，标题与摘要都用服务端给的中文。
    expect(find.text('SparseRead：省令牌的稀疏阅读'), findsOneWidget);
    expect(find.textContaining('准入控制'), findsOneWidget);
    expect(find.text('知乎 热榜第一条'), findsNothing);
    // 还能切回全部来源。
    await tester.tap(find.text('All sources'));
    await tester.pumpAndSettle();
    expect(find.text('知乎 热榜第一条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking one source shows just that board', (tester) async {
    _mockStorage();
    await tester.pumpWidget(_app(RadarPage(transport: _api())));
    await tester.pumpAndSettle();

    // 切换条上的「知乎」（榜单卡片里也有同名标题，取先渲染的那个）。
    await tester.tap(find.text('知乎').first);
    await tester.pumpAndSettle();

    // 只看一家：这一屏就是这份榜单本身，没有论文卡片，切换条还在。
    expect(find.text('SparseRead：省令牌的稀疏阅读'), findsNothing);
    expect(find.text('知乎 热榜第一条'), findsOneWidget);
    expect(find.text('All sources'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('consensus tab shows cross-source topics', (tester) async {
    _mockStorage();
    await tester.pumpWidget(_app(RadarPage(transport: _api())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();

    expect(find.text('国足对阵马来西亚'), findsWidgets);
    expect(find.text('2 outlets'), findsOneWidget);
    expect(find.text('rule-based'), findsOneWidget);
    // 展开话题能看到它背后的热榜条目。
    await tester.tap(find.text('国足对阵马来西亚'));
    await tester.pumpAndSettle();
    expect(find.text('Matching hot items'), findsWidgets);
    // 展开后每条都带来源名，不再只有一颗说不出是谁的色点。
    expect(find.text('抖音'), findsWidgets);
    expect(find.text('百度热搜'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without credentials the connect card is shown', (tester) async {
    _mockStorage(signedIn: false);
    await tester.pumpWidget(_app(RadarPage(transport: _api())));
    await tester.pumpAndSettle();

    expect(find.text('Connect and refresh'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
