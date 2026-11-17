# 自建信息雷达服务器

信息雷达是可选功能，**App 不内置任何服务器**。你需要一台自己的 Linux 服务器；
仓库里的脚本会把后端装成 systemd 服务，并用你自己的域名提供 HTTPS。

> 只想先用扫码连电脑？可以完全跳过这一页——雷达默认关闭，不影响其他功能。

## 前提

- Ubuntu 22.04 / 24.04（Debian 12 亦可），root 权限；
- **Python ≥ 3.11**（24.04 自带 3.12；22.04 需先装 `python3.11 python3.11-venv`）；
- 一个域名，A 记录指向这台服务器；
- 开放 80/443（申请证书 + HTTPS）。**不要**把 8787 暴露到公网。

## 1. 安装

```bash
git clone https://github.com/ccch1mneyyy/dsh-buddy.git
cd dsh-buddy

sudo radar/scripts/install-server.sh
```

脚本会：

1. 创建 `radar` 系统用户；
2. 把代码装到 `/opt/personal-assistant/radar`，建 venv 并安装依赖；
3. 生成 `/etc/personal-assistant/radar.env`（内含 64 字符随机令牌）；
4. 安装 Chromium（采集需要）；
5. 注册并启动 `radar-api`（127.0.0.1:8787）与 `radar-worker`（采集 + 热榜缓存）。

重复执行是安全的：代码整体替换、已有配置与令牌不会被覆盖。

## 2. 取令牌

```bash
sudo grep RADAR_BEARER_TOKEN /etc/personal-assistant/radar.env
```

这是手机端要粘的「访问令牌」，至少 32 字符。不要贴到聊天、Issue 或截图里。

## 3. 配 HTTPS

Caddy 最省事：

```bash
sudo cp radar/scripts/Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile       # 把 radar.example.com 换成你的域名
sudo systemctl reload caddy
```

```caddyfile
你的域名 {
    reverse_proxy 127.0.0.1:8787
}
```

验证：

```bash
curl https://你的域名/identity -H "Authorization: Bearer <令牌>"
# {"id":"admin","admin":true,"model_configured":false}
```

> 证书是签给域名的。App 里必须填 `https://你的域名`，填裸 IP 会命中无关站点。

## 4. 在 App 里连接

1. 设置 → 可选功能 → 信息雷达（打开）；
2. 底部出现「信息雷达」页签 → 填服务器地址与令牌 → 连接；
3. 热榜应立即出内容（服务端会预热 47 个来源的缓存）。

## 5. 采集调度

首次安装**没有**定时任务，需要手动建一个：

- App：自动化 → 雷达调度 → 新建（建议每 30–60 分钟一轮）；
- 或直接触发一轮：

```bash
TOKEN=$(sudo grep RADAR_BEARER_TOKEN /etc/personal-assistant/radar.env | cut -d= -f2-)
curl -X POST https://你的域名/runs \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"key":"manual-1","dry_run":false,"no_model":true}'
```

`no_model: true` 表示不调用模型：简报摘要取原文片段。配好模型 Key 后可以改成 `false`。

## 6. 平台登录（可选）

热榜的 47 个来源不需要登录。**简报链路**里的 X / 知乎 / 小红书通常需要登录态：

```bash
cd /opt/personal-assistant/radar
sudo -u radar env PLAYWRIGHT_BROWSERS_PATH=/var/lib/personal-assistant/browsers \
  /opt/personal-assistant/venv/bin/radar login --platform xhs
```

登录态写在 `/var/lib/personal-assistant/profiles/`，不会进 git。

## 7. 模型 Key（可选）

```bash
sudo nano /etc/personal-assistant/radar.env
# 追加一行：
RADAR_MODEL_API_KEY=sk-...
sudo systemctl restart radar-api radar-worker
```

配好后把调度的 `no_model` 关掉，简报才会有模型写的中文摘要。
费用由你自己的 Key 承担；不配也能用，只是摘要更朴素。

## 8. 升级 / 备份 / 卸载

```bash
# 升级（幂等，令牌与数据保留）
git pull && sudo radar/scripts/install-server.sh

# 备份（SQLite 在线一致性备份）
sudo /opt/personal-assistant/venv/bin/python radar/scripts/backup.py \
  /var/lib/personal-assistant/state.db /root/radar-$(date +%F).db

# 卸载（代码与服务；数据目录手动决定是否删除）
sudo systemctl disable --now radar-api radar-worker
sudo rm -rf /opt/personal-assistant /etc/personal-assistant
# 数据：/var/lib/personal-assistant（含 state.db、profiles、browsers）
```

## 排错

| 现象 | 检查 |
|---|---|
| 服务没起来 | `systemctl status radar-api radar-worker`、`journalctl -u radar-api -n 80` |
| 502 / 证书错误 | `curl -I https://你的域名/identity`；Caddy 日志 `journalctl -u caddy -n 50` |
| 401 | 令牌不对，或 `radar.env` 里少于 32 字符 |
| 热榜全空 | `systemctl status radar-worker`；手动 `POST /runs` 看 `sources_failed` |
| 简报只有几条 | 正常：每轮只取 5 条；X/知乎/小红书 可能未登录 |
| 论文一直英文 | 没配模型 Key 时走机器翻译，配置后重启服务 |
| 端口被外网扫到 | 8787 只应监听 127.0.0.1；用 `ss -lntp` 确认，防火墙只开 80/443 |

## 安全与合规

- 采集**只读**：不发帖、不点赞、不关注、不改资料；
- 请求按 `limits.min_interval_ms` / `jitter_ms` 控频，失败按退避阶梯重试；
- 服务端只存设备令牌的 SHA-256，管理员令牌只在环境变量里；
- 请遵守目标站点的服务条款与 robots 约定，不要做商业采集或批量分发。
