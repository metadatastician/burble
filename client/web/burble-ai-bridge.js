// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Burble AI Bridge — connects Claude Code to the P2P data channel.
//
// Run this in Deno alongside p2p-voice.html to give Claude programmatic
// access to the WebRTC data channel. Exposes a local HTTP API that Claude
// can call via shell commands (curl).
//
// Architecture:
//   Claude Code ←→ HTTP localhost:6474 ←→ this bridge ←→ WebSocket ←→ p2p-voice.html ←→ WebRTC ←→ remote peer
//
// The bridge talks to p2p-voice.html via a tiny WebSocket relay injected
// into the page. Messages flow:
//   curl POST /send → bridge → WS → page → DataChannel → remote page → WS → bridge → curl GET /recv

// Port can be overridden by env var so tests can run two bridges side-by-side.
// Defaults to 6474 (HTTP) + 6475 (WebSocket relay) for normal use.
const PORT = parseInt(Deno.env.get("BURBLE_AI_BRIDGE_PORT") || "6474");
const messageQueue = [];
let wsClient = null;

// SECURITY FIX: Maximum message queue size to prevent unbounded memory growth.
// If a consumer stops polling /recv, the queue would grow indefinitely as
// remote messages arrive. This cap discards the oldest messages when the
// queue exceeds the limit, implementing a ring-buffer-like eviction policy.
// Aligned with proven SafeQueue's bounded capacity principle (drop-oldest).
const MAX_MESSAGE_QUEUE_SIZE = 1000;

// Maximum payload size for /send (64 KiB). Reject oversized messages early
// to prevent memory pressure and WebSocket frame issues.
const MAX_SEND_PAYLOAD_BYTES = 65536;

// JSON response helper.
const jsonResponse = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });

// HTTP server for Claude to interact with
Deno.serve({ port: PORT, hostname: "127.0.0.1" }, async (req) => {
  const url = new URL(req.url);

  // Send a message to the remote peer
  if (req.method === "POST" && url.pathname === "/send") {
    // Validate Content-Type header.
    const ct = req.headers.get("content-type") || "";
    if (!ct.includes("application/json")) {
      return jsonResponse(
        { ok: false, error: "Content-Type must be application/json" },
        415
      );
    }

    // Read body with size limit.
    let rawBody;
    try {
      rawBody = await req.text();
    } catch (e) {
      return jsonResponse({ ok: false, error: "failed to read request body" }, 400);
    }

    if (rawBody.length > MAX_SEND_PAYLOAD_BYTES) {
      return jsonResponse(
        { ok: false, error: `payload too large (max ${MAX_SEND_PAYLOAD_BYTES} bytes)` },
        413
      );
    }

    // Parse JSON with error handling.
    let body;
    try {
      body = JSON.parse(rawBody);
    } catch (e) {
      return jsonResponse({ ok: false, error: "invalid JSON: " + e.message }, 400);
    }

    if (wsClient?.readyState === 1) {
      try {
        wsClient.send(JSON.stringify({ type: "send", payload: body }));
        return jsonResponse({ ok: true });
      } catch (e) {
        console.error("[Burble AI Bridge] WebSocket send error:", e);
        return jsonResponse({ ok: false, error: "send failed: " + e.message }, 502);
      }
    }
    return jsonResponse({ ok: false, error: "not connected" }, 503);
  }

  // Reject non-POST to /send.
  if (url.pathname === "/send" && req.method !== "POST") {
    return jsonResponse({ ok: false, error: "method not allowed, use POST" }, 405);
  }

  // Receive messages from remote peer (poll)
  if (req.method === "GET" && url.pathname === "/recv") {
    const msgs = messageQueue.splice(0);
    return jsonResponse({ messages: msgs, count: msgs.length });
  }

  // Check status
  if (req.method === "GET" && url.pathname === "/status") {
    return jsonResponse({
      connected: wsClient?.readyState === 1,
      queued: messageQueue.length,
      port: PORT,
      maxQueueSize: MAX_MESSAGE_QUEUE_SIZE,
      maxPayloadBytes: MAX_SEND_PAYLOAD_BYTES,
    });
  }

  // Health
  if (url.pathname === "/health") {
    return new Response("ok");
  }

  return new Response("Burble AI Bridge\n\nPOST /send — send JSON to remote peer\nGET /recv — poll received messages\nGET /status — connection status\nGET /health — health check\n", { status: 200 });
});

