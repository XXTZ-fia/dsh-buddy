import 'radar_client.dart';

/// One entry of the server's hot-list catalogue: a single board on one site,
/// e.g. 哔哩哔哩「排行榜」. Mirrors `radar/hot/catalog.py`.
class RadarHotSource {
  const RadarHotSource({
    required this.id,
    required this.name,
    required this.title,
    required this.column,
    required this.columnLabel,
    required this.home,
    required this.scheme,
    this.native = true,
  });

  final String id;
  final String name;
  final String title;
  final String column;
  final String columnLabel;
  final String home;
  final String scheme;

  /// 服务端有直连抓取器；false 表示这个源暂时抓不到，UI 直接标「暂不可用」。
  final bool native;

  /// 「哔哩哔哩 热搜」/「知乎」——search matches both parts.
  String get label => title.isEmpty ? name : '$name $title';

  factory RadarHotSource.fromJson(Map<String, dynamic> json) => RadarHotSource(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    title: '${json['title'] ?? ''}',
    column: '${json['column'] ?? ''}',
    columnLabel: '${json['column_label'] ?? ''}',
    home: '${json['home'] ?? ''}',
    scheme: '${json['scheme'] ?? ''}',
    native: json['native'] != false,
  );
}

class RadarHotItem {
  const RadarHotItem({
    required this.rank,
    required this.title,
    required this.url,
    required this.extra,
    required this.time,
  });

  final int rank;
  final String title;
  final String url;
  final String extra;
  final String time;

  factory RadarHotItem.fromJson(Map<String, dynamic> json) => RadarHotItem(
    rank: (json['rank'] as num?)?.toInt() ?? 0,
    title: '${json['title'] ?? ''}',
    url: '${json['url'] ?? ''}',
    extra: '${json['extra'] ?? ''}',
    time: '${json['time'] ?? ''}',
  );
}

/// One board's payload. `status` is `ok`, `stale` (cached after a failed
/// refresh) or `unavailable`; the UI never invents rows for the last case.
class RadarHotFeed {
  const RadarHotFeed({
    required this.source,
    required this.name,
    required this.title,
    required this.status,
    required this.origin,
    required this.updatedAt,
    required this.items,
    required this.error,
  });

  final String source;
  final String name;
  final String title;
  final String status;
  final String origin;
  final String updatedAt;
  final List<RadarHotItem> items;
  final String error;

  bool get isOk => status == 'ok';
  bool get isEmpty => items.isEmpty;

