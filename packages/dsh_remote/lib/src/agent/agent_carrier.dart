// Composition of two carriers on one tunnel: the selected agent answers its
// own domain (sessions, transcripts, approvals), and the real Harness answers
// the global read-only surfaces (settings, credentials, plugin inventory).
//
// Without this, an ACP or Codex host shows empty settings and model pages: the
// ACP gateway is backend-neutral and projects no DSH settings, while the same
// authenticated tunnel still serves `settings/describe` and friends.
library;

import 'package:dsh_client/dsh_client.dart';

/// Endpoints a synthetic dialect carrier (Codex, ACP) delegates to the real
/// Harness on the same tunnel: the surfaces that describe the *computer*
/// rather than a conversation.
///
/// Session and workspace endpoints are deliberately absent: those must always
/// be answered by the dialect, never by the Harness, or a Codex thread would
/// silently appear as a DSH session (and vice versa).
const Set<String> dialectGlobalFallbackEndpoints = {
  'settings/describe',
  'settings/update',
  'settings/mutate',
  'settings/replace',
  'credentials/describe',
  'credentials/set',
  'credentials/unset',
  'llm/listProviders',
  'llm/discoverModels',
  'llm/listConfigurableProviders',
  'pluginInventory/list',
  'pluginManager/listBundles',
  'pluginManager/listPlugins',
  'pluginManager/setBundleEnabled',
  'pluginManager/setPluginEnabled',
  'skills/list',
  'directoryPicker/list',
  'agentPresets/list',
  'agentPresets/read',
  'permissionPresets/catalog',
};

/// A carrier that prefers [primary] and falls back to [fallback] for an
/// explicit set of global endpoints.
class AgentCarrier implements DshCarrier {
  AgentCarrier({required this.primary, required this.fallback, this.globalEndpoints = const {}});

  final DshCarrier primary;

  /// The Harness carrier of the same tunnel; null when there is none.
  final DshCarrier? fallback;

  /// Endpoints [fallback] may answer. Empty disables the fallback entirely.
  final Set<String> globalEndpoints;

  @override
  String get kind => primary.kind;

  @override
  String? get hostVersion => primary.hostVersion ?? fallback?.hostVersion;

  @override
  DshTracer? get tracer => primary.tracer;

  @override
  bool get supportsUplink => primary.supportsUplink;

  @override
  Set<String>? get peerCapabilities {
    final a = primary.peerCapabilities;
    final b = fallback?.peerCapabilities;
    if (a == null) return b;
    if (b == null) return a;
    return {...a, ...b};
  }

  @override
  bool allowsEndpoint(String endpoint) {
    if (primary.allowsEndpoint(endpoint)) return true;
    return globalEndpoints.contains(endpoint) && (fallback?.allowsEndpoint(endpoint) ?? false);
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    if (primary.allowsEndpoint(endpoint)) return primary.call(endpoint, args, timeout: timeout);
    final other = fallback;
    if (other != null && globalEndpoints.contains(endpoint) && other.allowsEndpoint(endpoint)) {
      return other.call(endpoint, args, timeout: timeout);
    }
    return Future<RpcResult>.value(
      RpcError(DshRemoteException('METHOD_NOT_ALLOWED', '$endpoint is not available on this host.')),
    );
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => primary.openLink(options);

  /// Never tears down the shared tunnel: the account (or the Harness carrier)
  /// owns it, and closing one dialect must not disconnect the other.
  @override
  Future<void> close() => primary.close();
}
