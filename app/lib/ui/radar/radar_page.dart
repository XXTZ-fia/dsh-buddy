import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import '../../state/personal_server.dart';
import '../../state/radar_prefs.dart';
import '../../state/settings_state.dart';
import 'radar_client.dart';
import 'radar_brief_api.dart';
import 'radar_brief_view.dart';
import 'radar_digest_view.dart';
import 'radar_hot_api.dart';
import 'radar_hot_view.dart';
import 'radar_links.dart';
import 'radar_management.dart';
import 'radar_paper_settings.dart';
import 'radar_papers_api.dart';
import 'radar_papers_view.dart';
import 'radar_self_host_page.dart';
import 'radar_source_picker.dart';
import 'radar_visuals.dart';
import '../theme/app_icons.dart';

/// 三个页签：原始热榜、服务端整理好的六平台简报，以及跨源共识与 AI 洞察。
enum RadarTab { hot, brief, digest }

class RadarPage extends StatefulWidget {
  const RadarPage({super.key, this.onResearch, this.transport});

  /// 保留给宿主页（个人页用它跳回会话）；热榜本身不再产生研究任务。
  final VoidCallback? onResearch;

  /// Test seam: lets widget tests answer the radar API without a real server.
  @visibleForTesting
  final http.Client? transport;

  @override
  State<RadarPage> createState() => _RadarPageState();
}

class _RadarPageState extends State<RadarPage> with WidgetsBindingObserver {
  /// 服务端每 5 分钟抓一轮，手机端同样节奏；App 在后台时完全不联网。
  static const _autoRefreshInterval = Duration(minutes: 5);

  /// 吸顶切换条的总高：切换条自身 46 + 顶部 8 留白。
  static const _railHeight = 54.0;

  final _url = TextEditingController(text: personalServerOrigin);
  final _token = TextEditingController();
  final _scroll = ScrollController();
  final _store = const RadarCredentialStore();

  Timer? _autoRefresh;
  DateTime? _lastLoadedAt;

  RadarClient? _client;
  RadarCredentials? _credentials;
  RadarTab _tab = RadarTab.hot;

