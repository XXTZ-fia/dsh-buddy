# Remote host 常驻（关闭 DSH 桌面端也能用）

`ds-harness-remote` 的宿主部分跑在 DSH 进程里，关掉桌面窗口就等于下线。这里用**同一套 profile 以无头方式常驻**来解决：`dsh --profile web --no-open`，没有窗口、不弹浏览器。

已实测（一台 Windows 主机）：

```
[ds-harness-remote] host identity ready {"deviceId":"<device-id>","server":"https://relay.example.com"}
[ds-harness-remote] Codex App Server ready
[ds-harness-remote] Codex Remote domain ready
```

即：手机经中继操作 `codex` / `codex-cli` 时不再需要打开 DSH。

## 前置：web profile 要声明 host 角色

`~/.dsh/profiles/web/cordis.patch.yml` 的插件条目里加一行（缩进与 `serverUrl` 同级）：

```yaml
- id: ds-harness-remote
  config:
    serverUrl: https://relay.example.com
    role: host
    codex:
      enabled: true
      binary: 'C:/Users/<you>/AppData/Local/OpenAI/Codex/bin/<hash>/codex.exe'
```

没有 `role: host` 时插件以 **client** 身份连中继（日志 `client remote-mode identity ready`），不会接手机。

## 安装

```powershell
# 注册到登录启动（隐藏窗口，失败重启 3 次，不限时）
powershell -ExecutionPolicy Bypass -File code\tool\remote-host\install.ps1

# 手动跑（前台可见日志）
powershell -File code\tool\remote-host\remote-host.ps1

# 一次性健康检查：只判断"桌面端在不在"，不启动 host
powershell -File code\tool\remote-host\remote-host.ps1 -Once
```

卸载：`install.ps1 -Remove`。

## 行为（当前采用的方案：单 host 常驻）

- 守护进程**始终**保持一个无头 host（`--host 127.0.0.1 --port 0`，端口由系统分配），桌面端开不开都不影响。
- 桌面端的 remote 插件已关闭（`~/.dsh/profiles/desktop/cordis.patch.yml` 里 `disabled: true`），所以手机上只有**一个**「<host-name>」条目，不会出现两条连接互顶。
- 子进程退出会按 5→10→20→40→60 s 退避重启；同一会话只允许一个守护进程（互斥量）。
- 需要「桌面端开着时由桌面端接管」的旧行为：加 `-StopWhenDesktopRuns`，并把桌面 profile 的 `disabled` 改回 `false`（这时手机会看到两个身份）。

## 日志

| 文件 | 内容 |
|---|---|
| `~/.dsh/logs/remote-host/supervisor.log` | 启动/停止/重启记录 |
| `~/.dsh/logs/remote-host/headless.out.log` | 无头 host 的标准输出（含本地 UI 地址） |
| `~/.dsh/logs/remote-host/headless.err.log` | 错误 |
| `~/.dsh/logs/ds-harness-remote/host.log` | 插件自身：身份、Codex、连接 |

## 已实施的状态

- `~/.dsh/profiles/web/cordis.patch.yml`：`enabled: true` + `role: host` + codex 绝对路径。
- `~/.dsh/profiles/desktop/cordis.patch.yml`：`ds-harness-remote` 标 `disabled: true`、`enabled: false`（改前备份在 `~/dsh-desktop-patch.bak.*`）。
- 计划任务 `DSH Remote Host`：登录启动，当前状态 Running。
- 无头 host 的启动输出（`headless.out.log`）已出现：
  `host identity ready … server relay.example.com`、`Codex App Server ready`、`Codex Remote domain ready`。

## 多 agent：Claude Code / OpenCode / CLI

手机端除了 DSH 与 Codex，还能驱动 Claude Code、OpenCode，以及这四个工具各自的命令行（在终端里跑）。宿主侧需要：

```powershell
# 探测 node / claude-agent-acp / opencode / codex，重写 profile 的 acp 段（幂等，带备份）
powershell -File code\tool\remote-host\configure-acp.ps1

# 检查三后端、插件版本、profile 配置与最近日志
powershell -File code\tool\remote-host\remote-host.ps1 -Doctor

# 让配置生效
Stop-Process -Id (Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*--profile web*' }).ProcessId -Force
Start-ScheduledTask -TaskName 'DSH Remote Host'
```

成功标志（`~/.dsh/logs/remote-host/headless.out.log`）：

```
[ds-harness-remote] Cursor ACP ready      ← 通用日志串，实际后端是 claude
[ds-harness-remote] OpenCode ACP ready
```

### 为什么必须绝对路径

插件用 `spawn(binary, args, { stdio: 'pipe', env })` 直接拉起，**不走 shell**。Windows 上 `.cmd` 垫片、无扩展名的 sh 脚本都无法这样执行；失败只记在 `debug` 级别，最终表现为整域 `ACP Remote domain unavailable` —— 很容易误判成"插件不支持"。因此 claude 写成「node.exe + 入口 js」，opencode 写成原生 `.exe`。

### 登录

`configure-acp.ps1` 只安装与配置，**不登录**。真实对话前需要在电脑上执行一次 `claude`（登录 Claude Code）或 `opencode auth login`。未登录时手机端仍能看到项目与会话，发送会得到一条明确的鉴权错误。

### CLI 行

手机主机面板的「终端 · dsh/codex/claude/opencode」会在电脑上新建一个 DSH 会话，再打开终端并**只写入命令、不回车**。`codex` 默认不在 PATH，若终端提示 command not found，把 Codex 的 `bin` 目录加进 PATH，或改用完整路径。

## 身份取舍

无头 profile 与桌面端各自生成一份 host 身份（deviceId 不同），手机端会看到**两台电脑**。当前选择「只留无头」，因为它是唯一真正不依赖 dsh 窗口的形态。代价：DSH 会话与桌面 UI 的会话不共享；Codex 线程共享（都读 `~/.codex`）。

## 不做的事

- 不改 `applicationId`、不改 `/dsh-go/v1` 协议路径。
- 不在无头 host 里跑 DSH 的界面插件（web profile 会起一个本地 HTTP 服务，但没有人打开它）。
