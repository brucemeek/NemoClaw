// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

const { after, describe, it } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..");
const shortcutScript = path.join(ROOT, "docker", "dashboard-shortcut.py");

function resolvePythonCommand() {
  const candidates = [
    ["python3", []],
    ["python", []],
    ["py", ["-3"]],
  ];

  for (const [command, args] of candidates) {
    const result = spawnSync(command, [...args, "--version"], { stdio: "ignore" });
    if (result.status === 0) {
      return { command, args };
    }
  }

  throw new Error("Python interpreter not available for dashboard shortcut tests.");
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function request(port, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: "127.0.0.1",
        port,
        path: options.path || "/",
        method: options.method || "GET",
        headers: options.headers || {},
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf-8"),
          });
        });
      },
    );
    req.on("error", reject);
    if (options.body) {
      req.write(options.body);
    }
    req.end();
  });
}

async function waitForServer(port) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      await request(port, { method: "HEAD" });
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error(`dashboard shortcut server on port ${port} did not start`);
}

describe("dashboard shortcut service", () => {
  const disposers = [];

  after(async () => {
    for (const dispose of disposers.reverse()) {
      await dispose();
    }
  });

  it("serves a bootstrap page that sets the cookie and then proxies traffic", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "nemoclaw-dashboard-shortcut-"));
    const urlFile = path.join(tmpDir, "dashboard-url.txt");

    const backendServer = http.createServer((req, res) => {
      if (req.url === "/" || req.url === "/index.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end("<html><body>dashboard ok</body></html>");
        return;
      }
      if (req.url === "/api/ping") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end('{"ok":true}');
        return;
      }
      res.writeHead(404);
      res.end("missing");
    });
    const backendPort = await listen(backendServer);
    disposers.push(async () => {
      await new Promise((resolve) => backendServer.close(resolve));
    });

    fs.writeFileSync(urlFile, "http://127.0.0.1:18789/#token=test-token", "utf-8");

    const shortcutServer = http.createServer();
    const shortcutPort = await listen(shortcutServer);
    await new Promise((resolve) => shortcutServer.close(resolve));

    const python = resolvePythonCommand();
    const shortcutProc = spawn(python.command, [...python.args, shortcutScript], {
      env: {
        ...process.env,
        PORT: String(shortcutPort),
        DASHBOARD_URL_FILE: urlFile,
        DASHBOARD_PROXY_ORIGIN: `http://127.0.0.1:${backendPort}`,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    disposers.push(async () => {
      if (!shortcutProc.killed) {
        shortcutProc.kill();
      }
    });

    await waitForServer(shortcutPort);

    const first = await request(shortcutPort, {
      headers: { Accept: "text/html" },
    });
    assert.equal(first.statusCode, 200);
    assert.match(first.body, /Opening OpenClaw dashboard/);
    assert.match(first.body, new RegExp(`http://127\\.0\\.0\\.1:${shortcutPort}/index\\.html#token=test-token&gatewayUrl=ws%3A%2F%2F127\\.0\\.0\\.1%3A${shortcutPort}`));
    assert.doesNotMatch(first.body, /Location:/);

    const second = await request(shortcutPort, {
      path: "/index.html",
      headers: { Cookie: "nemoclaw_dashboard_token=1" },
    });
    assert.equal(second.statusCode, 200);
    assert.match(second.body, /dashboard ok/);

    const api = await request(shortcutPort, {
      path: "/api/ping",
      headers: { Cookie: "nemoclaw_dashboard_token=1" },
    });
    assert.equal(api.statusCode, 200);
    assert.equal(api.body, '{"ok":true}');
  });

  it("derives the Docker gateway from /proc/net/route when no proxy origin override is set", async () => {
    const script = fs.readFileSync(shortcutScript, "utf-8");
    assert.match(script, /def resolve_default_gateway\(/);
    assert.match(script, /\/proc\/net\/route/);
    assert.match(script, /DASHBOARD_PROXY_PORT/);
  });
});