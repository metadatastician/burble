<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# Burble Proof Status

**Short version (verified 2026-05-19, Idris2 0.8.0).** 6 of 7 ABI modules compile and type-check: `Types`, `Foreign`, `WebRTCSignaling`, `Permissions`, `Avow`, `Vext`. **`MediaPipeline.idr` does NOT compile** — it uses the Idris1 `postulate` keyword, removed in Idris2 (parse error at the `resampleFrame` declaration). The aggregate `just build-proofs` now works (ipkg `sourcedir` + `IDRIS2_PREFIX` were both broken — fixed) but the build still aborts at `MediaPipeline`. Tracked: see the proofs issue under epic #53. Per ADR-0007 the "formally verified" claim is type-check-level for 6/7 modules, NOT all-six.

## Current ABI proofs (all compile)

| Module | File |
|---|---|
| Types | `src/Burble/ABI/Types.idr` |
| Permissions | `src/Burble/ABI/Permissions.idr` |
| Avow (attestation chain non-circularity) | `src/Burble/ABI/Avow.idr` |
| Vext (hash chain + capability subsumption) | `src/Burble/ABI/Vext.idr` |
| MediaPipeline (linear buffer consumption) | `src/Burble/ABI/MediaPipeline.idr` |
| WebRTCSignaling (JSEP state machine) | `src/Burble/ABI/WebRTCSignaling.idr` |

## Dangerous-pattern debt

- 1 `postulate` in `MediaPipeline.idr` (`resampleFrame` — documented Zig FFI migration target to `burble_resample`)
- 0 `believe_me`, 0 `assert_total`

## Proof gaps (enforcement, not typecheck)

These modules **compile** but their *runtime enforcement* is incomplete — see `STATE.a2ml [blockers-and-issues]`:

- **Avow** — `server/lib/burble/verification/avow.ex` is data-type-only. No dependent-type verification at runtime. Phase 1 replaces with hash-chain audit log + property test.
- **LLM** — no `LLM.idr` proof of frame protocol well-formedness. Phase 2 target.
- **Timing** — no `Timing.idr` proof of best-source monotonicity. Phase 4 target.

## History

The older, longer version of this file described compilation issues (module name mismatches, master ABI module not building). All of those are resolved — `src/ABI.idr` compiles and re-exports the six modules above. The stale doc was collapsed 2026-04-16 as part of Phase 0 scrub-baseline.

## Phase 0 build-proofs status

**Package file:** `src/Burble/ABI/burble-abi.ipkg` (added 2026-05-10)

**Justfile recipe:** `just build-proofs` — runs `idris2 --build burble-abi.ipkg` from `src/Burble/ABI/`

**Module-name collision decision:** `src/interface/abi/Types.idr` also declares `module Burble.ABI.Types`.
This causes an Idris2 package collision if both trees share a `sourcedir`.
Phase 0 resolution: `burble-abi.ipkg` builds only `src/Burble/ABI/` (the canonical tree).
The `src/interface/abi/` tree is marked **deferred to Phase 1 module-path cleanup**.

**Modules compiled by `just build-proofs`:**

| Module | Status |
|---|---|
| `Burble.ABI.Types` | Compiles (imports: `Data.Fin`, `Data.Vect`) |
| `Burble.ABI.Foreign` | Compiles (imports: `Burble.ABI.Types`; live `%foreign` declarations) |
| `Burble.ABI.Avow` | Compiles (imports: `Data.Nat`; non-circularity theorem proven) |
| `Burble.ABI.Permissions` | Compiles (imports: `Data.Nat`; role-hierarchy proofs) |
| `Burble.ABI.Vext` | Compiles (imports: `Data.Nat`, `Data.Vect`; chain monotonicity proofs) |
| `Burble.ABI.MediaPipeline` | Compiles (imports: `Burble.ABI.Types`, `Data.Vect`; 1 postulate — see below) |
| `Burble.ABI.WebRTCSignaling` | Compiles (imports: none extra; JSEP state machine proofs) |

**Postulate debt:**
- `postulate resampleFrame` in `MediaPipeline.idr` — the resampling computation (interpolation/decimation) is performed by the Zig FFI layer. Deferred to Phase 3 when `burble_resample` NIF ships. Postulates compile cleanly; they only affect proof totality.

**Unsafe FFI debt:**
- `prim__registerCallback` in `Burble.ABI.Foreign` is intentionally unexposed. C→Idris callbacks require `believe_me` casts (tracked upstream in idris2#3182). Phase 0 replaces callback usage with `pollEvents` (lock-free ring buffer polling). No `believe_me` or `assert_total` in any module.

**Local smoke-test result (2026-05-19):** idris2 0.8.0 IS installed (`dev/tools/provers/idris2/0.8.0`); the prior "not installed" note was wrong. The recipe and package file were NOT correct: ipkg `sourcedir` resolved modules to a non-existent path and idris2's baked-in prefix pointed at a missing `~/.asdf` path. Both fixed. Verified per-module result above.

## Phase 0 deploy-smoke status (Workstream 0.4)

**Status: UNBLOCKED** — 2026-05-12

Workstream 0.4 (container stack smoke test) was previously blocked because
`podman-compose` is Python (banned by the hyperpolymath language policy) and
no TOML-native alternative existed.

**selur-compose v0.1.0** (Rust, TOML-native) is now functionally complete:

- 216 tests passing across five crates (`schema`, `interp`, `plan`, `driver`, binary)
- `cargo build --workspace` succeeds
- `just up` and `just down` in the burble Justfile are wired to
  `tools/selur-compose/target/release/selur-compose -f containers/compose.toml up -d`
- The binary is built on demand by `just deploy` (or `just build-selur-compose`)

**To run the deploy smoke test:**

```bash
just deploy
# → builds selur-compose (~3 min, one-time)
# → brings up containers/compose.toml stack
# → server: http://localhost:4000, web: http://localhost:8080

just down
# → tears down the stack cleanly
```

**Remaining blocker for full CI validation:** selur-compose v0.1.0 has not yet
been tagged and published to GitHub (pending maintainer tag action). Once
`v0.1.0` is pushed to `github.com/hyperpolymath/selur-compose`, the
`tools/selur-compose/` directory becomes a proper submodule and CI can run
`just deploy` as a smoke step.

See `.machine_readable/integrations/selur-compose.a2ml` for the canonical
integration manifest.
