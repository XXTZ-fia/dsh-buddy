import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import '../../state/personal_server.dart';
import '../../state/personal_tabs.dart';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../shell/page_frame.dart' show AppPage, GlassIconButton;
import '../theme/app_icons.dart';
import '../theme/theme.dart' show AppShape, DshColors;
import 'radar_client.dart';
import 'radar_page.dart';

enum RadarSection { schedules, events, artifacts, runs, devices }

class RadarManagementPage extends StatefulWidget {
  const RadarManagementPage({super.key, required this.section});
  final RadarSection section;
  @override
  State<RadarManagementPage> createState() => _RadarManagementPageState();
}

class _RadarManagementPageState extends State<RadarManagementPage> {
  List<dynamic> _rows = [];
  bool _busy = true;
  String? _error;
  bool _needsConnection = false;
  RadarClient? _client;
  Map<String, dynamic>? _identity;
  int _cursor = 0;
  bool _hasMore = false;
  final Map<String, String> _runKeys = {};

  /// The inbox switch lives on this page; see [_loadPolling].
  bool _polling = false;
  bool _pollingKnown = false;

  String get _path => '/${widget.section.name}';
  @override
  void initState() {
    super.initState();
    _load();
    if (widget.section == RadarSection.events) unawaited(_loadPolling());
  }

  Future<void> _loadPolling() async {
    final value = await const RadarCredentialStore().pollingEnabled();
    if (!mounted) return;
    setState(() {
      _polling = value;
      _pollingKnown = true;
    });
  }

