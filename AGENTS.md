# AGENTS.md — 给 AI / 新接手的开发者的项目说明

> 这份文件是本仓库的唯一"AI 入口"。动手前请通读，尤其是「硬约束」与「已知基线」两节：
> 那里写的是踩过的坑，不是建议。

## 1. 这是什么

**DSH（岸宝 / WorkBuddy）**：一套「AI 助手 App + 自建信息雷达后端」的个人系统。

- **App**（`app/`）：Flutter 安卓客户端。五个主 tab——工作（对话）、信息雷达、自动化、资料、我的。
  除了对话，还带宠物/桌面小组件、语音、插件、远程主机等模块。
- **雷达后端**（`radar/`）：Python 服务。两种能力：**NewsNow 式热榜**（47 个来源，每源最多 30 条）
  和**六平台简报**（B 站 / 微博 / 知乎 / 贴吧 / 抖音 / 小红书，按兴趣词抓取 + AI 摘要 + 推送）。
- **宿主运行时**（`runtime/`）：**不是 Go**，而是构建与补丁层——用 `build-runtime.sh` 打包一份
  Ubuntu + Node.js + DeepSeek Harness 的 rootfs，经 Termux proot 在 Android 内运行，
  用 `patches/*.diff`（版本钉在 `patches/pins.json`）打补丁。主体是 Node/ESM（`.mjs`）、
  Kotlin 原生层（媒体/锁/会话删除）与 Python 构建脚本。产物 `runtime/out/` 才是 App 依赖的东西。

App 与后端**不互相 import**，只通过 HTTP + JSON 契约通信（见 `docs/PROJECT.md` 第 4 节）。
所以「改雷达」和「改 App」是两件可以独立验证的事。

许可证 **AGPL-3.0**（见 `LICENSE`）。仓库当前为 private；**一旦对外分发 APK，必须能提供对应源码**。

## 2. 硬约束（违反会直接坏掉）

1. **仓库路径必须是纯 ASCII。** Gradle 无法把 pub 缓存相对化到中文路径，旧目录因为带中文被迫
   robocopy 到别处才能编译。把仓库放在纯 ASCII 路径下（例如 `D:\code\dsh-buddy`），**不要**用含中文/空格的路径。
2. **`runtime/out/` 与 `tool/test-fonts/` 不在 git 里，但打包必需。** 换机器后要单独复制，
   否则 APK 装上去起不来 / 金图测试全挂。
3. **不要提交 `radar/` 的运行时数据**：`secrets/`、`browser_profiles/`（登录态）、`*.db`、
   `config.yaml`、`outbox/`。`.gitignore` 已覆盖，别用 `git add -f` 绕过。
4. **只往 `app/` 写代码。** `radar/` 下的 Flutter 空壳脚手架已于 2026-11-15 删除；
   真正的雷达界面在 `app/lib/ui/radar/`。`radar/` 只放 Python。
5. **UI 一律走主题层**，不要硬编码颜色和 Material 图标（详见第 5 节）。
6. **改 `radar/` 后部署到服务器必须重装包。** 服务加载的是 venv 里的 site-packages 副本，
   直接覆盖 `/opt/personal-assistant/radar/src` 不会生效。两个办法：重跑
   `install-server.sh`（它会重新 `pip install`，本地目录同版本会卸载重装，已实测），或手工覆盖后执行
   `/opt/personal-assistant/venv/bin/pip install --no-deps --force-reinstall /opt/personal-assistant/radar`
   再 `systemctl restart radar-api`，否则你会对着一份没生效的代码排查半天。
7. **热榜目录与 `PROVIDERS` 必须一一对应。** 只加 `catalog.py` 不写 provider，用户勾选后只会看到
   「该来源暂不可用」；`tests/test_hot.py` 的 `test_catalog_matches_newsnow_visible_sources`
   会直接卡住这种半成品。抓不到的源就整条删掉，不要留占位。

## 3. 目录地图：改什么去哪

```
code/
├── app/                    Flutter 客户端（857 个 dart 文件 / 34 万行）
│   ├── lib/ui/             所有界面（559 文件）
│   │   ├── chat/           对话页：输入框、消息流、专家胶囊、运行设置弹窗
│   │   ├── radar/          信息雷达：热榜视图、简报、来源选择、管理页
│   │   ├── shell/          外壳与导航（personal_home.dart 是五个 tab 的门面）
│   │   ├── theme/          DshColors / AppShape / AppIcons / 动效
│   │   └── common/         页面原语（AppPage、ListPageRow、弹窗、胶囊…）
│   ├── lib/state/          Riverpod 状态（106 文件，chat/account/agents/…）
│   ├── lib/l10n/           国际化：parts/*.arb → gen/
│   ├── test/               968 个测试文件，含 golden 金图
│   ├── tool/               l10n 合并、图标字体、宠物资源等生成脚本
│   └── android/            包名 io.github.ccch1mneyyy.personal_assistant
├── packages/
│   ├── dsh_client/         RPC 客户端 + 事件桥（App 与宿主之间的协议层）
│   └── dsh_remote/         远程主机连接
├── runtime/                宿主编译与补丁层（Node/ESM + Kotlin + 构建脚本）
├── radar/                  Python 后端（39 文件 / 4733 行）
│   └── src/radar/
│       ├── hot/            热榜：catalog 源目录、providers 抓取器、service 缓存
│       ├── papers/         首页论文流：HF Daily + arXiv、打分、30 分钟缓存
│       ├── sources/        六平台简报的采集器
│       └── api.py worker.py management.py publication.py
├── tool/build-android.ps1  打包脚本
└── docs/PROJECT.md         产品与架构总文档（要改架构先读它）
```

