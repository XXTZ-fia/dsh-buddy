import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/chat_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import '../../state/personal_server.dart';
import '../../state/personal_tabs.dart';
import '../../state/radar_availability.dart';
import '../radar/radar_ask.dart';
import '../../state/sessions_state.dart';
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../common/status_dot.dart';
import '../remote/host_status.dart';
import '../remote/remote_screen.dart';
import 'page_frame.dart' show AppPage;
import 'work_destination.dart';
import '../agents/team_page.dart';
import '../features/agent_presets_page.dart';
import '../features/schedules_page.dart';
import '../files/files_page.dart';
import '../radar/radar_inbox_host.dart';
import '../radar/radar_management.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart' show DshColors, DshSurfaces;
import '../radar/radar_page.dart';
import '../session/session_artifacts.dart';
import '../settings/settings_screen.dart';
import '../web/mode_home.dart';
import '../workspace/workspaces_page.dart';

/// Keep the chat and its event subscriptions alive across the five destinations.
class PersonalHome extends ConsumerStatefulWidget {
  const PersonalHome({super.key, this.work});

  @visibleForTesting
  final Widget? work;

  @override
  ConsumerState<PersonalHome> createState() => _PersonalHomeState();
}

class _PersonalHomeState extends ConsumerState<PersonalHome>
    with SingleTickerProviderStateMixin {
  PersonalTab _tab = PersonalTab.work;
  final Set<PersonalTab> _visited = {PersonalTab.work};

  /// 可见目的地随中继类型变化：连官方中继时四个，连自建服务器时五个。
  /// 雷达需要用户自己的服务器，官方中继不跑雷达后端。
  List<PersonalTab> _tabsFor(bool radarAvailable) => [
    PersonalTab.work,
    if (radarAvailable) PersonalTab.radar,
    PersonalTab.automation,
    PersonalTab.library,
    PersonalTab.settings,
  ];

  int _indexFor(List<PersonalTab> tabs) {
    final index = tabs.indexOf(_tab);
    return index < 0 ? 0 : index;
  }

  /// 切 tab 时整块内容的淡入淡出。IndexedStack 保状态,但没有过渡,换页
  /// 是硬切;这里只加一层很短的明暗,页面本身不重建、滚动位置不丢。
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    personalTabsAvailable = true;
    personalTabRequest.addListener(_onTabRequest);
  }

  @override
  void dispose() {
    _fade.dispose();
    personalTabsAvailable = false;
    personalTabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  void _onTabRequest() {
    final tab = personalTabRequest.value;
    if (tab == null || !mounted) return;
    _select(tab);
    personalTabRequest.value = null;
  }

  void _select(PersonalTab value) {
    FocusManager.instance.primaryFocus?.unfocus();
    // 官方中继下雷达不存在：任何指向它的跳转都落到设置页。
    if (value == PersonalTab.radar && !ref.read(radarAvailableProvider)) {
      value = PersonalTab.settings;
    }
    ref.read(chatOnScreenProvider.notifier).set(value == PersonalTab.work);
    if (value == _tab) {
      if (!_visited.contains(value)) setState(() => _visited.add(value));
      return;
    }
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      setState(() {
        _tab = value;
        _visited.add(value);
      });
      return;
    }
    // 立即换页,只做一次淡入:不再先等 150ms 淡出,点哪页就是哪页。
    setState(() {
      _tab = value;
      _visited.add(value);
    });
    _fade.forward(from: 0);
  }

  Widget _pageFor(PersonalTab tab) => switch (tab) {
    PersonalTab.work => widget.work ?? const ModeHome(),
    PersonalTab.radar => RadarPage(onResearch: () => _select(PersonalTab.work)),
    PersonalTab.automation => const _AutomationHome(),
    PersonalTab.library => const _LibraryHome(),
    PersonalTab.settings => const SettingsScreen(),
  };

  @override
  Widget build(BuildContext context) {
    ref.listen(radarAskProvider, (_, next) {
      if (next != null) _select(PersonalTab.work);
    });
    // 启动即预热当前会话：home 常驻，chatProvider 随连接变化重建，
    // 用户点进「工作」时 history 往往已经在路上或已到。
    final prewarm = ref.watch(currentSessionProvider);
    if (prewarm != null) {
      ref.watch(chatProvider(prewarm).select((s) => s.loading));
    }
    ref.listen(currentSessionProvider, (previous, next) {
      if (next != previous) _select(PersonalTab.work);
    });
    final radarAvailable = ref.watch(radarAvailableProvider);
    ref.listen<bool>(radarAvailableProvider, (previous, next) {
      if (next == previous || next) return;
      if (_tab == PersonalTab.radar) {
        _select(PersonalTab.settings);
      }
      _visited.remove(PersonalTab.radar);
    });
    final tabs = _tabsFor(radarAvailable);
    final body = PopScope(
      canPop: _tab == PersonalTab.work,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(PersonalTab.work);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: FadeTransition(
          opacity: _fade,
          child: IndexedStack(
            index: _indexFor(tabs),
            children: [
              for (final tab in tabs)
                _visited.contains(tab)
                    ? _pageFor(tab)
                    : const SizedBox.shrink(),
            ],
          ),
        ),
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : _RadarNavBar(tabs: tabs, index: _indexFor(tabs), onSelect: _select),
      ),
    );
    return WorkDestination(
      reveal: () => _select(PersonalTab.work),
      // 雷达不存在时不挂轮询宿主：它每 30 秒会去请求 /events。
      child: radarAvailable ? RadarInboxHost(child: body) : body,
    );
  }
}

