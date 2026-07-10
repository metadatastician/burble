# Proof Requirements

## Current state
- `src/Burble/ABI/MediaPipeline.idr` — Linear buffer consumption proof (**compiles under Idris2 0.8.0 (DONE)** — the Idris1 `postulate resampleFrame` was replaced by a pure-Idris2 linear-interpolation definition, verified 2026-05-20; see `BURBLE-PROOF-STATUS.md`. Remaining proof-layer hygiene, not a compile blocker: the `just build-proofs` recipe has a path-escaping bug and idris2 is not yet in CI — tracked under epic #53)
- `src/Burble/ABI/WebRTCSignaling.idr` — **JSEP state machine proof (DONE)**
- `src/Burble/ABI/Permissions.idr` — **Role transition and lattice well-foundedness (DONE)**
- `src/Burble/ABI/Avow.idr` — **Attestation chain non-circularity (DONE)**
- `src/Burble/ABI/Vext.idr` — **Hash chain and capability subsumption (DONE)**
- `src/Burble/ABI/Types.idr` — **Core voice/media types and FFT size constraints (DONE)**

## What needs proving (Remaining)
- [x] **Permission model completeness**: Prove `Permissions.idr` capability checks are decidable and that the permission lattice is well-founded. (DONE)
- [x] **Attestation chain integrity**: Prove `Avow.idr` trust assertions form a valid chain (no circular trust). (DONE via rank-based well-foundedness)
- [x] **Extension sandboxing**: Prove `Vext.idr` extensions cannot escape their capability boundary. (DONE via capability subsumption proofs)
- [x] **Zig Bridge Validation**: Fully compile all `.idr` files and verify the logic is mirrored in `ffi/zig/src/abi.zig`. (DONE)

## Recent Progress
- [x] **Audio buffer linearity**: `MediaPipeline.idr` now uses Idris2 linear types to guarantee buffers are exactly consumed.
- [x] **WebRTC session safety**: `WebRTCSignaling.idr` now models the full JSEP lifecycle to prevent invalid state transitions.
- [x] **Attestation Chain Integrity**: `Avow.idr` now includes formal proofs that circular trust is impossible using rank-based well-foundedness.
- [x] **Capability Subsumption**: `Vext.idr` now includes proofs for capability transitivity and extension sandboxing.
- [x] **Full ABI Verification**: `src/ABI.idr` successfully compiles all formal models, serving as the master entry point for the Burble ABI.

## Recommended prover
- **Idris2** — Remains the canonical prover for the Burble ABI.

## Priority
- **HIGH** — The focus is now on **Compilation and Enforcement**. The proofs exist as code; they must now become the binary boundary for the Zig coprocessor.
