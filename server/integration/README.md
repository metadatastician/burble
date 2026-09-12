# Native Gossamer–Burble lifecycle and scoped signaling acceptance

This opt-in gate links Gossamer's actual shared library into a small C ABI
driver and runs it against `BurbleWeb.Endpoint` on loopback TCP port 6473.
It refuses to attach to an existing listener and fails if prerequisites are
missing. It is not included silently in the normal offline test suite.

Requirements: Zig 0.15.2, a C compiler, Gossamer's GTK3/WebKitGTK 4.1 development
libraries, Bun (for the WebSocket peer, never FFI), and Burble's Elixir/Erlang dependencies. Use an isolated local test
host. The existing test configuration permits an offline VeriSimDB and starts
the ordinary Burble application; it is not production configuration.

From this server directory:

```bash
GOSSAMER_CHECKOUT=/absolute/path/to/gossamer \
PAIRING_ARTIFACT_DIR=/absolute/path/to/agent-artifacts/pairing \
ZIG=/absolute/path/to/zig-0.15.2 \
bash integration/check_gossamer_pairing.sh
```

The script builds ReleaseSafe, compiles the driver with warnings denied,
prints artifact digests and source baseline revisions, and uses locked Mix
dependency resolution. Local modifications are part of the build; a baseline
revision alone does not identify an uncommitted working tree. Archive reviewed
patches and untracked integration sources before any release.

The lifecycle driver establishes:

- Real hard and soft lease negotiation through the C ABI and HTTP endpoint.
- Successful hard renewal, refused soft renewal, and rejection after expiry
  before the periodic provider sweep runs.
- A forged local handle cannot operate on the live slot. Consumed handles
  cannot be reused, including a child consumed by parent teardown.
- Ordered child-before-parent release and the absence of live provider sessions
  at the end. Provider telemetry independently observes five connects, three
  disconnects, and two expiries, using non-authorizing digests instead of bearers.

The additional scoped voice driver establishes:

- An existing Guardian guest identity connects a finite lease bound to its
  subject, room and target peer. The test establishes room membership separately;
  the adapter does not create users or join rooms.
- Native Gossamer sends full Bebop VoiceSignal offer/ICE frames to Burble's real
  HTTP Endpoint. An authenticated WebSocket peer receives an actual Bebop
  SdpPayload wrapper and ICE payload on `signaling:<room>`.
- That peer replies over the real WebSocket channel. Gossamer receives full
  VoiceSignal answer/ICE frames and validates them with its production decoder.
- The captured SDP/ICE payloads and returned native frames match across hard
  and soft postures. **Control-plane negotiation, tokens, timing, channel refs
  and complete network transcripts are not asserted identical.** SDP/ICE values
  are protocol fixtures, not a negotiated RTCPeerConnection or an audio call.
- Invalid/refresh JWTs, forged local handles, cross-room and truncated native
  frames reject alongside valid controls. The focused adapter suite additionally
  checks forged wire handles, other identities/peers, expired authority, room
  departure, generic-API bypass, queue bounds and delayed room operations.
- A serialized host-loop tick consumes expired soft sessions and renews hard
  sessions beyond three original TTL windows. Credential storage is wiped on
  release. Operations also check expiry if the host stops ticking.

The low-level synchronous adapter still requires a host-loop
`gossamer_groove_voice_tick()` at least twice per shortest TTL. Its session-table
operations are now internally serialized, but exchanges remain blocking with a
five-second bound each; do not put this directly on a UI thread. The separate
window-owned API below supplies its own native worker and needs no caller tick.
Legacy generic sessions still require explicit local cleanup after remote
expiry. Teardown's remote calls are best-effort; the five-second budget is per
exchange, not an entire owned subtree.

## Window-owned GTK host gate

On a local Linux GTK display, run `bash integration/check_gossamer_host.sh` with
the same three required environment variables shown above. It builds and links
the actual Gossamer library, runs the authenticated real-endpoint/WebSocket
fixture with the window driver, and runs two explicitly fault-injected provider
tests. No microphone or camera is requested. Invalid GTK object use is fatal
(`G_DEBUG=fatal-criticals`). This is native host/lifecycle acceptance, not a
launcher call-UI or media acceptance test.

The new `gossamer_window_voice_*` API attaches one worker to a live window. Start,
queue-send, queue-receive, status and stop run on the window's main thread without
network I/O. The worker has four 16-KiB frames per direction, retains no GTK
pointer, renews only its own hard lease, and terminates on expiry/failure or
cancellation. UI queue operations independently enforce a monotonic deadline
minted before connect/renewal I/O; a stalled worker cannot keep expired queued
frames readable. Provider acceptance increments a sent counter; enqueue success is
not delivery. The worker's credential copy is wiped after session creation;
session release and final worker destruction wipe their credential storage.
Window close requests cancellation; cleanup joins the worker before freeing it.
Native window-manager close also records widget destruction to avoid destroying
the same GTK widget twice.

