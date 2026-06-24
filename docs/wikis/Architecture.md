<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Architecture

This is the wiki-level signpost. The canonical, deep architecture doc is [`docs/architecture/ARCHITECTURE.adoc`](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/ARCHITECTURE.adoc) — read that for the full picture.

## One-paragraph summary

Burble is a self-hostable voice-first platform with three planes:

1. **Control plane** — Elixir / Phoenix (`server/`). Owns rooms, presence, signaling, auth, persistent state.
2. **Media plane** — Membrane SFU over WebRTC (`server/lib/burble/media/`), with a Zig SIMD NIF for the hot path (`ffi/zig/`).
3. **Discovery plane** — Bolt (UDP 7373 + 9 WoL-poke) for cold "incoming call" notifications, plus the `.well-known/groove` mesh for sibling-service discovery.

The web client (`client/web/`, ReScript → AffineScript migration) joins via signaling and runs entirely in the browser — no native install. A separate **P2P mode** (`p2p-voice.html`) skips the server entirely for two-party calls.

## Topology modes

| Mode | Use case | Server? |
|---|---|---|
| **P2P** | Two-party calls via WebRTC data channel + media channel | No |
| **SFU** | 3+ participants, server forwards (not transcodes) media | Yes |
| **Stage** | Broadcast room (1 speaker, N listeners) — RTSP fanout | Yes |
| **Bridge** | Inbound from Mumble / other voice tools | Yes |

See [TOPOLOGY.md](https://github.com/hyperpolymath/burble/blob/main/TOPOLOGY.md) for the network/process topology overview.

## Supervision tree (control plane)

`Burble.Application.start/2` boots:

- `Burble.Store` (persistent state, VeriSimDB)
- `Phoenix.PubSub` + `Burble.Presence`
- Room registry + dynamic supervisor
- Peer (WebRTC) registry + dynamic supervisor
- Coprocessor registry + dynamic supervisor
- `Burble.Chat.MessageStore` (ephemeral)
- `Burble.Text.NNTPSBackend` (persistent threads)
- `Burble.Media.Engine` (Membrane SFU)
- `Burble.Telemetry`
- `Burble.Security.KeyRotation` (per-room E2EE keys)
- `Burble.Timing.{PTP, ClockCorrelator, Alignment}` (multi-node clock sync)
- `Burble.Groove` + `Groove.HealthMesh` + `Groove.Feedback` (sibling-service discovery)
- `Burble.Transport.RTSP` (broadcast / screen-share)
- `Burble.LLM.Supervisor` (QUIC 8503, TCP-TLS 8085 fallback)
- `Burble.Bolt.Listener` (UDP 7373 — incoming-call signal)
- `BurbleWeb.Endpoint` (HTTP + WebSocket)

Strategy: `:one_for_one`. Children that depend on external resources (`Store`, `Bolt.Listener`, `Transport.RTSP`, `LLM.Supervisor`) degrade gracefully rather than crash boot.

## Coprocessor pipeline (media hot-path)

```
                         per-peer pipeline
    raw RTP            ┌──────────────────────────────┐
   ──────────►         │                              │
                       │  ZigBackend (SIMD NIF)       │
                       │    ↳ VAD, AGC, denoise,      │
                       │      resample, mix           │
                       │                              │
                       │  fallback: SNIFBackend       │
                       │    (WASM, crash-isolated)    │
                       │                              │
                       │  fallback: pure Elixir       │
                       │                              │
                       └──────────────────────────────┘
                                    │
                                    ▼
                              SFU forward
```

ABI proofs in `src/Burble/ABI/` document invariants the NIF must preserve. Type-check level today (per [ADR-0008 Option C](https://github.com/hyperpolymath/burble/blob/main/docs/decisions/0008-formal-proof-enforcement-vs-scope.adoc)); runtime enforcement on roadmap.

## Threat model

See [`docs/architecture/THREAT-MODEL.adoc`](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/THREAT-MODEL.adoc).

Headlines:

- **Trust boundary**: server can see metadata + (if E2EE off) media. With E2EE on, server sees only metadata.
- **NAT traversal**: STUN built-in, TURN via coturn (in `containers/`).
- **Bolt UDP poke**: small, validates source via signature; no amplification surface.
- **Web client**: no native install means no privileged code on user's device.
- **Self-host = no telemetry**: explicit, audited.

## Where to read next

- [Architecture deep dive](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/ARCHITECTURE.adoc)
- [Threat model](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/THREAT-MODEL.adoc)
- [Android client design](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/ANDROID-CLIENT.adoc)
- [ABI / FFI design](https://github.com/hyperpolymath/burble/blob/main/docs/developer/ABI-FFI-README.adoc)
- [ADRs (numbered design decisions)](https://github.com/hyperpolymath/burble/tree/main/docs/decisions)
- [Network topology overview](https://github.com/hyperpolymath/burble/blob/main/TOPOLOGY.md)
