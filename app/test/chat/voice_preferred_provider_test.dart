// A downloaded, ready model must actually be the recognizer that runs. The
// engine stores a saved selection in `speech/catalog`; when that selection
// points at another provider (a cloud one, an older pick) the local model was
// ready but never called. `preferredProviderId` fixes that without vetoing
// other usable providers.

import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/voice/voice_model_assets.dart' show voiceModelProviderId;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'voice_fallback_test.dart' show settleVoice;

void main() {
  late TextEditingController input;
  setUp(() => input = TextEditingController());
  tearDown(() => input.dispose());

  VoiceInputController controller(
    FakeVoiceBridge bridge,
    DshClient client, {
    String? preferredProviderId,
  }) {
    final voice = VoiceInputController(
      input: input,
      bridge: bridge,
      client: () => client,
      mode: () async => VoiceMode.engine,
      modelReady: () => true,
      preferredProviderId: preferredProviderId,
      observeLifecycle: false,
    );
    addTearDown(voice.dispose);
    return voice;
  }

  /// SenseVoice registered, but the engine's saved default is a cloud one.
  Map<String, Object?> cloudDefault({String localPhase = 'standby'}) {
    final catalog = readySpeechCatalog(phase: localPhase);
    catalog['selection'] = {'providerId': 'cloud', 'language': 'auto'};
    (catalog['providers'] as List).add({
      'id': 'cloud',
      'name': 'Cloud',
      'location': 'cloud',
      'preparation': {'phase': 'ready'},
    });
    return catalog;
  }

  Future<String?> transcribedProvider(WidgetTester tester, VoiceInputController voice, FakeRpcCarrier carrier) async {
    await voice.start();
    await settleVoice(tester);
    await voice.stop();
    await settleVoice(tester);
    final calls = carrier.argsOf('speech/transcribe');
    if (calls.isEmpty) return null;
    return ((calls.single['request'] as Map)['providerId']) as String?;
  }

  testWidgets('a ready local model wins over the engine\'s cloud default', (tester) async {
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => cloudDefault(),
      'speech/transcribe': (_) => {'text': '本地转写', 'audioSeconds': 1},
    });
    final bridge = FakeVoiceBridge()..recording = silentWav(1);
    final voice = controller(bridge, DshClient.withCarrier(carrier), preferredProviderId: voiceModelProviderId);

    expect(await transcribedProvider(tester, voice, carrier), voiceModelProviderId);
    expect(input.text, contains('本地转写'));
  });

  testWidgets('an unprepared local model does not veto another usable provider', (tester) async {
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => cloudDefault(localPhase: 'unprepared'),
      'speech/transcribe': (_) => {'text': 'cloud text', 'audioSeconds': 1},
    });
    final bridge = FakeVoiceBridge()..recording = silentWav(1);
    final voice = controller(bridge, DshClient.withCarrier(carrier), preferredProviderId: voiceModelProviderId);

    expect(await transcribedProvider(tester, voice, carrier), 'cloud');
  });

  testWidgets('without the preference the saved default is used as before', (tester) async {
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => cloudDefault(),
      'speech/transcribe': (_) => {'text': 'cloud text', 'audioSeconds': 1},
    });
    final bridge = FakeVoiceBridge()..recording = silentWav(1);
    final voice = controller(bridge, DshClient.withCarrier(carrier));

    expect(await transcribedProvider(tester, voice, carrier), 'cloud');
  });

  testWidgets('an offline provider is preferred over a cloud default only when it is host-local', (tester) async {
    final catalog = cloudDefault();
    // Same id, but the engine reports it as a cloud provider: the id alone
    // does not prove it is the phone's own model, so the preference is skipped.
    ((catalog['providers'] as List).first as Map)['location'] = 'cloud';
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => catalog,
      'speech/transcribe': (_) => {'text': 'cloud text', 'audioSeconds': 1},
    });
    final bridge = FakeVoiceBridge()..recording = silentWav(1);
    final voice = controller(bridge, DshClient.withCarrier(carrier), preferredProviderId: voiceModelProviderId);

    expect(await transcribedProvider(tester, voice, carrier), 'cloud');
  });
}
