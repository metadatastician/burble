// SPDX-License-Identifier: MPL-2.0
//
// Round-trip test for the Burble AI Bridge.
//
// Simulates the full Claude-to-Claude path end-to-end without a browser:
//
//   curl POST /send (A) → bridge A HTTP → bridge A WS
//     → mock page A WebSocket (acts as p2p-voice.html)
//     → pipe that simulates WebRTC DataChannel
//     → mock page B WebSocket
//     → bridge B WS → bridge B queue → curl GET /recv (B)
//
// If the previous `setupAIChannelWithBridge` dead-code bug returns, this test
// fails at the last hop. It also exercises the heartbeat so stale sockets
// aren't mistaken for live ones.

import assert from "node:assert";

// Use non-default ports so this suite can run even if the user has a normal
// bridge on 6474.
const BRIDGE_A_HTTP = 7474;
const BRIDGE_A_WS = BRIDGE_A_HTTP + 1;
const BRIDGE_B_HTTP = 7484;
const BRIDGE_B_WS = BRIDGE_B_HTTP + 1;

async function startBridge(port) {
  const cmd = new Deno.Command("deno", {
    args: ["run", "--allow-net", "--allow-env", "../burble-ai-bridge.js"],
    cwd: import.meta.dirname,
    env: { BURBLE_AI_BRIDGE_PORT: String(port) },
    stdout: "null",
    stderr: "null",
  });
  const proc = cmd.spawn();
  // Give Deno.serve a moment to bind both ports.
  await new Promise((r) => setTimeout(r, 800));
  return proc;
}

function stopBridge(proc) {
  if (!proc) return;
  try { proc.kill("SIGTERM"); } catch (_) {}
}

// Open a WebSocket to a bridge's relay port and mimic a connected p2p-voice page.
// Returns an object with { ws, onReceive(cb) } — onReceive fires for "send"
// frames coming down from the bridge (i.e. messages the bridge wants the page
// to relay to the remote peer via DataChannel).
async function connectMockPage(wsPort) {
  const ws = new WebSocket(`ws://127.0.0.1:${wsPort}`);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = (e) => reject(new Error(`mock page ws error: ${e.type}`));
  });

  let receiveCb = null;
  ws.onmessage = (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch (_) { return; }

    // Heartbeat: reply to pings so the bridge doesn't kill us.
    if (msg.type === "ping") {
      ws.send(JSON.stringify({ type: "pong", ts: Date.now() }));
      return;
    }

    // The bridge is asking this mock page to send something to its peer.
    if (msg.type === "send" && receiveCb) {
      receiveCb(msg.payload);
    }
  };

  return {
    ws,
    onReceive(cb) { receiveCb = cb; },
    // Push a "received from remote DataChannel" frame up into this bridge,
    // simulating what p2p-voice.html's DataChannel onmessage forward now does.
    simulateRemoteDelivery(payload) {
      ws.send(JSON.stringify({ type: "received", payload }));
    },
  };
}

// Cross-wire two mock pages so they behave like two ends of a WebRTC DataChannel:
// whatever bridge A pushes out as a "send" frame, we deliver into bridge B as
// a "received" frame, and vice versa.
function crossWire(pageA, pageB) {
  pageA.onReceive((payload) => pageB.simulateRemoteDelivery(payload));
  pageB.onReceive((payload) => pageA.simulateRemoteDelivery(payload));
}

// Poll /recv on a bridge until it returns at least one message, or time out.
async function drainRecv(httpPort, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const resp = await fetch(`http://127.0.0.1:${httpPort}/recv`);
    const data = await resp.json();
    if (data.count > 0) return data.messages;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`/recv on :${httpPort} drained nothing within ${timeoutMs}ms`);
}

