#!/usr/bin/env bash
# Run on the destination Linux server, from this source checkout. Does not change frp.
set -euo pipefail
test "$(id -u)" = 0 || { echo 'Run as root on the destination server.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || {
  echo "Python 3.11+ is required (found $(python3 -V 2>&1)). On Ubuntu 22.04 install python3.11 + python3.11-venv first." >&2
  exit 1
}
python3 -c 'import venv' 2>/dev/null || {
  echo 'python3-venv is required (apt install python3-venv).' >&2
  exit 1
}
command -v systemctl >/dev/null || { echo 'systemd is required.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
id radar >/dev/null 2>&1 || useradd --system --home /var/lib/personal-assistant --create-home --shell /usr/sbin/nologin radar
install -d -m 755 /opt/personal-assistant/radar
install -d -m 750 -o radar -g radar /var/lib/personal-assistant
install -d -m 750 -o root -g radar /etc/personal-assistant
# Copy only distributable code: never copy profiles, secrets or a developer database.
# Replace src/ instead of merging into it: a module deleted upstream must not linger here
# (the next `pip install` would still package it).
rm -rf /opt/personal-assistant/radar/src.new
cp -a "$source_dir/src" /opt/personal-assistant/radar/src.new
rm -rf /opt/personal-assistant/radar/src
mv /opt/personal-assistant/radar/src.new /opt/personal-assistant/radar/src
cp -a "$source_dir/pyproject.toml" "$source_dir/config.example.yaml" /opt/personal-assistant/radar/
python3 -m venv /opt/personal-assistant/venv
/opt/personal-assistant/venv/bin/pip install /opt/personal-assistant/radar
if ! test -e /etc/personal-assistant/config.yaml; then
  cp "$source_dir/config.example.yaml" /etc/personal-assistant/config.yaml
  /opt/personal-assistant/venv/bin/python - <<'PY'
from pathlib import Path
import yaml
p = Path('/etc/personal-assistant/config.yaml')
d = yaml.safe_load(p.read_text())
d['paths'].update(outbox='/var/lib/personal-assistant/radar.json',
    db='/var/lib/personal-assistant/state.db', profiles='/var/lib/personal-assistant/profiles',
    secrets='/var/lib/personal-assistant/secrets')
p.write_text(yaml.safe_dump(d, allow_unicode=True), encoding='utf-8')
PY
fi
if ! test -e /etc/personal-assistant/radar.env; then
  /opt/personal-assistant/venv/bin/python - <<'PY'
from pathlib import Path
import secrets
Path('/etc/personal-assistant/radar.env').write_text('RADAR_BEARER_TOKEN=' + secrets.token_urlsafe(48) + '\n', encoding='utf-8')
PY
fi
chown root:radar /etc/personal-assistant/config.yaml /etc/personal-assistant/radar.env
chmod 640 /etc/personal-assistant/config.yaml /etc/personal-assistant/radar.env
chmod 755 /opt/personal-assistant
chmod -R a+rX /opt/personal-assistant/venv
if test "${SKIP_PLAYWRIGHT_DEPS:-0}" != 1; then
  /opt/personal-assistant/venv/bin/playwright install-deps chromium
fi
runuser -u radar -- env PLAYWRIGHT_BROWSERS_PATH=/var/lib/personal-assistant/browsers /opt/personal-assistant/venv/bin/playwright install chromium
install -m 644 "$source_dir/scripts/radar-api.service" /etc/systemd/system/radar-api.service
install -m 644 "$source_dir/scripts/radar-worker.service" /etc/systemd/system/radar-worker.service
systemctl daemon-reload
systemctl enable radar-api radar-worker
systemctl restart radar-api radar-worker
echo 'Done. The API listens on 127.0.0.1:8787 — put it behind TLS before use (see scripts/Caddyfile.example).'
echo 'Access token: /etc/personal-assistant/radar.env (RADAR_BEARER_TOKEN)'
