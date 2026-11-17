# radar · 六平台简报 + 47 源热榜

完整的架构、契约、部署与红线见 [`../docs/PROJECT.md`](../docs/PROJECT.md)。这里只放命令。

```bash
# 一次性
pip install -e ".[dev]" && playwright install chromium
cp config.example.yaml config.yaml
export RADAR_BEARER_TOKEN=<至少 32 字符>

# 四个 CLI 命令
radar check-auth --platform <name>      # 单平台验活
radar run-once --dry-run                # fixtures 全链路，不联网不调模型
radar run-once [--only <name>] [--limit N] [--no-model]
radar verify-outbox [--file <path>]     # 校验 radar.json 契约

# 两个常驻进程
radar-api    --config config.yaml       # 127.0.0.1:8787
radar-worker --config config.yaml       # 调度 + 采集 + 热榜缓存
```

首次扫码登录（每平台一次，登录态存 `browser_profiles/<platform>/`）：

```bash
python -c "from radar.config import load, read_env; from radar.browser import open_login; open_login(load(None, read_env()), 'weibo')"
```

`weibo` 换成 `bili` / `zhihu` / `douyin` / `xhs` / `x`。程序不索取、不保存、不回显账号密码。

四件套验收：

```bash
ruff check . && ruff format --check . && mypy src/ && pytest -q
```

`secrets/`、`browser_profiles/`、`outbox/`、`*.db`、`config.yaml` 均为本机运行数据，不入库。
