/// Optional always-on host bridge. Read-only DSH observation; never approves,
/// prompts or executes tasks. Environment credentials are never logged.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';

Future<void> main() async {
  final env = Platform.environment;
  final origin = Uri.parse(env['RADAR_ORIGIN'] ?? '');
  final token = env['RADAR_BRIDGE_TOKEN'] ?? '';
  final host = env['RADAR_HOST_ID'] ?? '';
  final launch = DshLaunchUrl.tryParse(env['DSH_LAUNCH_URL'] ?? '');
  if (origin.scheme != 'https' ||
      origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      (origin.path.isNotEmpty && origin.path != '/') ||
      token.length < 32 ||
      host.isEmpty ||
      launch == null ||
      !['127.0.0.1', 'localhost', '::1'].contains(launch.baseUri.host)) {
    stderr.writeln('Configure HTTPS RADAR_ORIGIN, RADAR_BRIDGE_TOKEN, RADAR_HOST_ID, and loopback DSH_LAUNCH_URL.');
    exitCode = 2;
    return;
  }
  final dir = Directory(env['RADAR_BRIDGE_STATE'] ?? 'radar-bridge-state')..createSync(recursive: true);
  final lock = File('${dir.path}/bridge.lock').openSync(mode: FileMode.append);
  lock.lockSync(FileLock.exclusive);
  final client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token, startMux: false);
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final watches = <String, StreamSubscription<DshEvent>>{};
  final checkpoints = File('${dir.path}/cursors.json');
  final cursors = checkpoints.existsSync()
      ? Map<String, int>.from(jsonDecode(checkpoints.readAsStringSync()) as Map)
      : <String, int>{};
  var serial = Future<void>.value();
  var posting = false;
  var stopping = false;
  final pendingSessions = <String, String>{};
  // 一个会话出问题不该拖垮整台桥：按会话重试，超过次数就放弃并等 session/added。
  final failures = <String, int>{};
  final retries = <String, Timer>{};
  final dead = Directory('${dir.path}/dead');

  void saveCursor() {
    final staging = File('${checkpoints.path}.tmp');
    staging.writeAsStringSync(jsonEncode(cursors), flush: true);
    staging.renameSync(checkpoints.path);
  }

  void queue(String id, String session, String kind, {String? eventId}) {
    final random = Random.secure();
    final name = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final staged = File('${dir.path}/$name.pending');
    staged.writeAsStringSync(
      jsonEncode({'id': id, 'host': host, 'session': session, 'kind': kind, 'event_id': eventId}),
      flush: true,
    );
    staged.renameSync('${dir.path}/$name.event');
  }

  /// 最多保留 200 条死信：它们只用于事后排查，不该无限增长。
  void trimDeadLetters() {
    if (!dead.existsSync()) return;
    final letters = dead.listSync().whereType<File>().toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (final file in letters.take(max(0, letters.length - 200))) {
      file.deleteSync();
    }
  }

  Future<int> sendEvent(File file) async {
    try {
      final request = await http.postUrl(origin.replace(path: '/events'));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.add(file.readAsBytesSync());
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } on Object {
      return 0;
    }
  }

  Future<void> post() async {
    if (posting) return;
    posting = true;
    try {
      final files = dir.listSync().whereType<File>().where((file) => file.path.endsWith('.event')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final status = await sendEvent(file).timeout(const Duration(seconds: 20), onTimeout: () => 0);
        if (status == 200) {
          file.deleteSync();
          continue;
        }
        if (status >= 400 && status < 500) {
          // 4xx 是永久拒绝（令牌被撤、字段不合法）。留在队列里会阻塞之后所有
          // 事件，所以移进死信目录后继续处理下一条。
          dead.createSync(recursive: true);
          file.renameSync('${dead.path}/${file.uri.pathSegments.last}');
          stderr.writeln('Event rejected with $status; moved to dead/.');
          trimDeadLetters();
          continue;
        }
        // 5xx / 网络：保留队列（保序），下一轮整体重试。
        break;
      }
    } finally {
      posting = false;
    }
  }

  void logEvent(String id, SessionLogEvent event) {
    if (event.seq <= (cursors[id] ?? -1)) return;
    if (event is TurnEndedEvent) {
      queue('$id:${event.seq}', id, event.reason.isError ? 'failed' : 'completed');
    }
    cursors[id] = event.seq;
  }

  Future<void> consume(String id, DshEvent event) async {
    if (event is SessionSnapshotEvent) {
      final logs = [...event.events];
      var more = event.hasMore;
      while (more && logs.isNotEmpty && logs.first.seq > (cursors[id] ?? -1) + 1) {
        final page = await client.history(id, beforeSeq: logs.first.seq, throughSeq: event.cursor, maxMessages: 500);
        if (page.events.isEmpty) break;
        logs.insertAll(0, page.events);
        more = page.hasMore;
      }
      for (final entry in logs) {
        logEvent(id, entry);
      }
      saveCursor();
      // A complete snapshot means this session is healthy again.
      failures.remove(id);
    } else if (event is SessionLogEvent) {
      logEvent(id, event);
      saveCursor();
    }
  }

  late void Function(String id) follow;

  /// One session failed: retry it alone with a short backoff.
  ///
  /// Exiting the process (the previous behaviour) stopped observation of *every*
  /// session because of one deleted or briefly misbehaving one; the durable
  /// cursor already makes a re-follow safe.
  void retry(String id, String why) {
    final watch = watches.remove(id);
    unawaited(watch?.cancel());
    final attempts = (failures[id] ?? 0) + 1;
    failures[id] = attempts;
    if (attempts > 3) {
      stderr.writeln('Gave up on one session after $attempts attempts ($why).');
      return;
    }
    stderr.writeln('Retrying one session in ${2 * attempts}s ($why).');
    retries[id] = Timer(Duration(seconds: 2 * attempts), () {
      retries.remove(id);
      follow(id);
    });
  }

  follow = (String id) {
    if (stopping || watches.containsKey(id)) return;
    watches[id] = client
        .watch(id, options: const WatchOptions(activate: false, assistantStream: false, includeHostEvents: false))
        .listen((event) {
          serial = serial.then((_) => consume(id, event)).catchError((Object _) => retry(id, 'history read failed'));
        }, onError: (Object _) => retry(id, 'history stream interrupted'));
  };

  final events = client.hostEvents.listen((event) {
    switch (event) {
      case SessionAddedEvent(:final summary):
        follow(summary.sessionId);
      case ApprovalRequestedEvent(:final request):
        pendingSessions[request.eventId] = request.sessionId;
        queue('approval:${request.eventId}', request.sessionId, 'approval', eventId: request.eventId);
      case UserQuestionRequestedEvent(:final request):
        pendingSessions[request.eventId] = request.sessionId;
        queue('question:${request.eventId}', request.sessionId, 'question', eventId: request.eventId);
      case HostRequestCancelledEvent(:final eventId):
        final session = pendingSessions.remove(eventId);
        if (session != null) queue('cancelled:$eventId', session, 'cancelled', eventId: eventId);
      default:
        break;
    }
  });
  await client.mux.ready();
  for (final session in await client.listSessions()) {
    follow(session.sessionId);
  }
  final timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(post()));
  final stopped = Completer<void>();
  final interrupt = ProcessSignal.sigint.watch().listen((_) {
    if (!stopped.isCompleted) stopped.complete();
  });
  final term = Platform.isWindows
      ? null
      : ProcessSignal.sigterm.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        });
  try {
    await stopped.future;
  } finally {
    stopping = true;
    timer.cancel();
    for (final retry in retries.values) {
      retry.cancel();
    }
    retries.clear();
    await events.cancel();
    for (final watch in watches.values) {
      await watch.cancel();
    }
    await serial;
    await client.close();
    http.close(force: true);
    await interrupt.cancel();
    await term?.cancel();
    lock.closeSync();
  }
}
