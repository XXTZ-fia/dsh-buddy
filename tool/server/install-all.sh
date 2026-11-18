#!/usr/bin/env bash
# One command on a fresh Ubuntu/Debian server: relay + radar + HTTPS.
#
#   sudo tool/server/install-all.sh \
#     --relay-host dsh.example.com \
#     --radar-host radar.example.com \
#     --email you@example.com
#
# What it does
#   1. installs the relay server (liguobao/ds-harness-remote, pinned tag)
#   2. installs the radar backend from this repository
#   3. puts both behind nginx with Let's Encrypt certificates (or Caddy)
#   4. writes /etc/dsh-buddy/access.txt with the URLs, account and token
#
# The script is idempotent: re-running it updates the checkout, rebuilds the
# server, rewrites the units and reloads the proxy. It never touches other
# sites on the machine.

set -euo pipefail

RELAY_HOST=""
RADAR_HOST=""
EMAIL=""
ACCOUNT=""
PASSWORD=""
ZHIHU_COOKIE=""
PROXY="auto"
SKIP_RADAR=0
SKIP_RELAY=0
FORCE_OS=0
RELAY_TAG="v0.6.5"
REPO_URL="https://github.com/liguobao/ds-harness-remote.git"
ACCESS_DIR="/etc/dsh-buddy"
ACCESS_FILE="$ACCESS_DIR/access.txt"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --relay-host <host>   relay domain, e.g. dsh.example.com (required)
  --radar-host <host>   radar domain, e.g. radar.example.com (required)
  --email <address>     Let's Encrypt account (required for a first issue)
  --account <email>     relay login account (default: admin@<relay-host>)
  --password <secret>   relay password (default: generated, >= 16 chars)
  --zhihu-cookie <c>    Zhihu login cookie so the hot list works from a
                        datacenter IP (optional)
  --proxy <mode>        auto | nginx | caddy | none   (default: auto)
  --skip-radar          relay only
  --skip-relay          radar only
  --force               skip the Ubuntu/Debian check (unsupported)
  -h, --help
EOF
}

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n== %s ==\n' "$*"; }

while test $# -gt 0; do
  case "$1" in
    --relay-host) RELAY_HOST="${2:-}"; shift 2 ;;
    --radar-host) RADAR_HOST="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --zhihu-cookie) ZHIHU_COOKIE="${2:-}"; shift 2 ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --skip-radar) SKIP_RADAR=1; shift ;;
    --skip-relay) SKIP_RELAY=1; shift ;;
    --force) FORCE_OS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

test "$(id -u)" = 0 || die "run as root on the destination server"
command -v systemctl >/dev/null || die "systemd is required"
test -f /etc/os-release || die "cannot identify the OS"
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *)
    if test "$FORCE_OS" = 1; then
      echo "warning: forcing an unsupported OS (${ID:-unknown}); package steps may fail" >&2
    else
      die "this script targets Ubuntu/Debian (found ${ID:-unknown}); pass --force to try anyway"
    fi
    ;;
esac

test "$SKIP_RADAR" = 1 || test -n "$RADAR_HOST" || die "--radar-host is required"
test "$SKIP_RELAY" = 1 || test -n "$RELAY_HOST" || die "--relay-host is required"
command -v curl >/dev/null || die "curl is required"
command -v git >/dev/null || die "git is required"
command -v openssl >/dev/null || die "openssl is required"

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test -f "$source_dir/radar/scripts/install-server.sh" || die "run this from the repository checkout (radar/ not found)"

if test -z "$ACCOUNT"; then ACCOUNT="admin@${RELAY_HOST:-local}"; fi
if test -z "$PASSWORD"; then
  PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)
fi
test "${#PASSWORD}" -ge 12 || die "the relay password must be at least 12 characters"

install -d -m 700 "$ACCESS_DIR"

