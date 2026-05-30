// SPDX-License-Identifier: MPL-2.0
//
// signaling_relay_test.js — Signaling.Relay HTTP API tests.
//
// Exercises the relay-based room-join flow: PUT /room/<id>/offer,
// GET /room/<id>/offer, PUT /room/<id>/answer, GET /room/<id>/answer.
// Uses a stubbed fetch() so the test is hermetic.
//
// Closes part of #48 acceptance bullet 1 (room-join coverage at the
// HTTP-relay layer — the WS-Phoenix join path is the alternate
// transport tested by the existing channel safety contract tests in
// the server suite).

import assert from "node:assert";

// ---------------------------------------------------------------------------
// Fetch stub — records calls + returns canned responses
// ---------------------------------------------------------------------------

const fetchCalls = [];
const fetchResponses = new Map(); // url → response factory

function stubFetch(url, init) {
  fetchCalls.push({ url, init: init ?? {} });
  const factory = fetchResponses.get(url);
  if (factory) return Promise.resolve(factory());
  return Promise.resolve({
    ok: true,
    status: 200,
    json: async () => ({}),
    text: async () => "",
  });
}

globalThis.fetch = stubFetch;

const Signaling = await import("../src/Signaling.res.mjs");

// ---------------------------------------------------------------------------
// PUT offer / answer
// ---------------------------------------------------------------------------

Deno.test("Relay.putOffer issues PUT to /room/<id>/offer with JSON body", () => {
  fetchCalls.length = 0;
  const sdp = { type: "offer", sdp: "v=0\r\nhandshake\r\n" };
  Signaling.Relay.putOffer("https://relay.example.com", "apple-banana-cat", sdp);

  assert.strictEqual(fetchCalls.length, 1, "exactly one fetch call");
  const { url, init } = fetchCalls[0];
  assert.strictEqual(url, "https://relay.example.com/room/apple-banana-cat/offer");
  assert.strictEqual(init.method, "PUT");
  assert.strictEqual(init.body, JSON.stringify(sdp), "body must be SDP serialised to JSON");
});

Deno.test("Relay.putAnswer issues PUT to /room/<id>/answer", () => {
  fetchCalls.length = 0;
  const sdp = { type: "answer", sdp: "v=0\r\nhandshake-reply\r\n" };
  Signaling.Relay.putAnswer("https://relay.example.com", "river-sun-tree", sdp);

  assert.strictEqual(fetchCalls.length, 1);
  const { url, init } = fetchCalls[0];
  assert.strictEqual(url, "https://relay.example.com/room/river-sun-tree/answer");
  assert.strictEqual(init.method, "PUT");
  assert.strictEqual(init.body, JSON.stringify(sdp));
});

// ---------------------------------------------------------------------------
// GET offer / answer
// ---------------------------------------------------------------------------

Deno.test("Relay.getOffer issues GET and parses JSON response", async () => {
  fetchCalls.length = 0;
  const remoteOffer = { type: "offer", sdp: "v=0\r\nremote\r\n" };
  fetchResponses.clear();
  fetchResponses.set("https://relay.example.com/room/cat-dog-elephant/offer", () => ({
    ok: true,
    json: async () => remoteOffer,
  }));

  const result = await Signaling.Relay.getOffer("https://relay.example.com", "cat-dog-elephant");
  assert.deepStrictEqual(result, remoteOffer, "GET must return parsed JSON");

  assert.strictEqual(fetchCalls.length, 1);
  // Default fetch (no init) is GET.
  const init = fetchCalls[0].init;
  assert.ok(init.method === undefined || init.method === "GET", "default method is GET");
});

Deno.test("Relay.getAnswer parses JSON response", async () => {
  fetchCalls.length = 0;
  const remoteAnswer = { type: "answer", sdp: "v=0\r\nremote-reply\r\n" };
  fetchResponses.clear();
  fetchResponses.set("https://relay.example.com/room/yard-zero-book/answer", () => ({
    ok: true,
    json: async () => remoteAnswer,
  }));

  const result = await Signaling.Relay.getAnswer("https://relay.example.com", "yard-zero-book");
  assert.deepStrictEqual(result, remoteAnswer);
});

// ---------------------------------------------------------------------------
// End-to-end room-join sequence (caller perspective)
// ---------------------------------------------------------------------------

Deno.test("Relay e2e: caller PUTs offer, polls answer, gets remote SDP back", async () => {
  fetchCalls.length = 0;
  fetchResponses.clear();

  const callerOffer = { type: "offer", sdp: "v=0\r\ncaller\r\n" };
  const remoteAnswer = { type: "answer", sdp: "v=0\r\ncallee\r\n" };

  fetchResponses.set("https://relay.example.com/room/sun-water-tree/answer", () => ({
    ok: true,
    json: async () => remoteAnswer,
  }));

  // Step 1: caller pushes offer.
  Signaling.Relay.putOffer("https://relay.example.com", "sun-water-tree", callerOffer);

  // Step 2: caller polls for callee's answer.
  const got = await Signaling.Relay.getAnswer("https://relay.example.com", "sun-water-tree");
  assert.deepStrictEqual(got, remoteAnswer, "caller receives the callee's SDP answer");

  assert.strictEqual(fetchCalls.length, 2, "two HTTP calls: PUT offer + GET answer");
  assert.ok(fetchCalls[0].url.endsWith("/offer"));
  assert.ok(fetchCalls[1].url.endsWith("/answer"));
});

Deno.test("Relay e2e: callee GETs offer, PUTs answer", async () => {
  fetchCalls.length = 0;
  fetchResponses.clear();

  const callerOffer = { type: "offer", sdp: "v=0\r\nincoming\r\n" };
  const calleeAnswer = { type: "answer", sdp: "v=0\r\nresponding\r\n" };

  fetchResponses.set("https://relay.example.com/room/apple-banana-cat/offer", () => ({
    ok: true,
    json: async () => callerOffer,
  }));

  // Step 1: callee fetches caller's offer.
  const got = await Signaling.Relay.getOffer("https://relay.example.com", "apple-banana-cat");
  assert.deepStrictEqual(got, callerOffer, "callee receives the caller's SDP offer");

  // Step 2: callee uploads answer.
  Signaling.Relay.putAnswer("https://relay.example.com", "apple-banana-cat", calleeAnswer);

  assert.strictEqual(fetchCalls.length, 2);
  assert.ok(fetchCalls[0].url.endsWith("/offer"));
  assert.ok(fetchCalls[1].url.endsWith("/answer"));
  assert.strictEqual(fetchCalls[1].init.body, JSON.stringify(calleeAnswer));
});
