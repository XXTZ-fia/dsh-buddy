import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../performance/performance_state.dart';
import 'provider_keys.dart';
import 'read_list_epoch.dart';

/// User settings: the DeepSeek API key (and custom-provider keys, see
/// [ProviderKeyVault]) live in the Android Keystore-backed secure storage;
/// plain preferences go to SharedPreferences.
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.themeMode = ThemeMode.system,
    this.autoStartLocal = true,
    this.autoStartLocalExplicit = true,
    this.autoApproveCommands = false,
    this.phoneStorage = false,
    this.webPhoneLayout = true,
    this.hardwareEnterSends = false,
    this.chatTextScale = 1.0,
    this.foldCompletedTurns = true,
    this.visualReplies = true,
    this.customProviderIds = const {},
    this.loaded = false,
  });

  final String apiKey;
  final ThemeMode themeMode;

  /// Start the local DSH automatically when the app opens.
  final bool autoStartLocal;

  /// A stored user choice. Policy defaults never create this preference.
  final bool autoStartLocalExplicit;

  /// New local sessions use DSH's `danger-full-access` preset (commands run without asking).
  /// Off by default: there is no sandbox on Android, so each command escalation asks first.
  final bool autoApproveCommands;

  /// Mount the phone's shared storage at /sdcard in the Linux environment.
  final bool phoneStorage;

  /// Fit the embedded DSH Web to a phone (`assets/web/`). Off shows the
  /// official layout untouched, e.g. to check a plugin that restyles it.
  final bool webPhoneLayout;

  /// Hardware Enter sends; Shift+Enter and the software keyboard still insert newlines.
  final bool hardwareEnterSends;

  /// Size of chat content relative to the system setting (header and
  /// composer keep theirs). One of [chatTextScales].
  final double chatTextScale;

  /// A normally finished turn folds its thinking, tool calls and interim
  /// messages into one summary line above the answer (DSH Web's default).
  final bool foldCompletedTurns;

  /// Tell the local DSH it may answer with ```dsh-ui views (charts, cards,
  /// options): a section of the managed AGENTS.md, written at engine start.
  /// Off only drops the instructions; views that arrive are still drawn.
  final bool visualReplies;

  /// Custom providers created on the local engine whose key is kept on the
  /// phone ([ProviderKeyVault]). Known at launch, before the engine runs, so
  /// the first-run gate can tell "has a model to talk to" without it.
  final Set<String> customProviderIds;
  final bool loaded;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  /// A DeepSeek key or a custom provider on the local engine.
  bool get hasModelAccess => hasApiKey || customProviderIds.isNotEmpty;

  AppSettings copyWith({
    String? apiKey,
    ThemeMode? themeMode,
    bool? autoStartLocal,
    bool? autoStartLocalExplicit,
    bool? autoApproveCommands,
    bool? phoneStorage,
    bool? webPhoneLayout,
    bool? hardwareEnterSends,
    double? chatTextScale,
    bool? foldCompletedTurns,
    bool? visualReplies,
    Set<String>? customProviderIds,
    bool? loaded,
  }) => AppSettings(
    apiKey: apiKey ?? this.apiKey,
    themeMode: themeMode ?? this.themeMode,
    autoStartLocal: autoStartLocal ?? this.autoStartLocal,
    autoStartLocalExplicit: autoStartLocalExplicit ?? this.autoStartLocalExplicit,
    autoApproveCommands: autoApproveCommands ?? this.autoApproveCommands,
    phoneStorage: phoneStorage ?? this.phoneStorage,
    webPhoneLayout: webPhoneLayout ?? this.webPhoneLayout,
    hardwareEnterSends: hardwareEnterSends ?? this.hardwareEnterSends,
    chatTextScale: chatTextScale ?? this.chatTextScale,
    foldCompletedTurns: foldCompletedTurns ?? this.foldCompletedTurns,
    visualReplies: visualReplies ?? this.visualReplies,
    customProviderIds: customProviderIds ?? this.customProviderIds,
    loaded: loaded ?? this.loaded,
  );
}

/// Chat text sizes offered in settings: (scale, label).
List<(double, String)> get chatTextScales => [
  (0.9, appL10n.stateSizeSmall),
  (1.0, appL10n.stateSizeStandard),
  (1.15, appL10n.stateSizeLarge),
  (1.3, appL10n.stateSizeExtraLarge),
];

const _deepSeekApiKeyKey = 'deepseek_api_key';
const _secureStorage = FlutterSecureStorage();

/// Reads the stored DeepSeek API key without building the settings providers.
///
/// 信息雷达页面也会用到它，而那个页面在测试里是单独挂载的（没有 ProviderScope），
/// 所以这里给一个不依赖 Riverpod 的读法；Keystore 坏了就当作没填。
Future<String> readStoredApiKey() async {
  try {
    return await _secureStorage.read(key: _deepSeekApiKeyKey) ?? '';
  } catch (_) {
    return '';
  }
}

