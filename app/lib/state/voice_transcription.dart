// Dictation is a phone-side input method, not a property of the host a message
// is sent to. The on-device engine owns the SenseVoice model and is the only
// carrier that serves `speech/*`: the remote tunnel and the Codex carrier
// allowlists contain no speech endpoint at all.
//
// Before this existed, the composer asked the *active* host for its speech
// catalog. Whenever the person was connected to a remote machine (or the Codex
// dialect) that call could never succeed, so a downloaded, ready model looked
// fine in settings but was never used: dictation fell back to the phone
// service, which on many Chinese ROMs reports itself available then fails.
//
// The local engine is now always preferred for transcription; the active
// connection is only a fallback for a device whose runtime is not running (and
// for tests, which inject a carrier there). The transcribed text still goes
// into the composer and is sent to whichever host is active.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// The client that serves the microphone's `speech/catalog` and
/// `speech/transcribe`. Null while no engine is reachable.
final voiceTranscriptionClientProvider = Provider<DshClient?>((ref) {
  final local = ref.watch(localConnectionProvider).value?.client;
  if (local != null) return local;
  return ref.watch(activeConnectionProvider).value?.client;
});

/// Whether a change to the on-device model can affect dictation on this
/// screen. The model controller only ever talks to the local engine, so a
/// model event matters when that engine is up (or when the active host *is*
/// the local engine). It keeps a remote-only screen from re-probing a host
/// that has no speech endpoints on every download progress tick.
final voiceModelAppliesProvider = Provider<bool>((ref) {
  if (ref.watch(localConnectionProvider).value?.client != null) return true;
  return ref.watch(activeConnectionProvider).value?.isLocal ?? false;
});
