import 'radar_client.dart';

/// 一条简报：服务端 `sources → normalize → summarize → publication` 的产物。
///
/// 与热榜不同，这里的内容已经过跨源合并、去重与（配了模型时的）中文摘要，
/// 是「今天值得看什么」的答案；`read` 由服务端按设备无关的已读表回填。
class RadarBriefItem {
  const RadarBriefItem({
    required this.id,
    required this.platform,
    required this.title,
    required this.summary,
    required this.why,
    required this.url,
    required this.author,
    required this.publishedAt,
    required this.heat,
    required this.heatDelta,
    required this.crossPlatform,
    this.read = false,
  });

  final String id;
  final String platform;
  final String title;
  final String summary;

  /// 「为什么推给我」。服务端配了模型时是模型写的理由，否则是规则说明。
  final String why;
  final String url;
  final String author;
  final String publishedAt;
  final int heat;

  /// 形如 `+12%` / `-3%`，服务端算好的相对首轮基线。
  final String heatDelta;

  /// 同一事件还被哪些平台报道（含自己）。长度 > 1 说明是跨源共识。
  final List<String> crossPlatform;
  final bool read;

  RadarBriefItem copyWith({bool? read}) => RadarBriefItem(
    id: id,
    platform: platform,
    title: title,
    summary: summary,
    why: why,
    url: url,
    author: author,
    publishedAt: publishedAt,
    heat: heat,
    heatDelta: heatDelta,
    crossPlatform: crossPlatform,
    read: read ?? this.read,
  );

  factory RadarBriefItem.fromJson(Map<String, dynamic> json) {
    final heat = json['heat'];
    final value = heat is Map<String, dynamic> ? (heat['value'] as num?)?.toInt() ?? 0 : 0;
    final delta = heat is Map<String, dynamic> ? '${heat['delta'] ?? ''}' : '';
    return RadarBriefItem(
      id: '${json['id'] ?? ''}',
      platform: '${json['platform'] ?? ''}',
      title: '${json['title'] ?? ''}',
      summary: '${json['summary'] ?? ''}',
      why: '${json['why'] ?? ''}',
      url: '${json['url'] ?? ''}',
      author: '${json['author'] ?? ''}',
      publishedAt: '${json['published_at'] ?? ''}',
      heat: value,
      heatDelta: delta,
      crossPlatform: [for (final raw in json['cross_platform'] as List? ?? const []) '$raw'],
      read: json['read'] == true,
    );
  }
}

/// 某个平台本轮是否采到内容。`status` 为 `ok` / `stale` / `unavailable` / `error`。
class RadarBriefHealth {
  const RadarBriefHealth({
    required this.platform,
    required this.status,
    required this.checkedAt,
    required this.note,
  });

  final String platform;
  final String status;
  final String checkedAt;
  final String note;

  bool get isOk => status == 'ok';

  factory RadarBriefHealth.fromJson(Map<String, dynamic> json) => RadarBriefHealth(
    platform: '${json['platform'] ?? ''}',
    status: '${json['status'] ?? ''}',
    checkedAt: '${json['checked_at'] ?? ''}',
    note: '${json['note'] ?? ''}',
  );
}

class RadarBrief {
  const RadarBrief({required this.generatedAt, required this.items, required this.health});

  final String generatedAt;
  final List<RadarBriefItem> items;
  final List<RadarBriefHealth> health;

  int get unread => items.where((item) => !item.read).length;

  factory RadarBrief.fromJson(Map<String, dynamic> json) => RadarBrief(
    generatedAt: '${json['generated_at'] ?? ''}',
    items: [
      for (final raw in json['items'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarBriefItem.fromJson(raw),
    ],
    health: [
      for (final raw in json['health'] as List? ?? const [])
        if (raw is Map<String, dynamic>) RadarBriefHealth.fromJson(raw),
    ],
  );
}

/// `/radar/items` 的客户端。分页按 rowid 倒序，`limit` 上限 50（服务端校验）。
class RadarBriefApi {
  const RadarBriefApi(this.client, {this.pageSize = 20});

  final RadarClient client;
  final int pageSize;

  Future<RadarBrief> page({int offset = 0}) async {
    final json = await client.request(
      '/radar/items',
      query: {'offset': '$offset', 'limit': '$pageSize'},
    ) as Map<String, dynamic>;
    return RadarBrief.fromJson(json);
  }

  /// 标记已读。服务端对不存在的 id 返回 404，这里交给调用方忽略——
  /// 已读只是体验，不该因为一次写入失败把列表打回错误态。
  Future<void> markRead(String id) async {
    await client.request('/radar/items/${Uri.encodeComponent(id)}/read', method: 'PUT');
  }
}
