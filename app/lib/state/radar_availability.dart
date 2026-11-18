import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';
import 'personal_server.dart';

/// 信息雷达只在「用户自己的公网服务器」上才有意义。
///
/// 官方中继（[legacyRelayOrigin]）只是一条端到端加密的传输通道，它不跑雷达
/// 后端，也没有任何默认雷达地址。所以只要手机连的是官方中继，雷达页签、
/// 自动化里的雷达入口、后台轮询和通知点击全部隐藏，用户看不到一个永远连不
/// 上的功能。
///
/// 判定用的是**实际生效的中继地址**：
/// - 用户没选过服务器 -> [defaultRelayServer]（构建时可用 RELAY_SERVER_HOST
///   注入自建地址；不注入就是官方中继）
/// - 用户在「自建服务器」里填过地址 -> relayServerProvider 里的那个 origin
///
/// 因此同一台机器上既可以用官方中继（无雷达），也可以切到自建服务器
/// （有雷达），切换后无需重启：provider 会重建，外壳跟着重排页签。
bool isOfficialRelay(String? selection) {
  final origin = (selection ?? defaultRelayServer).trim();
  final normalized = origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
  return normalized == legacyRelayOrigin;
}

/// True when the radar surface should exist at all.
final radarAvailableProvider = Provider<bool>((ref) {
  return !isOfficialRelay(ref.watch(relayServerProvider));
});
