// Dictation must not depend on which host the message is sent to. The
// downloaded SenseVoice model lives in the on-device engine, and the remote
// tunnel / Codex carrier allowlists have no `speech/*` endpoint at all.
// These tests pin that choice: before the fix, connecting to a remote host
// made a ready local model unreachable.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/voice_transcription.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Local extends LocalConnectionController {
  _Local(this.connection);
  final HostConnection? connection;

  @override
  Future<HostConnection?> build() async => connection;
}

DshClient _client(String port) => DshClient(DshConnection(Uri.parse('http://127.0.0.1:$port')));

void main() {
  test('a running local engine serves dictation even while a remote host is active', () async {
    final local = _client('9');
    final remote = _client('10');
    final container = ProviderContainer(
      overrides: [
        localConnectionProvider.overrideWith(() => _Local(HostConnection(client: local, isLocal: true))),
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(client: remote, isLocal: false)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);

    expect(container.read(voiceTranscriptionClientProvider), same(local));
    expect(container.read(voiceModelAppliesProvider), isTrue);
  });

  test('without a local engine the active connection remains a fallback', () async {
    final remote = _client('11');
    final container = ProviderContainer(
      overrides: [
        localConnectionProvider.overrideWith(() => _Local(null)),
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(client: remote, isLocal: false)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);

    expect(container.read(voiceTranscriptionClientProvider), same(remote));
    // A remote-only screen must not re-probe a host with no speech endpoints
    // on every download progress tick.
    expect(container.read(voiceModelAppliesProvider), isFalse);
  });

  test('model events matter when the active host is the phone itself', () async {
    final local = _client('12');
    final container = ProviderContainer(
      overrides: [
        localConnectionProvider.overrideWith(() => _Local(null)),
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(client: local, isLocal: true)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);

    expect(container.read(voiceTranscriptionClientProvider), same(local));
    expect(container.read(voiceModelAppliesProvider), isTrue);
  });
}
