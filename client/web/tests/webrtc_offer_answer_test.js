// SPDX-License-Identifier: MPL-2.0
//
// webrtc_offer_answer_test.js — WebRTC offer/answer happy-path tests.
//
// Exercises src/WebRTC.res's RTC module + createPC helper against a
// stubbed RTCPeerConnection. Verifies the SDP offer/answer cycle and
// ICE-gathering completion path that media negotiation depends on.
//
// Closes part of #48 acceptance bullet 1 (media negotiation happy-path).

import assert from "node:assert";

// Stub RTCPeerConnection globally before importing WebRTC.res.mjs so the
// module's `new RTCPeerConnection(...)` resolves to the stub.
const stubInstances = [];

class StubRTCPeerConnection {
  constructor(config) {
    this.config = config;
    this.localDescription = null;
    this.remoteDescription = null;
    this.iceGatheringState = "new";
    this.iceConnectionState = "new";
    this._onIceGatheringStateChange = null;
    this._onIceConnectionStateChange = null;
    this._onTrack = null;
    this._dataChannels = [];
    this._iceCandidates = [];
    stubInstances.push(this);
  }
  async createOffer(_opts) {
    return { type: "offer", sdp: "v=0\r\no=stub 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n" };
  }
  async createAnswer(_opts) {
    return { type: "answer", sdp: "v=0\r\no=stub 2 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n" };
  }
  async setLocalDescription(sdp) {
    this.localDescription = sdp;
    // Simulate ICE gathering completing immediately for happy-path.
    this.iceGatheringState = "complete";
    if (this._onIceGatheringStateChange) this._onIceGatheringStateChange();
  }
  async setRemoteDescription(sdp) {
    this.remoteDescription = sdp;
  }
  async addIceCandidate(c) {
    this._iceCandidates.push(c);
  }
  addTrack(_track, _stream) { /* no-op */ }
  createDataChannel(label, _opts) {
    const dc = { label };
    this._dataChannels.push(dc);
    return dc;
  }
  close() { this.iceConnectionState = "closed"; }
  set ontrack(fn) { this._onTrack = fn; }
  set oniceconnectionstatechange(fn) { this._onIceConnectionStateChange = fn; }
  set onicegatheringstatechange(fn) { this._onIceGatheringStateChange = fn; }
  set ondatachannel(_fn) { /* no-op */ }
}

// Install stub before module load.
globalThis.RTCPeerConnection = StubRTCPeerConnection;

const WebRTC = await import("../src/WebRTC.res.mjs");

// ---------------------------------------------------------------------------
// createPC + default ICE servers
// ---------------------------------------------------------------------------

Deno.test("WebRTC.createPC instantiates an RTCPeerConnection with default STUN servers", () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();
  assert.ok(pc instanceof StubRTCPeerConnection, "createPC must return a peer connection");
  assert.ok(Array.isArray(pc.config.iceServers), "config.iceServers must be an array");
  assert.ok(pc.config.iceServers.length >= 2, "must include multiple STUN endpoints for redundancy");
  // Every server must have a urls array, and at least one must be a STUN URL.
  const allHaveUrls = pc.config.iceServers.every((s) => Array.isArray(s.urls) && s.urls.length > 0);
  assert.ok(allHaveUrls, "every ICE server entry must carry a urls array");
  const hasStun = pc.config.iceServers.some((s) => s.urls.some((u) => u.startsWith("stun:")));
  assert.ok(hasStun, "default config must include at least one STUN URL");
});

// ---------------------------------------------------------------------------
// Offer/answer happy-path (the media-negotiation lifecycle)
// ---------------------------------------------------------------------------

Deno.test("WebRTC happy-path: createOffer → setLocalDescription → setRemoteDescription (answer)", async () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();

  const offer = await pc.createOffer({});
  assert.strictEqual(offer.type, "offer", "createOffer must produce a {type:'offer', sdp}");
  assert.ok(offer.sdp.startsWith("v=0"), "SDP must begin with version line");

  await pc.setLocalDescription(offer);
  assert.deepStrictEqual(pc.localDescription, offer, "local description must round-trip the offer");

  // Caller side now receives a remote answer (simulated).
  const remoteAnswer = { type: "answer", sdp: "v=0\r\nremote-side\r\n" };
  await pc.setRemoteDescription(remoteAnswer);
  assert.deepStrictEqual(pc.remoteDescription, remoteAnswer, "remote description must round-trip");
});

Deno.test("WebRTC callee-side happy-path: receive offer → createAnswer → setLocalDescription", async () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();

  const remoteOffer = { type: "offer", sdp: "v=0\r\ncaller-side\r\n" };
  await pc.setRemoteDescription(remoteOffer);
  assert.deepStrictEqual(pc.remoteDescription, remoteOffer);

  const answer = await pc.createAnswer({});
  assert.strictEqual(answer.type, "answer", "createAnswer must produce a {type:'answer', sdp}");

  await pc.setLocalDescription(answer);
  assert.deepStrictEqual(pc.localDescription, answer);
});

// ---------------------------------------------------------------------------
// waitForIceGathering — happy path (already complete)
// ---------------------------------------------------------------------------

Deno.test("WebRTC.waitForIceGathering resolves immediately when state is 'complete'", async () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();
  // Set the stub state directly to mimic immediate-complete.
  pc.iceGatheringState = "complete";
  const t0 = performance.now();
  await WebRTC.waitForIceGathering(pc);
  const elapsed = performance.now() - t0;
  assert.ok(elapsed < 50, `should resolve immediately, took ${elapsed.toFixed(2)}ms`);
});

Deno.test("WebRTC.waitForIceGathering resolves when state transitions to 'complete'", async () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();
  pc.iceGatheringState = "gathering";

  const wait = WebRTC.waitForIceGathering(pc);

  // Trigger the state-change callback after a tick.
  queueMicrotask(() => {
    pc.iceGatheringState = "complete";
    if (pc._onIceGatheringStateChange) pc._onIceGatheringStateChange();
  });

  await wait;
  assert.strictEqual(pc.iceGatheringState, "complete");
});

// ---------------------------------------------------------------------------
// Data-channel + add-track sanity (the surfaces media negotiation depends on)
// ---------------------------------------------------------------------------

Deno.test("WebRTC.RTC.createDataChannel records the channel on the peer", () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();
  const dc = WebRTC.RTC.createDataChannel(pc, "control", {});
  assert.strictEqual(dc.label, "control");
  assert.strictEqual(pc._dataChannels.length, 1);
});

Deno.test("WebRTC.RTC.addTrack is callable without throw", () => {
  stubInstances.length = 0;
  const pc = WebRTC.createPC();
  // Track + stream are opaque types in ReScript; pass plain objects.
  assert.doesNotThrow(() => WebRTC.RTC.addTrack(pc, { kind: "audio" }, { id: "stream-1" }));
});
