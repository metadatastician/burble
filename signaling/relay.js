// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Burble Signaling Relay — ephemeral room-name rendezvous.
//
// Holds WebRTC offer/answer for 60 seconds so two peers can find each
// other by room name instead of copy-pasting codes. Zero data stored
// after connection. No accounts, no logs, no tracking.
//
// Deploy: deno run --allow-net signaling/relay.js
// Or:     Cloudflare Workers (see signaling/worker.js)
//
// Protocol:
//   PUT  /room/:name/offer   — creator posts SDP offer (body: JSON)
//   GET  /room/:name/offer   — joiner fetches SDP offer
//   PUT  /room/:name/answer  — joiner posts SDP answer
//   GET  /room/:name/answer  — creator fetches SDP answer
//   GET  /health              — health check

const PORT = parseInt(Deno.env.get("RELAY_PORT") || "6476");
const TTL_MS = 60_000; // Rooms expire after 60 seconds

// CORS origin policy.
// This is a PUBLIC WebRTC signaling relay — browsers from any origin need to
// reach it for the rendezvous handshake. Wildcard "*" is the safe default for
// local development because signaling carries only ephemeral SDP blobs (no
// credentials, no session tokens).
//
// In production, restrict origins by setting ALLOWED_ORIGINS to a
// comma-separated list:
//   ALLOWED_ORIGINS="https://burble.example.com,https://app.example.com"
const ALLOWED_ORIGINS = Deno.env.get("ALLOWED_ORIGINS") || "*";
if (ALLOWED_ORIGINS === "*") {
  console.warn("[Burble Relay] WARNING: CORS allows all origins (ALLOWED_ORIGINS not set). Fine for local dev; set ALLOWED_ORIGINS in production.");
}

const rooms = new Map(); // name -> { offer?, answer?, created }

// Cleanup expired rooms every 30s
setInterval(() => {
  const now = Date.now();
  for (const [name, room] of rooms) {
    if (now - room.created > TTL_MS) rooms.delete(name);
  }
}, 30_000);

Deno.serve({ port: PORT, hostname: "0.0.0.0" }, async (req) => {
  const url = new URL(req.url);
  const origin = req.headers.get("Origin") || "";
  const allowedOrigin = ALLOWED_ORIGINS === "*"
    ? "*"
    : ALLOWED_ORIGINS.split(",").map(o => o.trim()).includes(origin) ? origin : "";
  const cors = {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Content-Type": "application/json",
  };

  if (req.method === "OPTIONS") return new Response(null, { headers: cors });

  // Health
  if (url.pathname === "/health") {
    return new Response(JSON.stringify({ ok: true, rooms: rooms.size }), { headers: cors });
  }

  // Route: /room/:name/(offer|answer)
  const match = url.pathname.match(/^\/room\/([a-zA-Z0-9_-]+)\/(offer|answer)$/);
  if (!match) {
    return new Response(JSON.stringify({ error: "not found", usage: "PUT/GET /room/:name/offer or /room/:name/answer" }), { status: 404, headers: cors });
  }

  const [, name, type] = match;

  // PUT — store offer or answer
  if (req.method === "PUT") {
    const body = await req.text();
    if (!rooms.has(name)) rooms.set(name, { created: Date.now() });
    const room = rooms.get(name);
    room[type] = body;
    console.log(`[Relay] ${type} stored for room "${name}" (${body.length} bytes, expires in 60s)`);
    return new Response(JSON.stringify({ ok: true, room: name, type }), { headers: cors });
  }

  // GET — fetch offer or answer (long-poll: wait up to 30s if not yet available)
  if (req.method === "GET") {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const room = rooms.get(name);
      if (room?.[type]) {
        const data = room[type];
        // Delete answer after fetch (one-shot) — offer stays for retry
        if (type === "answer") delete room.answer;
        return new Response(data, { headers: { ...cors, "Content-Type": "application/json" } });
      }
      await new Promise(r => setTimeout(r, 500));
    }
    return new Response(JSON.stringify({ error: "timeout", message: `No ${type} for room "${name}" within 30s` }), { status: 408, headers: cors });
  }

  return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405, headers: cors });
});

console.log(`[Burble Relay] Signaling server on http://0.0.0.0:${PORT}`);
console.log(`[Burble Relay] Rooms expire after 60 seconds. No data persisted.`);
console.log("");
console.log("Usage:");
console.log(`  Creator:  curl -X PUT http://localhost:${PORT}/room/my-room/offer -d '...'`);
console.log(`  Joiner:   curl http://localhost:${PORT}/room/my-room/offer  (waits up to 30s)`);
