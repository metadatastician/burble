// SPDX-License-Identifier: MPL-2.0
//
// End-to-end test for the Burble signaling relay (signaling/relay.js).
//
// The relay is the room-name rendezvous the P2P voice page uses so two peers
// can find each other without copy-pasting codes. This exercises the full
// creator/joiner handshake over HTTP, plus the body-size and room-count caps
// added for hardening. No browser and no WebRTC needed — the relay just moves
// opaque SDP blobs.

import assert from "node:assert";

const PORT = 7601;
const BASE = `http://127.0.0.1:${PORT}`;

async function startRelay(env = {}) {
  const cmd = new Deno.Command("deno", {
    args: ["run", "--allow-net", "--allow-env", "../../../signaling/relay.js"],
    cwd: import.meta.dirname,
    env: { RELAY_PORT: String(PORT), RELAY_HOST: "127.0.0.1", ...env },
    stdout: "null",
    stderr: "null",
  });
  const proc = cmd.spawn();
  await new Promise((r) => setTimeout(r, 800));
  return proc;
}

function stopRelay(proc) {
  if (!proc) return;
  try { proc.kill("SIGTERM"); } catch (_) {}
}

Deno.test({
  name: "relay rendezvous: creator posts offer, joiner fetches it and answers, creator fetches answer",
  async fn() {
    const relay = await startRelay();
    try {
      const room = "dad-and-son";
      const offer = JSON.stringify({ type: "offer", sdp: "v=0 fake-offer" });
      const answer = JSON.stringify({ type: "answer", sdp: "v=0 fake-answer" });

      // Creator posts the offer.
      const put1 = await fetch(`${BASE}/room/${room}/offer`, { method: "PUT", body: offer });
      assert.strictEqual(put1.status, 200);
      assert.strictEqual((await put1.json()).ok, true);

      // Joiner fetches the offer (present, so returns immediately).
      const get1 = await fetch(`${BASE}/room/${room}/offer`);
      assert.strictEqual(get1.status, 200);
      assert.strictEqual(await get1.text(), offer, "joiner gets exactly the offer bytes");

      // Joiner posts the answer.
      const put2 = await fetch(`${BASE}/room/${room}/answer`, { method: "PUT", body: answer });
      assert.strictEqual(put2.status, 200);

      // Creator fetches the answer.
      const get2 = await fetch(`${BASE}/room/${room}/answer`);
      assert.strictEqual(get2.status, 200);
      assert.strictEqual(await get2.text(), answer, "creator gets exactly the answer bytes");
    } finally {
      stopRelay(relay);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "relay hardening: an oversized PUT is rejected with 413",
  async fn() {
    const relay = await startRelay({ RELAY_MAX_BODY: "1024" });
    try {
      const tooBig = "x".repeat(2048);
      const res = await fetch(`${BASE}/room/huge/offer`, { method: "PUT", body: tooBig });
      assert.strictEqual(res.status, 413, "body over the cap is refused");
      await res.body?.cancel();
    } finally {
      stopRelay(relay);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "relay hardening: new rooms are refused once the room ceiling is reached",
  async fn() {
    const relay = await startRelay({ RELAY_MAX_ROOMS: "2" });
    try {
      const a = await fetch(`${BASE}/room/room-a/offer`, { method: "PUT", body: "a" });
      assert.strictEqual(a.status, 200);
      const b = await fetch(`${BASE}/room/room-b/offer`, { method: "PUT", body: "b" });
      assert.strictEqual(b.status, 200);
      // Third distinct room exceeds the ceiling of 2.
      const c = await fetch(`${BASE}/room/room-c/offer`, { method: "PUT", body: "c" });
      assert.strictEqual(c.status, 503, "a new room beyond the ceiling is refused");
      await c.body?.cancel();
      // But updating an existing room (posting its answer) still works.
      const upd = await fetch(`${BASE}/room/room-a/answer`, { method: "PUT", body: "a-ans" });
      assert.strictEqual(upd.status, 200, "existing rooms remain writable at the ceiling");
    } finally {
      stopRelay(relay);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "relay: health endpoint reports ok and room count",
  async fn() {
    const relay = await startRelay();
    try {
      const res = await fetch(`${BASE}/health`);
      assert.strictEqual(res.status, 200);
      const body = await res.json();
      assert.strictEqual(body.ok, true);
      assert.strictEqual(typeof body.rooms, "number");
    } finally {
      stopRelay(relay);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});
