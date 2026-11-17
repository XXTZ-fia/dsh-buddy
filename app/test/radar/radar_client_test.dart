import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dsh_app/ui/radar/radar_client.dart';

void main() {
  test('rejects insecure origins and embedded credentials', () {
    for (final url in [
      'http://example.com',
      'https://u:p@example.com',
      'https://example.com/prefix',
      'https://example.com?token=x',
    ]) {
      expect(() => RadarClient(baseUrl: url, token: 'test'), throwsFormatException);
    }
  });
  test('config save preserves version and sends authorization', () async {
    final client = RadarClient(
      baseUrl: 'https://example.com',
      token: 'test',
      transport: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/radar/config');
        expect(request.headers['Authorization'], 'Bearer test');
        expect(request.followRedirects, isFalse);
        expect(jsonDecode(request.body)['version'], 4);
        return http.Response('{"version":5}', 200);
      }),
    );
    addTearDown(client.close);
    expect(await client.request('/radar/config', body: {'version': 4}), {'version': 5});
  });
  test('model key rides along as a header only when set', () async {
    final seen = <String?>[];
    final client = RadarClient(
      baseUrl: 'https://example.com',
      token: 'test',
      transport: MockClient((request) async {
        seen.add(request.headers['X-Radar-Model-Key']);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    await client.request('/radar/papers');
    client.modelKey = '  sk-abc123  ';
    await client.request('/radar/papers');
    client.modelKey = '   ';
    await client.request('/radar/papers');
    expect(seen, [null, 'sk-abc123', null]);
  });
  test('conflict is preserved without echoing server body', () async {
    final client = RadarClient(
      baseUrl: 'https://example.com',
      token: 'test',
      transport: MockClient((_) async => http.Response('private details', 409)),
    );
    addTearDown(client.close);
    await expectLater(
      client.request('/radar/config'),
      throwsA(
        isA<RadarApiException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.toString(), 'message', isNot(contains('private'))),
      ),
    );
  });
}
