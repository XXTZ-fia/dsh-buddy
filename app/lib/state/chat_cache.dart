import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import '../ui/theme/app_icons.dart';

/// 一段对话里"能看懂"的那几行:谁说、说了什么。
///
/// 只留正文,不留工具调用、思考和附件:这是给「上次聊到哪了」看的,不是把
/// 整份 transcript 搬到手机上。原始结构也没法反序列化(ChatItem 是从事件流
/// 构建的),存文本是最小且可靠的形状。
class CachedLine {
  const CachedLine({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;

  Map<String, Object?> toJson() => {'u': fromUser, 't': text};

  static CachedLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['t'];
    if (text is! String || text.trim().isEmpty) return null;
    return CachedLine(fromUser: raw['u'] == true, text: text);
  }
}

/// 一台机器上最近打开过的那次对话。
class CachedConversation {
  const CachedConversation({
    required this.hostId,
    required this.sessionId,
    required this.lines,
    required this.savedAt,
  });

  final String hostId;
  final String sessionId;
  final List<CachedLine> lines;
  final DateTime savedAt;
}

/// 把「在这台手机上打开过的对话」按**会话**存下来,下次点哪条都能先显示它。
///
/// - 每台机器最多 [maxSessions] 条会话,每条正文最多 [maxLines] 行;
/// - 打开聊天页就存(内容没变不写盘),不用等到有新消息;
/// - 写盘去抖 1.5 s,流式输出时不会每帧写。
class ChatCache {
  ChatCache._();

  static const maxLines = 60;

  /// 最多记几条会话,换会话换得多也不会让文件无限长。
  static const maxSessions = 40;

  static const _fileName = 'conversations.json';

  static Timer? _pending;

  /// 去抖窗口里待写的那一笔;`null` 表示没有待写。
  static (String, String, List<CachedLine>)? _pendingSave;

  /// 把待写的那一笔写掉(定时器到点,或页面关闭时提前写)。
  static void _firePending() {
    _pending = null;
    final save = _pendingSave;
    _pendingSave = null;
    if (save != null) unawaited(_write(save.$1, save.$2, save.$3));
  }
  static Map<String, _Entry>? _entries;
  static Future<void>? _loading;

  static Map<String, _Entry> get _data => _entries ?? const {};

  static String _key(String hostId, String sessionId) => '$hostId::$sessionId';

  /// 某台机器上某条会话的缓存;没有就 null。
  static CachedConversation? forSession(String? hostId, String? sessionId) {
    if (hostId == null || sessionId == null) return null;
    final entry = _data[_key(hostId, sessionId)];
    if (entry == null || entry.lines.isEmpty) return null;
    return CachedConversation(
      hostId: hostId,
      sessionId: sessionId,
      lines: entry.lines,
      savedAt: entry.savedAt,
    );
  }

