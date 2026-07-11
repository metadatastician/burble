// SPDX-License-Identifier: MPL-2.0
//
// Security tests for the Burble AI Bridge.
//
// The bridge's WebSocket relay (PORT+1) is the control channel that lets the
// page drive Claude's data channel. Because WebSocket upgrades bypass the
// same-origin policy and CORS, and because the HTTP side had no auth, three
// hardening rules were added and are verified here:
//
//   1. one active WS client per bridge (no silent hijack by a newer socket)
//   2. optional shared-secret auth (BURBLE_AI_BRIDGE_TOKEN) on HTTP + WS
//   3. cross-origin WS upgrades are rejected (drive-by page can't connect)

import assert from "node:assert";

const HTTP = 7501;
const WS = HTTP + 1;

async function startBridge(port, env = {}) {
  const cmd = new Deno.Command("deno", {
    args: ["run", "--allow-net", "--allow-env", "../burble-ai-bridge.js"],
    cwd: import.meta.dirname,
    env: { BURBLE_AI_BRIDGE_PORT: String(port), ...env },
    stdout: "null",
    stderr: "null",
  });
  const proc = cmd.spawn();
  await new Promise((r) => setTimeout(r, 800)); // let both ports bind
  return proc;
}

function stopBridge(proc) {
  if (!proc) return;
  try { proc.kill("SIGTERM"); } catch (_) {}
}

// Try to open a WebSocket; resolve { opened } once we know the outcome.
function tryOpen(url, timeoutMs = 1500) {
  return new Promise((resolve) => {
    let done = false;
    const ws = new WebSocket(url);
    const finish = (opened) => { if (!done) { done = true; resolve({ opened, ws }); } };
    ws.onopen = () => finish(true);
    ws.onerror = () => finish(false);
    ws.onclose = () => finish(false);
    setTimeout(() => finish(false), timeoutMs);
  });
}

// Raw HTTP/1.1 upgrade so we can set an Origin header the WebSocket client
// won't let us set. Returns the numeric status code of the response line.
async function rawUpgradeStatus(port, origin) {
  const conn = await Deno.connect({ hostname: "127.0.0.1", port });
  const req =
    "GET / HTTP/1.1\r\n" +
    `Host: 127.0.0.1:${port}\r\n` +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Version: 13\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
    (origin ? `Origin: ${origin}\r\n` : "") +
    "\r\n";
  await conn.write(new TextEncoder().encode(req));
  const buf = new Uint8Array(1024);
  const n = await conn.read(buf);
  try { conn.close(); } catch (_) {}
  const statusLine = new TextDecoder().decode(buf.subarray(0, n || 0)).split("\r\n")[0];
  return parseInt(statusLine.split(" ")[1] || "0", 10);
}

Deno.test({
  name: "bridge security: a second WS client is refused while one is active (no hijack)",
  async fn() {
    const bridge = await startBridge(HTTP);
    let first;
    try {
      const a = await tryOpen(`ws://127.0.0.1:${WS}`);
      assert.strictEqual(a.opened, true, "first client should connect");
      first = a.ws;
      await new Promise((r) => setTimeout(r, 150)); // let server register wsClient

      const b = await tryOpen(`ws://127.0.0.1:${WS}`);
      assert.strictEqual(b.opened, false, "second client must be refused while the first is live");

      // The bridge should still report the FIRST client as connected.
      const status = await (await fetch(`http://127.0.0.1:${HTTP}/status`)).json();
      assert.strictEqual(status.connected, true, "original client stays connected");
    } finally {
      try { first?.close(); } catch (_) {}
      stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "bridge security: HTTP endpoints require the token when one is set (/health stays open)",
  async fn() {
    const bridge = await startBridge(HTTP, { BURBLE_AI_BRIDGE_TOKEN: "s3cr3t" });
    try {
      const noTok = await fetch(`http://127.0.0.1:${HTTP}/status`);
      await noTok.body?.cancel();
      assert.strictEqual(noTok.status, 401, "/status without token is unauthorized");

      const withTok = await fetch(`http://127.0.0.1:${HTTP}/status?token=s3cr3t`);
      assert.strictEqual(withTok.status, 200, "/status with correct token is allowed");
      await withTok.body?.cancel();

      const withBearer = await fetch(`http://127.0.0.1:${HTTP}/status`, {
        headers: { authorization: "Bearer s3cr3t" },
      });
      assert.strictEqual(withBearer.status, 200, "Bearer header is accepted too");
      await withBearer.body?.cancel();

      const health = await fetch(`http://127.0.0.1:${HTTP}/health`);
      assert.strictEqual(health.status, 200, "/health needs no token");
      await health.body?.cancel();
    } finally {
      stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "bridge security: WS upgrade requires the token when one is set",
  async fn() {
    const bridge = await startBridge(HTTP, { BURBLE_AI_BRIDGE_TOKEN: "s3cr3t" });
    let good;
    try {
      const wrong = await tryOpen(`ws://127.0.0.1:${WS}?token=nope`);
      assert.strictEqual(wrong.opened, false, "WS with wrong token is refused");

      const ok = await tryOpen(`ws://127.0.0.1:${WS}?token=s3cr3t`);
      assert.strictEqual(ok.opened, true, "WS with correct token connects");
      good = ok.ws;
    } finally {
      try { good?.close(); } catch (_) {}
      stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "bridge security: cross-origin WS upgrade is rejected, local origin is allowed",
  async fn() {
    const bridge = await startBridge(HTTP);
    try {
      assert.strictEqual(
        await rawUpgradeStatus(WS, "https://evil.example"),
        403,
        "a visited web page's origin must be rejected",
      );
      assert.strictEqual(
        await rawUpgradeStatus(WS, "http://localhost:8080"),
        101,
        "a localhost page origin is allowed to upgrade",
      );
    } finally {
      stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});
