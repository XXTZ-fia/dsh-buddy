import 'radar_client.dart';

/// 一天的总结：服务端按天缓存的 `/radar/daily`。
class RadarDaily {
  const RadarDaily({
    required this.date,
    required this.summary,
    required this.itemCount,
    required this.sourceCount,
    required this.crossCount,
    required this.highlights,
    required this.focus,
    required this.usage,
    required this.generatedAt,
    required this.model,
  });

  final String date;
  final String summary;
  final int itemCount;
  final int sourceCount;
  final int crossCount;
  final List<RadarDailyHighlight> highlights;
  final List<RadarDailyFocus> focus;
  final RadarUsage usage;
  final String generatedAt;
  final String model;

  factory RadarDaily.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'] as Map<String, dynamic>? ?? const {};
    return RadarDaily(
      date: '${json['date'] ?? ''}',
      summary: '${json['summary'] ?? ''}',
      itemCount: (counts['items'] as num?)?.toInt() ?? 0,
      sourceCount: (counts['sources'] as num?)?.toInt() ?? 0,
      crossCount: (counts['cross'] as num?)?.toInt() ?? 0,
      highlights: [
        for (final raw in json['highlights'] as List? ?? const [])
          if (raw is Map<String, dynamic>) RadarDailyHighlight.fromJson(raw),
      ],
      focus: [
        for (final raw in json['focus'] as List? ?? const [])
          if (raw is Map<String, dynamic>) RadarDailyFocus.fromJson(raw),
      ],
      usage: RadarUsage.fromJson(json['usage'] as Map<String, dynamic>? ?? const {}),
      generatedAt: '${json['generated_at'] ?? ''}',
      model: '${json['model'] ?? ''}',
    );
  }

  Map<String, Object?> toJson() => {
    'date': date,
    'summary': summary,
    'counts': {'items': itemCount, 'sources': sourceCount, 'cross': crossCount},
    'highlights': [for (final item in highlights) item.toJson()],
    'focus': [for (final item in focus) item.toJson()],
    'usage': usage.toJson(),
    'generated_at': generatedAt,
    'model': model,
  };

  RadarDaily copyWithSummary(String value) => RadarDaily(
    date: date,
    summary: value,
    itemCount: itemCount,
    sourceCount: sourceCount,
    crossCount: crossCount,
    highlights: highlights,
    focus: focus,
    usage: usage,
    generatedAt: generatedAt,
    model: model,
  );
}

class RadarDailyHighlight {
  const RadarDailyHighlight({
    required this.title,
    required this.url,
    required this.platform,
    required this.note,
    required this.crossPlatform,
  });

  final String title;
  final String url;
  final String platform;
  final String note;
  final List<String> crossPlatform;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'platform': platform,
    'note': note,
    'cross_platform': crossPlatform,
  };

  factory RadarDailyHighlight.fromJson(Map<String, dynamic> json) => RadarDailyHighlight(
    title: '${json['title'] ?? ''}',
    url: '${json['url'] ?? ''}',
    platform: '${json['platform'] ?? ''}',
    note: '${json['note'] ?? ''}',
    crossPlatform: [for (final raw in json['cross_platform'] as List? ?? const []) '$raw'],
  );
}

class RadarDailyFocus {
  const RadarDailyFocus({required this.topic, required this.count});
  final String topic;
  final int count;

  Map<String, Object?> toJson() => {'topic': topic, 'count': count};

  factory RadarDailyFocus.fromJson(Map<String, dynamic> json) => RadarDailyFocus(
    topic: '${json['topic'] ?? ''}',
    count: (json['count'] as num?)?.toInt() ?? 0,
  );
}

class RadarUsage {
  const RadarUsage({required this.total, required this.byDevice, required this.byBackend, required this.byModel});

  final RadarUsageBucket total;
  final List<RadarUsageSlice> byDevice;
  final List<RadarUsageSlice> byBackend;
  final List<RadarUsageSlice> byModel;

  Map<String, Object?> toJson() => {
    'total': total.toJson(),
    'by_device': [for (final slice in byDevice) slice.toJson('device')],
    'by_backend': [for (final slice in byBackend) slice.toJson('backend')],
    'by_model': [for (final slice in byModel) slice.toJson('model')],
  };