**判断该改哪里的三句话**：界面/交互 → `app/lib/ui`；状态/数据 → `app/lib/state`；
抓取/接口 → `radar/src/radar`。

## 4. 命令（都已实测，可直接复制）

### Python 后端
```bash
cd radar                                  # 先在仓库根执行 pip install -e ".[dev]"
python -m pytest -q                       # 全量，应 132 passed
python -m pytest tests/test_hot.py -q
```
需要 Python ≥ 3.11；抓真实站点还要 `playwright install chromium`（`--dry-run` 用 `radar/fixtures` 的离线样本，不需要浏览器）。

### Flutter
```powershell
# 静态分析（在 app/ 下）：只有既有 deprecated 提示，无 error/warning 才算通过
cd app
dart analyze

# 跑测试：必须先清代理，否则本地 WebSocket 被拦，测试会假失败
$env:http_proxy=''; $env:https_proxy=''; $env:HTTP_PROXY=''; $env:HTTPS_PROXY=''
$env:NO_PROXY='localhost,127.0.0.1,::1'
$env:DSH_TEST_FONT_DIR='<repo>\tool\test-fonts'   # 金图字体，不入库，见 §2.2
flutter test test/radar                            # 只跑相关目录，别跑全量
```

### 改文案（i18n）
文案**不要**直接写进界面代码，走这条流水线：
```
lib/l10n/parts/<area>_zh.arb + <area>_en.arb   →   python tool/l10n_merge.py   →   lib/l10n/gen/
```
两个语言必须同时加同一个 key，`l10n_merge.py` 会做结构校验（重复 key、占位符不一致都会 fatal）。
只校验不写盘：`python tool/l10n_merge.py --check`，当前应为 `✓ 64 parts, 6255 keys`。

