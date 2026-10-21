// SPDX-License-Identifier: MPL-2.0
//
// e2ee_session_test.js — the key-exchange driver (client/web/e2ee-session.js).
//
// These tests run against a fake `RoomChannel` that implements the same rules
// as `Burble.Media.E2EE`: public keys only, an epoch that bumps when the peer
// set changes, sealed blobs that are dropped on a bump, and no key-returning
// event at all. That makes it possible to test the *conversation* — who makes
// the key, who receives it, what happens when someone joins — without a
// Phoenix server or a browser.
//
// What this cannot prove: that the real channel behaves as modelled here. The
// server half is covered by `room_channel_e2ee_test.exs`; the two meet at the
// five event names, which is the contract both sides are written against.

import assert from "node:assert";

import * as E2EE from "../e2ee.js";
import { E2EESession, STATUS, leaderOf } from "../e2ee-session.js";
import { test } from "./runner.js";

// ---------------------------------------------------------------------------
// A faithful-enough `RoomChannel`
// ---------------------------------------------------------------------------

class FakeRoom {
  constructor() {
    this.epoch = 0;
    this.peers = new Map(); // peerId -> base64 public key
    this.sealed = new Map(); // peerId -> { epoch, blob }
    this.subscribers = new Map(); // peerId -> session
  }

  channelFor(peerId) {
    return { push: (event, payload) => this.#dispatch(peerId, event, payload) };
  }

  subscribe(peerId, session) {
    this.subscribers.set(peerId, session);
  }

  async #dispatch(peerId, event, payload) {
    switch (event) {
      case "e2ee_register_key": {
        const encoded = payload?.public_key;
        if (typeof encoded !== "string") return { ok: false, data: { reason: "invalid_public_key" } };

        const raw = E2EE.fromBase64(encoded);
        if (raw.length !== 32) return { ok: false, data: { reason: "invalid_public_key" } };

        const isNew = !this.peers.has(peerId);
        if (isNew && this.peers.size > 0 && this.sealed.size > 0) {
          // Mirrors `Burble.Media.E2EE.register_peer_key/3`: the epoch moves
          // only once a key has actually been distributed. Bumping on every
          // join would churn epochs through the gap before the first seal.
          this.epoch += 1;
          this.sealed.clear();
        }

        this.peers.set(peerId, encoded);
        // The real broadcast carries the key set, not just counts —
        // `RoomChannel` sends `public_keys: public_key_set(room_id)`.
        await this.#broadcast("e2ee_key_set", {
          epoch: this.epoch,
          peers: this.peers.size,
          public_keys: Object.fromEntries(this.peers)
        });

        return { ok: true, data: { epoch: this.epoch, peers: this.peers.size } };
      }

      case "e2ee_key_set":
        return {
          ok: true,
          data: { epoch: this.epoch, public_keys: Object.fromEntries(this.peers) }
        };

      case "e2ee_publish_sealed": {
        const { to, epoch, blob } = payload ?? {};
        if (typeof to !== "string" || typeof blob !== "string") {
          return { ok: false, data: { reason: "invalid_sealed_blob" } };
        }
        if (epoch !== this.epoch) return { ok: false, data: { reason: "invalid_epoch" } };

        this.sealed.set(to, { epoch, blob });
        await this.#broadcast("e2ee_sealed_key", { from: peerId, to, epoch, blob });

        return { ok: true, data: { epoch } };
      }

      case "e2ee_fetch_sealed": {
        const held = this.sealed.get(peerId);
        return held ? { ok: true, data: held } : { ok: false, data: { reason: "not_found" } };
      }

      case "e2ee_status":
        return {
          ok: true,
          data: { epoch: this.epoch, peers: this.peers.size, key_custody: "peers" }
        };

      default:
        return { ok: false, data: { reason: "unknown_event", event } };
    }
  }

  async #broadcast(event, payload) {
    for (const subscriber of this.subscribers.values()) {
      if (event === "e2ee_key_set") await subscriber.onKeySet(payload);
      if (event === "e2ee_sealed_key") await subscriber.onSealedKey(payload);
    }
  }
}

async function join(room, peerId) {
  const statuses = [];
  const session = new E2EESession({
    roomId: "room-1",
    localId: peerId,
    channel: room.channelFor(peerId),
    onStatus: (status, detail) => statuses.push({ status, detail })
  });

  room.subscribe(peerId, session);
  await session.start();

  return { session, statuses };
}

// ---------------------------------------------------------------------------
// Leadership
// ---------------------------------------------------------------------------

test("leaderOf is the lowest peer id, independent of insertion order", () => {
  assert.strictEqual(leaderOf(["zoe", "alice", "bob"]), "alice");
  assert.strictEqual(leaderOf(["bob", "zoe"]), "bob");
  assert.strictEqual(leaderOf([]), null);
});

// ---------------------------------------------------------------------------
// Two peers
// ---------------------------------------------------------------------------

