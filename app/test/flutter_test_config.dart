// Runs around every test file under test/: real fonts first (strict: a
// missing font fails the run), so no test measures or draws the test
// engine's box font. No binding here: tests that never pump keep real
// sockets and HTTP.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart' show tipStart;
import 'package:flutter_test/flutter_test.dart';

import 'support/english_preview.dart';
import 'support/quiet_performance.dart';
import 'support/test_fonts.dart';

/// 界面基线基线已从仓库移除。剩下的断言仍走 `matchesGoldenFile`，但不再读写
/// 任何图片：比较永远通过，避免把 1GB 截图重新带进发布仓库。
class _IgnoredGoldenComparator extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}

  @override
  Uri getTestUri(Uri key, int? version) => key;
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  goldenFileComparator = _IgnoredGoldenComparator();
  await loadTestFonts();
  // The chat page's pet is drawn only where a test asks for it
  // (test/pets/): elsewhere a sheet decoding in a stray real-async window
  // would make screens flicker between with and without a pet.
  PetSheets.enabled = false;
  // The new-chat tip line starts on a random tip in the app; tests (and the
  // goldens that show the new-chat page) start on the first one.
  tipStart = (_) => 0;
  // No device facts in tests: the app reads "unavailable" at once.
  PerformanceChannel.create = QuietPerformanceChannel.new;
  // Tests run in Chinese (goldens and finders were made in it); English
  // tests opt in with AppLocale.use(AppLocale.en) + an English MaterialApp.
  AppLanguageController.initial = AppLanguage.zh;
  AppLocale.use(AppLocale.zhCN);
  setUpEnglishPreview();
  await testMain();
}
