import 'radar_client.dart';

/// One paper from the home feed (`GET /radar/papers`).
///
/// `source` is `hf` (Hugging Face Daily), `arxiv`, or `both` when the same
/// paper appeared in both feeds. [matched] holds the interest words the server
/// found in the title or abstract, so the card can say why it is here.
class RadarPaper {
  const RadarPaper({
    required this.id,
    required this.title,
    required this.titleZh,
    required this.abstract,
    required this.abstractZh,
    required this.authors,
    required this.url,
    required this.pdfUrl,
    required this.source,
    required this.publishedAt,
    required this.upvotes,
    required this.matched,
  });

  final String id;
  final String title;

  /// 服务端译好的中文标题；为空就用英文原标题。
  final String titleZh;
  final String abstract;

  /// 服务端译好的中文摘要；为空表示没译（模型未配或翻译失败），此时看 [abstract]。
  ///
  /// 卡片默认显示它：手机上没有模型凭证，中文只能由服务端提前译好带下来。
  final String abstractZh;
  final List<String> authors;
  final String url;
  final String pdfUrl;
  final String source;
  final String publishedAt;
  final int upvotes;
  final List<String> matched;

  bool get fromBoth => source == 'both';

  /// 有没有中文摘要可显示：没有就退回英文原文，不留空白卡片。
  bool get hasChineseAbstract => abstractZh.isNotEmpty;

  /// 卡片正文：优先中文，其次英文原文。
  String get bodyText => hasChineseAbstract ? abstractZh : abstract;

  /// 卡片标题：中文优先，没有译文就显示原标题（不留空行）。
  String get displayTitle => titleZh.isNotEmpty ? titleZh : title;

  factory RadarPaper.fromJson(Map<String, dynamic> json) => RadarPaper(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? ''}',
    titleZh: '${json['title_zh'] ?? ''}',
    abstract: '${json['abstract'] ?? ''}',
    abstractZh: '${json['abstract_zh'] ?? ''}',
    authors: [for (final raw in json['authors'] as List? ?? const []) '$raw'],
    url: '${json['url'] ?? ''}',
    pdfUrl: '${json['pdf_url'] ?? ''}',
    source: '${json['source'] ?? ''}',
    publishedAt: '${json['published_at'] ?? ''}',
    upvotes: (json['upvotes'] as num?)?.toInt() ?? 0,
    matched: [for (final raw in json['matched'] as List? ?? const []) '$raw'],
  );
}

/// Per-source health: `fresh` (just fetched), `cached` (network failed, older
/// copy shown) or `unavailable` (nothing to show). The UI never invents rows.
class RadarPaperSourceStatus {
  const RadarPaperSourceStatus({
    required this.source,
    required this.label,
    required this.status,
    required this.count,
    required this.fetchedAt,
  });

  final String source;
  final String label;
  final String status;
  final int count;
  final String fetchedAt;

  factory RadarPaperSourceStatus.fromJson(Map<String, dynamic> json) => RadarPaperSourceStatus(
    source: '${json['source'] ?? ''}',
    label: '${json['label'] ?? ''}',
    status: '${json['status'] ?? ''}',
    count: (json['count'] as num?)?.toInt() ?? 0,
    fetchedAt: '${json['fetched_at'] ?? ''}',
  );
}

class RadarPapers {
  const RadarPapers({
    required this.generatedAt,
    required this.interests,
    required this.sources,
    required this.items,
  });

  final String generatedAt;
  final List<String> interests;
  final List<RadarPaperSourceStatus> sources;
  final List<RadarPaper> items;

  factory RadarPapers.fromJson(Map<String, dynamic> json) => RadarPapers(
    generatedAt: '${json['generated_at'] ?? ''}',
    interests: [for (final raw in json['interests'] as List? ?? const []) '$raw'],
    sources: [
      for (final raw in json['sources'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarPaperSourceStatus.fromJson(raw),
    ],
    items: [
      for (final raw in json['items'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarPaper.fromJson(raw),
    ],
  );

  bool get isDegraded => sources.any((source) => source.status != 'fresh');
}

/// `GET /radar/papers`: the home feed's papers, ranked for the saved interests.
///
/// `limit` 为 0 时不下发 limit，由服务端按手机端设置（`paper_limit`）决定；
/// 显式传值只为调试与测试。
class RadarPaperApi {
  const RadarPaperApi(this.client);

  final RadarClient client;

  Future<RadarPapers> fetch({int limit = 0, bool refresh = false}) async {
    final json = await client.request(
      '/radar/papers',
      query: {if (limit > 0) 'limit': '$limit', if (refresh) 'refresh': 'true'},
    ) as Map<String, dynamic>;
    return RadarPapers.fromJson(json);
  }
}
