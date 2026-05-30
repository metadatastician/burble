// SPDX-License-Identifier: MPL-2.0
//
// room_test.js — Room.res utility tests.
//
// Exercises generateRoomName + isValidRoomName from src/Room.res.
// These are pure utility functions; no WebSocket / fetch / browser
// globals required.
//
// Closes part of #48 acceptance bullet 1 (room join coverage at the
// room-name layer — the WS-channel join itself is exercised by
// signaling_relay_test.js).

import assert from "node:assert";
import * as Room from "../src/Room.res.mjs";

// ---------------------------------------------------------------------------
// generateRoomName
// ---------------------------------------------------------------------------

Deno.test("Room.generateRoomName produces three-word hyphenated name", () => {
  const name = Room.generateRoomName();
  assert.match(
    name,
    /^[a-z]+-[a-z]+-[a-z]+$/,
    `generated name '${name}' must be lowercase-word triple separated by hyphens`,
  );
});

Deno.test("Room.generateRoomName is non-empty and bounded", () => {
  for (let i = 0; i < 20; i++) {
    const name = Room.generateRoomName();
    assert.ok(name.length > 0, "name must be non-empty");
    assert.ok(name.length < 80, `name must be reasonably short (got ${name.length})`);
    assert.ok(name.split("-").length === 3, "name must split into exactly 3 parts");
  }
});

Deno.test("Room.generateRoomName produces variety across many calls", () => {
  const seen = new Set();
  for (let i = 0; i < 100; i++) {
    seen.add(Room.generateRoomName());
  }
  // With ~49 unique words × 3 slots, 100 calls should produce well over 50
  // unique names. A floor of 30 is generous slack for the RNG.
  assert.ok(
    seen.size >= 30,
    `expected ≥30 distinct names in 100 calls, got ${seen.size}`,
  );
});

// ---------------------------------------------------------------------------
// isValidRoomName
// ---------------------------------------------------------------------------

Deno.test("Room.isValidRoomName accepts valid 3-word names", () => {
  assert.strictEqual(Room.isValidRoomName("apple-banana-cat"), true);
  assert.strictEqual(Room.isValidRoomName("a-b-c"), true);
  assert.strictEqual(Room.isValidRoomName("water-xylophone-yellow"), true);
});

Deno.test("Room.isValidRoomName rejects wrong shape", () => {
  // Too few parts
  assert.strictEqual(Room.isValidRoomName("apple-banana"), false);
  assert.strictEqual(Room.isValidRoomName("apple"), false);
  // Too many parts
  assert.strictEqual(Room.isValidRoomName("apple-banana-cat-dog"), false);
  // Empty
  assert.strictEqual(Room.isValidRoomName(""), false);
  // Whitespace
  assert.strictEqual(Room.isValidRoomName("apple banana cat"), false);
});

Deno.test("Room.isValidRoomName rejects uppercase / digits / symbols", () => {
  assert.strictEqual(Room.isValidRoomName("Apple-banana-cat"), false);
  assert.strictEqual(Room.isValidRoomName("apple1-banana-cat"), false);
  assert.strictEqual(Room.isValidRoomName("apple_banana_cat"), false);
  assert.strictEqual(Room.isValidRoomName("apple.banana.cat"), false);
});

Deno.test("Room.isValidRoomName accepts what generateRoomName produces", () => {
  for (let i = 0; i < 20; i++) {
    const name = Room.generateRoomName();
    assert.strictEqual(
      Room.isValidRoomName(name),
      true,
      `generated '${name}' should pass validation`,
    );
  }
});