# ── Node ─────────────────────────────────────────────────────────────────────
resolve_node() {
  if command -v node >/dev/null; then command -v node; return; fi
  for candidate in /opt/node24/bin/node /opt/node22/bin/node /usr/local/bin/node; do
    test -x "$candidate" && { echo "$candidate"; return; }
  done
  return 1
}

ensure_node() {
  local node major
  if node=$(resolve_node); then
    major=$("$node" -p 'process.versions.node.split(".")[0]')
    test "$major" -ge 22 || die "Node.js 22+ is required (found $("$node" -v))"
    echo "$node"
    return
  fi
  log "installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null
  command -v node >/dev/null || die "Node.js install failed"
  echo "$(command -v node)"
}

ensure_pnpm() {
  local node="$1"
  local dir major
  dir=$(dirname "$node")
  if test -x "$dir/pnpm"; then echo "$dir/pnpm"; return; fi
  if command -v pnpm >/dev/null; then command -v pnpm; return; fi
  export PATH="$dir:$PATH"
  corepack enable >/dev/null 2>&1 || true
  corepack prepare pnpm@9.15.4 --activate >/dev/null 2>&1 || true
  command -v pnpm >/dev/null || die "pnpm is required (corepack enable failed)"
  command -v pnpm
}

# ── Relay ────────────────────────────────────────────────────────────────────
install_relay() {
  local node pnpm node_dir
  node=$(ensure_node)
  node_dir=$(dirname "$node")
  pnpm=$(ensure_pnpm "$node")
  log "relay: checkout $RELAY_TAG"
  if test -d /opt/ds-harness-remote/.git; then
    git -C /opt/ds-harness-remote fetch --tags --quiet origin
  else
    rm -rf /opt/ds-harness-remote
    git clone --quiet "$REPO_URL" /opt/ds-harness-remote
  fi
  git -C /opt/ds-harness-remote checkout --quiet "$RELAY_TAG"
  log "relay: build"
  ( cd /opt/ds-harness-remote
    PATH="$node_dir:$PATH" "$pnpm" install --frozen-lockfile --silent
    PATH="$node_dir:$PATH" "$pnpm" --filter @dsh-remote/protocol build >/dev/null
    PATH="$node_dir:$PATH" "$pnpm" --filter @dsh-remote/server build >/dev/null
  )
  test -f /opt/ds-harness-remote/apps/server/dist/main.js || die "relay build produced no dist/main.js"

  id dsh-relay >/dev/null 2>&1 || useradd --system --home /var/lib/dsh-relay --shell /usr/sbin/nologin dsh-relay
  install -d -m 750 -o dsh-relay -g dsh-relay /var/lib/dsh-relay
  umask 077
  cat > /etc/dsh-relay.env <<EOF
DSH_SERVER_ACCOUNT=$ACCOUNT
DSH_SERVER_PASSWORD=$PASSWORD
DSH_SERVER_HOST=127.0.0.1
DSH_SERVER_PORT=3300
DSH_SERVER_PUBLIC_URL=https://$RELAY_HOST
DSH_SERVER_DATA_FILE=/var/lib/dsh-relay/state.json
DSH_SERVER_TRUSTED_PROXY_IPS=127.0.0.1
DSH_SERVER_LOG_LEVEL=info
EOF
  chmod 600 /etc/dsh-relay.env

  cat > /etc/systemd/system/dsh-relay.service <<EOF
[Unit]
Description=DSH Remote relay (ds-harness-remote server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dsh-relay
Group=dsh-relay
WorkingDirectory=/opt/ds-harness-remote/apps/server
EnvironmentFile=/etc/dsh-relay.env
ExecStart=$node dist/main.js
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/dsh-relay

[Install]
WantedBy=multi-user.target
EOF
  install -d -m 755 /etc/systemd/system/dsh-relay.service.d
  systemctl daemon-reload
  systemctl enable dsh-relay >/dev/null
  systemctl restart dsh-relay
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 http://127.0.0.1:3300/healthz >/dev/null 2>&1 || \
       curl -fsS --max-time 2 http://127.0.0.1:3300/ >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  systemctl is-active --quiet dsh-relay || die "dsh-relay failed to start (journalctl -u dsh-relay)"
}

# ── Radar ────────────────────────────────────────────────────────────────────
install_radar() {
  log "radar: install"
  if test "$FORCE_OS" = 1; then
    SKIP_PLAYWRIGHT_DEPS=1 bash "$source_dir/radar/scripts/install-server.sh"
  else
    bash "$source_dir/radar/scripts/install-server.sh"
  fi
  RADAR_TOKEN=$(grep -m1 '^RADAR_BEARER_TOKEN=' /etc/personal-assistant/radar.env | cut -d= -f2-)
  test -n "$RADAR_TOKEN" || die "radar token was not generated"
  if test -n "$ZHIHU_COOKIE"; then
    if grep -q '^RADAR_ZHIHU_COOKIE=' /etc/personal-assistant/radar.env; then
      sed -i "s|^RADAR_ZHIHU_COOKIE=.*|RADAR_ZHIHU_COOKIE=$ZHIHU_COOKIE|" /etc/personal-assistant/radar.env
    else
      echo "RADAR_ZHIHU_COOKIE=$ZHIHU_COOKIE" >> /etc/personal-assistant/radar.env
    fi
    systemctl restart radar-api radar-worker
  fi
}

# ── HTTPS ────────────────────────────────────────────────────────────────────
certbot_issue() {
  local host="$1"
  test -f "/etc/letsencrypt/live/$host/fullchain.pem" && return 0
  test -n "$EMAIL" || die "no certificate for $host; pass --email to issue one"
  log "certificate: $host"
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null
  # Standalone briefly stops nginx: no vhost has to exist yet, which keeps the
  # first install working on a machine with no 80/443 site at all.
  certbot certonly --standalone -d "$host" \
    --email "$EMAIL" --agree-tos --non-interactive --keep-until-expiring \
    --pre-hook 'systemctl stop nginx' --post-hook 'systemctl start nginx'
  test -f "/etc/letsencrypt/live/$host/fullchain.pem" || die "certificate for $host was not issued"
}

write_nginx() {
  command -v nginx >/dev/null || die "nginx is not installed (use --proxy caddy or install nginx)"
  local stream_file="" use_stream=0
  if grep -rqs 'ssl_preread on' /etc/nginx/stream.d/*.conf 2>/dev/null; then
    stream_file=$(grep -rls 'map \$ssl_preread_server_name' /etc/nginx/stream.d/*.conf | head -1 || true)
    test -n "$stream_file" && use_stream=1
  fi

  local radar_port=10444 relay_port=10446
  local radar_listen="443" relay_listen="443"
  if test "$use_stream" = 1; then
    # This machine already routes 443 by SNI; add our two names to that map and
    # give each a loopback TLS vhost. Nothing else on 443 changes.
    for pair in "radar $RADAR_HOST $radar_port" "relay $RELAY_HOST $relay_port"; do
      set -- $pair
      local kind="$1" host="$2" port="$3"
      test "$kind" = radar && test "$SKIP_RADAR" = 1 && continue
      test "$kind" = relay && test "$SKIP_RELAY" = 1 && continue
      test "$kind" = radar && radar_listen="127.0.0.1:$port"
      test "$kind" = relay && relay_listen="127.0.0.1:$port"
      if ! grep -q "$host" "$stream_file"; then
        sed -i "/default /i\\    $host 127.0.0.1:$port;" "$stream_file"
      fi
    done
  else
    radar_port=443
    relay_port=443
    radar_listen="443"
    relay_listen="443"
  fi

  local conf=/etc/nginx/conf.d/dsh-buddy.conf
  : > "$conf"
  if test "$SKIP_RADAR" = 0; then
    certbot_issue "$RADAR_HOST"
    cat >> "$conf" <<EOF
server {
    listen 80;
    server_name $RADAR_HOST;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen $radar_listen ssl;
    server_name $RADAR_HOST;
    ssl_certificate /etc/letsencrypt/live/$RADAR_HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$RADAR_HOST/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 24m;
    add_header Strict-Transport-Security "max-age=15552000" always;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
EOF
  fi
  if test "$SKIP_RELAY" = 0; then
    certbot_issue "$RELAY_HOST"
    if test "$use_stream" = 1; then
      cat >> "$conf" <<EOF
server {
    listen $relay_listen ssl;
    server_name $RELAY_HOST;
    ssl_certificate /etc/letsencrypt/live/$RELAY_HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$RELAY_HOST/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 64m;
    add_header Strict-Transport-Security "max-age=15552000" always;

    location / {
        proxy_pass http://127.0.0.1:3300;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF
    else
      cat >> "$conf" <<EOF
server {
    listen 80;
    server_name $RELAY_HOST;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen $relay_listen ssl;
    server_name $RELAY_HOST;
    ssl_certificate /etc/letsencrypt/live/$RELAY_HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$RELAY_HOST/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 64m;
    add_header Strict-Transport-Security "max-age=15552000" always;

    location / {
        proxy_pass http://127.0.0.1:3300;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF
    fi
  fi
  nginx -t >/dev/null || die "nginx rejected the generated config ($conf)"
  # restart, not reload: a changed listen address can leave the old wildcard
  # socket bound in the master process until it is replaced.
  systemctl restart nginx
}

write_caddy() {
  command -v caddy >/dev/null || die "caddy is not installed"
  local file=/etc/caddy/Caddyfile
  test -f "$file" || : > "$file"
  local block=/etc/caddy/dsh-buddy.caddy
  : > "$block"
  if test "$SKIP_RADAR" = 0; then
    cat >> "$block" <<EOF
$RADAR_HOST {
    reverse_proxy 127.0.0.1:8787
}

EOF
  fi
  if test "$SKIP_RELAY" = 0; then
    cat >> "$block" <<EOF
$RELAY_HOST {
    reverse_proxy 127.0.0.1:3300
}

EOF
  fi
  if ! grep -q 'dsh-buddy.caddy' "$file"; then
    printf '\nimport %s\n' "$block" >> "$file"
  fi
  caddy validate --config "$file" >/dev/null || die "caddy rejected the config"
  systemctl reload caddy
}

install_proxy() {
  case "$PROXY" in
    none) log "proxy: skipped (services listen on loopback)"; return ;;
    auto)
      if command -v caddy >/dev/null; then PROXY=caddy
      elif command -v nginx >/dev/null; then PROXY=nginx
      else die "neither nginx nor caddy is installed; install one or use --proxy none"
      fi
      ;;
  esac
  log "proxy: $PROXY"
  case "$PROXY" in
    nginx) write_nginx ;;
    caddy) write_caddy ;;
    *) die "unknown proxy: $PROXY" ;;
  esac
}

# ── Run ──────────────────────────────────────────────────────────────────────
test "$SKIP_RELAY" = 1 || install_relay
test "$SKIP_RADAR" = 1 || install_radar
install_proxy

{
  echo "DSH Buddy server"
  echo "created: $(date -Is)"
  echo
  test "$SKIP_RELAY" = 1 || {
    echo "relay:    https://$RELAY_HOST"
    echo "account:  $ACCOUNT"
    echo "password: $PASSWORD"
    echo
  }
  test "$SKIP_RADAR" = 1 || {
    echo "radar:    https://$RADAR_HOST"
    echo "token:    ${RADAR_TOKEN:-see /etc/personal-assistant/radar.env}"
    echo
  }
  echo "In the app: Remote -> Self-hosted server, then the radar page uses the"
  echo "same server address and the token above."
} > "$ACCESS_FILE"
chmod 600 "$ACCESS_FILE"

log "done"
cat "$ACCESS_FILE"