  final RadarHotController _hot = RadarHotController();
  final RadarBriefController _brief = RadarBriefController();
  final RadarDigestController _digest = RadarDigestController();
  final RadarPapersController _papers = RadarPapersController();
  String? _hotFilter;
  bool _hotBusy = false;
  bool _busy = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    radarPrefs.addListener(_onPrefsChanged);
    radarAutoRefresh.addListener(_onAutoRefreshChanged);
    // 概览的取数是异步的：控制器一通知就重建，不然切到概览后只能停在
    // 转圈上，得再切一次页签才看到内容。
    _digest.addListener(_onRemoteDataChanged);
    _brief.addListener(_onRemoteDataChanged);
    unawaited(radarPrefs.load());
    unawaited(radarAutoRefresh.load());
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    radarPrefs.removeListener(_onPrefsChanged);
    radarAutoRefresh.removeListener(_onAutoRefreshChanged);
    _digest.removeListener(_onRemoteDataChanged);
    _brief.removeListener(_onRemoteDataChanged);
    _autoRefresh?.cancel();
    _url.dispose();
    _token.dispose();
    _scroll.dispose();
    _client?.close();
    _digest.dispose();
    _brief.dispose();
    super.dispose();
  }

  void _onRemoteDataChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!radarAutoRefresh.value) return;
      _startAutoRefresh();
      final last = _lastLoadedAt;
      final stale =
          last == null ||
          DateTime.now().difference(last) >= _autoRefreshInterval;
      if (_client != null && stale) unawaited(_refresh());
    } else if (state == AppLifecycleState.paused) {
      // No background network chatter: refresh resumes when the app returns.
      _autoRefresh?.cancel();
    }
  }

  void _onPrefsChanged() {
    if (!mounted) return;
    final hotFilter = _hotFilter;
    // 「论文」不是来源 id，不能按「来源被取消关注」处理。
    if (hotFilter != null &&
        hotFilter != RadarHotRail.papersId &&
        !radarPrefs.value.hasHotSource(hotFilter)) {
      _hotFilter = null;
    }
    setState(() {});
  }

  void _onAutoRefreshChanged() {
    if (!mounted) return;
    if (radarAutoRefresh.value) {
      _startAutoRefresh();
      if (_client != null) unawaited(_refresh());
    } else {
      _autoRefresh?.cancel();
    }
  }

  void _startAutoRefresh() {
    _autoRefresh?.cancel();
    // With launch auto-refresh off, the page still loads once when opened and
    // keeps its manual refresh button, but no background timer or resume fetch.
    if (!radarAutoRefresh.value) return;
    _autoRefresh = Timer.periodic(_autoRefreshInterval, (_) {
      if (mounted && _client != null && !_busy) unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    switch (_tab) {
      case RadarTab.hot:
        await _loadHot(force: true);
      case RadarTab.brief:
        await _loadBrief(force: true);
      case RadarTab.digest:
        await _loadDigest(force: true);
    }
  }

  Future<void> _restore() async {
    try {
      final saved = await _store.read();
      if (!mounted) return;
      if (saved != null && saved.isComplete) {
        _credentials = saved;
        _url.text = saved.url;
        _token.text = saved.token;
        _client?.close();
        _client = RadarClient(
          baseUrl: saved.url,
          token: saved.token,
          transport: widget.transport,
        );
        await _syncModelKey();
        await _loadHot();
        _startAutoRefresh();
      }
    } on Object {
      if (mounted) setState(() => _error = context.l10n.radarFailure);
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  /// 把 App 里存的 DeepSeek Key 挂到雷达连接上。
  ///
  /// App 的「DeepSeek 账号登录」是 Host 侧的 OAuth 授权，令牌到不了手机、也不是
  /// `sk-` 形式的平台 Key，所以雷达服务端用不上它；真正能用的是设置里那份 API Key。
  Future<void> _syncModelKey() async {
    final key = await readStoredApiKey();
    if (!mounted) return;
    _client?.modelKey = key.trim();
  }

  Future<bool> _connect(String rawUrl, String rawToken) async {
    final credentials = RadarCredentials(
      url: normalizeRadarOrigin(rawUrl),
      token: rawToken.trim(),
    );
    // 开源版没有内置服务器：地址或令牌缺一个都要给出明确提示，而不是静默什么都不做。
    if (!credentials.isComplete) {
      if (mounted) setState(() => _error = context.l10n.radarFailure);
      return false;
    }
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    RadarClient? candidate;
    try {
      candidate = RadarClient(
        baseUrl: credentials.url,
        token: credentials.token,
        transport: widget.transport,
      );
      // 用来源目录当握手：能拿到目录就说明地址与 token 都对。
      final catalog = await RadarHotApi(candidate).catalog();
      if (catalog.sources.isEmpty) throw const RadarApiException(200);
      await _store.save(credentials);
      _client?.close();
      _client = candidate;
      _credentials = credentials;
      _url.text = credentials.url;
      _token.text = credentials.token;
      await _syncModelKey();
      _digest.reset();
      _brief.reset();
      _startAutoRefresh();
      await _loadHot();
      return true;
    } on Object {
      candidate?.close();
      if (mounted) setState(() => _error = context.l10n.radarFailure);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一次请求拉齐所有已勾选来源的榜单；失败时保留旧榜单，由横幅说明原因。
  Future<void> _loadHot({bool force = false}) async {
    final client = _client;
    if (client == null) return;
    if (mounted) setState(() => _hotBusy = true);
    try {
      // 首页两块钱一起取：论文与榜单互不依赖，串行只会让首屏多等一个来回。
      await Future.wait([
        _hot.load(RadarHotApi(client), force: force),
        _papers.load(RadarPaperApi(client), force: force),
      ]);
      _lastLoadedAt = DateTime.now();
    } finally {
      if (mounted) setState(() => _hotBusy = false);
    }
  }

  Future<void> _reloadPapers() async {
    final client = _client;
    if (client == null) return;
    await _papers.load(RadarPaperApi(client), force: true);
    if (mounted) setState(() {});
  }

  /// 论文推荐规则：兴趣词、来源开关、条数。保存后立刻重排，不用等下一轮。
  Future<void> _openPaperSettings() async {
    final client = _client;
    if (client == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => RadarPaperSettingsPage(client: client),
      ),
    );
    if (!mounted || saved != true) return;
    await _reloadPapers();
  }

  Future<void> _loadDigest({bool force = false}) async {
    final client = _client;
    if (client == null) return;
    await _digest.load(RadarHotApi(client), force: force);
  }

  /// 六平台简报：服务端采集/摘要后的快照，读的是 `/radar/items`。
  Future<void> _loadBrief({bool force = false}) async {
    final client = _client;
    if (client == null) return;
    await _brief.load(RadarBriefApi(client), force: force);
  }

  Future<void> _loadMoreBrief() async {
    final client = _client;
    if (client == null) return;
    await _brief.loadMore(RadarBriefApi(client));
  }

  /// 打开一条简报：先本地标已读（列表立刻变灰），再异步写服务端，最后跳转。
  Future<void> _openBriefItem(RadarBriefItem item) async {
    _brief.markReadLocally(item.id);
    final client = _client;
    if (client != null) {
      // 已读写入失败不该拦住打开——这条可能已被服务端清理。
      unawaited(
        RadarBriefApi(client).markRead(item.id).catchError((Object _) {}),
      );
    }
    await openHotLink(sourceId: item.platform, itemUrl: item.url);
  }

  Future<void> _openSourcePicker() async {
    if (_hot.catalog == null) {
      await _loadHot(force: true);
      if (!mounted) return;
      if (_hot.catalog == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.radarFailure)));
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RadarSourcePickerPage(
          catalog: _hot.catalog!,
          // 没有直连实现的源在列表里就标出来，别等人勾了才发现是空的。
          unavailable: {
            for (final source in _hot.catalog!.sources)
              if (!source.native) source.id,
            for (final feed in _hot.feeds)
              if (feed.isEmpty) feed.source,
          },
        ),
      ),
    );
    if (mounted) {
      setState(() {});
      // 新勾选的来源还没缓存，服务端会现取；已缓存的复用 5 分钟结果。
      await _loadHot();
    }
  }

  /// Boards to draw: the picked one, or every starred source in user order.
  ///
  /// 选了「论文」时没有榜单要画——那一屏是论文列表自己。
  List<String> _hotBoardIds() {
    final filter = _hotFilter;
    if (filter == RadarHotRail.papersId) return const [];
    if (filter != null) return [filter];
    return radarPrefs.value.hotSources.take(60).toList();
  }

  Future<void> _disconnect() async {
    await _store.clear();
    _client?.close();
    _client = null;
    _autoRefresh?.cancel();
    _lastLoadedAt = null;
    _hot.reset();
    _brief.reset();
    _digest.reset();
    _papers.reset();
    if (!mounted) return;
    setState(() {
      _credentials = null;
      _error = null;
      _token.clear();
    });
  }

  Future<void> _openEvents() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RadarManagementPage(section: RadarSection.events),
      ),
    );
  }

  /// 打开共识话题下的某条热榜：直接跳到它所属来源的榜单卡片。
  Future<void> _openDigestItem(RadarDigestItem item) async {
    final sourceId = item.source;
    final catalogId = _hot.catalog?.byId(sourceId)?.id;
    if (catalogId != null) {
      setState(() {
        _tab = RadarTab.hot;
        _hotFilter = catalogId;
      });
      return;
    }
    final url = Uri.tryParse(item.url);
    if (url != null) {
      await openHotLink(
        sourceId: sourceId,
        itemUrl: item.url,
        scheme: '',
        keyword: item.title,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final p = RadarPalette.of(context);
    return Scaffold(
      // 透明:让外层 AppBackdrop 的页面渐变与光晕透上来。这里若填不透明
      // 底色,那一层背景就白画了。
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: !_ready
            ? Center(child: CircularProgressIndicator(color: p.accent))
            : RefreshIndicator(
                color: p.accent,
                onRefresh: () async {
                  if (_client == null) {
                    await _restore();
                  } else {
                    await _refresh();
                  }
                },
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(child: _buildHeader(t, p)),
                    if (_busy || _hotBusy || _digest.loading)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: radarGutter,
                            vertical: 4,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              minHeight: 2,
                              color: p.accent,
                              backgroundColor: p.hairline,
                            ),
                          ),
                        ),
                      ),
                    if (_error != null)
                      SliverToBoxAdapter(child: _buildError(t, p, _error!)),
                    if (_credentials == null)
                      SliverToBoxAdapter(child: _buildConnectCard(t, p))
                    else ...[
                      SliverToBoxAdapter(child: _buildTabSwitch(t, p)),
                      if (_tab == RadarTab.hot)
                        ..._buildHotSlivers(t, p)
                      else if (_tab == RadarTab.brief)
                        SliverToBoxAdapter(
                          child: RadarBriefView(
                            controller: _brief,
                            onOpen: _openBriefItem,
                            onRefresh: () => _loadBrief(force: true),
                            onLoadMore: _loadMoreBrief,
                          ),
                        )
                      else
                        SliverToBoxAdapter(
                          child: RadarDigestView(
                            controller: _digest,
                            catalog: _hot.catalog,
                            onOpen: _openDigestItem,
                            onRefresh: () => _loadDigest(force: true),
                          ),
                        ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 44)),
                  ],
                ),
              ),
      ),
    );
  }

  /// 页面头部：一个大标题、一行状态，右侧三个低对比度图标。
  ///
  /// The old header led with a 40px accent tile, then repeated the same state
  /// three times (tile, pill, pill). Now the title carries the hierarchy and
  /// state is a single quiet line with one coloured dot.
  Widget _buildHeader(dynamic t, RadarPalette p) {
    final connected = _credentials != null;
    final boards = _hot.feeds;
    final total = boards.length;
    final healthy = boards.where((feed) => feed.items.isNotEmpty).length;
    final updated = _lastUpdatedLabel(t);
    return Padding(
      padding: const EdgeInsets.fromLTRB(radarGutter, 16, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.radarTitle,
                  style: TextStyle(
                    // 22/700:再大就压过内容了。这个页面是"读列表"的,
                    // 标题只负责定位,不负责气氛。
                    fontSize: 22,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: p.text,
                  ),
                ),
              ),
              _HeaderIcon(
                tooltip: t.radarSourcesTitle,
                icon: AppIcons.configure,
                onPressed: connected ? _openSourcePicker : null,
                palette: p,
              ),
              _HeaderIcon(
                tooltip: connected ? t.radarDisconnect : t.radarConnect,
                icon: connected ? AppIcons.disconnected : AppIcons.link,
                onPressed: connected
                    ? _disconnect
                    : () => _connect(_url.text, _token.text),
                palette: p,
                tint: connected ? null : p.accent,
              ),
              _HeaderIcon(
                tooltip: t.radarInbox,
                icon: AppIcons.notifications,
                onPressed: connected ? _openEvents : null,
                palette: p,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: connected ? p.success : p.warning,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  connected ? t.radarConnected : t.radarNotConnected,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: connected ? p.muted : p.warning,
                  ),
                ),
                if (connected && total > 0) ...[
                  _HeaderDot(p),
                  Text(
                    t.radarSourceHealthy(healthy, total),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: healthy == total ? p.faint : p.warning,
                    ),
                  ),
                ],
                if (updated.isNotEmpty) ...[
                  _HeaderDot(p),
                  Flexible(
                    child: Text(
                      updated,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: p.faint),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                // Which server this list came from, kept as a quiet footnote on
                // the same line rather than on a line of its own.
                Flexible(
                  child: Text(
                    personalServerIp,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: p.faint.withValues(alpha: 0.65),
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _lastUpdatedLabel(dynamic t) {
    if (_tab == RadarTab.digest) {
      final at = _digest.digest?.generatedAt;
      if (at == null || at.isEmpty) return '';
      return t.radarUpdatedAt(formatRelative(at));
    }
    final feed = _hot.feeds.isEmpty ? null : _hot.feeds.first.updatedAt;
    if (feed == null || feed.isEmpty) return '';
    return t.radarUpdatedAt(formatRelative(feed));
  }

  /// 错误提示：一条 3px 竖线加淡底，不再是一个圆角描边盒子。
  Widget _buildError(dynamic t, RadarPalette p, String message) => Container(
    margin: const EdgeInsets.fromLTRB(
      radarGutter,
      radarGapMd,
      radarGutter,
      radarGapSm,
    ),
    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
    decoration: BoxDecoration(
      color: p.hot.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(10),
      border: Border(
        left: BorderSide(color: p.hot.withValues(alpha: 0.7), width: 3),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 12, height: 1.45, color: p.text),
          ),
        ),
        TextButton(
          onPressed: _busy || _hotBusy
              ? null
              : () => _credentials == null ? _restore() : _refresh(),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(t.radarRetry, style: const TextStyle(fontSize: 12.5)),
        ),
      ],
    ),
  );

  /// 首次连接：一个真正的面板（这里允许有填充，因为它是一张表单），
  /// 但字段本身无描边，只靠底色和间距分层。
  Widget _buildConnectCard(dynamic t, RadarPalette p) => Padding(
    padding: const EdgeInsets.fromLTRB(radarGutter, radarGapLg, radarGutter, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.radarConnectionTitle,
          style: TextStyle(
            fontSize: 21,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: p.text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          t.radarConnectionHelp,
          style: TextStyle(fontSize: 12.5, height: 1.65, color: p.muted),
        ),
        const SizedBox(height: 24),
        _ConnectField(
          controller: _url,
          label: t.radarServer,
          icon: Icons.dns_outlined,
          palette: p,
        ),
        const SizedBox(height: 12),
        _ConnectField(
          controller: _token,
          label: t.radarToken,
          icon: Icons.key_outlined,
          palette: p,
          obscure: true,
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: _busy ? null : () => _connect(_url.text, _token.text),
            style: FilledButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            child: Text(
              t.radarConnect,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(AppIcons.done, size: 13, color: p.faint),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                t.radarServerNote,
                style: TextStyle(fontSize: 11.5, height: 1.4, color: p.faint),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () =>
                Navigator.of(context).push(RadarSelfHostPage.route()),
            icon: const Icon(AppIcons.article, size: 15),
            label: Text(
              t.radarSelfHostGuide,
              style: const TextStyle(fontSize: 12.5),
            ),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    ),
  );

  /// 页签：下划线式，只有文字和 2px 指示条。原来那条带描边的胶囊容器
  /// 既是卡片又像输入框，属于最典型的「框框」。
  Widget _buildTabSwitch(dynamic t, RadarPalette p) {
    final tabs = <(RadarTab, String)>[
      (RadarTab.hot, t.radarHotTab),
      (RadarTab.brief, t.radarBriefTab),
      (RadarTab.digest, t.radarDigestTab),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        radarGutter,
        radarGapMd,
        radarGutter,
        radarGapXs,
      ),
      child: Row(
        children: [
          for (final (tab, label) in tabs)
            Padding(
              padding: const EdgeInsets.only(right: 26),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  setState(() => _tab = tab);
                  if (tab == RadarTab.brief &&
                      !_brief.hasData &&
                      !_brief.loading) {
                    unawaited(_loadBrief());
                  } else if (tab == RadarTab.digest &&
                      !_digest.hasData &&
                      !_digest.loading) {
                    unawaited(_loadDigest());
                  }
                },
                // IntrinsicWidth bounds the column inside the Row, so the
                // underline spans exactly the label.
                child: IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: _tab == tab
                                ? FontWeight.w600
                                : FontWeight.w500,
                            letterSpacing: -0.1,
                            color: _tab == tab ? p.text : p.muted,
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 170),
                        height: 2,
                        decoration: BoxDecoration(
                          color: _tab == tab ? p.accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 换信源后回到列表开头：否则会停在上一份榜单的相对位置，
  /// 看起来像「切了没反应」。
  void _backToTop() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    unawaited(
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Map<String, int> _hotCounts() {
    final counts = <String, int>{};
    for (final feed in _hot.feeds) {
      counts[feed.source] = feed.items.length;
    }
    return counts;
  }

  List<Widget> _buildHotSlivers(dynamic t, RadarPalette p) {
    final slivers = <Widget>[];
    if (_hot.error != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildError(
            t,
            p,
            _hot.error == 'HTTP 401' ? t.radarTokenExpired : t.radarFailure,
          ),
        ),
      );
    }
    final ids = _hot.hasData ? _hotBoardIds() : const <String>[];
    final papersTab = _hotFilter == RadarHotRail.papersId;
    // 切换条吸顶：翻到某个信源半页想换一家时，不必先滚回顶部。
    if (_hot.hasData) {
      slivers.add(
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyRail(
            height: _railHeight,
            background: p.canvas,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: RadarHotRail(
                catalog: _hot.catalog,
                selected: _hotFilter,
                counts: _hotCounts(),
                paperCount: _papers.data?.items.length ?? 0,
                onSelect: (id) {
                  setState(() => _hotFilter = id);
                  _backToTop();
                },
              ),
            ),
          ),
        ),
      );
    }
    // 论文是切换条上的一个入口，和各个站点平级：选中它时只画论文，
    // 其余时候只画榜单，不做「上面一块、下面一堆」的堆叠。
    if (papersTab) {
      slivers.add(
        SliverToBoxAdapter(
          child: RadarPapersSection(
            controller: _papers,
            onRetry: () => unawaited(_reloadPapers()),
            onSettings: () => unawaited(_openPaperSettings()),
          ),
        ),
      );
    } else {
      slivers.add(
        SliverList.builder(
          itemCount: ids.length,
          itemBuilder: (context, index) {
            final id = ids[index];
            final source = _hot.sourceFor(id);
            if (source == null) return const SizedBox.shrink();
            return RadarHotBoardCard(
              key: ValueKey(id),
              source: source,
              feed: _hot.feedFor(id),
              onOpen: (item) => unawaited(openHotItem(context, source, item)),
              onRetry: () => _loadHot(force: true),
              onRemove: () => radarPrefs.toggleHotSource(id),
            );
          },
        ),
      );
    }
    if (!_hot.hasData) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              radarGutter,
              28,
              radarGutter,
              40,
            ),
            child: Center(
              child: CircularProgressIndicator(
                color: p.accent,
                strokeWidth: 2.2,
              ),
            ),
          ),
        ),
      );
    } else if (ids.isEmpty && !papersTab) {
      slivers.add(
        SliverToBoxAdapter(child: RadarHotEmpty(onManage: _openSourcePicker)),
      );
    } else if (_hot.feeds.isEmpty && _hotBusy) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              radarGutter,
              28,
              radarGutter,
              24,
            ),
            child: Center(
              child: CircularProgressIndicator(
                color: p.accent,
                strokeWidth: 2.2,
              ),
            ),
          ),
        ),
      );
    }
    return slivers;
  }
}

