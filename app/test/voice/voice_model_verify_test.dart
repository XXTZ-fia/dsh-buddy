// 「已就绪」 must mean "dictation actually works", not "the files are on
// disk". `verify()` reads the live catalog and runs one real transcription
// through the offline provider on the on-device engine.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/voice/voice_model_assets.dart' show VoiceModelFiles, voiceModelProviderId;
import 'package:dsh_app/voice/voice_model_download.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart' show FakeRpcCarrier, readySpeechCatalog;

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient? client;

  @override
  Future<HostConnection?> build() async =>
      client == null ? null : HostConnection(client: client!, isLocal: true);
}

/// The model controller never touches the platform during [verify]; this
/// keeps a stray refresh from reaching the real rootfs.
class _QuietPlatform implements VoiceModelPlatform {
  @override
  Future<VoiceModelFiles?> files() async => null;
  @override
  Future<int?> freeBytes() async => null;
  @override
  Future<bool> metered() async => false;
  @override
  Future<VoiceDownloadRun> download(List<VoiceDownloadJob> jobs) async => throw UnimplementedError();
  @override
  Future<void> notice(String? text, {int? progress}) async {}
}

ProviderContainer _container(DshClient? client) {
  final c = ProviderContainer(
    overrides: [
      voiceModelPlatformProvider.overrideWithValue(_QuietPlatform()),
      localConnectionProvider.overrideWith(() => _Local(client)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the silent WAV is a canonical 16 kHz mono PCM16 recording', () {
    final wav = silentWav();
    expect(wav.length, 44 + 32000); // one second, 16 kHz, 16-bit mono
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    final view = ByteData.sublistView(wav);
    expect(view.getUint16(20, Endian.little), 1); // PCM
    expect(view.getUint16(22, Endian.little), 1); // mono
    expect(view.getUint32(24, Endian.little), 16000);
    expect(view.getUint16(34, Endian.little), 16); // bits
    expect(view.getUint32(40, Endian.little), 32000); // data bytes
  });

  test('verify says the engine is offline when no local engine is connected', () async {
    final container = _container(null);
    final notifier = container.read(voiceModelProvider.notifier);
    await container.read(localConnectionProvider.future);
    expect(await notifier.verify(), VoiceModelCheck.engineOffline);
  });

  test('verify runs one real transcription through the offline provider', () async {
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => readySpeechCatalog(),
      'speech/transcribe': (_) => {'text': '', 'audioSeconds': 1},
    });
    final client = DshClient.withCarrier(carrier);
    final container = _container(client);
    final notifier = container.read(voiceModelProvider.notifier);
    await container.read(localConnectionProvider.future);

    expect(await notifier.verify(), VoiceModelCheck.ok);
    final calls = carrier.argsOf('speech/transcribe');
    expect(calls, hasLength(1));
    final request = calls.single['request'] as Map;
    expect(request['providerId'], voiceModelProviderId);
    final audio = base64Decode(request['audioBase64'] as String);
    expect(audio.length, 44 + 32000);
  });

  test('verify reports a model that is not prepared instead of claiming success', () async {
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => readySpeechCatalog(phase: 'unprepared'),
    });
    final client = DshClient.withCarrier(carrier);
    final container = _container(client);
    final notifier = container.read(voiceModelProvider.notifier);
    await container.read(localConnectionProvider.future);

    expect(await notifier.verify(), VoiceModelCheck.providerNotReady);
    expect(carrier.argsOf('speech/transcribe'), isEmpty);
  });

  test('verify reports a host that does not serve speech at all', () async {
    final carrier = FakeRpcCarrier({});
    final client = DshClient.withCarrier(carrier);
    final container = _container(client);
    final notifier = container.read(voiceModelProvider.notifier);
    await container.read(localConnectionProvider.future);

    expect(await notifier.verify(), VoiceModelCheck.noSpeechService);
  });
}
