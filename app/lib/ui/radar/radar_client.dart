import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../state/personal_server.dart';

/// A radar connection never follows redirects with its bearer credential.
class RadarClient {
  RadarClient({
    required String baseUrl,
    required this.token,
    http.Client? transport,
    this.modelKey = '',
  }) : base = Uri.parse(baseUrl.trim()),
       transport = transport ?? http.Client() {
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw const FormatException('Expected an HTTPS origin');
    }
  }
  final Uri base;
  final String token;
  final http.Client transport;

  /// App 自己填的 DeepSeek Key：服务端没配 Key 时，用它替这一次请求跑 AI 摘要。
  ///
  /// 只作为请求头带过去，不写磁盘、不进日志；服务端配了自己的 Key 会优先用
  /// 服务端那份（手机换了也不至于让翻译断掉）。
  String modelKey;

  static Future<RadarClient> saved({http.Client? transport}) async {
    final credentials = await const RadarCredentialStore().read();
    if (credentials == null || !credentials.isComplete) {
      throw const FormatException('Connect radar first');
    }
    return RadarClient(baseUrl: credentials.url, token: credentials.token, transport: transport);
  }

  /// The saved origin shown in the UI, or the user's own server before sign-in.
  static Future<String> savedOrigin() async => (await const RadarCredentialStore().read())?.url ?? personalServerOrigin;

  Future<dynamic> request(String path, {Object? body, String? method, Map<String, String>? query}) async {
    final bytes = await transfer(
      path,
      method: method ?? (body == null ? 'GET' : 'PUT'),
      bytes: body == null ? null : utf8.encode(jsonEncode(body)),
      query: query,
    );
    return jsonDecode(utf8.decode(bytes));
  }

  Future<Uint8List> transfer(String path, {String method = 'GET', List<int>? bytes, Map<String, String>? query}) async {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw const FormatException('Expected an API path');
    }
    final response = await _send(method, path, bytes, query);
    // 服务端只为管理员令牌开放 refresh=true（它绕过 TTL 直接打上游或调模型）。
    // 手机若用设备令牌，下拉刷新会拿到 403；这里降级成「读缓存」再发一次，
    // 而不是让一次刷新把整个页签变成错误页——频率约束仍由服务端把关。
    if (response.statusCode == 403 && (query?.containsKey('refresh') ?? false)) {
      final relaxed = Map<String, String>.from(query!)..remove('refresh');
      final retry = await _send(method, path, bytes, relaxed);
      if (retry.statusCode == 200) return retry.bodyBytes;
      throw RadarApiException(retry.statusCode);
    }
    if (response.statusCode != 200) throw RadarApiException(response.statusCode);
    return response.bodyBytes;
  }

  Future<http.Response> _send(String method, String path, List<int>? bytes, Map<String, String>? query) {
    final request = http.Request(method, base.replace(path: path, queryParameters: query))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        if (modelKey.trim().isNotEmpty) 'X-Radar-Model-Key': modelKey.trim(),
      });
    if (bytes != null) request.bodyBytes = bytes;
    // The deadline covers both connection establishment and response consumption.
    return (() async => http.Response.fromStream(
      await transport.send(request),
    ))().timeout(const Duration(seconds: 20));
  }

  void close() => transport.close();
}

class RadarApiException implements Exception {
  const RadarApiException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Radar API HTTP $statusCode';
}
