#!/usr/bin/env bash

set -euo pipefail

export HOME="${HOME:-/home/nemoclaw}"
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

mkdir -p "$HOME/.nemoclaw" "$HOME/.openclaw"
chmod 700 "$HOME/.nemoclaw" "$HOME/.openclaw"

DASHBOARD_URL_FILE="$HOME/.nemoclaw/dashboard-url.txt"

persist_env_credentials() {
  python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path(os.environ.get('HOME', '/tmp'))
creds_path = home / '.nemoclaw' / 'credentials.json'
creds_path.parent.mkdir(parents=True, exist_ok=True)

creds = {}
if creds_path.exists():
    try:
        creds = json.loads(creds_path.read_text())
    except Exception:
        creds = {}

updated = False
for key in ('NVIDIA_API_KEY', 'GITHUB_TOKEN'):
    value = os.environ.get(key)
    if value and creds.get(key) != value:
        creds[key] = value
        updated = True

if updated:
    creds_path.write_text(json.dumps(creds, indent=2))
    os.chmod(creds_path, 0o600)
PY
}

get_default_sandbox() {
  python3 - <<'PY'
import json
import os
from pathlib import Path

registry_path = Path(os.environ.get('HOME', '/tmp')) / '.nemoclaw' / 'sandboxes.json'
if not registry_path.exists():
    raise SystemExit(0)

try:
    data = json.loads(registry_path.read_text())
except Exception:
    raise SystemExit(0)

sandboxes = data.get('sandboxes') or {}
default_name = data.get('defaultSandbox')
if default_name and default_name in sandboxes:
    print(default_name)
elif sandboxes:
    print(next(iter(sandboxes)))
PY
}

get_registered_sandboxes() {
  python3 - <<'PY'
import json
import os
from pathlib import Path

registry_path = Path(os.environ.get('HOME', '/tmp')) / '.nemoclaw' / 'sandboxes.json'
if not registry_path.exists():
    raise SystemExit(0)

try:
    data = json.loads(registry_path.read_text())
except Exception:
    raise SystemExit(0)

sandboxes = data.get('sandboxes') or {}
default_name = data.get('defaultSandbox')
ordered = []
if default_name and default_name in sandboxes:
    ordered.append(default_name)
for name in sandboxes:
    if name not in ordered:
        ordered.append(name)

for name in ordered:
    print(name)
PY
}

has_registered_sandbox() {
  [ -n "$(get_registered_sandboxes | head -n 1)" ]
}

prune_stale_registered_sandboxes() {
  if ! openshell sandbox list >/dev/null 2>&1; then
    echo "[control] OpenShell gateway metadata is not ready; skipping stale registry cleanup."
    return 0
  fi

  local reachable_csv
  reachable_csv="$(openshell sandbox list 2>/dev/null | awk 'NR > 1 && NF { print $1 }' | paste -sd, -)"

  REACHABLE_SANDBOXES="$reachable_csv" python3 - <<'PY'
import json
import os
from pathlib import Path

registry_path = Path(os.environ.get('HOME', '/tmp')) / '.nemoclaw' / 'sandboxes.json'
if not registry_path.exists():
    raise SystemExit(0)

try:
    data = json.loads(registry_path.read_text())
except Exception:
    raise SystemExit(0)

reachable = {name for name in os.environ.get('REACHABLE_SANDBOXES', '').split(',') if name}
sandboxes = data.get('sandboxes') or {}
removed = [name for name in list(sandboxes) if name not in reachable]

for name in removed:
    sandboxes.pop(name, None)

if removed:
    default_name = data.get('defaultSandbox')
    if default_name in removed:
      data['defaultSandbox'] = next(iter(sandboxes), None)
    data['sandboxes'] = sandboxes
    registry_path.write_text(json.dumps(data, indent=2))
    os.chmod(registry_path, 0o600)
    print('[control] Removed stale registry entries: ' + ', '.join(removed))
PY
}

set_default_sandbox() {
  local sandbox_name="$1"
  python3 - "$sandbox_name" <<'PY'
import json
import os
import sys
from pathlib import Path

registry_path = Path(os.environ.get('HOME', '/tmp')) / '.nemoclaw' / 'sandboxes.json'
if not registry_path.exists():
    raise SystemExit(0)

try:
    data = json.loads(registry_path.read_text())
except Exception:
    raise SystemExit(0)

name = sys.argv[1]
if name not in (data.get('sandboxes') or {}):
    raise SystemExit(0)

if data.get('defaultSandbox') != name:
    data['defaultSandbox'] = name
    registry_path.write_text(json.dumps(data, indent=2))
    os.chmod(registry_path, 0o600)
PY
}

get_best_sandbox() {
  local sandbox_name
  while IFS= read -r sandbox_name; do
    [ -n "$sandbox_name" ] || continue
    if openshell sandbox get "$sandbox_name" >/dev/null 2>&1; then
      printf '%s\n' "$sandbox_name"
      return 0
    fi
  done < <(get_registered_sandboxes)

  printf '%s\n' "$(get_default_sandbox)"
}

