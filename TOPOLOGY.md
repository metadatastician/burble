<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
# TOPOLOGY.md — Burble

## Purpose

Burble is a self-hostable voice communications platform delivering sub-10ms latency WebRTC audio with IEEE 1588 PTP precision timing. It targets privacy-conscious teams and individuals who need Mumble-quality audio with browser-based joining and zero-friction setup. The platform is built on an Elixir/Phoenix control plane with Zig SIMD NIFs for the media hot-path, E2EE optional, no telemetry.

## Module Map

```
burble/
├── server/                        # Elixir/Phoenix control plane
│   └── lib/
│       ├── burble/
│       │   ├── application.ex     # OTP application entry
│       │   ├── rooms/             # Room lifecycle (room.ex, room_manager.ex, participant.ex, instant_connect.ex)
│       │   ├── media/             # Media engine (engine.ex, peer.ex, e2ee.ex, pipewire.ex, lmdb_playout.ex)
│       │   ├── transport/         # Transport layer (multipath.ex, quic.ex, rtsp.ex)
│       │   ├── auth/              # Authentication and sessions
│       │   ├── permissions/       # Room and user permissions
│       │   ├── groove/            # Groove IPC protocol integration
│       │   ├── network/           # Network topology and routing
│       │   ├── timing/            # IEEE 1588 PTP precision timing (framework complete; HW NIF pending Phase 4)
│       │   ├── coprocessor/       # Backend dispatch (smart/zig/elixir) + pipeline
│       │   ├── store/             # Persistent state (store.ex)
│       │   ├── topology/          # Room topology management
│       │   ├── security/          # Security hardening (SDP / SPA)
│       │   ├── moderation/        # Content moderation
│       │   ├── bebop/             # Bebop binary serialization
│       │   ├── llm/               # LLM integration (STUB — Phase 2: provider + circuit breaker)
│       │   ├── verification/      # Avow + Vext attestation (Avow = stub; Vext = real)
│       │   └── bridges/           # External bridge adapters (Mumble, IDApTIK, PanLL)
│       └── burble_web/
│           ├── router.ex          # Phoenix router
│           ├── channels/          # WebSocket channels (RoomChannel + UserSocket)
│           ├── controllers/       # HTTP controllers (api/* — Phoenix REST, not zig)
│           └── plugs/             # Request plugs
├── signaling/                     # WebRTC signaling relay
│   ├── relay.js                   # Sole relay — Deno, ephemeral SDP, 60s TTL
│   └── worker.js                  # Cloudflare Worker wrapper
├── src/                           # Idris2 ABI definitions + proofs
│   ├── ABI.idr                    # Top-level ABI (re-exports)
│   └── Burble/ABI/                # Types, Permissions, Avow, Vext, MediaPipeline, WebRTCSignaling, Foreign
├── ffi/zig/                       # SOLE Zig FFI — SIMD audio/DSP/neural/compression NIFs
│   └── src/coprocessor/           # audio.zig, dsp.zig, neural.zig, compression.zig, firewall.zig, nif.zig
├── client/
│   ├── web/                       # Browser client — ReScript (migrating to AffineScript, Phase 3/5)
│   └── lib/                       # Embeddable SDK (BurbleClient, BurbleVoice, BurbleSpatial, BurbleSignaling)
├── admin/                         # Admin dashboard (ReScript — migrates in Phase 5; needs un-vendored Gossamer runtime)
├── verification/                  # Pointer README only — real artifacts: src/Burble/ABI, server/test, ffi/zig/test
├── containers/                    # Containerfile + compose.toml (Chainguard base)
└── .machine_readable/             # contractiles (MUST/TRUST/INTENT/ADJUST) + 6a2/*.a2ml
```

### Removed 2026-04-16 (Phase 0)

- `api/v/` — zig REST client (banned; Zig FFI at `ffi/zig/` replaces it)
- `api/zig/` — broken merge-conflicted half-migration duplicate of `ffi/zig/`
- `signaling/Relay.res` — ReScript duplicate of the authoritative `relay.js`
- `alloyiser.toml` — orphaned Alloy spec pointing at deleted zig source

### Removed 2026-07-02 (Phase 0 completion — dispositions + kill list, ADR-0009)

Never-started server subsystems (no supervision-tree entry, unreachable):

- `server/lib/burble/transport/multipath.ex` — multipath UDP manager
- `server/lib/burble/transport/quic.ex` — QUIC/WebTransport placeholder
- `server/lib/burble/cluster/distributed.ex` — multi-region scaffold
- `server/lib/burble/bridges/{sip,discord,matrix}.ex` — unproven bridges
  (Mumble kept, quarantined at `server/lib/burble/experimental/`)
- `server/lib/burble/bebop/` — hand-maintained duplicate of the generated
  `Burble.Protocol.*` Bebop codecs

Repo-wide decorative/drifted artifacts:

- `generated/wokelangiser/` — 7MB compliance scan of *other* repos
- `generated/tlaiser/` — TLA+ that could not model-check
- `verification/*/` scaffolding — empty; replaced by a pointer README
- `docs/theory/`, `docs/whitepapers/` — one-line stubs, no content
- `src/interface/abi/` — duplicate Idris ABI tree (module collision)
- `client/desktop/` — Ephapax skeleton; compiler not vendored
- `container/` — uninitialized `{{PLACEHOLDER}}` template tree
  (`containers/` is canonical)

## Data Flow

```
[Browser/Client]
      │  WebRTC + WebSocket
      ▼
[signaling/relay.js] ──► [burble_web/channels/] ──► [rooms/room_manager.ex]
                                                              │
                    ┌─────────────────────────────────────────┘
                    │
                    ▼
          [media/engine.ex] ──► [ffi/zig SIMD NIFs] ──► [transport/multipath.ex]
                    │                                           │
                    ▼                                           ▼
          [media/lmdb_playout.ex]                   [transport/quic.ex]
          (LMDB ring buffer)                         (QUIC + RTSP egress)
                    │
                    ▼
          [timing/] (IEEE 1588 PTP)
                    │
                    ▼
          [store/store.ex] ──► [VeriSimDB coprocessor]
```
