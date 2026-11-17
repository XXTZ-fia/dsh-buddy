import 'radar_client.dart';

/// 手机端可改的偏好：`GET/PUT /radar/config`。
///
/// 服务端用 `version` 做乐观锁（409 = 别人先改过），所以写入一律是
/// 「刚读到的那一份 + 自己改的字段」，冲突时重读一次再写，不猜服务端结构。
class RadarSettingsApi {
  const RadarSettingsApi(this.client);

  final RadarClient client;

  Future<Map<String, dynamic>> read() async =>
      await client.request('/radar/config') as Map<String, dynamic>;

  Future<Map<String, dynamic>> write(Map<String, dynamic> body) async =>
      await client.request('/radar/config', method: 'PUT', body: body) as Map<String, dynamic>;

  /// 只覆盖 [changes] 里的字段，其余原样回传——这样不会把平台选择、简报条数
  /// 这些别处的设置一起改掉。
  Future<Map<String, dynamic>> patch(Map<String, Object?> changes) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      final current = await read();
      try {
        return await write({...current, ...changes});
      } on RadarApiException catch (error) {
        if (error.statusCode != 409) rethrow;
        last = error;
      }
    }
    throw last as RadarApiException;
  }
}