  factory RadarHotFeed.fromJson(Map<String, dynamic> json) => RadarHotFeed(
    source: '${json['source'] ?? ''}',
    name: '${json['name'] ?? ''}',
    title: '${json['title'] ?? ''}',
    status: '${json['status'] ?? ''}',
    origin: '${json['origin'] ?? ''}',
    updatedAt: '${json['updated_at'] ?? ''}',
    error: '${json['error'] ?? ''}',
    items: [
      for (final raw in json['items'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarHotItem.fromJson(raw),
    ],
  );
}

class RadarHotCatalog {
  const RadarHotCatalog({required this.sources, required this.columns});

  final List<RadarHotSource> sources;

  /// `(id, 显示名)`，顺序即分组顺序：国内 → 国际 → 财经 → 科技 → 体育。
  final List<(String, String)> columns;

  RadarHotSource? byId(String id) {
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }
}

/// Thin wrapper over [RadarClient] for the two hot-list endpoints.
class RadarHotApi {
  const RadarHotApi(this.client);

  final RadarClient client;

  Future<RadarHotCatalog> catalog() async {
    final json = await client.request('/radar/hot/sources') as Map<String, dynamic>;
    return RadarHotCatalog(
      sources: [
        for (final raw in json['sources'] as List? ?? const [])
          if (raw is Map<String, dynamic>) RadarHotSource.fromJson(raw),
      ],
      columns: [
        for (final raw in json['columns'] as List? ?? const [])
          if (raw is Map<String, dynamic>) ('${raw['id']}', '${raw['label']}'),
      ],
    );
  }

  /// One request for every visible board; the server fans out in parallel.
  Future<List<RadarHotFeed>> boards(List<String> sourceIds, {int limit = 30, bool refresh = false}) async {
    if (sourceIds.isEmpty) return const [];
    final json = await client.request(
      '/radar/hot/boards',
      // 目录共 47 个源；服务端上限 64，一次就能取全（旧的 30 会静默丢 17 个）。
      query: {'sources': sourceIds.take(60).join(','), 'limit': '$limit', if (refresh) 'refresh': 'true'},
    ) as Map<String, dynamic>;
    return [
      for (final raw in json['feeds'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarHotFeed.fromJson(raw),
    ];
  }

  /// 跨源共识简报：服务端按 2 小时缓存，refresh 只用于手动下拉。
  Future<RadarDigest> digest({bool refresh = false}) async {
    final json =
        await client.request('/radar/hot/digest', query: {if (refresh) 'refresh': 'true'}) as Map<String, dynamic>;
    return RadarDigest.fromJson(json);
  }

  Future<RadarHotFeed> board(String sourceId, {int limit = 30, bool refresh = false}) async {
    final json = await client.request(
      '/radar/hot/feed',
      query: {'source': sourceId, 'limit': '$limit', if (refresh) 'refresh': 'true'},
    ) as Map<String, dynamic>;
    return RadarHotFeed.fromJson(json);
  }
}

/// 一条跨源共识话题：同一件事被几个站点同时放上热榜。
class RadarDigestTopic {
  const RadarDigestTopic({
    required this.title,
    required this.note,
    required this.sources,
    required this.outlets,
    required this.count,
    required this.items,
  });

  final String title;
  final String note;
  final List<String> sources;
  final int outlets;
  final int count;
  final List<RadarDigestItem> items;

  factory RadarDigestTopic.fromJson(Map<String, dynamic> json) => RadarDigestTopic(
    title: '${json['title'] ?? ''}',
    note: '${json['note'] ?? ''}',
    sources: [for (final raw in json['sources'] as List? ?? const []) '$raw'],
    outlets: (json['outlets'] as num?)?.toInt() ?? (json['sources'] as List? ?? const []).length,
    count: (json['count'] as num?)?.toInt() ?? 0,
    items: [
      for (final raw in json['items'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarDigestItem.fromJson(raw),
    ],
  );
}

class RadarDigestItem {
  const RadarDigestItem({
    required this.title,
    required this.url,
    required this.source,
    this.sourceName = '',
  });

  final String title;
  final String url;

  /// 来源 id（`zhihu` 之类），用于跳回对应榜单。
  final String source;

  /// 来源显示名（`知乎`）。旧版服务端只下发 source（当时放的是显示名），
  /// 所以这里留一个空串回落，两种情况都能显示。
  final String sourceName;

  /// 给人看的来源名。
  String get outlet => sourceName.isNotEmpty ? sourceName : source;

  factory RadarDigestItem.fromJson(Map<String, dynamic> json) => RadarDigestItem(
    title: '${json['title'] ?? ''}',
    url: '${json['url'] ?? ''}',
    source: '${json['source'] ?? ''}',
    sourceName: '${json['source_name'] ?? ''}',
  );
}

class RadarDigest {
  const RadarDigest({
    required this.generatedAt,
    required this.model,
    required this.sources,
    required this.scanned,
    required this.topics,
  });

  final String generatedAt;

  /// 润色用的模型名；空串表示只用规则聚合（没配 Key 时的默认状态）。
  final String model;
  final int sources;
  final int scanned;
  final List<RadarDigestTopic> topics;

  factory RadarDigest.fromJson(Map<String, dynamic> json) => RadarDigest(
    generatedAt: '${json['generated_at'] ?? ''}',
    model: '${json['model'] ?? ''}',
    sources: (json['sources'] as num?)?.toInt() ?? 0,
    scanned: (json['scanned'] as num?)?.toInt() ?? 0,
    topics: [
      for (final raw in json['topics'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarDigestTopic.fromJson(raw),
    ],
  );
}
