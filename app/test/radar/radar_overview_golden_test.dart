import 'package:dsh_app/ui/radar/radar_digest_view.dart';
import 'package:dsh_app/ui/radar/radar_hot_api.dart';
import 'package:dsh_app/ui/radar/radar_papers_api.dart';
import 'package:dsh_app/ui/radar/radar_papers_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

/// 概览页的版式基线：一条共识话题，含展开后的来源名。
///
/// 这里只画视图本身，控制器直接塞数据，不走网络——目的是锁住版式，
/// 尤其是「来源名」这一列的对齐。
RadarDigestTopic _topic() => const RadarDigestTopic(
  title: 'APEC 中国时间｜对话俄罗斯学者：中俄美元首会晤',
  note: '今日头条、百度热搜、哔哩哔哩、微博',
  sources: ['toutiao', 'baidu', 'bilibili-hot-search', 'weibo'],
  outlets: 4,
  count: 14,
  items: [
    RadarDigestItem(
      title: '外交部谈中俄美元首会晤',
      url: 'https://example.invalid/1',
      source: 'bilibili-hot-search',
      sourceName: '哔哩哔哩',
    ),
    RadarDigestItem(
      title: '中俄美元首将在深圳举行会晤，有哪些信息值得关注？',
      url: 'https://example.invalid/2',
      source: 'zhihu',
      sourceName: '知乎',
    ),
    RadarDigestItem(
      title: '中俄美元首会晤将在深圳举行',
      url: 'https://example.invalid/3',
      source: 'weibo',
      sourceName: '微博',
    ),
  ],
);

RadarDigest _digest() => RadarDigest(
  generatedAt: '2026-11-16T09:00:00Z',
  model: 'deepseek-chat',
  sources: 47,
  scanned: 1139,
  topics: [_topic()],
);

Widget _digestView() => Scaffold(
  body: SingleChildScrollView(
    child: RadarDigestView(
      controller: RadarDigestController()..digest = _digest(),
      catalog: null,
      onOpen: (_) async {},
      onRefresh: () async {},
    ),
  ),
);

/// 首页那一节：标题与摘要都走服务端译文，右下角留「原文」的切换。
RadarPaper _paper(int index) => RadarPaper(
  id: '2601.0000$index',
  title: 'SparseRead: Token-Efficient Sparse Reading of External Content for AI Agents',
  titleZh: 'SparseRead：给 AI 智能体做省令牌的稀疏阅读',
  abstract:
      'We propose a sparse reading layer that gates external content before it reaches the model, '
      'cutting prompt tokens by up to 92.9% without retraining.',
  abstractZh:
      '我们提出了一层稀疏阅读：在外部内容进入模型之前先做准入控制，无需重训即可把提示词令牌量'
      '最多压掉 92.9%。关键在于把「读什么」从读取阶段前移到筛选阶段。',
  authors: const ['Wei Zhang', 'Mia Chen'],
  url: 'https://example.invalid/p1',
  pdfUrl: 'https://example.invalid/p1.pdf',
  source: 'both',
  publishedAt: '2026-11-15T00:00:00Z',
  upvotes: 138,
  matched: const ['agent', 'rag'],
);

Widget _papers() => Scaffold(
  body: SingleChildScrollView(
    child: RadarPapersSection(
      controller: RadarPapersController()
        ..data = RadarPapers(
          generatedAt: '2026-11-16T09:00:00Z',
          interests: const ['agent', 'rag', 'efficient inference'],
          sources: const [
            RadarPaperSourceStatus(
              source: 'hf',
              label: 'Hugging Face Daily',
              status: 'fresh',
              count: 100,
              fetchedAt: '2026-11-16T09:00:00Z',
            ),
            RadarPaperSourceStatus(
              source: 'arxiv',
              label: 'arXiv',
              status: 'fresh',
              count: 60,
              fetchedAt: '2026-11-16T09:00:00Z',
            ),
          ],
          items: [_paper(1), _paper(2)],
        ),
      onRetry: () {},
    ),
  ),
);

void main() {
  goldenBoth('radar_overview', _digestView);

  // 展开态单独锁一张：这一屏就是「展开后不知道哪条是哪家的」那个问题，
  // 来源名占一列之后要保证标题仍然对齐、长名字不挤掉标题。
  goldenBoth(
    'radar_overview_expanded',
    _digestView,
    before: (tester) async {
      await tester.tap(find.textContaining('APEC 中国时间'));
      await tester.pumpAndSettle();
    },
  );

  // 论文一节：中文标题 + 中文摘要 + 「展开摘要 / 原文」两条操作，
  // 长标题与两行摘要都不能溢出。
  goldenBoth('radar_papers_section', _papers);
}
