// Composition: the agent answers its own domain, the Harness answers globals.
import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

class _FakeCarrier implements DshCarrier {
  _FakeCarrier(this.name, this.endpoints);

  final String name;
  final Set<String> endpoints;
  final List<String> calls = [];

  @override
  String get kind => name;

  @override
  String? get hostVersion => null;

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  Set<String>? get peerCapabilities => null;

  @override
  bool allowsEndpoint(String endpoint) => endpoints.contains(endpoint);

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    return RpcOk({'by': name});
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

void main() {
  late _FakeCarrier agent;
  late _FakeCarrier harness;
  late AgentCarrier composed;

  setUp(() {
    agent = _FakeCarrier('opencode', {'session/list', 'session/prompt', 'terminal/write'});
    harness = _FakeCarrier('remote-relay', {'session/list', 'settings/describe', 'plugins/list'});
    composed = AgentCarrier(
      primary: agent,
      fallback: harness,
      globalEndpoints: const {'settings/describe'},
    );
  });

  test('sessions never reach the Harness even when it serves the endpoint', () async {
    await composed.call('session/list', const {});
    expect(agent.calls, ['session/list']);
    expect(harness.calls, isEmpty);
  });

  test('a whitelisted global endpoint falls back to the Harness', () async {
    final result = await composed.call('settings/describe', const {});
    expect((result as RpcOk).value, {'by': 'remote-relay'});
    expect(harness.calls, ['settings/describe']);
  });

  test('an endpoint outside the whitelist is refused instead of leaking through', () async {
    final result = await composed.call('plugins/list', const {});
    expect(result, isA<RpcError>());
    expect((result as RpcError).error.code, 'METHOD_NOT_ALLOWED');
    expect(harness.calls, isEmpty, reason: 'the Harness serves it, but the ACP surface must not expose it');
  });

  test('allowsEndpoint mirrors the same policy', () {
    expect(composed.allowsEndpoint('session/prompt'), isTrue);
    expect(composed.allowsEndpoint('settings/describe'), isTrue);
    expect(composed.allowsEndpoint('plugins/list'), isFalse);
    expect(composed.allowsEndpoint('unknown/endpoint'), isFalse);
  });
}