restore_dashboard_forward() {
  local sandbox_name="$1"

  if ! openshell sandbox get "$sandbox_name" >/dev/null 2>&1; then
    echo "[control] Registered sandbox '$sandbox_name' is not reachable from the current gateway metadata."
    return 0
  fi

  openshell forward stop 18789 >/dev/null 2>&1 || true
  if openshell forward start --background 18789 "$sandbox_name" >/dev/null 2>&1; then
    echo "[control] Dashboard forward restored for '$sandbox_name' on http://127.0.0.1:18789/"
  else
    echo "[control] Failed to restore dashboard forward for '$sandbox_name'."
  fi
}

print_dashboard_url() {
  local sandbox_name="$1"
  local openshell_bin token

  openshell_bin="$(command -v openshell)"
  token="$({
    ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o GlobalKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ProxyCommand="$openshell_bin ssh-proxy --gateway-name nemoclaw --name $sandbox_name" \
      "sandbox@openshell-$sandbox_name" \
      "python3 -c \"import json, os; print(json.load(open(os.path.expanduser('~/.openclaw/openclaw.json')))['gateway']['auth']['token'])\"";
  } 2>/dev/null || true)"

  if [ -n "$token" ]; then
    local url="http://127.0.0.1:18789/#token=$token"
    printf '%s\n' "$url" > "$DASHBOARD_URL_FILE"
    chmod 600 "$DASHBOARD_URL_FILE"
    echo "[control] Dashboard URL: $url"
  else
    : > "$DASHBOARD_URL_FILE"
    echo "[control] Dashboard token is not available yet."
  fi
}

start_dashboard_redirector() {
  local redirect_port="${NEMOCLAW_REDIRECT_PORT:-18788}"

  nohup python3 - "$redirect_port" "$DASHBOARD_URL_FILE" > /tmp/nemoclaw-dashboard-redirector.log 2>&1 <<'PY' &
import http.server
import pathlib
import socketserver
import sys

port = int(sys.argv[1])
url_file = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
  def respond(self, include_body=True):
        try:
            target = url_file.read_text().strip()
        except Exception:
            target = ''

        if not target:
            body = b'Dashboard URL is not ready yet. Check control container logs.'
            self.send_response(503)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
      if include_body:
        self.wfile.write(body)
            return

        self.send_response(302)
        self.send_header('Location', target)
        self.end_headers()

  def do_GET(self):
    self.respond(include_body=True)

  def do_HEAD(self):
    self.respond(include_body=False)

    def log_message(self, format, *args):
        return

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReusableTCPServer(('0.0.0.0', port), Handler) as httpd:
    httpd.serve_forever()
PY

  echo "[control] Shortcut URL: http://127.0.0.1:${redirect_port}/"
}

ensure_policy_presets() {
  local sandbox_name="$1"
  local presets_csv="${NEMOCLAW_ENSURE_POLICY_PRESETS:-}"

  [ -n "$presets_csv" ] || return 0

  SANDBOX_NAME="$sandbox_name" PRESET_NAMES="$presets_csv" node - <<'NODE'
const { execSync } = require("child_process");
const policies = require("/workspace/bin/lib/policies");

const sandboxName = process.env.SANDBOX_NAME;
const presetNames = (process.env.PRESET_NAMES || "")
  .split(",")
  .map((name) => name.trim())
  .filter(Boolean);

if (!sandboxName || presetNames.length === 0) {
  process.exit(0);
}

let currentPolicy = "";
try {
  const raw = execSync(`openshell policy get --full "${sandboxName}" 2>/dev/null`, {
    encoding: "utf-8",
    stdio: ["pipe", "pipe", "pipe"],
  }).trim();
  currentPolicy = policies.parseCurrentPolicy(raw);
} catch {
  console.log(`[control] Could not inspect current policy for '${sandboxName}'.`);
  process.exit(0);
}

for (const presetName of presetNames) {
  const content = policies.loadPreset(presetName);
  if (!content) {
    console.log(`[control] Unknown policy preset '${presetName}'.`);
    continue;
  }

  const hosts = policies.getPresetEndpoints(content);
  const missingHosts = hosts.filter((host) => !currentPolicy.includes(host));
  if (missingHosts.length === 0) {
    console.log(`[control] Policy preset '${presetName}' already present.`);
    continue;
  }

  policies.applyPreset(sandboxName, presetName);
  console.log(`[control] Ensured policy preset '${presetName}'.`);
}
NODE
}

persist_env_credentials
start_dashboard_redirector

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ "${NEMOCLAW_AUTO_ONBOARD:-0}" = "1" ]; then
  if has_registered_sandbox; then
    echo "[control] Existing NemoClaw state detected. Skipping auto-onboard."
  else
    echo "[control] Running non-interactive onboard..."
    nemoclaw onboard --non-interactive
  fi
fi

prune_stale_registered_sandboxes

default_sandbox="$(get_best_sandbox)"
if [ -n "$default_sandbox" ]; then
  set_default_sandbox "$default_sandbox"
  restore_dashboard_forward "$default_sandbox"
  ensure_policy_presets "$default_sandbox"
  print_dashboard_url "$default_sandbox"
else
  echo "[control] No registered sandbox found."
  echo "[control] Run: docker compose -f compose.persistent.yaml exec nemoclaw-control nemoclaw onboard"
fi

echo "[control] NemoClaw control plane is ready."
echo "[control] State is bound to ${NEMOCLAW_HOST_HOME:-the configured WSL home} so existing NemoClaw/OpenClaw metadata is reused."

exec tail -f /dev/null