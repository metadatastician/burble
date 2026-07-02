// SPDX-License-Identifier: MPL-2.0
// Tests for the Burble AI Bridge (burble-ai-bridge.js).
//
// These tests verify the HTTP API contract without requiring a live
// WebSocket connection. They exercise /status, /health, /recv, and
// error handling on /send when no peer is connected.

import assert from "node:assert";

const BASE_URL = "http://127.0.0.1:6474";
let bridgeProcess = null;

// Start the bridge before tests.
async function startBridge() {
  const cmd = new Deno.Command("deno", {
    args: ["run", "--allow-net", "../burble-ai-bridge.js"],
    cwd: import.meta.dirname,
    stdout: "null",
    stderr: "null",
  });
  bridgeProcess = cmd.spawn();
  // Give the server time to start.
  await new Promise((r) => setTimeout(r, 1000));
}

async function stopBridge() {
  if (bridgeProcess) {
    try { bridgeProcess.kill("SIGTERM"); } catch (_) {}
    bridgeProcess = null;
  }
}

// ---------------------------------------------------------------------------
// /health endpoint
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge /health returns ok",
  async fn() {
    await startBridge();
    try {
      const resp = await fetch(`${BASE_URL}/health`);
      assert.strictEqual(resp.status, 200);
      const body = await resp.text();
      assert.strictEqual(body, "ok");
    } finally {
      await stopBridge();
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

// ---------------------------------------------------------------------------
// /status endpoint
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge /status returns JSON with expected fields",
  async fn() {
    await startBridge();
    try {
      const resp = await fetch(`${BASE_URL}/status`);
      assert.strictEqual(resp.status, 200);
      const data = await resp.json();
      assert.strictEqual(data.connected, false, "should not be connected without page");
      assert.strictEqual(data.queued, 0, "queue should be empty initially");
      assert.strictEqual(data.port, 6474);
    } finally {
      await stopBridge();
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

// ---------------------------------------------------------------------------
// /recv endpoint
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge /recv returns empty messages array when no messages",
  async fn() {
    await startBridge();
    try {
      const resp = await fetch(`${BASE_URL}/recv`);
      assert.strictEqual(resp.status, 200);
      const data = await resp.json();
      assert.ok(Array.isArray(data.messages), "messages should be an array");
      assert.strictEqual(data.messages.length, 0, "messages should be empty");
    } finally {
      await stopBridge();
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

// ---------------------------------------------------------------------------
// /send endpoint (no WebSocket peer connected)
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge /send returns 503 when no peer connected",
  async fn() {
    await startBridge();
    try {
      const resp = await fetch(`${BASE_URL}/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ type: "hello", from: "test" }),
      });
      assert.strictEqual(resp.status, 503, "should return 503 when not connected");
      const data = await resp.json();
      assert.strictEqual(data.ok, false);
      assert.strictEqual(data.error, "not connected");
    } finally {
      await stopBridge();
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

// ---------------------------------------------------------------------------
// Unknown route
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge unknown route returns 200 with help text",
  async fn() {
    await startBridge();
    try {
      const resp = await fetch(`${BASE_URL}/unknown`);
      assert.strictEqual(resp.status, 200);
      const body = await resp.text();
      assert.ok(body.includes("Burble AI Bridge"), "should include bridge name in help text");
      assert.ok(body.includes("/send"), "should mention /send endpoint");
      assert.ok(body.includes("/recv"), "should mention /recv endpoint");
    } finally {
      await stopBridge();
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});
