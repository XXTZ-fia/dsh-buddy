import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import '../../notify/notify_channel.dart';
import '../../state/hosts_state.dart';
import '../../state/personal_server.dart';
import '../../state/radar_prefs.dart' show radarAutoRefresh;
import 'radar_client.dart';

/// Explicitly enabled best-effort polling. Server inbox remains authoritative;
/// Android can suspend this process, so this is not a push delivery guarantee.
class RadarInboxHost extends StatefulWidget {
  const RadarInboxHost({super.key, required this.child, this.transport});

  final Widget child;

  /// Test seam: answers `/events` without a real server.
  @visibleForTesting
  final http.Client? transport;

  @override
  State<RadarInboxHost> createState() => _RadarInboxHostState();
}

class _RadarInboxHostState extends State<RadarInboxHost> with WidgetsBindingObserver {
  /// The server fetches on a five-minute loop, so events arrive in bursts at
  /// that cadence. Two minutes still lands inside one server cycle but is a
  /// quarter of the old thirty-second wake-ups.
  static const interval = Duration(minutes: 2);

  final _storage = const FlutterSecureStorage();
  final _store = const RadarCredentialStore();
  final _notify = NotifyChannel();
  Timer? _timer;
  bool _polling = false;
  RadarClient? _client;

  /// Credentials and the user's switch are read once, then trusted until the
  /// connection epoch moves (sign-in, disconnect, switch flip).
  bool? _enabled;
  final Map<Uri, int> _cursors = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    radarAutoRefresh.addListener(_onAutoRefreshChanged);
    radarConnectionEpoch.addListener(_onCredentialsChanged);
    unawaited(radarAutoRefresh.load().then((_) {
      if (!mounted) return;
      _startTimer();
      // A fresh sign-in should sync immediately, but only when auto-refresh
      // is on: otherwise a cold start pays for a network round trip.
      if (radarAutoRefresh.value) unawaited(_poll());
    }));
  }

  void _onAutoRefreshChanged() {
    if (!mounted) return;
    if (radarAutoRefresh.value) {
      _startTimer();
      unawaited(_poll());
    } else {
      _timer?.cancel();
    }
  }

  /// Sign-in, disconnect and the polling switch all land here. The cached
  /// client and flag belong to the previous state, so they are dropped.
  void _onCredentialsChanged() {
    _dropSession();
    if (radarAutoRefresh.value) unawaited(_poll());
  }

  /// Polling is a foreground concern; a suspended app would only waste radio.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _startTimer();
      if (radarAutoRefresh.value) unawaited(_poll());
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (!radarAutoRefresh.value) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    radarAutoRefresh.removeListener(_onAutoRefreshChanged);
    radarConnectionEpoch.removeListener(_onCredentialsChanged);
    _timer?.cancel();
    _client?.close();
    super.dispose();
  }

  void _dropSession() {
    _client?.close();
    _client = null;
    _enabled = null;
  }

  /// Keeps one transport across polls instead of building and tearing down a
  /// fresh HTTP client every tick (a new connection each time, plus the
  /// keep-alive pool thrown away).
  Future<RadarClient?> _session() async {
    final existing = _client;
    if (existing != null) return existing;
    try {
      return _client = await RadarClient.saved(transport: widget.transport);
    } on FormatException {
      return null;
    }
  }

  Future<int> _cursor(RadarClient client, String key) async {
    final memory = _cursors[client.base];
    if (memory != null) return memory;
    return _cursors[client.base] = int.tryParse(await _storage.read(key: key) ?? '') ?? 0;
  }

  Future<void> _poll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final enabled = _enabled ??= await _store.pollingEnabled();
      if (!enabled || !mounted) return;
      final client = await _session();
      if (client == null || !mounted) return;
      final key = 'radarCursor:${client.base}';
      final after = await _cursor(client, key);
      if (!mounted) return;
      final doc = await client.request('/events', query: {'after': '$after', 'limit': '20'});
      for (final raw in doc['events'] as List) {
        if (!mounted) return;
        final row = raw as Map<String, dynamic>;
        if (row['read'] != true) {
          // Notification payload contains identifiers only; details require API auth.
          final accepted = await _notify.tryShow(
            NotifyPost(
              group: 'radar:${client.base}',
              key: '${row['id']}',
              attention: false,
              title: context.l10n.radarInbox,
              text: context.l10n.radarNewEvent,
              publicText: context.l10n.radarNewEvent,
              sessionId: 'radar-inbox',
              host: HostRef.local,
              kind: 'radar',
              eventId: jsonEncode({'origin': client.base.toString(), 'id': row['id']}),
            ),
          );
          if (!accepted) break;
        }
        final seq = '${row['seq']}';
        final parsed = int.tryParse(seq);
        if (parsed != null) _cursors[client.base] = parsed;
        await _storage.write(key: key, value: seq);
      }
    } on Object {
      // No credentials or response body in logs. Durable cursor retries next
      // poll: the cached session may hold a revoked token or a dead socket.
      _dropSession();
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