/// 吸顶的来源切换条：底色取自页面，底边做 4dp 渐隐，滚过去的内容不会
/// 在条下面留下一条硬边。
class _StickyRail extends SliverPersistentHeaderDelegate {
  _StickyRail({
    required this.height,
    required this.background,
    required this.child,
  });

  final double height;
  final Color background;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [background, background, background.withValues(alpha: 0)],
            stops: const [0, 0.84, 1],
          ),
        ),
        child: child,
      );

  @override
  bool shouldRebuild(_StickyRail old) =>
      old.height != height ||
      old.background != background ||
      old.child != child;
}

class _ConnectField extends StatelessWidget {
  const _ConnectField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.palette,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final RadarPalette palette;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(11),
      borderSide: BorderSide(color: color, width: width),
    );
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(fontSize: 13.5, color: p.text),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 12, color: p.muted),
        prefixIcon: Icon(icon, size: 18, color: p.faint),
        filled: true,
        fillColor: p.card,
        contentPadding: const EdgeInsets.symmetric(vertical: 15),
        border: border(Colors.transparent, 0),
        enabledBorder: border(Colors.transparent, 0),
        focusedBorder: border(p.accent, 1.2),
      ),
    );
  }
}

/// 头部图标：36px 点击区、19px 线条图标，默认低对比度 —— 它们在页面上
/// 是次要动作，不该和标题抢注意力。
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.palette,
    this.tint,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final RadarPalette palette;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final enabled = onPressed != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      icon: Icon(
        icon,
        size: 19,
        color: enabled ? (tint ?? p.muted) : p.faint.withValues(alpha: 0.45),
      ),
    );
  }
}

/// 状态行里的分隔点。
class _HeaderDot extends StatelessWidget {
  const _HeaderDot(this.palette);

  final RadarPalette palette;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 7),
    child: Text(
      '·',
      style: TextStyle(fontSize: 11.5, height: 1.2, color: palette.faint),
    ),
  );
}
