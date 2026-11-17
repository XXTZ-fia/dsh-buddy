import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for the user-owned middle server.
///
/// 开源版不内置任何服务器地址：由构建者用 `--dart-define` 注入，或由用户在连接卡片里
/// 自己填。留空时 [personalServerOrigin] 是空串，界面会要求用户输入地址，而不是把某个
/// 具体服务器（作者自己的或第三方的）当成默认值。
///
/// - `RADAR_SERVER_HOST` / `RADAR_SERVER_IP`：你的雷达服务域名与其 A 记录（可选，
///   用于把用户输入的直接 IP 规范化到有证书的域名）
/// - `RELAY_SERVER_HOST`：自建中继域名（可选；不注入时回落到官方中继）
///
/// 证书是签给域名的：直接用 IP 访问 443 会命中无关的默认站点，所以输入会归一到域名。
/// 中继服务端不在本仓库（见 docs/PROJECT.md），没法要求用户先自建才可用，因此它保留
/// 官方中继作为默认值；雷达后端在本仓库内，必须由用户自己部署，所以没有默认地址。
const personalServerIp = String.fromEnvironment('RADAR_SERVER_IP');
const personalServerHost = String.fromEnvironment('RADAR_SERVER_HOST');
const personalServerOrigin = personalServerHost == '' ? '' : 'https://$personalServerHost';
const legacyRelayOrigin = 'https://dsh.r2049.cn';

/// 同一台 VPS 上的岸宝远程中继（ds-harness-remote server）。
///
/// 雷达 API 与中继是两个进程：雷达走 [personalServerOrigin]，中继走这个子域。
/// 单独给中继一个域名，是因为它的 WebSocket 连接要长期挂着，混在一起容易
/// 被雷达的 5 分钟轮询和反代超时互相影响。
const relayServerHost = String.fromEnvironment('RELAY_SERVER_HOST');
const relayServerOrigin = relayServerHost == '' ? legacyRelayOrigin : 'https://$relayServerHost';

const radarConnectionKey = 'personalRadarConnection';
const radarPollingKey = 'radarPolling';

/// Bumped whenever credentials change so every tab can refresh its connection
/// state without a second secure-storage read.
final radarConnectionEpoch = ValueNotifier<int>(0);

/// Normalizes anything the user may type into the server field.
///
/// - empty -> the user's own server
/// - bare IP / IP with scheme or port / the server domain -> canonical origin
/// - other hosts -> their plain origin (scheme defaults to https)
/// Invalid or credential-bearing input is returned untouched so the client's
/// strict validation can reject it instead of silently "fixing" it.
String normalizeRadarOrigin(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return personalServerOrigin;
  final bareHost = value
      .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
      .split(RegExp(r'[/?#]'))
      .first
      .split(':')
      .first
      .toLowerCase();
  // 只有构建时注入过服务器，才把它的 IP/域名归一过去；留空时 '' == '' 会误吞输入。
  if (personalServerHost.isNotEmpty &&
      (bareHost == personalServerIp || bareHost == personalServerHost || bareHost == 'www.$personalServerHost')) {
    return personalServerOrigin;
  }
  // 客户端只接受 HTTPS（RadarClient 会拒掉 http）；用户把 http 粘进来时直接升级，
  // 别让他先连接失败一次才知道。
  final withScheme = value.contains('://')
      ? value.replaceFirst(RegExp(r'^http://', caseSensitive: false), 'https://')
      : 'https://$value';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return value;
  return uri.origin;
}

class RadarCredentials {
  const RadarCredentials({required this.url, required this.token});

  final String url;
  final String token;

  bool get isComplete => url.trim().isNotEmpty && token.trim().isNotEmpty;

  Map<String, String> toMap() => {'url': normalizeRadarOrigin(url), 'token': token.trim()};

  static RadarCredentials? decode(String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return RadarCredentials(url: data['url'] as String? ?? '', token: data['token'] as String? ?? '');
    } on Object {
      return null;
    }
  }
}

