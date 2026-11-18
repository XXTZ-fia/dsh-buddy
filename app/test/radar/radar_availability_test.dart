import 'package:dsh_app/state/radar_availability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('官方中继下没有雷达', () {
    expect(isOfficialRelay(null), isTrue);
    expect(isOfficialRelay('https://dsh.r2049.cn'), isTrue);
    expect(isOfficialRelay('https://dsh.r2049.cn/'), isTrue);
  });

  test('自建服务器才显示雷达', () {
    expect(isOfficialRelay('https://radar.example.com'), isFalse);
    expect(isOfficialRelay('https://dsh.example.com/'), isFalse);
  });
}