  factory RadarUsage.fromJson(Map<String, dynamic> json) => RadarUsage(
    total: RadarUsageBucket.fromJson(json['total'] as Map<String, dynamic>? ?? const {}),
    byDevice: _slices(json['by_device'], 'device'),
    byBackend: _slices(json['by_backend'], 'backend'),
    byModel: _slices(json['by_model'], 'model'),
  );

  static List<RadarUsageSlice> _slices(Object? raw, String label) => [
    for (final item in raw as List? ?? const [])
      if (item is Map<String, dynamic>)
        RadarUsageSlice(name: '${item[label] ?? ''}', bucket: RadarUsageBucket.fromJson(item)),
  ];
}

class RadarUsageBucket {
  const RadarUsageBucket({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    required this.turns,
  });

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int turns;

  /// 实际处理的输入：未命中 + 命中 + 写入。`input` 只是未命中部分。
  int get billedInput => input + cacheRead + cacheWrite;
  int get total => billedInput + output;
  double? get cacheRate => billedInput == 0 ? null : cacheRead / billedInput;

  Map<String, Object?> toJson() => {
    'input': input,
    'output': output,
    'cache_read': cacheRead,
    'cache_write': cacheWrite,
    'turns': turns,
  };

  factory RadarUsageBucket.fromJson(Map<String, dynamic> json) => RadarUsageBucket(
    input: (json['input'] as num?)?.toInt() ?? 0,
    output: (json['output'] as num?)?.toInt() ?? 0,
    cacheRead: (json['cache_read'] as num?)?.toInt() ?? 0,
    cacheWrite: (json['cache_write'] as num?)?.toInt() ?? 0,
    turns: (json['turns'] as num?)?.toInt() ?? 0,
  );
}

class RadarUsageSlice {
  const RadarUsageSlice({required this.name, required this.bucket});
  final String name;
  final RadarUsageBucket bucket;

  Map<String, Object?> toJson(String label) => {label: name, ...bucket.toJson()};
}

class RadarUsageRecord {
  const RadarUsageRecord({
    required this.day,
    required this.device,
    required this.backend,
    required this.model,
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    required this.turns,
  });

  final String day;
  final String device;
  final String backend;
  final String model;
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int turns;

  Map<String, Object?> toJson() => {
    'day': day,
    'device': device,
    'backend': backend,
    'model': model,
    'input': input,
    'output': output,
    'cache_read': cacheRead,
    'cache_write': cacheWrite,
    'turns': turns,
  };
}

class RadarDailyCalendarDay {
  const RadarDailyCalendarDay({required this.date, required this.count, required this.teaser, required this.generated});
  final String date;
  final int count;
  final String teaser;
  final bool generated;
}

class RadarDailyApi {
  const RadarDailyApi(this.client);
  final RadarClient client;

  Future<RadarDaily> fetch(String date) async {
    final json = await client.request('/radar/daily', query: {'day': date}) as Map<String, dynamic>;
    return RadarDaily.fromJson(json);
  }

  Future<RadarDaily> refresh(String date) async {
    final json = await client.request('/radar/daily/refresh', method: 'POST', query: {'day': date}) as Map<String, dynamic>;
    return RadarDaily.fromJson(json);
  }

  Future<List<RadarDailyCalendarDay>> calendar(String month) async {
    final json = await client.request('/radar/daily/calendar', query: {'month': month}) as Map<String, dynamic>;
    return [
      for (final raw in json['days'] as List? ?? const [])
        if (raw is Map<String, dynamic>)
          RadarDailyCalendarDay(
            date: '${raw['date'] ?? ''}',
            count: (raw['count'] as num?)?.toInt() ?? 0,
            teaser: '${raw['teaser'] ?? ''}',
            generated: raw['generated'] == true,
          ),
    ];
  }

  Future<void> sendUsage(List<RadarUsageRecord> records) async {
    if (records.isEmpty) return;
    await client.request('/radar/usage', method: 'POST', body: [for (final row in records) row.toJson()]);
  }
}
