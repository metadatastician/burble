// SPDX-License-Identifier: MPL-2.0
// Bun is only the real WebSocket peer/process runner. No bun:ffi is used.
import assert from "node:assert/strict";

const required = name => { assert.ok(process.env[name], `missing ${name}`); return process.env[name]; };
const room = required("VOICE_ROOM");
const socket = new WebSocket(`ws://127.0.0.1:6473/voice/websocket?vsn=2.0.0&token=${encodeURIComponent(required("VOICE_BOB_TOKEN"))}`);
let sequence = 1;
let child;
const payloads = [];
let fail;
const failed = new Promise((_, reject) => { fail = reject; });
const joined = new Promise((resolve, reject) => {
  socket.onopen = () => socket.send(JSON.stringify(["1", "1", `signaling:${room}`, "phx_join", {wire_format: "bebop"}]));
  socket.onerror = () => reject(new Error("WebSocket transport failed"));
  socket.onmessage = event => {
    try {
      const [, ref, topic, type, payload] = JSON.parse(event.data);
      if (type === "phx_reply" && ref === "1") {
        assert.equal(payload.status, "ok"); resolve(); return;
      }
      if (type !== "msg") return;
      assert.equal(topic, `signaling:${room}`);
      assert.equal(payload.from, "alice");
      payloads.push(payload);
      let reply;
      if (payload.type === "sdp:offer") {
        assert.equal(payload.enc, "bebop");
        assert.equal(payload.sdp, undefined);
        // Exact bytes from Burble's own SdpPayload encoder, received on the
        // actual socket, not an internal PubSub/helper invocation.
        assert.equal(payload.sdp_b64, required("VOICE_SDP_B64"));
        reply = {to: "alice", sdp: "v=0\r\ns=answer\r\n", mediaType: "audio"};
      } else {
        assert.equal(payload.type, "ice:candidate");
        assert.equal(payload.candidate.candidate, "candidate:alice");
        reply = {to: "alice", candidate: {candidate: "candidate:bob", sdpMLineIndex: 0, sdpMid: "audio", usernameFragment: "ufrag"}};
      }
      socket.send(JSON.stringify(["1", String(++sequence), topic,
        payload.type === "sdp:offer" ? "sdp:answer" : "ice:candidate", reply]));
    } catch (error) { reject(error); fail(error); }
  };
});
let timer;
try {
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("voice capture timed out")), 25000); });
  await Promise.race([joined, timeout]);
  child = Bun.spawn([required("GOSSAMER_VOICE_DRIVER")], {env: process.env, stdout: "pipe", stderr: "pipe"});
  const result = await Promise.race([Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]), failed, timeout]);
  assert.equal(result[0], 0, result[1] + result[2]);
  assert.equal(payloads.length, 4);
  assert.deepEqual(payloads[0], payloads[2], "SDP payload changed with lease posture");
  assert.deepEqual(payloads[1], payloads[3], "ICE payload changed with lease posture");
  process.stdout.write(result[1]);
  console.log("captured_websocket_payloads=" + JSON.stringify(payloads));
  console.log("PASS real WebSocket Bebop delivery, native reverse decoding, posture-invariant data payloads");
} finally {
  clearTimeout(timer);
  if (child && child.exitCode === null) child.kill();
  socket.close();
}
