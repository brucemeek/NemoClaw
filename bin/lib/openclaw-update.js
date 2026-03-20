// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

const { run } = require("./runner");

const DEFAULT_OPENCLAW_TARGET = "latest";
const SANDBOX_PATH_EXPORT = 'export PATH="$HOME/.npm-global/bin:$PATH"';

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function normalizeOpenClawTarget(value) {
  const target = String(value || DEFAULT_OPENCLAW_TARGET).trim();
  if (!target) {
    return DEFAULT_OPENCLAW_TARGET;
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(target)) {
    throw new Error(`Unsupported OpenClaw version or tag: ${value}`);
  }
  return target;
}

function buildSandboxOpenClawUpdateScript(target = DEFAULT_OPENCLAW_TARGET) {
  const normalizedTarget = normalizeOpenClawTarget(target);

  return [
    "set -euo pipefail",
    'PREFIX="$HOME/.npm-global"',
    'BIN_DIR="$PREFIX/bin"',
    'OPENCLAW_BIN="$BIN_DIR/openclaw"',
    `PATH_LINE=${shellQuote(SANDBOX_PATH_EXPORT)}`,
    'mkdir -p "$BIN_DIR"',
    'npm config set prefix "$PREFIX" >/dev/null',
    'case ":$PATH:" in',
    '  *":$BIN_DIR:"*) ;;',
    '  *) export PATH="$BIN_DIR:$PATH" ;;',
    'esac',
    'touch "$HOME/.bashrc" "$HOME/.profile"',
    'grep -Fqx "$PATH_LINE" "$HOME/.bashrc" || printf "\\n%s\\n" "$PATH_LINE" >> "$HOME/.bashrc"',
    'grep -Fqx "$PATH_LINE" "$HOME/.profile" || printf "\\n%s\\n" "$PATH_LINE" >> "$HOME/.profile"',
    `TARGET=${shellQuote(normalizedTarget)}`,
    'echo "  Configured npm prefix: $PREFIX"',
    'echo "  Installing OpenClaw target: $TARGET"',
    'npm i -g "openclaw@$TARGET" --no-fund --no-audit --loglevel=error',
    'if [ ! -x "$OPENCLAW_BIN" ]; then',
    '  echo "  Expected upgraded OpenClaw binary at $OPENCLAW_BIN" >&2',
    '  exit 1',
    'fi',
    '"$OPENCLAW_BIN" doctor --fix > /dev/null 2>&1 || true',
    '"$OPENCLAW_BIN" plugins install /opt/nemoclaw > /dev/null 2>&1 || true',
    'echo "  OpenClaw binary: $OPENCLAW_BIN"',
    'echo "  OpenClaw version: $("$OPENCLAW_BIN" --version)"',
    'echo "  Future sandbox shells will prefer the user-local OpenClaw install."',
  ].join("\n");
}

function updateOpenClawInSandbox(sandboxName, target = DEFAULT_OPENCLAW_TARGET) {
  const script = buildSandboxOpenClawUpdateScript(target);
  run(`cat <<'EOF_NEMOCLAW_OPENCLAW_UPDATE' | openshell sandbox connect "${sandboxName}"
${script}
EOF_NEMOCLAW_OPENCLAW_UPDATE`, { stdio: ["ignore", "inherit", "inherit"] });
}

module.exports = {
  DEFAULT_OPENCLAW_TARGET,
  SANDBOX_PATH_EXPORT,
  buildSandboxOpenClawUpdateScript,
  normalizeOpenClawTarget,
  updateOpenClawInSandbox,
};