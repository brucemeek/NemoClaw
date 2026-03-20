// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const startupScript = fs.readFileSync(path.join(ROOT, "scripts", "nemoclaw-start.sh"), "utf-8");
const dockerfile = fs.readFileSync(path.join(ROOT, "Dockerfile"), "utf-8");
const sandboxDockerfile = fs.readFileSync(path.join(ROOT, "test", "Dockerfile.sandbox"), "utf-8");
const {
  SANDBOX_PATH_EXPORT,
  buildSandboxOpenClawUpdateScript,
  normalizeOpenClawTarget,
} = require(path.join(ROOT, "bin", "lib", "openclaw-update"));

describe("sandbox OpenClaw upgrade support", () => {
  it("accepts a normal semver or channel target", () => {
    assert.equal(normalizeOpenClawTarget("latest"), "latest");
    assert.equal(normalizeOpenClawTarget("2026.3.13"), "2026.3.13");
    assert.equal(normalizeOpenClawTarget("beta"), "beta");
  });

  it("rejects unsupported target strings", () => {
    assert.throws(() => normalizeOpenClawTarget("latest now"), /Unsupported OpenClaw version or tag/);
  });

  it("builds a sandbox update script that installs into a user-local npm prefix", () => {
    const script = buildSandboxOpenClawUpdateScript("2026.3.13");

    assert.match(script, /npm config set prefix "\$PREFIX"/);
    assert.match(script, /npm i -g "openclaw@\$TARGET"/);
    assert.match(script, /plugins install \/opt\/nemoclaw/);
    assert.match(script, /TARGET='2026\.3\.13'/);
    assert.ok(script.includes(SANDBOX_PATH_EXPORT));
  });

  it("configures sandbox startup shells to prefer the user-local npm prefix", () => {
    assert.match(startupScript, /ensure_user_local_openclaw_updates/);
    assert.ok(startupScript.includes(SANDBOX_PATH_EXPORT));
    assert.match(startupScript, /npm config set prefix/);
  });

  it("auto-syncs the sandbox OpenClaw version to the bundled image version on startup", () => {
    assert.match(startupScript, /ensure_bundled_openclaw_version/);
    assert.match(startupScript, /npm i -g "openclaw@\$\{target_version\}"/);
    assert.match(startupScript, /NEMOCLAW_OPENCLAW_VERSION/);
    assert.match(dockerfile, /ENV NEMOCLAW_OPENCLAW_VERSION=2026\.3\.13/);
    assert.match(sandboxDockerfile, /ENV NEMOCLAW_OPENCLAW_VERSION=2026\.3\.13/);
  });
});