// Heartbeat parameters. The bridge pings every HEARTBEAT_INTERVAL_MS; if no
// pong arrives within HEARTBEAT_TIMEOUT_MS the socket is considered dead.
// Silent network drops (laptop sleep, wifi switch) otherwise leave wsClient
// stuck at readyState=1 until the next send fails.
const HEARTBEAT_INTERVAL_MS = 15_000;
const HEARTBEAT_TIMEOUT_MS = 5_000;

// WebSocket server for p2p-voice.html to connect to.
Deno.serve({ port: PORT + 1, hostname: "127.0.0.1" }, (req) => {
  if (req.headers.get("upgrade") !== "websocket") {
    return new Response("WebSocket only", { status: 400 });
  }
  const { socket, response } = Deno.upgradeWebSocket(req);

  // Assign wsClient IMMEDIATELY after upgrade rather than inside onopen.
  // Under Deno 2.x upgraded sockets are frequently already in readyState=1
  // by the time we reach this line, meaning the `open` event may not fire
  // and wsClient would otherwise stay null indefinitely.
  wsClient = socket;

  let pongTimer = null;
  let heartbeatTimer = null;

  const stopHeartbeat = () => {
    if (heartbeatTimer !== null) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
    if (pongTimer !== null) { clearTimeout(pongTimer); pongTimer = null; }
  };

  const sendPing = () => {
    if (socket.readyState !== 1) return;
    try {
      socket.send(JSON.stringify({ type: "ping", ts: Date.now() }));
      pongTimer = setTimeout(() => {
        console.warn("[Burble AI Bridge] Pong timeout — closing stale socket");
        try { socket.close(1011, "heartbeat timeout"); } catch (_) {}
      }, HEARTBEAT_TIMEOUT_MS);
    } catch (e) {
      console.warn("[Burble AI Bridge] Ping send failed:", e.message);
    }
  };

  socket.onopen = () => {
    console.log("[Burble AI Bridge] Page connected via WebSocket");
    heartbeatTimer = setInterval(sendPing, HEARTBEAT_INTERVAL_MS);
  };

  socket.onmessage = (ev) => {
    try {
      const msg = JSON.parse(ev.data);
      if (msg.type === "pong") {
        // Heartbeat reply — cancel the timeout.
        if (pongTimer !== null) { clearTimeout(pongTimer); pongTimer = null; }
        return;
      }
      if (msg.type === "received") {
        // Message from remote peer, queue for Claude to poll.
        // SECURITY FIX: Enforce bounded queue size (proven SafeQueue principle).
        // Discard oldest messages when at capacity to prevent memory exhaustion
        // if the consumer stops polling /recv.
        if (messageQueue.length >= MAX_MESSAGE_QUEUE_SIZE) {
          messageQueue.shift();
          console.warn(
            `[Burble AI Bridge] Queue full (${MAX_MESSAGE_QUEUE_SIZE}), discarded oldest message`
          );
        }
        messageQueue.push(msg.payload);
        console.log("[Burble AI Bridge] ← Remote:", JSON.stringify(msg.payload));
      }
    } catch (e) {
      console.error("[Burble AI Bridge] Parse error:", e);
    }
  };

  socket.onclose = () => {
    stopHeartbeat();
    if (wsClient === socket) wsClient = null;
    console.log("[Burble AI Bridge] Page disconnected");
  };

  // Start the heartbeat even if onopen never fires (see comment above).
  heartbeatTimer = setInterval(sendPing, HEARTBEAT_INTERVAL_MS);

  return response;
});

console.log(`[Burble AI Bridge] HTTP API on http://localhost:${PORT}`);
console.log(`[Burble AI Bridge] WebSocket relay on ws://localhost:${PORT + 1}`);
console.log("");
console.log("Claude can now:");
console.log(`  curl -X POST http://localhost:${PORT}/send -d '{"type":"hello","from":"claude"}'`);
console.log(`  curl http://localhost:${PORT}/recv`);
console.log(`  curl http://localhost:${PORT}/status`);
