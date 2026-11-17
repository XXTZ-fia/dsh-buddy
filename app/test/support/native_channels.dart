// 原生插件通道的测试替身。
//
// 测试 VM 里没有原生实现，而 `EventChannel` 在「激活/取消平台流」失败时**不是**把
// 错误交给 `onError`，而是 `FlutterError.reportError` —— 任何用例只要挂载了会读
// 网络状态或运行时状态的界面，就会因为这条上报而判错（`onError` 拦不住它）。
//
// 所以凡是要挂载外壳 / 聊天 / 陪伴页的测试，先在 `setUp` 里调一次
// [mockNativeChannels]。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 连通性（`connectivity_plus`）与宿主运行时事件流的空闲替身。
void mockNativeChannels() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // connectivity_plus：一条永不发事件的流 + 一个「有网」的查询结果。
  messenger.setMockStreamHandler(
    const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
    MockStreamHandler.inline(onListen: (arguments, sink) {}, onCancel: (arguments) {}),
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (call) async => call.method == 'check' ? <String>['wifi'] : null,
  );

  // 宿主运行时事件（`dsh/runtime/events`）：一条什么都不发的空闲流。
  messenger.setMockStreamHandler(
    const EventChannel('dsh/runtime/events'),
    MockStreamHandler.inline(onListen: (arguments, sink) {}, onCancel: (arguments) {}),
  );
}

/// 只要运行时事件流（不需要连通性）时用这个。
void mockRuntimeEvents() => mockNativeChannels();