The gate checks hard renewal beyond three original TTL windows, identical
protocol data across hard/soft postures, local soft expiry, explicit/native
close, and zero remaining owned workers/provider sessions. A separate fake
provider withholds its connect response; the test observes the actual request,
keeps GTK timers running, then checks cancellation interrupts the ordinary
five-second I/O wait. Another fake provider fails receive after an accepted
connect: that reports `failed`, never clean `ended`. `ended` means observed local
soft expiry only, not distributed agreement about clean completion.

Limits: the UI-responsiveness measurement starts after WebKit document load;
initial loading on the measured WSL display took about a second with few GTK
timer callbacks. This gate does not qualify cold-start latency. Session
operations currently share one mutex across network I/O, so multi-window
contention/fairness and a process-wide shutdown latency bound are not qualified.
The isolated stalled-socket cancellation bound is not such a bound. There is no
automatic reconnect, no replacement session on the same window, and no real
negotiated SDP, ICE connectivity or RTP audio in these protocol fixtures. Only
the GTK/Linux backend was exercised. A production call UI and working WebRTC
runtime remain separate release gates.

Burble's legacy message/recv and feedback endpoints are not turned into
capability-gated operations by this change. Guest/JWT/Phoenix signaling authority
is distinct from a generic Groove lease, whose connect still declares an empty
`consumes` set. The scoped adapter explicitly requests voice and enforces both
authorities. Do not expose legacy Groove control endpoints to untrusted networks
as a security boundary. The native client is loopback-only; requested but
unimplemented TLS fails closed.

WebSocket clients explicitly opt in with `{"wire_format":"bebop"}` in their
signaling-channel join. Other clients retain JSON-normalized SDP delivery. All
peer PubSub topics are now room-scoped; internal consumers must use
`Burble.GrooveVoice.peer_topic(room, user)` rather than the old user-only topic.

The Gossamer Bebop decoder now runs in this native adapter. The Idris models
remain separate: neither the live test nor a proof package typecheck establishes
proof-to-binary refinement, distributed joint completion or clean-versus-rupture
agreement. Spline's promotion gate stays open.

## Scoped HTTP contract

All routes are beneath `/.well-known/groove/voice/` and require an existing
`Authorization: Bearer <access-or-guest-JWT>` on every operation. Refresh JWTs
are rejected. A lease is not identity and does not grant room membership.

| Operation | Method | Additional input | Success |
| --- | --- | --- | --- |
| `connect` | POST | JSON `room_id`, `peer_id`, `lease:{mode,ttl_ms}` | 200 with private `handle` and exact lease echo |
| `send` | POST | `X-Groove-Handle`, `X-Groove-Peer`, octet-stream VoiceSignal | 204: routed, not a media or delivery acknowledgement |
| `recv` | GET | Same two scope headers | 200 full frame, or 204 empty |
| `heartbeat` | GET | Same two scope headers | 204 hard renewal; soft returns 409 |
| `disconnect` | POST | Same two scope headers | 204 consuming release |

Failures: invalid authentication 401, scope/membership 403, unknown/expired
handle 410, malformed request/frame 400, capacity 503. A timed-out room effect
also returns 410; it cannot execute later. Both room memberships are rechecked
in the room's serialized operation, with an effect deadline shorter than the
caller timeout. That deadline is minted before entering either the provider
or room mailbox; a late provider turn cannot start a fresh timeout window.
JWT expiry is also checked at the routing point. Delayed frames carry an
internal delivery epoch and cannot enter a lease created after their emission.

Only tags 9/10/11 (offer/answer/ICE) are accepted, with exact decode consumption
and re-encoding equality. Frames are at most 16 KiB; JSON connect bodies 8 KiB;
JWTs 4096 bytes; room/peer names 1–128 ASCII alphanumeric/underscore/dot/hyphen
characters. Provider TTL range is 100–3,600,000 ms, native API 1–3600 seconds.
Each lease has at most four pending frames. Overflow drops the new frame and
receive is destructive: this is bounded best-effort signaling, not a durable
acknowledged delivery queue. Generic queue draining cannot access this inbox.

Permissions use the same guest/member templates as RoomChannel, intersected
with explicit resource permissions if supplied. This does not implement new
dynamic room ACLs or a JWT revocation list. The WebSocket bridge requires its
previously verified access/guest authority to remain unexpired; legacy socket
authentication outside this bridge is unchanged.

Compatibility changes: connect now includes canonical `handle` as well as legacy
`session_id`; disconnect accepts either but rejects contradictions. Unknown or
consumed disconnects return 410; invalid leases return 400; bare heartbeat returns
204. Public status map keys are SHA-256 digests; local timing values use a
monotonic clock and are not Unix timestamps. Trusted in-process status still
contains bearer keys. Raw peer manifests are no longer retained in connection
state, and a provider admits at most 1024 concurrent sessions.