class SettingsController extends Notifier<AppSettings> {
  static const _apiKeyKey = _deepSeekApiKeyKey;
  static const _themeKey = 'theme_mode';
  static const _autoStartKey = 'auto_start_local';
  static const _autoApproveKey = 'auto_approve_commands';
  static const _phoneStorageKey = 'phone_storage';
  static const _webPhoneLayoutKey = 'web_phone_layout';
  static const _hardwareEnterKey = 'hardware_enter_sends';
  static const _chatTextScaleKey = 'chat_text_scale';
  static const _foldTurnsKey = 'fold_completed_turns';
  static const _visualRepliesKey = 'visual_replies';
  static const _secure = FlutterSecureStorage();
  late Future<void> _loaded;

  @override
  AppSettings build() {
    ref.listen(performanceDefaultsProvider.select((p) => p.autoStartLocal), (_, next) {
      if (!state.autoStartLocalExplicit) state = state.copyWith(autoStartLocal: next);
    });
    _loaded = _load();
    return const AppSettings(autoStartLocalExplicit: false);
  }

  /// Reads the stored API key; a broken Keystore just means the user re-enters it.
  Future<String> _readApiKey() => readStoredApiKey();

  /// Ids with a key in the self-heal vault; the providers work without it.
  Future<Set<String>> _readProviderIds() async {
    try {
      return (await ref.read(providerKeyVaultProvider).readAll()).keys.toSet();
    } catch (_) {
      return const <String>{};
    }
  }

  Future<void> _load() async {
    // These three reads are independent and each one can be slow on a cold start
    // (prefs XML, Keystore decrypt, a second Keystore sweep). Serially they added
    // 150–400 ms of splash; together they cost the slowest one.
    //
    // The performance snapshot is deliberately not awaited here: it is only a
    // default for 自启动, the listener in build() corrects it when it arrives, and
    // waiting for it turned a stuck platform channel into a 5 s splash.
    final prefsFuture = SharedPreferences.getInstance();
    final keyFuture = _readApiKey();
    final providersFuture = _readProviderIds();
    final prefs = await prefsFuture;
    if (!ref.mounted) return;
    final apiKey = await keyFuture;
    if (!ref.mounted) return;
    final providerIds = await providersFuture;
    if (!ref.mounted) return;
    state = AppSettings(
      apiKey: apiKey,
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == prefs.getString(_themeKey),
        orElse: () => ThemeMode.system,
      ),
      autoStartLocal: prefs.getBool(_autoStartKey) ?? ref.read(performanceDefaultsProvider).autoStartLocal,
      autoStartLocalExplicit: prefs.containsKey(_autoStartKey),
      autoApproveCommands: prefs.getBool(_autoApproveKey) ?? false,
      phoneStorage: prefs.getBool(_phoneStorageKey) ?? false,
      webPhoneLayout: prefs.getBool(_webPhoneLayoutKey) ?? true,
      hardwareEnterSends: prefs.getBool(_hardwareEnterKey) ?? false,
      chatTextScale: _knownScale(prefs.getDouble(_chatTextScaleKey)),
      foldCompletedTurns: prefs.getBool(_foldTurnsKey) ?? true,
      visualReplies: prefs.getBool(_visualRepliesKey) ?? true,
      customProviderIds: providerIds,
      loaded: true,
    );
  }

  /// Keeps [key] for the local engine's custom provider [id] (see
  /// [ProviderKeyVault]).
  Future<void> saveProviderKey(String id, String key) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await ref.read(providerKeyVaultProvider).write(id, key);
    state = state.copyWith(customProviderIds: {...state.customProviderIds, id});
  }

  Future<void> removeProviderKey(String id) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await ref.read(providerKeyVaultProvider).delete(id);
    state = state.copyWith(customProviderIds: {...state.customProviderIds}..remove(id));
  }

  Future<void> setApiKey(String key) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _secure.delete(key: _apiKeyKey);
    } else {
      await _secure.write(key: _apiKeyKey, value: trimmed);
    }
    state = state.copyWith(apiKey: trimmed);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setAutoApproveCommands(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoApproveKey, value);
    state = state.copyWith(autoApproveCommands: value);
  }

  Future<void> setPhoneStorage(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_phoneStorageKey, value);
    state = state.copyWith(phoneStorage: value);
  }

  static double _knownScale(double? v) => chatTextScales.any((s) => s.$1 == v) ? v! : 1.0;

  Future<void> setChatTextScale(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_chatTextScaleKey, value);
    state = state.copyWith(chatTextScale: value);
  }

  Future<void> setFoldCompletedTurns(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_foldTurnsKey, value);
    state = state.copyWith(foldCompletedTurns: value);
  }

  /// Takes effect at the next engine start (the instructions live in the
  /// managed AGENTS.md, written before DSH starts).
  Future<void> setVisualReplies(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_visualRepliesKey, value);
    state = state.copyWith(visualReplies: value);
  }

  Future<void> setWebPhoneLayout(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webPhoneLayoutKey, value);
    state = state.copyWith(webPhoneLayout: value);
  }

  Future<void> setHardwareEnterSends(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(hardwareEnterSends: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hardwareEnterKey, value);
  }

  Future<void> setAutoStartLocal(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(autoStartLocal: value, autoStartLocalExplicit: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoStartKey, value);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