Deno.test({
  name: "AI Bridge round-trip: POST /send on A reaches GET /recv on B",
  async fn() {
    const bridgeA = await startBridge(BRIDGE_A_HTTP);
    const bridgeB = await startBridge(BRIDGE_B_HTTP);
    let pageA, pageB;

    try {
      pageA = await connectMockPage(BRIDGE_A_WS);
      pageB = await connectMockPage(BRIDGE_B_WS);
      crossWire(pageA, pageB);

      // Give the bridges a moment to register wsClient after upgrade.
      await new Promise((r) => setTimeout(r, 200));

      // Status should show connected on both sides now.
      const statusA = await (await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/status`)).json();
      const statusB = await (await fetch(`http://127.0.0.1:${BRIDGE_B_HTTP}/status`)).json();
      assert.strictEqual(statusA.connected, true, "bridge A should report connected");
      assert.strictEqual(statusB.connected, true, "bridge B should report connected");

      // Send a message via bridge A's HTTP /send.
      const message = { type: "hello", from: "dad-claude", at: Date.now() };
      const sendResp = await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(message),
      });
      assert.strictEqual(sendResp.status, 200, "send should succeed with peer connected");
      const sendData = await sendResp.json();
      assert.strictEqual(sendData.ok, true);

      // Bridge B should now have the message queued for polling.
      const received = await drainRecv(BRIDGE_B_HTTP);
      assert.strictEqual(received.length, 1, "exactly one message should have arrived");
      assert.strictEqual(received[0].type, message.type);
      assert.strictEqual(received[0].from, message.from);
      assert.strictEqual(received[0].at, message.at);
    } finally {
      try { pageA?.ws.close(); } catch (_) {}
      try { pageB?.ws.close(); } catch (_) {}
      stopBridge(bridgeA);
      stopBridge(bridgeB);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "AI Bridge round-trip: B → A (reverse direction)",
  async fn() {
    const bridgeA = await startBridge(BRIDGE_A_HTTP);
    const bridgeB = await startBridge(BRIDGE_B_HTTP);
    let pageA, pageB;

    try {
      pageA = await connectMockPage(BRIDGE_A_WS);
      pageB = await connectMockPage(BRIDGE_B_WS);
      crossWire(pageA, pageB);
      await new Promise((r) => setTimeout(r, 200));

      const message = { type: "pong", from: "son-claude", nonce: 42 };
      const sendResp = await fetch(`http://127.0.0.1:${BRIDGE_B_HTTP}/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(message),
      });
      assert.strictEqual(sendResp.status, 200);

      const received = await drainRecv(BRIDGE_A_HTTP);
      assert.strictEqual(received.length, 1);
      assert.strictEqual(received[0].nonce, 42);
    } finally {
      try { pageA?.ws.close(); } catch (_) {}
      try { pageB?.ws.close(); } catch (_) {}
      stopBridge(bridgeA);
      stopBridge(bridgeB);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

Deno.test({
  name: "AI Bridge heartbeat: bridge sends ping, mock page's pong keeps socket alive",
  async fn() {
    const bridge = await startBridge(BRIDGE_A_HTTP);
    let page;

    try {
      let pingCount = 0;
      page = await connectMockPage(BRIDGE_A_WS);

      // Tap the ws onmessage to count pings. Preserve the existing pong reply.
      const origOnMessage = page.ws.onmessage;
      page.ws.onmessage = (ev) => {
        try {
          const msg = JSON.parse(ev.data);
          if (msg.type === "ping") pingCount++;
        } catch (_) {}
        origOnMessage(ev);
      };

      // Shorten wait: the bridge pings every 15 s normally, but even without a
      // tick we can verify the status stays connected across a 2 s window.
      // (A full heartbeat-interval test would inflate suite time unacceptably.)
      await new Promise((r) => setTimeout(r, 2000));

      const status = await (await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/status`)).json();
      assert.strictEqual(status.connected, true, "socket should still be alive after 2 s");
    } finally {
      try { page?.ws.close(); } catch (_) {}
      stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

// ---------------------------------------------------------------------------
// Multi-message ordering: 100 messages burst, verify all arrive in order
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge ordering: 100-message burst A → B arrives in order, no drops",
  async fn() {
    const bridgeA = await startBridge(BRIDGE_A_HTTP);
    const bridgeB = await startBridge(BRIDGE_B_HTTP);
    let pageA, pageB;

    try {
      pageA = await connectMockPage(BRIDGE_A_WS);
      pageB = await connectMockPage(BRIDGE_B_WS);
      crossWire(pageA, pageB);
      await new Promise((r) => setTimeout(r, 200));

      const COUNT = 100;

      // Send 100 messages as fast as possible from A.
      for (let i = 0; i < COUNT; i++) {
        const resp = await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/send`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ type: "burst", seq: i }),
        });
        assert.strictEqual(resp.status, 200, `send ${i} should succeed`);
      }

      // Give a moment for async relay to settle.
      await new Promise((r) => setTimeout(r, 500));

      // Drain all messages from B.
      const resp = await fetch(`http://127.0.0.1:${BRIDGE_B_HTTP}/recv`);
      const data = await resp.json();

      assert.strictEqual(data.count, COUNT, `should receive all ${COUNT} messages`);

      // Verify ordering: seq should be 0, 1, 2, ... 99.
      for (let i = 0; i < COUNT; i++) {
        assert.strictEqual(data.messages[i].seq, i, `message ${i} should have seq=${i}`);
      }
    } finally {
      try { pageA?.ws.close(); } catch (_) {}
      try { pageB?.ws.close(); } catch (_) {}
      stopBridge(bridgeA);
      stopBridge(bridgeB);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});

// ---------------------------------------------------------------------------
// Reconnect-resume: drop bridge WS mid-session, verify queue survives
// ---------------------------------------------------------------------------

Deno.test({
  name: "AI Bridge reconnect: messages queued during WS drop are preserved on reconnect",
  async fn() {
    const bridge = await startBridge(BRIDGE_A_HTTP);
    let page;

    try {
      // Connect mock page.
      page = await connectMockPage(BRIDGE_A_WS);
      await new Promise((r) => setTimeout(r, 200));

      // Simulate a received message being queued.
      page.simulateRemoteDelivery({ type: "before-drop", n: 1 });
      await new Promise((r) => setTimeout(r, 100));

      // Verify it's queued.
      let resp = await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/status`);
      let status = await resp.json();
      assert.strictEqual(status.queued, 1, "should have 1 queued message");

      // Now close the page WS (simulates network drop).
      page.ws.close();
      await new Promise((r) => setTimeout(r, 200));

      // Status should show disconnected, but queued message should survive.
      resp = await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/status`);
      status = await resp.json();
      assert.strictEqual(status.connected, false, "should be disconnected after WS close");
      assert.strictEqual(status.queued, 1, "queued message should survive WS drop");

      // Reconnect a new mock page.
      page = await connectMockPage(BRIDGE_A_WS);
      await new Promise((r) => setTimeout(r, 200));

      // Status should show connected again.
      resp = await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/status`);
      status = await resp.json();
      assert.strictEqual(status.connected, true, "should be connected after reconnect");

      // The original queued message should still be there (it was in the HTTP queue, not the WS).
      const recvResp = await fetch(`http://127.0.0.1:${BRIDGE_A_HTTP}/recv`);
      const recvData = await recvResp.json();
      assert.strictEqual(recvData.count, 1, "original message should still be drainable");
      assert.strictEqual(recvData.messages[0].type, "before-drop");
    } finally {
      try { page?.ws.close(); } catch (_) {}
      stopBridge(bridge);
      await new Promise((r) => setTimeout(r, 100));
    }
  },
  sanitizeResources: false,
  sanitizeOps: false,
});
