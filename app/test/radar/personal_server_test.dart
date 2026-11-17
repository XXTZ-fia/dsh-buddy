import 'dart:convert';

import 'package:dsh_app/state/personal_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const server = 'https://radar.example.com';

  test('every way of entering the user server resolves to its HTTPS origin', () {
    for (final raw in [
      'radar.example.com',
      'http://radar.example.com',
      'https://radar.example.com',
      'https://radar.example.com:443',
      'radar.example.com/identity',
      'https://radar.example.com/',
      'https://radar.example.com/radar/items?limit=5',
    ]) {
      expect(normalizeRadarOrigin(raw), server, reason: 'input: "$raw"');
    }
  });

  test('a build without an injected server has no default address', () {
    // 开源版不内置服务器：没有 --dart-define 时，空输入不会被指向任何机器。
    if (personalServerHost.isEmpty) {
      expect(personalServerOrigin, '');
      expect(normalizeRadarOrigin(''), '');
      expect(normalizeRadarOrigin('   '), '');
    } else {
      expect(Uri.parse(personalServerOrigin).host, personalServerHost);
    }
  });

  test('other hosts keep their own origin and credentials are not sanitized away', () {
    expect(normalizeRadarOrigin('example.com:8443'), 'https://example.com:8443');
    expect(normalizeRadarOrigin('https://example.com/prefix'), 'https://example.com');
    expect(normalizeRadarOrigin('https://u:p@example.com'), 'https://u:p@example.com');
  });

  test('saved credentials are canonicalized and decoded defensively', () {
    final credentials = RadarCredentials(url: 'radar.example.com', token: ' secret ');
    expect(credentials.toMap(), {'url': server, 'token': 'secret'});
    expect(RadarCredentials.decode('{"url":"https://radar.example.com","token":"t"}')?.token, 't');
    expect(RadarCredentials.decode('not json'), isNull);
    expect(RadarCredentials(url: server, token: '').isComplete, isFalse);
  });

  test('a lost secure entry falls back to the plain copy', () async {
    // 模拟 ROM 让 Keystore 密文失效：安全存储读不到，但副本还在。
    SharedPreferences.setMockInitialValues({
      radarCredentialsShadowKey: jsonEncode({'url': server, 'token': 'shadow-token'}),
    });
    final saved = await const RadarCredentialStore().read();
    expect(saved?.token, 'shadow-token');
    expect(saved?.url, server);

    // 断开时要连副本一起清掉，否则会出现「断开又被恢复」。
    await const RadarCredentialStore().clear();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(radarCredentialsShadowKey), isNull);
  });
}
