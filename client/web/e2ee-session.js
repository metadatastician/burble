// SPDX-License-Identifier: MPL-2.0
//
// e2ee-session.js — the key-exchange driver for one peer in one room.
//
// e2ee.js is the crypto; this is the conversation. It speaks the five channel
// events `RoomChannel` relays (ADR-0016 §4) and ends with either a room key in
// hand or a status that says why not:
//
//   e2ee_register_key   → publish this peer's public key
//   e2ee_key_set        → fetch the room's public keys and epoch
//   e2ee_publish_sealed → hand one peer the room key, sealed to it
//   e2ee_sealed_key     → someone handed us a room key
//   e2ee_status         → epoch, peers, key_custody
//
// The server never sees a room key or a private key; it stores public keys,
// an epoch counter and opaque blobs.
//
// ## Who makes the key
//
// The lowest peer id in the key set, compared as strings. Deterministic, needs
// no election traffic, and every peer computes it the same way from the same
// broadcast. When that peer leaves, the epoch bumps and the new lowest id takes
// over — which is also the failover path, at epoch granularity.
//
// ## What this does not do
//
// It does not touch media. `attach()` pipes the frame layer into a peer
// connection; the browser's Encoded Transform support decides whether that
// works, and if it does not, `attach()` says so instead of pretending.

import * as E2EE from "./e2ee.js";

export const STATUS = Object.freeze({
  IDLE: "idle",
  REGISTERING: "registering",
  AWAITING_KEY: "awaiting-key",
  READY: "ready",
  FAILED: "failed"
});

/** Return the lowest peer id using string sort order, or null for an empty set. */
export function leaderOf(peerIds) {
  const ids = [...peerIds].sort();
  return ids.length === 0 ? null : ids[0];
}

export class E2EESession {
  #roomId;
  #localId;
  #channel;
  #onStatus;
  #epochs;
  #keypair = null;
  #keySet = new Map();
  #cryptors = new Map();
  #status = STATUS.IDLE;
  #lastError = null;
  #sealedSent = new Set();

  // The key this peer minted for the current epoch while it is leader, so a
  // retry distributes the same one rather than starting a second key.
  #leaderKey = null;

  /**
   * Create local key-exchange state; callers must forward channel broadcasts
   * to `onKeySet` and `onSealedKey`. Invalid ids or a missing `push` throw `TypeError`.
   *
   * @param {object} options
   * @param {string} options.roomId
   * @param {string} options.localId      this peer's id, as the server knows it
   * @param {{push: (event: string, payload: object) => Promise<{ok: boolean, data?: object}>}} options.channel
   * @param {(status: string, detail?: object) => void} [options.onStatus]
   */
  constructor({ roomId, localId, channel, onStatus = null }) {
    if (typeof roomId !== "string" || roomId.length === 0) throw new TypeError("roomId is required");
    if (typeof localId !== "string" || localId.length === 0) throw new TypeError("localId is required");
    if (!channel || typeof channel.push !== "function") throw new TypeError("channel.push(event, payload) is required");

    this.#roomId = roomId;
    this.#localId = localId;
    this.#channel = channel;
    this.#onStatus = onStatus;
    this.#epochs = new E2EE.KeyEpoch(roomId);
  }

  get status() {
    return this.#status;
  }

  get epoch() {
    return this.#epochs.epoch;
  }

  get localId() {
    return this.#localId;
  }

  get lastError() {
    return this.#lastError;
  }

  /** True once a room key for the current epoch is held. */
  get hasRoomKey() {
    return this.#epochs.hasRoomKey();
  }

  get keySet() {
    return new Map(this.#keySet);
  }

  get isLeader() {
    return leaderOf(this.#keySet.keys()) === this.#localId;
  }

  #setStatus(status, detail = null) {
    this.#status = status;
    if (status === STATUS.FAILED && detail && detail.error) this.#lastError = detail.error;
    this.#onStatus?.(status, detail);
  }

  async #push(event, payload) {
    const reply = await this.#channel.push(event, payload);
    if (!reply || reply.ok !== true) {
      const reason = reply?.data?.reason ?? "channel-error";
      throw new Error(`${event} refused: ${reason}`);
    }
    return reply.data ?? {};
  }