/// 安全存储之外的明文副本的键：只放地址与访问令牌，和服务器上那份同源。
///
/// 为什么需要它：MIUI/HyperOS 这类 ROM 在应用升级、清缓存或换锁屏密码后，
/// Keystore 里的旧密文会解不开，`flutter_secure_storage` 读取直接返回 null
/// （甚至抛异常），表现就是「每次打开都要重新粘一次令牌」。
const radarCredentialsShadowKey = 'radar.credentialsShadow';

/// All radar consumers (page, management pages, inbox poller, notification
/// bridge) go through this store so a sign-in on the phone is immediately
/// visible everywhere.
///
/// 安全存储是首选，读不到时用 [radarCredentialsShadowKey] 兜底，并顺手把
/// 安全存储补回来——用户不该为一次 ROM 的密钥失效重新手打 64 位令牌。
class RadarCredentialStore {
  const RadarCredentialStore([this.storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage storage;

  Future<String?> _readSecure(String key) async => storage.read(key: key);

  /// 副本读写都带超时：偏好后端在个别机型上会卡住，而恢复连接不该等它——
  /// 卡住时按「没有副本」处理，页面继续走表单那条路。
  static const _shadowTimeout = Duration(milliseconds: 400);

  Future<RadarCredentials?> _readShadow() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(_shadowTimeout);
      return RadarCredentials.decode(prefs.getString(radarCredentialsShadowKey));
    } on Object {
      return null;
    }
  }

  Future<void> _writeShadow(RadarCredentials value) async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(_shadowTimeout);
      await prefs.setString(radarCredentialsShadowKey, jsonEncode(value.toMap())).timeout(_shadowTimeout);
    } on Object {
      // 副本写不进去不影响连接本身。
    }
  }

  Future<RadarCredentials?> read() async {
    String? raw;
    Object? failure;
    try {
      raw = await _readSecure(radarConnectionKey);
    } on Object catch (error) {
      failure = error;
    }
    final secure = RadarCredentials.decode(raw);
    final saved = (secure != null && secure.isComplete) ? secure : await _readShadow();
    // 两处都没有、而安全存储本身报错：把错误抛回去，页面才能区分
    // 「存储读不出来」和「还没连过」——前者要提示重试，后者只要一个表单。
    if (saved == null || !saved.isComplete) {
      if (failure != null) throw failure;
      return null;
    }
    // 安全存储这份丢了或坏了：用副本把它补回去，下次启动就走快路径。
    if (raw == null) unawaited(_resecure(saved));
    // Migrate an old third-party relay entry to the user's own server.
    if (saved.url.contains('dsh.r2049.cn')) {
      final migrated = RadarCredentials(url: personalServerOrigin, token: saved.token);
      await save(migrated);
      return migrated;
    }
    return saved;
  }

  Future<void> _resecure(RadarCredentials value) async {
    try {
      await storage.write(key: radarConnectionKey, value: jsonEncode(value.toMap()));
    } on Object {
      // 写不回去也无所谓：副本还在，下次照样能读出来。
    }
  }

  /// 影子副本先写：它是「下次还能连上」的底线；安全存储只做加固。
  Future<void> save(RadarCredentials value) async {
    await _writeShadow(value);
    await _resecure(value);
    radarConnectionEpoch.value++;
  }

  Future<void> clear() async {
    try {
      await storage.delete(key: radarConnectionKey);
      await storage.delete(key: radarPollingKey);
    } on Object {
      // 删不掉密文也要把副本清掉，否则会「断开又被恢复」。
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(radarCredentialsShadowKey);
    } on Object {
      // ignore
    }
    radarConnectionEpoch.value++;
  }

  Future<bool> pollingEnabled() async {
    try {
      return await storage.read(key: radarPollingKey) == 'true';
    } on Object {
      return false;
    }
  }

  /// Flips the inbox poller. The epoch bump is what actually reaches the
  /// running inbox host: it caches this flag, so a change must invalidate that
  /// cache or the switch would only take effect after a cold start.
  Future<void> setPolling(bool value) async {
    try {
      await storage.write(key: radarPollingKey, value: value ? 'true' : 'false');
    } on Object {
      // 这个开关不是关键路径：写不进去时保持默认关闭。
    }
    radarConnectionEpoch.value++;
  }
}
