# 自建公网服务器（中继 + 雷达）

一条命令把中继、信息雷达、systemd 服务和 HTTPS 装到你的 Ubuntu/Debian 服务器上。
装完后手机切到这台服务器，雷达页签自动出现。

## 前提

| 项 | 要求 |
|---|---|
| 系统 | Ubuntu 22.04+/24.04 或 Debian 12+，systemd，root |
| 资源 | 2 vCPU / 2 GB 内存 / 20 GB 磁盘起（Playwright 会装 Chromium） |
| 域名 | 两个 A/AAAA 记录：中继一个（如 `dsh.example.com`），雷达一个（如 `radar.example.com`） |
| 网络 | 80/443 可从公网访问；服务器能访问 GitHub 与 npm |
| 仓库 | 已把本仓库放到服务器上（`git clone` 或上传） |

## 安装

```bash
sudo tool/server/install-all.sh \
  --relay-host dsh.example.com \
  --radar-host radar.example.com \
  --email you@example.com
```

可选参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--account` | `admin@<relay-host>` | 中继登录账号（手机端用它登录） |
| `--password` | 随机 24 位 | 中继密码，至少 12 位 |
| `--zhihu-cookie` | 无 | 知乎登录 Cookie；机房 IP 抓知乎热榜必需 |
| `--proxy` | `auto` | `nginx` / `caddy` / `none`；auto 优先 Caddy，其次 nginx |
| `--skip-radar` | 否 | 只装中继 |
| `--skip-relay` | 否 | 只装雷达 |

脚本做这些事：

1. 安装 Node.js 22+（若缺）与 pnpm，克隆 `liguobao/ds-harness-remote` 到
   `/opt/ds-harness-remote` 并切到固定 tag（默认 `v0.6.5`），构建 protocol 与 server；
2. 创建 `dsh-relay` 系统用户、`/etc/dsh-relay.env`、`dsh-relay.service`（127.0.0.1:3300）；
3. 调用 `radar/scripts/install-server.sh` 安装雷达（127.0.0.1:8787）；
4. 申请/复用 Let's Encrypt 证书，写反代配置并 reload；
5. 把地址、账号、密码、令牌写到 `/etc/dsh-buddy/access.txt`（0600）。

重复执行是安全的：会更新代码、重建、重写配置并重启服务，不会动同一台机器上的其他站点。

> 443 已被 `stream` + SNI 分流占用时（例如同一台机器还跑着别的 TLS 站点），脚本会把
> 两个域名加进现有的 `map $ssl_preread_server_name`，并为它们各开一个回环 TLS vhost，
> 不会抢占 443。

## 手机端

1. 「我的 → 连接 → 自建服务器」，填 `https://dsh.example.com`、账号、密码；
2. 登录成功后底部出现「信息雷达」；
3. 雷达页填 `https://radar.example.com` 与 `access.txt` 里的令牌；
4. 热榜/每日总结/概览任一页能加载即成功。

切回官方中继（连接页底部「使用官方中继」）后，雷达界面立即隐藏，服务器上的数据保留。

## 验证

```bash
# 中继存活
curl -fsS https://dsh.example.com/ | head

# 雷达身份（需要令牌）
TOKEN=$(sudo grep RADAR_BEARER_TOKEN /etc/personal-assistant/radar.env | cut -d= -f2-)
curl -fsS https://radar.example.com/identity -H "Authorization: Bearer $TOKEN"

# 服务状态
systemctl status dsh-relay radar-api radar-worker --no-pager
```

## 排错

| 现象 | 处理 |
|---|---|
| `dsh-relay` 起不来 | `journalctl -u dsh-relay -n 100`；多为 3300 被占或 `.env` 权限不对 |
| 证书申请失败 | 确认域名已解析到本机、80 端口可达；`certbot certificates` 看现有证书 |
| 手机登录报 `ACCOUNT_AUTH_REQUIRED` | 账号/密码与 `/etc/dsh-relay.env` 不一致；改完 `systemctl restart dsh-relay` |
| 雷达 401 | 令牌不对；重新读 `radar.env`，或删掉 App 里的连接重填 |
| 雷达页空白 | 服务端 `curl 127.0.0.1:8787/identity`；检查 `radar-api` 与反代 |
| 知乎 unavailable / 需要登录 | 机房 IP 必须有登录态：手机雷达页会自动提示「登录知乎」，登录后 Cookie 只存到你的服务器；也可用 `--zhihu-cookie` 直接写进 `radar.env` |
| 其他源 unavailable | X/小红书需要登录态，属预期；见 README 已知限制 |
| 443 冲突 | 用 `--proxy caddy` 或 `--proxy none` 自行反代；脚本不会改别人的 vhost |

## 卸载

```bash
sudo systemctl disable --now dsh-relay radar-api radar-worker
sudo rm -f /etc/systemd/system/dsh-relay.service /etc/systemd/system/radar-api.service /etc/systemd/system/radar-worker.service
sudo rm -rf /opt/ds-harness-remote /opt/personal-assistant /etc/dsh-relay.env /etc/personal-assistant /etc/dsh-buddy
sudo systemctl daemon-reload
```

反向代理里与本项目相关的 server 块（`/etc/nginx/conf.d/dsh-buddy.conf` 或
`/etc/caddy/dsh-buddy.caddy`）一并删除后 reload。