  /// 这台机器上最近打开过的那条会话（兼容旧入口）。
  static CachedConversation? forHost(String? hostId) {
    if (hostId == null) return null;
    _Entry? latest;
    String? id;
    for (final entry in _data.entries) {
      if (!entry.key.startsWith('$hostId::')) continue;
      if (latest == null || entry.value.savedAt.isAfter(latest.savedAt)) {
        latest = entry.value;
        id = entry.value.sessionId;
      }
    }
    if (latest == null || latest.lines.isEmpty) return null;
    return CachedConversation(hostId: hostId, sessionId: id!, lines: latest.lines, savedAt: latest.savedAt);
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// 读一次盘(进程内只读一次)。
  static Future<void> ensureLoaded() {
    if (_entries != null) return Future<void>.value();
    return _loading ??= () async {
      try {
        final file = await _file();
        if (await file.exists()) _entries = _decode(jsonDecode(await file.readAsString()));
      } on Object {
        // 坏文件不该让聊天页起不来:当作没有缓存。
      } finally {
        _entries ??= <String, _Entry>{};
        _loading = null;
      }
    }();
  }

  static Map<String, _Entry> _decode(Object? raw) {
    final out = <String, _Entry>{};
    if (raw is! Map) return out;
    // v2:按机器分。v1(单条、没有 hostId)认不出是哪台机器的,不收。
    final hosts = raw['hosts'];
    if (hosts is Map) {
      for (final entry in hosts.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final id = value['id'];
        final lines = [for (final line in (value['lines'] as List? ?? const [])) ?CachedLine.fromJson(line)];
        if (id is! String || lines.isEmpty) continue;
        out[entry.key.contains('::') ? '${entry.key}' : '${entry.key}::$id'] = _Entry(
          sessionId: id,
          lines: lines,
          savedAt: DateTime.tryParse('${value['at']}') ?? DateTime.now(),
        );
      }
    }
    return out;
  }

  /// 打开聊天页就该存一次;内容没变时直接返回,所以可以从 build 里调。
  static void scheduleSave(String hostId, String sessionId, List<ChatItem> items) {
    final lines = _extract(items);
    if (lines.isEmpty) return;
    final kept = lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
    final existing = _data[_key(hostId, sessionId)];
    if (existing != null &&
        existing.lines.length == kept.length &&
        existing.lines.last.text == kept.last.text) {
      return;
    }
    _pending?.cancel();
    _pendingSave = (hostId, sessionId, kept);
    _pending = Timer(const Duration(milliseconds: 1500), _firePending);
  }

  /// 立刻落盘,不等去抖。
  ///
  /// 由聊天页的 `dispose` 调用:定时器不能比开它的那块界面活得更久。页面一关
  /// 就把这笔存下来,既保住了「冷启动看到上次聊到哪」,也不会留下一个悬着的
  /// 定时器 —— 后者在测试里是直接判错的(pending timer),在真机上则是页面已
  /// 经没了还在写盘。
  static void flush() {
    _pending?.cancel();
    _firePending();
  }

  static List<CachedLine> _extract(List<ChatItem> items) {
    final lines = <CachedLine>[];
    for (final item in items) {
      switch (item) {
        case UserChatItem(:final text):
          if (text.trim().isNotEmpty) lines.add(CachedLine(fromUser: true, text: text));
        case AssistantChatItem(:final text):
          if (text.trim().isNotEmpty) lines.add(CachedLine(fromUser: false, text: text));
        default:
          break;
      }
    }
    return lines;
  }

  static Future<void> _write(String hostId, String sessionId, List<CachedLine> lines) async {
    await ensureLoaded();
    final entries = Map<String, _Entry>.from(_data);
    entries[_key(hostId, sessionId)] = _Entry(sessionId: sessionId, lines: lines, savedAt: DateTime.now());
    if (entries.length > maxSessions) {
      final oldest = entries.entries.toList()..sort((a, b) => a.value.savedAt.compareTo(b.value.savedAt));
      for (final entry in oldest.take(entries.length - maxSessions)) {
        entries.remove(entry.key);
      }
    }
    _entries = entries;
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'version': 3,
          'hosts': {
            for (final entry in entries.entries)
              entry.key: {
                'host': entry.key.split('::').first,
                'id': entry.value.sessionId,
                'at': entry.value.savedAt.toIso8601String(),
                'lines': [for (final line in entry.value.lines) line.toJson()],
              },
          },
        }),
      );
    } on Object {
      // 写不进去(空间/权限)就只留内存里的这份。
    }
  }

  static Future<void> clear() async {
    _entries = <String, _Entry>{};
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } on Object {
      // 没有就没有。
    }
  }
}

class _Entry {
  const _Entry({required this.sessionId, required this.lines, required this.savedAt});

  final String sessionId;
  final List<CachedLine> lines;
  final DateTime savedAt;
}

/// 这台机器上次打开过的对话;没有时为空。
final cachedConversationProvider = FutureProvider.family<CachedConversation?, String>((ref, hostId) async {
  await ChatCache.ensureLoaded();
  return ChatCache.forHost(hostId);
});

/// 某台机器上某条会话的本地正文快照。
final cachedSessionProvider =
    FutureProvider.family<CachedConversation?, (String hostId, String sessionId)>((ref, key) async {
  await ChatCache.ensureLoaded();
  return ChatCache.forSession(key.$1, key.$2);
});

/// 进会话时先给"上次聊到哪":一个标题条 + 正文气泡,底部渐隐。
///
/// 只是占位:真正的 history 一到就整块换掉,所以不做交互、不做流式、不显示
/// 时间戳(时间戳会让人以为这是当前会话)。
class CachedTranscriptView extends StatelessWidget {
  const CachedTranscriptView({super.key, required this.lines});

  final List<CachedLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final shown = lines.length > 24 ? lines.sublist(lines.length - 24) : lines;
    return ShaderMask(
      // 底部淡出:一眼看出"下面是空的 / 还在同步",而不是内容被截断。
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0, 0.82, 1],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(AppIcons.history, size: 14, color: muted),
              const SizedBox(width: 6),
              Text(context.l10n.viewCachedTranscript, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
          const SizedBox(height: 12),
          for (final line in shown) ...[
            Align(
              alignment: line.fromUser ? Alignment.centerRight : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: line.fromUser
                        ? theme.colorScheme.primary.withValues(alpha: 0.16)
                        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    line.text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
