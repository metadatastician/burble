// SPDX-License-Identifier: MPL-2.0
// Client-side tests for BurbleSignaling ReScript module.
//
// These tests exercise the compiled JS output from BurbleSignaling.res
// to verify the signaling API contract: state construction, connection
// lifecycle, and event sending.

import assert from "node:assert";
import * as Signaling from "../../lib/src/BurbleSignaling.res.mjs";

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

Deno.test("BurbleSignaling.make creates initial state", () => {
  const callbacks = {
    onEvent: () => {},
    onJoined: () => {},
    onError: () => {},
  };

  const state = Signaling.make("ws://localhost:6473/voice", callbacks);
  assert.ok(state !== null, "make() should return a non-null state");
  assert.strictEqual(state.connected, false, "initial state should be disconnected");
  assert.strictEqual(state.serverUrl, "ws://localhost:6473/voice");
  assert.strictEqual(state.socket, undefined, "socket should be None (undefined)");
  assert.strictEqual(state.channel, undefined, "channel should be None (undefined)");
  assert.strictEqual(state.roomId, undefined, "roomId should be None (undefined)");
});

Deno.test("BurbleSignaling.make preserves callbacks", () => {
  let eventCalled = false;
  const callbacks = {
    onEvent: () => { eventCalled = true; },
    onJoined: () => {},
    onError: () => {},
  };

  const state = Signaling.make("ws://localhost:6473/voice", callbacks);
  assert.ok(state.callbacks !== undefined, "callbacks should be preserved");
  assert.strictEqual(typeof state.callbacks.onEvent, "function");
  assert.strictEqual(typeof state.callbacks.onJoined, "function");
  assert.strictEqual(typeof state.callbacks.onError, "function");
});

Deno.test("BurbleSignaling.make with different URLs", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };

  const state1 = Signaling.make("ws://server1:6473/voice", callbacks);
  const state2 = Signaling.make("ws://server2:6473/voice", callbacks);

  assert.strictEqual(state1.serverUrl, "ws://server1:6473/voice");
  assert.strictEqual(state2.serverUrl, "ws://server2:6473/voice");
  assert.notStrictEqual(state1.serverUrl, state2.serverUrl);
});

// ---------------------------------------------------------------------------
// Disconnect (no-op when not connected)
// ---------------------------------------------------------------------------

Deno.test("BurbleSignaling.disconnect on fresh state does not throw", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);

  // Should not throw even when socket and channel are None.
  assert.doesNotThrow(() => Signaling.disconnect(state));
  assert.strictEqual(state.connected, false);
});

// ---------------------------------------------------------------------------
// Leave room (no-op when not in a room)
// ---------------------------------------------------------------------------

Deno.test("BurbleSignaling.leaveRoom on fresh state does not throw", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);

  assert.doesNotThrow(() => Signaling.leaveRoom(state));
  assert.strictEqual(state.roomId, undefined);
});

// ---------------------------------------------------------------------------
// Send helpers (no-op when channel is None)
// ---------------------------------------------------------------------------

Deno.test("BurbleSignaling.sendVoiceState without connection does not throw", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);

  assert.doesNotThrow(() => Signaling.sendVoiceState(state, "muted"));
});

Deno.test("BurbleSignaling.sendSignal without connection does not throw", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);

  assert.doesNotThrow(() =>
    Signaling.sendSignal(state, "peer_b", "offer", { sdp: "test" })
  );
});

Deno.test("BurbleSignaling.sendText without connection does not throw", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);

  assert.doesNotThrow(() => Signaling.sendText(state, "hello"));
});

Deno.test("BurbleSignaling.sendWhisper without connection does not throw", () => {
  const callbacks = { onEvent: () => {}, onJoined: () => {}, onError: () => {} };
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);

  assert.doesNotThrow(() => Signaling.sendWhisper(state, "target_user"));
});

// ---------------------------------------------------------------------------
// joinRoom without connection triggers onError callback
// ---------------------------------------------------------------------------

Deno.test("BurbleSignaling.joinRoom without connect calls onError", () => {
  let errorMsg = null;
  const callbacks = {
    onEvent: () => {},
    onJoined: () => {},
    onError: (msg) => { errorMsg = msg; },
  };

  const state = Signaling.make("ws://localhost:6473/voice", callbacks);
  Signaling.joinRoom(state, "test-room", "TestUser");

  assert.strictEqual(errorMsg, "Not connected",
    "joinRoom without connect should call onError with 'Not connected'");
});
