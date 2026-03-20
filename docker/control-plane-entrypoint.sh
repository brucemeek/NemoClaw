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

  pkill -f "openshell forward start 18789" >/dev/null 2>&1 || true
  openshell forward stop 18789 >/dev/null 2>&1 || true
  rm -f /tmp/nemoclaw-dashboard-forward.log
  nohup openshell forward start 18789 "$sandbox_name" >/tmp/nemoclaw-dashboard-forward.log 2>&1 &

  for _ in $(seq 1 10); do
    if python3 - <<'PY' >/dev/null 2>&1
import urllib.request
with urllib.request.urlopen("http://127.0.0.1:18789", timeout=2) as response:
    response.read(1)
PY
    then
      echo "[control] Dashboard forward restored for '$sandbox_name' on http://127.0.0.1:18789/"
      return 0
    fi
    sleep 1
  done

  echo "[control] Failed to restore dashboard forward for '$sandbox_name'."
  tail -n 40 /tmp/nemoclaw-dashboard-forward.log 2>/dev/null || true
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
    chmod 644 "$DASHBOARD_URL_FILE"
    echo "[control] Dashboard URL: $url"
  else
    : > "$DASHBOARD_URL_FILE"
    chmod 644 "$DASHBOARD_URL_FILE"
    echo "[control] Dashboard token is not available yet."
  fi
}

get_sandbox_selection_config() {
  local sandbox_name="$1"
  local openshell_bin

  openshell_bin="$(command -v openshell)"
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ProxyCommand="$openshell_bin ssh-proxy --gateway-name nemoclaw --name $sandbox_name" \
    "sandbox@openshell-$sandbox_name" \
    "python3 -c \"import os, pathlib; path = pathlib.Path(os.path.expanduser('~/.nemoclaw/config.json')); print(path.read_text() if path.exists() else '')\"" 2>/dev/null || true
}

restore_inference_config() {
  local sandbox_name="$1"
  local selection_json parsed provider_name endpoint_url model_name

  selection_json="$(get_sandbox_selection_config "$sandbox_name")"
  [ -n "$selection_json" ] || return 0

  parsed="$({
    SELECTION_JSON="$selection_json" python3 - <<'PY'
import json
import os

try:
    cfg = json.loads(os.environ.get('SELECTION_JSON', ''))
except Exception:
    raise SystemExit(0)

provider = str(cfg.get('provider') or '').strip()
endpoint = str(cfg.get('endpointUrl') or '').strip()
model = str(cfg.get('model') or '').strip()

if provider in {'nvidia-nim', 'vllm-local', 'ollama-local'} and endpoint and model:
    print(provider)
    print(endpoint)
    print(model)
PY
  } 2>/dev/null)"

  [ -n "$parsed" ] || return 0

  mapfile -t _nemoclaw_inference_lines <<<"$parsed"
  provider_name="${_nemoclaw_inference_lines[0]:-}"
  endpoint_url="${_nemoclaw_inference_lines[1]:-}"
  model_name="${_nemoclaw_inference_lines[2]:-}"

  if [ -z "$provider_name" ] || [ -z "$endpoint_url" ] || [ -z "$model_name" ]; then
    return 0
  fi

  openshell provider create \
    --name "$provider_name" \
    --type openai \
    --credential OPENAI_API_KEY=dummy \
    --config "OPENAI_BASE_URL=$endpoint_url" >/dev/null 2>&1 || \
  openshell provider update \
    "$provider_name" \
    --credential OPENAI_API_KEY=dummy \
    --config "OPENAI_BASE_URL=$endpoint_url" >/dev/null 2>&1 || true

  if openshell inference set --no-verify --provider "$provider_name" --model "$model_name" >/dev/null 2>&1; then
    echo "[control] Inference route restored: $provider_name -> $model_name @ $endpoint_url"
  else
    echo "[control] Failed to restore inference route for '$sandbox_name'."
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

start_dashboard_bridge() {
  local bridge_port="${NEMOCLAW_DASHBOARD_BRIDGE_PORT:-18790}"

  nohup env \
    PORT="$bridge_port" \
    TARGET_ORIGIN="http://127.0.0.1:18789" \
    python3 /workspace/docker/dashboard-bridge.py > /tmp/nemoclaw-dashboard-bridge.log 2>&1 &

  echo "[control] Dashboard bridge: http://0.0.0.0:${bridge_port}/ -> http://127.0.0.1:18789/"
}

refresh_dashboard_state() {
  prune_stale_registered_sandboxes

  local default_sandbox
  default_sandbox="$(get_best_sandbox)"
  if [ -n "$default_sandbox" ]; then
    set_default_sandbox "$default_sandbox"
    restore_dashboard_forward "$default_sandbox"
    restore_inference_config "$default_sandbox"
    ensure_policy_presets "$default_sandbox"
    print_dashboard_url "$default_sandbox"
    return 0
  fi

  : > "$DASHBOARD_URL_FILE"
  chmod 644 "$DASHBOARD_URL_FILE"
  echo "[control] No registered sandbox found."
  echo "[control] Run: docker compose -f compose.persistent.yaml exec nemoclaw-control nemoclaw onboard"
  return 1
}

wait_for_dashboard_state() {
  local attempts="${NEMOCLAW_DASHBOARD_RETRY_ATTEMPTS:-30}"
  local sleep_seconds="${NEMOCLAW_DASHBOARD_RETRY_SLEEP:-2}"

  for _ in $(seq 1 "$attempts"); do
    if refresh_dashboard_state; then
      if [ -s "$DASHBOARD_URL_FILE" ]; then
        return 0
      fi
    fi
    sleep "$sleep_seconds"
  done

  echo "[control] Dashboard URL is still not ready after waiting for OpenShell metadata."
  return 1
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
start_dashboard_bridge
if [ "${NEMOCLAW_INTERNAL_REDIRECTOR:-0}" = "1" ]; then
  start_dashboard_redirector
fi

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

wait_for_dashboard_state || true

echo "[control] NemoClaw control plane is ready."
echo "[control] State is bound to ${NEMOCLAW_HOST_HOME:-the configured WSL home} so existing NemoClaw/OpenClaw metadata is reused."

exec tail -f /dev/null