void _open(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

/// The bottom bar, stripped to icons and labels.
///
/// Material's default paints a tinted pill behind the active destination — the
/// last box on the screen. Removed: active state is colour and weight only, and
/// a single hairline separates the bar from the page. Colours come from the
/// app theme, like every other surface in the shell.
class _RadarNavBar extends StatelessWidget {
  const _RadarNavBar({
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  final List<PersonalTab> tabs;
  final int index;
  final ValueChanged<PersonalTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final chrome = DshSurfaces.of(context).chrome;
    return Container(
      decoration: BoxDecoration(
        color: chrome.fallbackFill,
        border: Border(
          top: BorderSide(color: chrome.hairline, width: chrome.hairlineWidth),
        ),
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          indicatorColor: Colors.transparent,
          elevation: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          // 选中只靠明度,不靠主色:参考图里底栏是一排灰,当前那一项亮起来。
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected)
                  ? scheme.onSurface
                  : colors.textTertiary,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 10.5,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? scheme.onSurface
                  : colors.textTertiary,
            ),
          ),
        ),
        child: NavigationBar(
          height: 62,
          selectedIndex: index,
          onDestinationSelected: (selected) => onSelect(tabs[selected]),
          destinations: [
            for (final tab in tabs)
              NavigationDestination(
                icon: Icon(switch (tab) {
                  PersonalTab.work => AppIcons.navWork,
                  PersonalTab.radar => AppIcons.navRadar,
                  PersonalTab.automation => AppIcons.navAutomation,
                  PersonalTab.library => AppIcons.navLibrary,
                  PersonalTab.settings => AppIcons.navMine,
                }),
                label: switch (tab) {
                  PersonalTab.work => t.radarWork,
                  PersonalTab.radar => t.radarTitle,
                  PersonalTab.automation => t.radarAutomationTab,
                  PersonalTab.library => t.radarLibrary,
                  PersonalTab.settings => t.radarMine,
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Previously these two entries were simply disabled with no explanation.
/// Now the tap always does something useful: tell the person why and take them
/// to the Work tab where a task can be selected.
void _openWithSession(
  BuildContext context,
  String? session,
  Widget Function(String id) builder,
) {
  if (session == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.radarChooseSession)));
    openPersonalTab(PersonalTab.work);
    return;
  }
  _open(context, builder(session));
}

class _AutomationHome extends ConsumerWidget {
  const _AutomationHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final radarAvailable = ref.watch(radarAvailableProvider);
    return _PersonalPage(
      title: t.radarAutomationTab,
      hint: t.radarAutomationHint,
      groups: [
        // 官方中继没有雷达后端：服务/运行/收件箱三个入口一起消失。
        if (radarAvailable)
          _Group(
            title: t.radarServerGroup,
            entries: [
              _Entry(
                icon: AppIcons.automation,
                label: t.radarAutomation,
                onTap: () => _open(
                  context,
                  const RadarManagementPage(section: RadarSection.schedules),
                ),
              ),
              _Entry(
                icon: AppIcons.history,
                label: t.radarRuns,
                onTap: () => _open(
                  context,
                  const RadarManagementPage(section: RadarSection.runs),
                ),
              ),
              _Entry(
                icon: AppIcons.notifications,
                label: t.radarInbox,
                onTap: () => _open(
                  context,
                  const RadarManagementPage(section: RadarSection.events),
                ),
              ),
            ],
          ),
        _Group(
          title: t.radarHostGroup,
          leading: const _HostStatusEntry(),
          entries: [
            _Entry(
              icon: AppIcons.scheduled,
              label: t.radarHostSchedules,
              onTap: () => _open(context, const SchedulesPage()),
            ),
            _Entry(
              icon: AppIcons.team,
              label: t.botsAgentTeam,
              onTap: () => _open(context, const TeamPage()),
            ),
            _Entry(
              icon: AppIcons.bot,
              label: t.radarExperts,
              onTap: () => _open(context, const AgentPresetsPage()),
            ),
          ],
        ),
      ],
    );
  }
}

class _LibraryHome extends ConsumerWidget {
  const _LibraryHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final session = ref.watch(currentSessionProvider);
    return _PersonalPage(
      title: t.radarLibrary,
      hint: t.radarLibraryHint,
      groups: [
        _Group(
          title: t.radarServerGroup,
          entries: [
            _Entry(
              icon: AppIcons.cloud,
              label: t.radarCloudFiles,
              onTap: () => _open(
                context,
                const RadarManagementPage(section: RadarSection.artifacts),
              ),
            ),
          ],
        ),
        _Group(
          title: t.radarLocalGroup,
          entries: [
            _Entry(
              icon: AppIcons.workspaceGroup,
              label: t.radarProjects,
              onTap: () => _open(context, const WorkspacesPage()),
            ),
            _Entry(
              icon: AppIcons.files,
              label: t.radarSessionFiles,
              subtitle: session == null ? t.radarChooseSession : null,
              onTap: () => _openWithSession(
                context,
                session,
                (id) => SessionArtifactsPage(sessionId: id),
              ),
            ),
            _Entry(
              icon: AppIcons.folderOpen,
              label: t.radarWorkspaceFiles,
              subtitle: session == null ? t.radarChooseSession : null,
              onTap: () => _openWithSession(
                context,
                session,
                (id) => WorkspaceFilesPage(sessionId: id),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Shared page shell for the two new destinations: one large title, one line of
/// context, then one card per labelled run of rows.
///
/// It uses the same [AppPage] frame and [ListPageCard] rows as the rest of the
/// app: no bordered boxes, no tinted icon tiles, hairlines only where the frame
/// puts them.
class _PersonalPage extends StatelessWidget {
  const _PersonalPage({
    required this.title,
    required this.hint,
    required this.groups,
  });

  final String title;
  final String hint;
  final List<_Group> groups;

  @override
  Widget build(BuildContext context) {
    return AppPage.list(
      title: title,
      subtitle: Text(hint),
      showBack: false,
      children: [
        const _ConnectionBanner(),
        for (final group in groups)
          ListPageCard(
            title: group.title,
            children: [
              if (group.leading != null) group.leading!,
              for (final entry in group.entries)
                ListPageRow(
                  icon: entry.icon,
                  title: entry.label,
                  subtitle: entry.subtitle,
                  subtitleColor: entry.subtitle == null
                      ? null
                      : DshColors.of(context).warning,
                  onTap: entry.onTap,
                ),
            ],
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// One quiet line about the server link. It used to be a bordered card holding
/// a pill, a sentence and a button — three boxes to say one true/false.
class _ConnectionBanner extends ConsumerStatefulWidget {
  const _ConnectionBanner();

  @override
  ConsumerState<_ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<_ConnectionBanner> {
  bool? _connected;

  @override
  void initState() {
    super.initState();
    radarConnectionEpoch.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    radarConnectionEpoch.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    unawaited(_read());
  }

  Future<void> _read() async {
    bool connected;
    try {
      final saved = await const RadarCredentialStore().read();
      connected = saved != null && saved.isComplete;
    } on Object {
      // Secure storage can be unavailable (first run / locked device).
      connected = false;
    }
    if (mounted) setState(() => _connected = connected);
  }

  @override
  Widget build(BuildContext context) {
    // 官方中继下这条服务器状态也不该出现（它带着「信息雷达」入口）。
    if (!ref.watch(radarAvailableProvider)) return const SizedBox.shrink();
    final t = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final connected = _connected == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 8, 8, 8),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: connected ? colors.success : colors.warning,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            connected ? t.radarConnected : t.radarNotConnected,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: connected ? scheme.onSurfaceVariant : colors.warning,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t.radarServerNote,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => openPersonalTab(PersonalTab.radar),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(
              connected ? t.radarTitle : t.radarGoConnect,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live link to the computer running DSH (or the on-device engine). The
/// host-dependent entries below this row are useless while it is down, so the
/// row says why and opens the host page (parameters, connection test, retry).
class _HostStatusEntry extends ConsumerWidget {
  const _HostStatusEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    final active = ref.watch(activeHostProvider);
    final view = watchHostStatus(ref, active);
    final name = active.isLocal
        ? t.commonThisPhone
        : ref.watch(hostNameProvider(active)) ?? t.commonRemoteHost;
    final link = active.isLocal
        ? null
        : ref.watch(hostLinkStatusProvider(active)).value;
    final failure = link?.phase == HostLinkPhase.failed
        ? link?.error?.message
        : null;
    final color = switch (view.tone) {
      StatusTone.ok => colors.success,
      StatusTone.busy => scheme.primary,
      StatusTone.warn => colors.warning,
      StatusTone.error => colors.danger,
      StatusTone.idle => colors.textTertiary,
    };
    return ListPageRow(
      leading: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: name,
      subtitle: failure,
      subtitleColor: failure == null ? null : colors.danger,
      trailing: Text(
        view.label,
        style: TextStyle(fontSize: 11.5, color: color),
      ),
      onTap: () => _open(context, const RemoteScreen()),
    );
  }
}

class _Group {
  const _Group({required this.title, required this.entries, this.leading});
  final String title;
  final List<_Entry> entries;

  /// Optional live status row rendered above the static entries.
  final Widget? leading;
}

class _Entry {
  const _Entry({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
}
