import 'package:dsh_app/ui/radar/radar_brief_api.dart';
import 'package:dsh_app/ui/radar/radar_brief_view.dart';
import 'package:flutter_test/flutter_test.dart';

RadarBrief _sample() => RadarBrief.fromJson({
  'generated_at': '2026-11-17T02:00:00Z',
  'health': [
    {'platform': 'douyin', 'status': 'ok', 'checked_at': '', 'note': ''},
  ],
  'items': [
    {
      'id': 'douyin:a',
      'platform': 'douyin',
      'title': '第一条',
      'summary': '摘要',
      'why': '理由',
      'url': 'https://example.invalid/a',
      'author': '',
      'published_at': '2026-11-17T01:00:00Z',
      'heat': {'value': 8027417, 'delta': '+12%'},
      'cross_platform': ['douyin', 'weibo'],
      'read': false,
    },
    {
      'id': 'weibo:b',
      'platform': 'weibo',
      'title': '第二条',
      'summary': '',
      'why': '',
      'url': 'https://example.invalid/b',
      'author': '',
      'published_at': '2026-11-17T01:00:00Z',
      'heat': {'value': 0, 'delta': ''},
      'cross_platform': ['weibo'],
      'read': false,
    },
  ],
});

void main() {
  _summaryGuards();
  _whyGuards();

  test('markReadLocally flips one item and keeps the order', () {
    final controller = RadarBriefController()..brief = _sample();
    expect(controller.brief!.unread, 2);

    controller.markReadLocally('weibo:b');

    expect(controller.brief!.items.map((item) => item.id), ['douyin:a', 'weibo:b']);
    expect(controller.brief!.items[1].read, isTrue);
    expect(controller.brief!.items[0].read, isFalse);
    expect(controller.brief!.unread, 1);
    // 已读不该动服务端给的排序：那是最初的推荐顺序。
    expect(controller.brief!.items.first.title, '第一条');
  });

  test('a missing id is a no-op instead of an error', () {
    final controller = RadarBriefController()..brief = _sample();
    controller.markReadLocally('douyin:gone');
    expect(controller.brief!.unread, 2);
  });

  test('reset clears both the data and the paging state', () {
    final controller = RadarBriefController()..brief = _sample();
    controller.reset();
    expect(controller.brief, isNull);
    expect(controller.hasData, isFalse);
    expect(controller.canLoadMore, isFalse);
  });

  test('the item model keeps heat, cross-platform and read flag', () {
    final item = _sample().items.first;
    expect(item.heat, 8027417);
    expect(item.heatDelta, '+12%');
    expect(item.crossPlatform, ['douyin', 'weibo']);
    expect(item.read, isFalse);
    expect(item.copyWith(read: true).heat, 8027417);
  });
}

RadarBriefItem _item({required String title, required String summary}) => RadarBriefItem.fromJson({
  'id': 'douyin:x',
  'platform': 'douyin',
  'title': title,
  'summary': summary,
  'url': 'https://example.invalid/x',
  'heat': {'value': 1, 'delta': ''},
});

void _summaryGuards() {
  test('a summary that repeats the title is hidden', () {
    expect(briefSummaryOf(_item(title: '同一个标题', summary: '同一个标题')), '');
    expect(briefSummaryOf(_item(title: '同一个标题', summary: '真正的摘要')), '真正的摘要');
  });

  test('the legacy offline placeholder is hidden but a real snippet is kept', () {
    expect(briefSummaryOf(_item(title: '乙', summary: '【离线】乙（原文标题，未生成模型摘要）')), '');
    expect(briefSummaryOf(_item(title: '丙', summary: '  ')), '');
  });
}

void _whyGuards() {
  test('the offline implementation prefix is stripped for display', () {
    final withPrefix = RadarBriefItem.fromJson({
      'id': 'x',
      'platform': 'weibo',
      'title': '标题',
      'why': '离线摘要（未调用模型），按热度与兴趣词入选',
    });
    expect(briefWhyOf(withPrefix), '按热度与兴趣词入选');
    final model = RadarBriefItem.fromJson({
      'id': 'y',
      'platform': 'weibo',
      'title': '标题',
      'why': '命中「AI Agent」，今天讨论度高',
    });
    expect(briefWhyOf(model), '命中「AI Agent」，今天讨论度高');
  });
}