  /// Best-effort inbox polling used to have storage and a host that read it,
  /// but nothing ever wrote the flag, so notifications could not be turned on.
  /// This is the missing writer.
  Future<void> _setPolling(bool value) async {
    setState(() => _polling = value);
    await const RadarCredentialStore().setPolling(value);
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _action(
    Future<void> Function() action, {
    bool connection = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
      if (connection) _needsConnection = false;
    });
    try {
      await action();
    } on FormatException {
      if (mounted) {
        setState(() {
          _needsConnection = connection;
          _error = connection
              ? context.l10n.radarConnectRequired
              : context.l10n.radarFailure;
        });
      }
    } on RadarApiException catch (e) {
      if (mounted) {
        setState(() {
          _needsConnection = e.statusCode == 401;
          _error = _needsConnection
              ? context.l10n.radarTokenExpired
              : context.l10n.radarFailure;
        });
      }
    } on Object {
      if (mounted) setState(() => _error = context.l10n.radarFailure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final result = await _client!.request(_path);
    _cursor = widget.section == RadarSection.events
        ? result['cursor'] as int
        : 0;
    if (mounted) {
      setState(() {
        _rows = widget.section == RadarSection.events
            ? result['events'] as List
            : result as List;
        _hasMore = _rows.length == 50;
      });
    }
  }

  Future<void> _load() => _action(() async {
    _client?.close();
    _client = await RadarClient.saved();
    _identity = await _client!.request('/identity') as Map<String, dynamic>;
    await _refresh();
  }, connection: true);

  Future<void> _moreRows() => _action(() async {
    final result = await _client!.request(
      _path,
      query: widget.section == RadarSection.events
          ? {'after': '$_cursor'}
          : {'offset': '${_rows.length}'},
    );
    final rows = widget.section == RadarSection.events
        ? result['events'] as List
        : result as List;
    if (!mounted) return;
    setState(() {
      _rows.addAll(rows);
      if (widget.section == RadarSection.events)
        _cursor = result['cursor'] as int;
      _hasMore = rows.length == 50;
    });
  });

  Future<void> _enroll() => _action(() async {
    final issued = await _client!.request(
      '/devices',
      method: 'POST',
      body: {'name': 'Android'},
    );
    await const RadarCredentialStore().save(
      RadarCredentials(
        url: _client!.base.toString(),
        token: '${issued['token']}',
      ),
    );
    _client!.close();
    _client = await RadarClient.saved();
    _identity = await _client!.request('/identity') as Map<String, dynamic>;
    await _refresh();
  });

  Map<String, dynamic> _scheduleBody(Map<String, dynamic> row) => {
    for (final key in [
      'title',
      'version',
      'enabled',
      'interval_minutes',
      'time_zone',
      'next_run',
      'no_model',
    ])
      key: row[key],
  };

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final title = TextEditingController(
      text: row?['title'] as String? ?? context.l10n.radarTitle,
    );
    final minutes = TextEditingController(
      text: '${row?['interval_minutes'] ?? 60}',
    );
    final zone = TextEditingController(
      text: row?['time_zone'] as String? ?? 'Asia/Shanghai',
    );
    bool model = !(row?['no_model'] as bool? ?? true);
    final value = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(context.l10n.radarAutomation),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: InputDecoration(
                    labelText: context.l10n.radarName,
                  ),
                ),
                TextField(
                  controller: minutes,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: context.l10n.radarInterval,
                  ),
                ),
                TextField(
                  controller: zone,
                  decoration: InputDecoration(
                    labelText: context.l10n.featuresTimeZone,
                  ),
                ),
                SwitchListTile(
                  title: Text(context.l10n.radarUseModel),
                  value: model,
                  onChanged: (v) => update(() => model = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                final interval = int.tryParse(minutes.text);
                if (interval == null ||
                    interval < 5 ||
                    interval > 525600 ||
                    title.text.trim().isEmpty)
                  return;
                Navigator.pop(dialog, {
                  'title': title.text.trim(),
                  'version': row?['version'] ?? 0,
                  'enabled': row?['enabled'] ?? true,
                  'interval_minutes': interval,
                  'time_zone': zone.text.trim(),
                  'no_model': !model,
                  'next_run':
                      row?['next_run'] ??
                      DateTime.now().millisecondsSinceEpoch / 1000 +
                          interval * 60,
                });
              },
              child: Text(context.l10n.commonSave),
            ),
          ],
        ),
      ),
    );
    // Dialog route still owns the fields through its exit animation.
    Future<void>.delayed(const Duration(seconds: 1), () {
      title.dispose();
      minutes.dispose();
      zone.dispose();
    });
    if (value == null || !mounted) return;
    await _action(() async {
      await _client!.request(
        row == null ? _path : '$_path/${row['id']}',
        body: value,
        method: row == null ? 'POST' : 'PUT',
      );
      await _refresh();
    });
  }

  Future<void> _upload() => _action(() async {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final bytes = BytesBuilder();
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > 20 * 1024 * 1024)
        throw const FormatException('File too large');
      bytes.add(chunk);
    }
    await _client!.transfer(
      '/artifacts',
      method: 'POST',
      query: {'name': file.name},
      bytes: bytes.takeBytes(),
    );
    await _refresh();
  });

  Future<void> _delete(Map<String, dynamic> row) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.commonDelete),
        content: Text('${row['title'] ?? row['name']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _action(() async {
      await _client!.request(
        '$_path/${row['id']}',
        method: 'DELETE',
        query: row.containsKey('version')
            ? {'version': '${row['version']}'}
            : null,
      );
      await _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final colors = DshColors.of(context);
    final title = switch (widget.section) {
      RadarSection.schedules => t.radarAutomation,
      RadarSection.events => t.radarInbox,
      RadarSection.artifacts => t.radarCloudFiles,
      RadarSection.runs => t.radarRuns,
      RadarSection.devices => t.radarDevices,
    };
    final rows = [
      for (final raw in _rows) _row(Map<String, dynamic>.from(raw as Map)),
    ];
    return AppPage.list(
      title: title,
      actions: [
        GlassIconButton(
          icon: AppIcons.refresh,
          tooltip: t.radarConnect,
          onPressed: _busy ? null : _load,
        ),
        if (widget.section == RadarSection.devices &&
            _identity?['admin'] == true)
          GlassIconButton(
            icon: AppIcons.link,
            tooltip: t.radarEnroll,
            onPressed: _busy ? null : _enroll,
          ),
        if (widget.section == RadarSection.schedules)
          GlassIconButton(
            icon: AppIcons.add,
            tooltip: t.featuresNew,
            onPressed: _busy || _client == null ? null : _edit,
          ),
        if (widget.section == RadarSection.artifacts)
          GlassIconButton(
            icon: AppIcons.uploadToHost,
            tooltip: t.radarUpload,
            onPressed: _busy || _client == null ? null : _upload,
          ),
      ],
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_error != null) _errorCard(t),
        if (widget.section == RadarSection.events && _pollingKnown)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.notifications,
                  title: t.radarPolling,
                  trailing: Switch(
                    key: const ValueKey('radar-polling'),
                    value: _polling,
                    onChanged: _setPolling,
                  ),
                ),
              ],
            ),
          ),
        if (rows.isEmpty)
          if (!_busy && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ListPageRow.horizontal,
                24,
                ListPageRow.horizontal,
                24,
              ),
              child: Text(
                t.radarNoRecords,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.textTertiary),
              ),
            )
          else
            const SizedBox.shrink()
        else
          ListPageCard(children: rows),
        if ((widget.section == RadarSection.events ||
                widget.section == RadarSection.artifacts ||
                widget.section == RadarSection.runs) &&
            _hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ListPageRow.horizontal,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _moreRows,
                child: Text(t.radarMore),
              ),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// One quiet card about the failure: a soft tint, no outline, the retry (and,
  /// when the token is the problem, the way to reconnect) right under it.
  Widget _errorCard(dynamic t) {
    final colors = DshColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        ListPageRow.horizontal,
        0,
        ListPageRow.horizontal,
        12,
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.10),
        borderRadius: AppShape.radiusLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(_error!, style: Theme.of(context).textTheme.bodySmall),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : _load,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(t.radarRetry),
              ),
              if (_needsConnection)
                TextButton.icon(
                  onPressed: () {
                    if (personalTabsAvailable) {
                      openPersonalTab(PersonalTab.radar);
                      Navigator.of(context).maybePop();
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const RadarPage(),
                        ),
                      );
                    }
                  },
                  icon: const Icon(AppIcons.link, size: 17),
                  label: Text(t.radarGoConnect),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// One record. Records are rows of one card, like every other list page —
  /// no boxes, no dividers.
  Widget _row(Map<String, dynamic> row) {
    final t = context.l10n;
    final colors = DshColors.of(context);
    if (widget.section == RadarSection.schedules) {
      final next = DateTime.fromMillisecondsSinceEpoch(
        ((row['next_run'] as num) * 1000).toInt(),
      ).toUtc();
      return Column(
        children: [
          ListPageRow(
            icon: AppIcons.automation,
            title: '${row['title']}',
            subtitle:
                '${t.radarInterval}: ${row['interval_minutes']} · ${row['time_zone']} · UTC: $next',
            trailing: Switch(
              value: row['enabled'] == true,
              onChanged: _busy
                  ? null
                  : (enabled) => _action(() async {
                      await _client!.request(
                        '$_path/${row['id']}',
                        body: {..._scheduleBody(row), 'enabled': enabled},
                      );
                      await _refresh();
                    }),
            ),
            onTap: _busy ? null : () => _edit(row),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _action(() async {
                          await _client!.request(
                            '/runs',
                            method: 'POST',
                            body: {
                              'key': _runKeys.putIfAbsent(
                                '${row['id']}',
                                () =>
                                    'manual-${DateTime.now().microsecondsSinceEpoch}',
                              ),
                              'dry_run': false,
                              'no_model': row['no_model'],
                            },
                          );
                          _runKeys.remove('${row['id']}');
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(t.radarQueued)),
                            );
                          }
                        }),
                  child: Text(t.radarRun),
                ),
                IconButton(
                  onPressed: _busy ? null : () => _delete(row),
                  icon: const Icon(AppIcons.delete, size: 20),
                  tooltip: t.commonDelete,
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (widget.section == RadarSection.devices) {
      return ListPageRow(
        icon: AppIcons.profile,
        title: '${row['name']}',
        subtitle: '${row['id']}',
        trailing: row['revoked'] == true
            ? const Icon(AppIcons.offline, size: 20)
            : IconButton(
                onPressed:
                    _busy ||
                        (_identity?['admin'] != true &&
                            _identity?['id'] != row['id'])
                    ? null
                    : () => _delete(row),
                icon: const Icon(AppIcons.delete, size: 20),
                tooltip: t.commonDelete,
              ),
      );
    }
    if (widget.section == RadarSection.events) {
      final read = row['read'] == true;
      return ListPageRow(
        icon: read ? AppIcons.done : AppIcons.notifications,
        iconColor: read ? colors.textTertiary : null,
        title: '${row['kind']}',
        subtitle:
            '${row['host'] ?? 'radar-server'} · ${row['session'] ?? row['run'] ?? row['id']}',
        trailing: row['session'] == null
            ? null
            : IconButton(
                icon: const Icon(AppIcons.openLink, size: 20),
                tooltip: t.radarWork,
                onPressed: () {
                  final container = ProviderScope.containerOf(
                    context,
                    listen: false,
                  );
                  final matches = container
                      .read(hostsProvider)
                      .ssh
                      .where(
                        (host) =>
                            host.id == row['host'] || host.name == row['host'],
                      )
                      .toList();
                  if (matches.length != 1) {
                    setState(() => _error = t.radarHostMismatch);
                    return;
                  }
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  container
                      .read(chatAlertsProvider.notifier)
                      .open(
                        HostRef.ssh(matches.single.id),
                        '${row['session']}',
                      );
                },
              ),
        onTap: _busy
            ? null
            : () => _action(() async {
                await _client!.request(
                  '/events/${row['id']}/read',
                  method: 'PUT',
                );
                await _refresh();
              }),
      );
    }
    if (widget.section == RadarSection.artifacts) {
      return ListPageRow(
        icon: AppIcons.files,
        title: '${row['name']}',
        subtitle: '${row['host']} · ${row['session']} · ${row['size']} B',
        trailing: IconButton(
          onPressed: _busy ? null : () => _delete(row),
          icon: const Icon(AppIcons.delete, size: 20),
          tooltip: t.commonDelete,
        ),
        onTap: _busy
            ? null
            : () => _action(() async {
                final bytes = await _client!.transfer(
                  '/artifacts/${row['id']}',
                );
                final name = '${row['name']}'.replaceAll(
                  RegExp(r'[/\\\x00-\x1f]'),
                  '_',
                );
                await SharePlus.instance.share(
                  ShareParams(
                    files: [XFile.fromData(bytes, name: name)],
                    fileNameOverrides: [name],
                  ),
                );
              }),
      );
    }
    return ListPageRow(
      icon: AppIcons.history,
      title: '${row['status']}',
      subtitle: '${row['key']} · ${row['result']}',
    );
  }
}
