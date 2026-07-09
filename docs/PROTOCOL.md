<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->
<!-- Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Burble Protocol Surface

> Status: **DRAFT** — initial publication, addresses [#106 concern 1].
> Source of truth for the wire surface estate sibling apps (neurophone,
> idaptik, gossamer, etc.) can depend on to use Burble as their
> voice + messaging back-end.

This document is the single discoverable index of Burble's external
protocol surface. Each surface links to its canonical source file in
`server/lib/`. Versioned per `mix.exs` `@version`.

## At-a-glance

Burble exposes three integration surfaces:

| Surface       | Transport        | Purpose                          | Source                                          |
|---------------|------------------|----------------------------------|-------------------------------------------------|
| HTTP REST     | HTTPS / JSON     | Auth, room/server CRUD, control  | `server/lib/burble_web/router.ex`               |
| Realtime      | Phoenix Channels | Signaling, room events, presence | `server/lib/burble_web/channels/`               |
| Wire schemas  | Bebop binary     | Voice signal + room event frames | `server/lib/burble/protocol/`                   |
| Media plane   | WebRTC SRTP      | E2EE audio frames (SFU-blind)    | `server/lib/burble/media/`                      |
| BLE presence  | BLE advertising  | Knock/rendezvous + presence beacon (v1 FROZEN) | `server/lib/burble/presence/ble_spa.ex` |

The SFU **does not decrypt** media: voice frames pass through the media
plane uninterpreted. The Mumble control-plane bridge (experimental) transcodes
at the control plane only.

## HTTP REST (`/api/v1`)

All routes live under `server/lib/burble_web/router.ex`. Three pipelines:

- `:api` — public, rate-limited + input-sanitised (auth, setup,
  diagnostics, instant-connect lookup).
- `:authenticated_api` — Guardian JWT required (rooms, messages,
  moderation, llm, routing).
- `:accepts_json` — unauthenticated, no rate limit (health only).

### Public (rate-limited)

| Method | Path                                  | Purpose                          |
|--------|---------------------------------------|----------------------------------|
| GET    | `/api/v1/health`                      | Health check (unauth, no limit)  |
| POST   | `/api/v1/auth/register`               | Create account                   |
| POST   | `/api/v1/auth/login`                  | Password login                   |
| POST   | `/api/v1/auth/guest`                  | Guest token                      |
| POST   | `/api/v1/auth/magic-link`             | Passwordless magic link          |
| POST   | `/api/v1/auth/refresh`                | Refresh JWT                      |
| POST   | `/api/v1/invites/:token/accept`       | Accept room invite               |
| GET    | `/api/v1/setup/check`                 | Pre-flight checks                |
| POST   | `/api/v1/setup/audio-devices`         | Enumerate devices                |
| POST   | `/api/v1/setup/test-microphone`       | Mic loopback                     |
| POST   | `/api/v1/setup/test-speakers`         | Speaker test                     |
| POST   | `/api/v1/setup/complete`              | Persist setup                    |
| GET    | `/api/v1/diagnostics/self-test`       | Self-test (modes)                |
| GET    | `/api/v1/llm/status`                  | LLM availability                 |
| GET    | `/api/v1/rtsp/status`                 | RTSP gateway status              |
| GET    | `/api/v1/join/:code`                  | Instant-connect lookup           |
| POST   | `/api/v1/join/:code`                  | Instant-connect redeem           |

### Authenticated (Guardian JWT)

| Method | Path                                              | Purpose                |
|--------|---------------------------------------------------|------------------------|
| GET    | `/api/v1/servers`                                 | List servers           |
| POST   | `/api/v1/servers`                                 | Create server          |
| GET    | `/api/v1/servers/:id`                             | Show server            |
| GET    | `/api/v1/servers/:server_id/rooms`                | List rooms             |
| POST   | `/api/v1/servers/:server_id/rooms`                | Create room            |
| GET    | `/api/v1/rooms/:id`                               | Show room              |
| GET    | `/api/v1/rooms/:id/participants`                  | List participants      |
| GET    | `/api/v1/rooms/:id/routing/mode`                  | Get routing mode       |
| POST   | `/api/v1/rooms/:id/routing/groups`                | Create routing group   |
| GET    | `/api/v1/rooms/:id/routing/groups`                | List routing groups    |
| POST   | `/api/v1/rooms/:id/routing/groups/:gid/join`      | Join routing group     |
| GET    | `/api/v1/rooms/:id/messages`                      | List messages          |
| POST   | `/api/v1/rooms/:id/messages`                      | Post message           |
| POST   | `/api/v1/rooms/:id/{kick,mute,move}`              | Moderation             |
| POST   | `/api/v1/servers/:id/ban`                         | Server-level ban       |
| POST   | `/api/v1/llm/query`                               | LLM query              |
| POST   | `/api/v1/llm/stream`                              | LLM stream             |

Authoritative route list lives in `server/lib/burble_web/router.ex`;
this table is a discovery aid — pin against the router when the two
disagree, and file a PR to update this table.

## Realtime — Phoenix Channels

Channels live in `server/lib/burble_web/channels/`. Two primary topics:

- `signaling:<room_id>` — WebRTC offer/answer/ICE relay. Tested in
  `server/test/burble_web/channels/signaling_channel_test.exs`.
- `room:<room_id>` — chat + presence + room events. Tested in
  `server/test/burble_web/channels/room_channel_text_test.exs`.

Frames over the channel transport are encoded as **JSON**. A Bebop binary
encoding (see below) exists as generated, tested codecs but is **not yet
wired into the live channel transport** — it is the planned binary fast
path, not the current one (ADR-0007 honesty note).

## Wire schemas — Bebop

Binary schemas live in `server/lib/burble/protocol/` (generated from
`server/priv/schemas/*.bop` by `mix bebop.generate`):

- `voice_signal.ex` — voice signaling frames (offer/answer/ICE/keepalive).
- `room_event.ex` — room lifecycle events (join/leave/mute/move/kick).

Tests: `server/test/burble/protocol/protocol_test.exs`.
(A duplicate hand-maintained `Burble.Bebop.*` namespace was removed in the
Phase 0 cleanup; the generated `Burble.Protocol.*` namespace is canonical.)

## BLE presence & knock (v1 — FROZEN)

Burble's Bluetooth-LE presence layer (for proximity rendezvous without the
internet, and as a sensor input for estate siblings like neurophone). Three
legacy-advertising frames, one 24-byte Manufacturer Specific Data payload each,
one primitive (HMAC-SHA256): a Single-Packet-Authorisation **knock**, a
connectable **response**, and a rotating contact-resolvable **presence beacon**.

