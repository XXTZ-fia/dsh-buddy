import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  appErrorCapture.install();
  // The first frame is already in the chosen language (设置 → 语言).
  // 启动动画已停用：不再接管系统启动画面，也不挂载 LaunchLayer。
  // 语言必须在首帧前就位（否则整屏会先按系统语言排版再重建）；结束系统启动画面
  // 只影响原生那一层，挪到首帧之后再做，省掉 runApp 前的一次通道往返。
  await AppLanguageController.load();
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  runApp(const ProviderScope(child: DshApp()));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // The native splash stays until the first frame is on screen, so handing it
    // over now cannot flash a blank window.
    unawaited(const LaunchChannel().done());
  });
}
