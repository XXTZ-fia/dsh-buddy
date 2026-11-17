import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Deep links for the boards whose URLs carry an id the native app accepts.
///
/// Only transforms we can state from the public URL shape are listed here; a
/// source with no rule falls back to its catalogue scheme (open the app) and
/// then to the browser, so tapping a row never dead-ends.
String? appLinkFor(String sourceId, String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final segments = uri.pathSegments;
  String after(String key) {
    final index = segments.indexOf(key);
    return index >= 0 && index + 1 < segments.length ? segments[index + 1] : '';
  }

  switch (sourceId) {
    case 'bilibili-hot-video':
    case 'bilibili-ranking':
      final bvid = segments.isEmpty ? '' : segments.last;
      return bvid.startsWith('BV') ? 'bilibili://video/$bvid' : null;
    case 'zhihu':
      final answer = after('answer');
      if (answer.isNotEmpty) return 'zhihu://answers/$answer';
      final question = after('question');
      return question.isEmpty ? null : 'zhihu://questions/$question';
    case 'douyin':
      final aweme = after('video');
      return aweme.isEmpty ? null : 'snssdk1128://aweme/detail/$aweme';
    case 'weibo':
      final detail = after('detail');
      if (detail.isNotEmpty) return 'sinaweibo://detail?mblogid=$detail';
      return null;
    case 'tieba':
      final tid = after('p');
      return tid.isEmpty ? null : 'com.baidu.tieba://thread?tid=$tid';
    case 'steam':
      return 'steam://openurl/${Uri.encodeComponent(url)}';
    case 'xueqiu-hotstock':
      final symbol = segments.length >= 2 && segments.first == 'S' ? segments[1] : '';
      return symbol.isEmpty ? null : 'xueqiu://stock/$symbol';
    default:
      return null;
  }
}

/// Query parameters the boards use for the word a row stands for.
const _keywordParams = ['keyword', 'q', 'wd', 'word', 'searchKey', 'searchWord'];

/// The search word a row's URL carries, or '' when it only has an id.
String keywordOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '';
  for (final key in _keywordParams) {
    final value = uri.queryParameters[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return '';
}

/// The App's own search screen for a board that only knows a search word.
///
/// 热搜 / 热点 / 话题类条目本身就是「一个词」而不是「一条内容」：它们的 URL 是
/// 搜索结果页，拿不到内容 id，条目级深链在这些源上根本不存在。这里给的是各 App
/// 的搜索入口，落到「搜到的那一屏」而不是「那一条」。
///
/// 唤不起来的候选会由 [hotLinkCandidates] 的循环跳过，点按不会因此失败。
String? appSearchLinkFor(String sourceId, String keyword) {
  final word = keyword.trim();
  if (word.isEmpty) return null;
  final q = Uri.encodeComponent(word);
  switch (sourceId) {
    case 'bilibili-hot-search':
      return 'bilibili://search?keyword=$q';
    case 'weibo':
      // 综合搜索容器 100103 是 s.weibo.com/weibo?q= 网页对应的那一屏。
      return 'sinaweibo://searchall?containerid=100103type%3D1%26q%3D$q';
    case 'douyin':
      return 'snssdk1128://search?keyword=$q';
    case 'tieba':
      return 'com.baidu.tieba://search?word=$q';
    case 'toutiao':
      return 'snssdk143://search?keyword=$q';
    case 'kuaishou':
      return 'kwai://search?keyword=$q';
    case 'baidu':
      return 'baiduboxapp://search?word=$q';
    case 'zhihu':
      return 'zhihu://search?q=$q';
    default:
      return null;
  }
}

/// Every way to open one row, most precise first: the item inside its App, the
/// App's search for a word-only board, the App itself, then the page.
///
/// [keyword] is the row's title; a URL that carries its own search word wins
/// over it, because the title has been trimmed for display.
List<String> hotLinkCandidates({
  required String sourceId,
  required String itemUrl,
  String scheme = '',
  String keyword = '',
}) {
  final own = keywordOf(itemUrl);
  final word = own.isNotEmpty ? own : keyword;
  final candidates = <String>[
    ?appLinkFor(sourceId, itemUrl),
    ?appSearchLinkFor(sourceId, word),
    if (scheme.isNotEmpty) scheme,
    itemUrl,
  ];
  // 目录里的 scheme 可能和搜索入口撞上（或本就是 https），同一个链接只留一次。
  return <String>{for (final link in candidates) if (link.isNotEmpty) link}.toList();
}

/// Tap behaviour: item deep link → App search → source scheme → https. Returns
/// the link that actually opened, or null when every attempt failed.
Future<String?> openHotLink({
  required String sourceId,
  required String itemUrl,
  String scheme = '',
  String keyword = '',
}) async {
  // 同一个链接试两次没有意义：目录里的 scheme 可能和搜索入口撞上。
  final tried = <String>{};
  for (final candidate in hotLinkCandidates(
    sourceId: sourceId,
    itemUrl: itemUrl,
    scheme: scheme,
    keyword: keyword,
  )) {
    if (!tried.add(candidate)) continue;
    final uri = Uri.tryParse(candidate);
    if (uri == null) continue;
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return candidate;
    } on Object catch (error) {
      // 没装对应 App 时插件会抛 PlatformException，继续试下一个候选。
      if (kDebugMode) debugPrint('open $candidate failed: $error');
    }
  }
  return null;
}
