import assert from "node:assert";
import * as Signaling from "../../lib/src/BurbleSignaling.res.mjs";
import { test } from "./runner.js";

test("BurbleSignaling default state", () => {
  const callbacks = {
    onEvent: () => {},
    onJoined: () => {},
    onError: () => {}
  };
  
  const state = Signaling.make("ws://localhost:6473/voice", callbacks);
  assert.ok(state !== null);
  assert.strictEqual(state.connected, false);
  assert.strictEqual(state.serverUrl, "ws://localhost:6473/voice");
});