  /**
   * Join the key exchange: publish a public key, then fetch the room's set.
   *
   * Generates a fresh keypair on each call; epoch broadcasts alone do not
   * regenerate or re-register it. Resolves to the current status and epoch.
   * Crypto and channel errors set FAILED, are retained in `lastError`, and
   * are rethrown.
   */
  async start() {
    this.#setStatus(STATUS.REGISTERING);

    try {
      this.#keypair = await E2EE.generateKeypair();

      const registered = await this.#push("e2ee_register_key", {
        public_key: E2EE.toBase64(this.#keypair.publicKey)
      });

      this.#adoptEpoch(registered.epoch);
      await this.refreshKeySet();

      return { status: this.#status, epoch: this.epoch };
    } catch (error) {
      this.#setStatus(STATUS.FAILED, { error });
      throw error;
    }
  }

  /**
   * Fetch and process the room's public keys after `start()` has begun.
   * Returns the resulting status and epoch; channel and processing errors propagate.
   */
  async refreshKeySet() {
    const data = await this.#push("e2ee_key_set", {});
    return this.onKeySet({ epoch: data.epoch, public_keys: data.public_keys ?? {} });
  }

  /**
   * Handle an `e2ee_key_set` broadcast (or a reply to `e2ee_key_set`).
   *
   * If the epoch moved, every cached key goes: the frame cryptors, the room
   * key, and the record of which peers we already sealed to.
   * The local keypair is retained. Same or older epochs do not rewind the
   * epoch, but their public key set still replaces the cached set.
   * Returns the resulting status and epoch; leader distribution errors propagate.
   */
  async onKeySet({ epoch, public_keys }) {
    const moved = this.#adoptEpoch(epoch);

    this.#keySet = new Map(Object.entries(public_keys ?? {}));

    if (moved) {
      this.#cryptors.clear();
      this.#sealedSent.clear();
    }

    if (this.#keySet.size <= 1) {
      // Alone in the room: nothing to seal to yet, and nothing to decrypt. A
      // solo peer does not need a room key, and generating one would only
      // create state to discard when the second peer arrives.
      this.#setStatus(STATUS.AWAITING_KEY, { epoch: this.epoch, peers: this.#keySet.size });
      return { status: this.#status, epoch: this.epoch };
    }

    if (this.hasRoomKey) {
      this.#setStatus(STATUS.READY, { epoch: this.epoch });
      return { status: this.#status, epoch: this.epoch };
    }

    if (this.isLeader) {
      await this.#distributeRoomKey();
      return { status: this.#status, epoch: this.epoch };
    }

    this.#setStatus(STATUS.AWAITING_KEY, { epoch: this.epoch, leader: leaderOf(this.#keySet.keys()) });
    return { status: this.#status, epoch: this.epoch };
  }

  /**
   * Handle an `e2ee_sealed_key` broadcast.
   *
   * Returns an ignored reason for other recipients, self/missing senders,
   * stale epochs, or unresolved senders/epochs after at most one refresh.
   * Refresh errors are caught. A known sender need not be the leader.
   * Successful opening installs the room key and returns READY and the epoch;
   * decoding or crypto errors return `{error: message}` and set AWAITING_KEY.
   */
  async onSealedKey({ from, to, epoch, blob }, { retried = false } = {}) {
    if (to && to !== this.#localId) return { ignored: "not-for-me" };
    if (!from || from === this.#localId) return { ignored: "from-self" };

    if (epoch > this.epoch) {
      // The leader seals as soon as it sees the new key set, so its blob can
      // arrive here before this peer has processed the broadcast that moved
      // the epoch. Catch up, then retry once. Dropping it would be wrong and
      // silent: nobody would ever resend it.
      if (!retried) {
        try {
          await this.refreshKeySet();
        } catch {
          // fall through to the ignore below
        }
        if (epoch === this.epoch) return this.onSealedKey({ from, to, epoch, blob }, { retried: true });
      }

      return { ignored: "epoch-ahead", epoch };
    }

    if (epoch < this.epoch) {
      // Sealed under an epoch we have already left. Dropping it is correct:
      // the key it protects is no longer current.
      return { ignored: "stale-epoch", epoch };
    }

    let publicKey = this.#keySet.get(from);

    if (!publicKey && !retried) {
      // The blob can arrive before this peer has fetched the key set — a
      // broadcast is delivered to everyone, including whoever just joined and
      // is still mid-registration. Fetch, then look again; do it once, so a
      // genuinely unknown sender cannot drive a loop.
      try {
        await this.refreshKeySet();
      } catch {
        // fall through to the ignore below; the caller sees an ignored blob
        // rather than an exception in a broadcast handler
      }
      publicKey = this.#keySet.get(from);
    }

    if (!publicKey) return { ignored: "unknown-sender", from };

    try {
      const pairwise = await E2EE.pairwiseKey(
        this.#keypair.privateKey,
        E2EE.fromBase64(publicKey),
        this.#roomId,
        epoch,
        this.#localId,
        from
      );

      const groupKey = await E2EE.openGroupKey(
        E2EE.decodeSealed(blob),
        pairwise,
        this.#roomId,
        epoch,
        from,
        this.#localId
      );

      this.#epochs.setRoomKey(groupKey);
      this.#cryptors.clear();
      this.#setStatus(STATUS.READY, { epoch, from });

      return { status: STATUS.READY, epoch };
    } catch (error) {
      // A blob we cannot open is not fatal: the leader may still be mid-epoch.
      this.#setStatus(STATUS.AWAITING_KEY, { epoch, error: error.message });
      return { error: error.message };
    }
  }

  #adoptEpoch(epoch) {
    if (!Number.isInteger(epoch)) return false;
    const moved = this.#epochs.advanceTo(epoch);
    if (moved) this.#cryptors.clear();
    return moved;
  }

  /**
   * Leader only: seal the room key to peers not yet served in this epoch.
   * Retries reuse the same key and skip peers whose publish already succeeded.
   * After all publishes succeed, install the key locally and set READY.
   * Rejects if `start()` has not generated a keypair; crypto and channel errors
   * propagate, retaining the key and completed publishes for a retry.
   */
  async #distributeRoomKey() {
    if (!this.#keypair) throw new Error("start() must run before a key can be distributed");

    const epoch = this.epoch;

    // One room key per epoch, not one per call. `#sealedSent` remembers which
    // peers already have this epoch's key, so a retry after a partial failure
    // (or a second key-set broadcast for a new peer) runs this loop again —
    // and minting a fresh random key here would hand the remaining peers a
    // different group key from the one already distributed, in the same epoch.
    // They would then be unable to read each other.
    if (!this.#leaderKey || this.#leaderKey.epoch !== epoch) {
      this.#leaderKey = { epoch, key: E2EE.randomGroupKey() };
    }

    const groupKey = this.#leaderKey.key;

    for (const [peerId, publicKey] of this.#keySet) {
      if (peerId === this.#localId) continue;
      if (this.#sealedSent.has(peerId)) continue;

      const pairwise = await E2EE.pairwiseKey(
        this.#keypair.privateKey,
        E2EE.fromBase64(publicKey),
        this.#roomId,
        epoch,
        this.#localId,
        peerId
      );

      const sealed = await E2EE.sealGroupKey(
        groupKey,
        pairwise,
        this.#roomId,
        epoch,
        this.#localId,
        peerId
      );

      await this.#push("e2ee_publish_sealed", {
        to: peerId,
        epoch,
        blob: E2EE.encodeSealed(sealed)
      });

      this.#sealedSent.add(peerId);
    }

    this.#epochs.setRoomKey(groupKey);
    this.#cryptors.clear();
    this.#setStatus(STATUS.READY, { epoch, leader: this.#localId });
  }

  /**
   * Return a cached cryptor, or create one using `remoteId` as the sender pin
   * (null for SFU reception). `onError` is used only on creation.
   * Throws if no room key is held; constructor validation errors propagate.
   */
  cryptorFor(remoteId, { onError = null } = {}) {
    if (!this.hasRoomKey) throw new Error("no room key for this epoch yet");

    const cached = this.#cryptors.get(remoteId);
    if (cached) return cached;

    const cryptor = new E2EE.FrameCryptor({
      epochs: this.#epochs,
      roomId: this.#roomId,
      localId: this.#localId,
      remoteId,
      onError
    });

    this.#cryptors.set(remoteId, cryptor);
    return cryptor;
  }

  /**
   * Attach media transforms to this connection.
   *
   * Returns the attachment result. `ok: false` means the media on this
   * connection is NOT end-to-end encrypted and the caller must not describe it
   * as if it were.
   * `role` selects current senders, receivers, or both. Missing room keys,
   * argument validation, and synchronous attachment errors propagate.
   */
  attach(pc, remoteId, { role = "both", onError = null } = {}) {
    const cryptor = this.cryptorFor(remoteId, { onError });
    return E2EE.attachFrameCrypto(pc, { cryptor, role, onError });
  }

  /**
   * Clear local keys and caches and set IDLE; retain the epoch and last error.
   * Call on leave or page hide.
   */
  clear() {
    this.#keypair = null;
    this.#keySet.clear();
    this.#cryptors.clear();
    this.#sealedSent.clear();
    this.#leaderKey = null;
    this.#epochs.clear();
    this.#setStatus(STATUS.IDLE);
  }
}