### 打包 APK
```powershell
powershell -File D:\whm\dsh-buddy\code\tool\build-android.ps1
```
产物落在 `D:\whm\dsh-buddy\artifacts\apk\`。arm64 debug，versionCode 取构建分钟数。

**交付和自用一律用 release（AOT）**，debug 只用于调试：同一台机器实测冷启动
debug 1.87 s → release 0.43 s，APK 295 MB → 204 MB。没有 `key.properties` 时
release 用 debug 签名，可以覆盖安装现有 debug 包：

```powershell
cd D:\whm\dsh-buddy\code\app
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
flutter build apk --release --flavor arm64 --target-platform android-arm64
```

### Remote host 常驻（不打开 DSH 也能连手机）
```powershell
powershell -File D:\whm\dsh-buddy\code\tool\remote-host\install.ps1      # 登录自启
powershell -File D:\whm\dsh-buddy\code\tool\remote-host\remote-host.ps1 -Once   # 健康检查
```
细节见 `tool/remote-host/README.md`。要点：web profile 必须带 `role: host`，
否则插件以 client 身份连中继，不会接手机。

## 5. 代码约定

- **Riverpod 3.5**：`StateProvider` 已被移除，别再写。用 `Notifier` / `NotifierProvider`，
  需要参数时用 family（`class X extends Notifier<T> { X(this.id); final String id; ... }`）。
- **颜色**：`DshColors.of(context)`（`lib/ui/theme/semantic_colors.dart`）。禁止裸 `Color(0xFF…)`。
- **圆角/间距**：`AppShape`（`lib/ui/theme/shapes.dart`）。
- **图标**：`AppIcons`（`lib/ui/theme/app_icons.dart`，Phosphor 派生）。新代码不要用 `Icons.xxx`。
- **页面骨架**：`AppPage.list(...)`（`lib/ui/shell/page_frame.dart`）；
  列表卡片用 `ListPageCard` / `ListPageRow`（`lib/ui/common/list_page_row.dart`）；
  图标按钮 `GlassIconButton`；弹窗 `showAppSheet` + `SheetTitleBar` + `SheetGroup`。
- **设计语言**：Calm UI / Linear 风——深色圆角卡片、无强描边、靠亮度层级区分、单一强调色。
  新页面请先看 `lib/ui/radar/radar_management.dart` 和 `lib/ui/chat/run_settings_sheet.dart` 当范式。
- **交互必须真实可用**：后端不可用时显示「重试 / 去连接」，**不要**用假数据或占位列表填充。

## 6. 已知基线（别把这些当成你改坏的）

- `pytest -q` → **98 passed**。低于这个数就是你引入的。
- `packages/dsh_remote` 的 `dart test` 有 1~2 项不稳定用例
  （`activation uses fresh descriptor *`、`stream_transfer` 的 StreamSink 竞态），
  单独跑能过，属既有问题。
- `dart analyze` → 23 条 `deprecated_member_use`（`ref.exists` 等），**属既有**，不要顺手改。
- `flutter test test/radar` → **47 passed**。
- 金图基线（`test/**/goldens/`，约 224 MB）已于 2026-11-20 **从仓库移除**，`.gitignore` 已忽略该目录。
  `test/flutter_test_config.dart` 会把「基线不存在」当作跳过，其余断言照常跑；需要视觉回归时先
  `flutter test --update-goldens test/<目录>` 生成基线，再用 `DSH_GOLDEN_STRICT=1 flutter test ...`
  恢复严格比较。基线不进 git，只在本机存在。
- `flutter test` 全量 → **约 131 项非金图失败**，分类如下（都不是界面改动引入的）：
  - **Windows 专属**（CI 是 Linux，那里能过）：`test/remote/remote_bootstrap_test.dart`
    需要 `/bin/sh`；`test/ui_config/local_source_test.dart` 依赖 Linux 的 inotify 语义；
    `test/system_entry/*`、`test/launch/launch_read_error_test.dart`、
    `test/diagnostics/diagnostics_bundle_test.dart`、`test/features/preset_composition_test.dart`
    把路径分隔符写死成 `/` 或行尾写死成 `\r\n`。
  - **原生桩缺失**：挂载外壳/聊天/陪伴页的测试必须先调
    `test/support/native_channels.dart` 的 `mockNativeChannels()`。缺了会让
    `connectivity_plus` 与 `dsh/runtime/events` 的 `MissingPluginException` 被
    `FlutterError.reportError` 上报而判错（`onError` 拦不住）。
  - **待修**：`test/icons/app_icons_test.dart` 的「never Icons.*」——`ui/radar/radar_page.dart`、
    `ui/radar/radar_visuals.dart`、`ui/settings/settings_screen.dart` 共 9 处仍用原生 `Icons`；
    `test/wallpaper/wallpaper_render_test.dart` 对比度回归（实测 1.25，要求 ≥4.5，疑与
    `surfaces.dart` 光晕/alpa 下调有关）；`test/chat/artifact_*` 两项 30 s 超时。
- 服务器地址不再硬编码：`lib/state/personal_server.dart` 从 `--dart-define` 读取
  `RADAR_SERVER_HOST` / `RADAR_SERVER_IP` / `RELAY_SERVER_HOST`。不注入时雷达没有默认地址
  （连接卡片要求用户自己填），中继回落到官方地址。改动这几个常量会连带影响金图，
  先跑 `flutter test test/radar`，确认差异来自文案再 `--update-goldens`。

## 7. 常见任务怎么做

| 任务 | 路径 |
|---|---|
| 改某个页面的样式 | 先 `grep -r "class XxxPage"` 定位 `app/lib/ui/`，再对照第 5 节的原语替换硬编码 |
| 加一个热榜来源 | `radar/src/radar/hot/catalog.py` 加一行 `Source(...)`，**同时在** `providers/` 加函数并在 `providers/__init__.py` 注册；同步改 `tests/test_hot.py` 的数量断言（当前 47）。目录与 `PROVIDERS` 必须一一对应，`test_catalog_matches_newsnow_visible_sources` 会卡住“只加目录不写实现” |
| 改接口契约 | 同时改 `radar/src/radar/*/api.py` 与 `app/lib/state/` 里的调用方，两边都要跑测试 |
| 调论文推荐 | `radar/src/radar/papers/rank.py`（权重）与 `sources.py`（来源/分类）；兴趣词来自 `config.yaml` 的 `interests`，与简报共用 |
| 加一条设置项 | 状态放 `app/lib/state/`，界面用 `ListPageRow` + `showAppSheet`，文案走 l10n 流水线 |
| 排查抓取失败 | `radar/src/radar/hot/service.py` 有 `stale` / `unavailable` 两种降级状态，先看日志再判定是反爬还是解析器过期 |

## 8. 提交前自检清单

1. 改动落在正确的子系统（App 还是雷达），没有跨层硬连。
2. `dart analyze` 无新增 error/warning；Python 侧 `pytest` 不低于 89 passed。
3. 新文案中英双语都加了，`l10n_merge.py` 通过。
4. 没有把 `runtime/out`、字体、登录态、数据库、`failures/` 金图对比图带进 git。
5. 涉及界面的改动，附一张真机或 golden 截图。
