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
import { test, spawnServer } from "./runner.js";

const HTTP = 7501;
const WS = HTTP + 1;

async function startBridge(port, env = {}) {
  const proc = await spawnServer("../burble-ai-bridge.js", {
    cwd: import.meta.dirname,
    env: { BURBLE_AI_BRIDGE_PORT: String(port), ...env },
  });
  await proc.waitReady(`http://127.0.0.1:${port}/status`);
  return proc;
}

async function stopBridge(proc) {
  // Waits for exit, so the next test can bind the same ports.
  if (proc) await proc.stop();
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
//
// Uses node:net rather than Deno.connect so this runs under Bun, Deno and Node
// alike — it is the one place in the suite that needs a socket below the
// WebSocket API, and a raw TCP write is the same bytes everywhere.
async function rawUpgradeStatus(port, origin) {
  const { connect } = await import("node:net");

  return await new Promise((resolve, reject) => {
    const socket = connect({ host: "127.0.0.1", port });
    let received = "";
    let settled = false;

    const finish = (value) => {
      if (settled) return;
      settled = true;
      try { socket.destroy(); } catch (_) {}
      resolve(value);
    };

    socket.setEncoding("utf8");
    socket.on("error", (err) => (settled ? undefined : (settled = true, reject(err))));
    socket.on("data", (chunk) => {
      received += chunk;
      if (received.includes("\r\n")) {
        const statusLine = received.split("\r\n")[0];
        finish(parseInt(statusLine.split(" ")[1] || "0", 10));
      }
    });

    const req =
      "GET / HTTP/1.1\r\n" +
      `Host: 127.0.0.1:${port}\r\n` +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      "Sec-WebSocket-Version: 13\r\n" +
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
      (origin ? `Origin: ${origin}\r\n` : "") +
      "\r\n";

    socket.write(req);

    // A refused upgrade answers with headers only; do not hang if the server
    // switches protocols instead of replying with a status line.
    setTimeout(() => {
      if (settled) return;
      settled = true;
      try { socket.destroy(); } catch (_) {}
      reject(new Error(`rawUpgradeStatus: no status line from port ${port} within 2000 ms`));
    }, 2000).unref?.();
  });
}

test({
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
      await stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

test({
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
      await stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

test({
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
      await stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

test({
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
      await stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

test({
  name: "bridge security: HTTP API refuses a foreign Origin (CSRF / queue-drain guard)",
  async fn() {
    const bridge = await startBridge(HTTP);
    try {
      // A page the user happened to visit can still ISSUE this request even
      // though it cannot read the response — and GET /recv drains the queue.
      const evil = await fetch(`http://127.0.0.1:${HTTP}/recv`, {
        headers: { Origin: "https://evil.example" },
      });
      assert.strictEqual(evil.status, 403, "foreign Origin is refused on the HTTP API");
      await evil.body?.cancel();

      const local = await fetch(`http://127.0.0.1:${HTTP}/recv`, {
        headers: { Origin: "http://localhost:8080" },
      });
      assert.strictEqual(local.status, 200, "a local page origin is still allowed");
      await local.body?.cancel();

      // No Origin at all (curl, the browser extension, tests) stays allowed.
      const noOrigin = await fetch(`http://127.0.0.1:${HTTP}/status`);
      assert.strictEqual(noOrigin.status, 200, "requests without an Origin are allowed");
      await noOrigin.body?.cancel();

      // /health is deliberately open so liveness probes need no secret — but it
      // is not a hole: it returns a fixed body and touches no queue.
      const health = await fetch(`http://127.0.0.1:${HTTP}/health`);
      assert.strictEqual(health.status, 200);
      await health.body?.cancel();
    } finally {
      await stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});