test("two peers end up with the same room key, made by the leader", async () => {
  const room = new FakeRoom();
  const { session: alice } = await join(room, "alice");
  const { session: bob } = await join(room, "bob");

  assert.strictEqual(alice.status, STATUS.READY);
  assert.strictEqual(bob.status, STATUS.READY);
  assert.strictEqual(alice.hasRoomKey, true);
  assert.strictEqual(bob.hasRoomKey, true);
  assert.strictEqual(alice.isLeader, true);
  assert.strictEqual(bob.isLeader, false);

  // The proof that they agree is that a frame sealed by one opens in the other.
  const plaintext = new Uint8Array([1, 2, 3, 4]);
  const wire = await alice.cryptorFor("bob").seal(plaintext);
  assert.deepStrictEqual(await bob.cryptorFor("alice").open(wire), plaintext);

  // And the reverse direction, which uses a different key.
  const back = await bob.cryptorFor("alice").seal(new Uint8Array([5, 6]));
  assert.deepStrictEqual(await alice.cryptorFor("bob").open(back), new Uint8Array([5, 6]));
});

test("the server only ever holds public values", async () => {
  const room = new FakeRoom();
  await join(room, "alice");
  await join(room, "bob");

  // Every stored public key is 32 bytes, and the sealed blobs are 60 bytes of
  // ciphertext — the fake room has no field that could hold a room key.
  for (const encoded of room.peers.values()) {
    assert.strictEqual(E2EE.fromBase64(encoded).length, 32);
  }
  for (const { blob } of room.sealed.values()) {
    assert.strictEqual(E2EE.decodeSealed(blob).length, 60);
  }
});

test("a solo peer waits rather than inventing a room key", async () => {
  const room = new FakeRoom();
  const { session } = await join(room, "alice");

  assert.strictEqual(session.status, STATUS.AWAITING_KEY);
  assert.strictEqual(session.hasRoomKey, false);
});

// ---------------------------------------------------------------------------
// Membership changes
// ---------------------------------------------------------------------------

test("a third peer bumps the epoch and the leader redistributes", async () => {
  const room = new FakeRoom();
  const { session: alice } = await join(room, "alice");
  const { session: bob } = await join(room, "bob");

  assert.strictEqual(alice.epoch, 0);

  const { session: carol } = await join(room, "carol");

  assert.strictEqual(room.epoch, 1, "the fake server bumps on a new peer");
  assert.strictEqual(alice.epoch, 1);
  assert.strictEqual(bob.epoch, 1);
  assert.strictEqual(carol.epoch, 1);

  // Alice re-seals under the new epoch; everybody ends up ready and agreeing.
  assert.strictEqual(carol.status, STATUS.READY);

  const wire = await carol.cryptorFor("alice").seal(new Uint8Array([9]));
  assert.deepStrictEqual(await alice.cryptorFor("carol").open(wire), new Uint8Array([9]));
});

test("a blob for another peer is ignored, not attempted", async () => {
  const room = new FakeRoom();
  const { session: alice } = await join(room, "alice");
  await join(room, "bob");

  const result = await alice.onSealedKey({
    from: "bob",
    to: "carol",
    epoch: alice.epoch,
    blob: "AAAA"
  });

  assert.deepStrictEqual(result, { ignored: "not-for-me" });
});

test("a blob from a departed epoch is dropped", async () => {
  const room = new FakeRoom();
  const { session: alice } = await join(room, "alice");
  await join(room, "bob");

  const result = await alice.onSealedKey({
    from: "bob",
    to: "alice",
    epoch: alice.epoch - 1,
    blob: E2EE.encodeSealed(new Uint8Array(60))
  });

  assert.deepStrictEqual(result, { ignored: "stale-epoch", epoch: alice.epoch - 1 });
});

// ---------------------------------------------------------------------------
// Failure handling
// ---------------------------------------------------------------------------

test("a refused registration surfaces as a failed session, not a hang", async () => {
  const room = new FakeRoom();
  const channel = {
    push: async (event) =>
      event === "e2ee_register_key"
        ? { ok: false, data: { reason: "invalid_public_key" } }
        : { ok: true, data: {} }
  };

  const session = new E2EESession({ roomId: "room-1", localId: "alice", channel });

  await assert.rejects(session.start(), /e2ee_register_key refused: invalid_public_key/);
  assert.strictEqual(session.status, STATUS.FAILED);
  assert.match(session.lastError.message, /invalid_public_key/);
});

test("cryptorFor refuses to hand out a cryptor before there is a key", async () => {
  const room = new FakeRoom();
  const { session } = await join(room, "alice");

  assert.throws(() => session.cryptorFor("bob"), /no room key/);
});

test("attach reports honestly that encoded transforms are unavailable here", async () => {
  const room = new FakeRoom();
  await join(room, "alice");
  const { session: bob } = await join(room, "bob");

  const fakePc = { getSenders: () => [{}], getReceivers: () => [{}] };
  const result = bob.attach(fakePc, "alice");

  assert.strictEqual(result.ok, false);
  assert.match(result.results[0].reason, /encoded-transform-unavailable/);
});

test("clear drops the room key and every cached cryptor", async () => {
  const room = new FakeRoom();
  const { session: alice } = await join(room, "alice");
  await join(room, "bob");

  assert.strictEqual(alice.hasRoomKey, true);
  alice.cryptorFor("bob");

  alice.clear();

  assert.strictEqual(alice.hasRoomKey, false);
  assert.strictEqual(alice.status, STATUS.IDLE);
  assert.strictEqual(alice.keySet.size, 0);
  assert.throws(() => alice.cryptorFor("bob"), /no room key/);
});