- Authority / decisions: `docs/decisions/0015-ble-presence-wire-format-v1.adoc`
- Pinnable specs: `.machine_readable/descriptiles/ble-spa-knock.a2ml`,
  `.machine_readable/descriptiles/nearby-presence.a2ml`
- Reference impl: `server/lib/burble/presence/ble_spa.ex`
  (Zig verifier: `ffi/zig/src/coprocessor/firewall.zig#ble_spa_verify`;
  Idris types: `src/Burble/ABI/{BleSpa,NearbyPresence}.idr`)
- **Committed test vectors (the freeze):**
  `.machine_readable/test-vectors/ble-spa-v1.json`, recomputed in CI by
  `server/test/burble/presence/ble_spa_vectors_test.exs`. Consumers pin against
  these bytes.

**Freeze covenant:** any change to the on-air bytes requires a superseding ADR,
a **major** bump of `@version` (below), and a `CHANGELOG.md` "Protocol" entry.
The Android emitter, CoC establishment, and key bootstrap are deferred — this
freezes the contract, not the radio.

## Auth model

- **JWT** issued by `Burble.Auth.Guardian` (`server/lib/burble/auth/guardian.ex`).
- **Pipeline** `Burble.Auth.GuardianPipeline` enforces auth on
  `:authenticated_api`.
- **PAKE/SAS tiered auth** per ADR-0003
  (`docs/decisions/0003-pake-sas-tiered-auth.adoc`) for stronger
  bootstrap; magic-link is the friction-light path.

## AI-channel protocol

Distinct, machine-readable surface for LLM-mediated control:
`docs/AI-CHANNEL-PROTOCOL.json`. Reachable via the `/api/v1/llm/*`
routes above.

## groove-protocol discovery

Burble is the estate's canonical voice + messaging service. Sister
apps (neurophone, idaptik, gossamer) discover this surface via
`hyperpolymath/groove-protocol`; the groove-protocol manifest entry
for Burble points back to this document and to `mix.exs` for the
versioned dependency pin.

## Versioning

This document tracks `@version` in `server/mix.exs`. Breaking changes
to any surface above (route removed, schema field repurposed, channel
topic renamed) require a major-version bump and a `CHANGELOG.md`
entry under "Protocol".

## See also

- ADR-0001 — `docs/decisions/0001-adopt-rsr-standard.adoc`
- ADR-0003 — `docs/decisions/0003-pake-sas-tiered-auth.adoc`
- ADR-0007 — `docs/decisions/0007-claims-to-evidence-discipline.adoc`
- Threat model — `docs/architecture/THREAT-MODEL.adoc`
