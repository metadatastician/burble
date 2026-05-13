# Burble Full Implementation — Scoping

**Date:** 2026-05-07
**Purpose:** scope a "full implementation" effort against current code, separate aspirational claims from real ones, and produce a phased plan.

---

## 1. Executive Summary

Burble is meaningfully further along than a typical "aspirational README" project, but the STATE.a2ml self-report of 97% completion is not credible against the code. The accurate figure is closer to **65–75%**, depending on what you count. The core voice SFU, OTP supervision tree, Zig SIMD coprocessor (compression, audio, DSP), Mumble bridge, Bolt protocol, LLM service, and P2P AI channel are all genuinely present and tested. What is missing or significantly incomplete: real Opus transcoding in all server-side paths (currently stubbed with `{:error, :not_implemented}`), the four topology modes exist as configuration flags but the oligarchic and distributed modes lack the federation runtime that would make them meaningfully distinct, the AffineScript client compiles syntactically but has no verified runtime compilation or integration test coverage, the Idris2 proofs compile but contain a `postulate` that defers the most critical resampling operation to Zig code that has no proof coverage, and the supply-chain story (cerro-torre signing, svalinn gateway, vordr monitoring) is fully vapor within the Burble tree — those tools are referenced but not present or installed.

Recommendation: target definition **(A) Code-complete** as the near-term goal and treat (B) Spec-complete as a 6–12 month follow-on requiring hardware procurement. Definition (C) Production-ready is blocked on tools that do not yet exist in buildable form. A realistic code-complete effort is four phases over approximately 8–10 weeks of focused engineering.

---

## 2. Current Implementation Map

| Subsystem | Status | Key File References | Effort to Code-Complete |
|---|---|---|---|
| WebRTC SFU (ExWebRTC, per-peer PCs) | ✅ | `server/lib/burble/media/peer.ex`, `engine.ex` | S — already solid, minor hardening |
| OTP supervision tree | ✅ | `server/lib/burble/application.ex` | S — present, well-structured |
| Zig SIMD coprocessor (LZ4, echo cancel, FFT, DSP) | ✅ | `ffi/zig/src/coprocessor/compression.zig`, `audio.zig`, `dsp.zig`, `neural.zig` | S — functional, benchmarks runnable |
| Elixir NIF bridge | ✅ | `server/lib/burble/coprocessor/zig_backend.ex` | S |
| Mumble bridge | ✅ | `server/lib/burble/bridges/mumble.ex` | M — untested against a real Murmur; no CI integration test |
| SIP bridge | 🟡 | `server/lib/burble/bridges/sip.ex` (1,400+ lines) | M — `opus_to_pcm_stub` at line 1397 returns silence; DNS SRV at line 1306 returns `:not_implemented` |
| Discord bridge | 🟡 | `server/lib/burble/bridges/discord.ex` | M — xsalsa20_poly1305 uses stub path when `:crypto` doesn't provide it |
| Matrix bridge | 🟡 | `server/lib/burble/bridges/matrix.ex` | M — file present, structure complete, untested against any homeserver |
| PTP timing (software stack) | ✅ | `server/lib/burble/timing/ptp.ex` (594 lines), `ffi/zig/src/coprocessor/ptp.zig` | S — Zig NIF reads `/dev/ptp0`, Elixir fallback hierarchy working |
| PTP hardware clock NIF wiring | 🟡 | `ffi/zig/src/coprocessor/ptp.zig` | M — NIF exists, but real hardware validation deferred to Phase 4 per STATE.a2ml |
| Topology mode: Monarchic | ✅ | `server/lib/burble/topology.ex` | S — default path, solid |
| Topology mode: Oligarchic | 🟡 | `server/lib/burble/cluster/distributed.ex`, `topology.ex` | L — cluster membership GenServer present; VeriSimDB federation, distributed Erlang cookie setup, and room handoff logic are not implemented |
| Topology mode: Distributed (federated) | 🟡 | `server/lib/burble/topology/transition.ex` | L — `fork_vext_chain` returns `{:ok, :stub}` at line 64; cross-server Avow verification not wired |
| Topology mode: Serverless (P2P) | ✅ | `client/web/p2p-voice.html`, `burble-ai-bridge.js` | S — working end-to-end for the P2P use case |
| Avow consent attestation | 🟡 | `server/lib/burble/verification/avow.ex` | M — hash-chain data structure present and tested; no dependent-type enforcement at runtime |
| Vext integrity chains | ✅ | `server/lib/burble/verification/vext.ex` | S — hash-chain linkage wired, tested |
| Idris2 ABI proofs | 🟡 | `src/Burble/ABI/MediaPipeline.idr` line 65, `src/interface/abi/Foreign.idr` line 232 | M — proofs compile, but `resampleFrame` is a `postulate` and `prim__registerCallback` is marked unsafe/deferred per idris2#3182 |
| AffineScript client (35 .affine files) | 🟡 | `client/web/src/`, `client/lib/src/` | L — syntactically ported from ReScript; no evidence of compilation against the `tools/affinescript` compiler submodule being verified in CI |
| Burble Bolt | ✅ | `server/lib/burble/bolt/packet.ex`, `listener.ex`, `naptr.ex`, `server_lib/burble_web/channels/bolt_channel.ex` | S — fully implemented |
| VeriSimDB integration | 🟡 | `server/lib/burble/store.ex`, `tools/nextgen-databases/` (submodule) | M — submodule present and substantial (Rust core, Elixir orchestration); Burble's `Burble.Store` references it but actual HTTP client wiring needs audit |
| LMDB playout buffer | 🟡 | `server/lib/burble/media/lmdb_playout.ex` | M — ETS fallback present; LMDB NIF dependency path needs verification |
| Voice mask (MASK subsystem) | ✅ | `server/lib/burble/coprocessor/voice_mask.ex` | S — implemented in pure Elixir DSP via FFT/IFFT; CPU-expensive but functional |
| LLM service (AnthropicProvider) | ✅ | `server/lib/burble/llm/anthropic_provider.ex`, `circuit_breaker.ex` | S — fully wired per STATE.a2ml |
| P2P AI bridge | ✅ | `client/web/burble-ai-bridge.js` | S — fixed 2026-04-16, tested |
| OTP circuit breakers | ✅ | `server/lib/burble/circuit_breaker.ex` | S |
| Automated VeriSimDB backups | ✅ | `server/lib/burble/store/backup_scheduler.ex` | S |
| Elixir test suite | 🟡 | `server/test/` (60+ test files) | M — broad coverage claimed; bridges (Discord, Matrix, SIP) have minimal integration tests |
| Zig FFI tests | ✅ | `ffi/zig/` (`zig build test`) | S |
| Idris2 proof compilation | 🟡 | `src/Burble/ABI/` | M — `just build-proofs` target listed in MUST.contractile but no Justfile recipe found |
| CI / GitHub Actions | 🟡 | `.github/workflows/elixir-ci.yml` | M — workflow created 2026-04-21; first green run not confirmed per CRG-C note |
| Supply chain (.ctp bundles, svalinn, vordr) | 🔴 | `containers/compose.toml` (commented-out svalinn block), `container/vordr.toml` | XL — tools are vapor within Burble; svalinn/cerro-torre/vordr must be built first |
| Accessibility scaffolding | 🟡 | `server/lib/burble/accessibility/screen_reader.ex`, `keyboard.ex` | L — server-side scaffolding present; full WCAG AA on the client is unstarted |
| Embeddable client library | 🟡 | `client/lib/src/BurbleClient.affine`, `IDApTIKVoice.affine`, `PanLLVoice.affine` | M — AffineScript files ported; no compilation verification or API documentation |
| QUIC transport | 🟡 | `server/lib/burble/transport/quic.ex` | M — GenServer structure complete; `quicer` dependency compilation requires system prerequisites (msquic build guards in Justfile) |

---

## 3. README Claim Audit

| Claim | File Evidence | Verdict | Effort to Make Fully Real |
|---|---|---|---|
| 26,350× LZ4 speedup | `ffi/zig/src/coprocessor/compression.zig` — custom LZ4 implementation present; `server/lib/mix/tasks/bench_coprocessor.ex` — benchmark runnable | **Partially-real** — the Zig code implements a real LZ4 block compressor, not a wrapper around liblz4. The benchmark is claimed runnable but not CI-verified. The ratio requires measurement on the claimed hardware to confirm it wasn't a cherry-picked input | S — run benchmark in CI against a fixed frame size, publish actual numbers |
| Sub-microsecond PTP (<1µs) | `server/lib/burble/timing/ptp.ex`, `ffi/zig/src/coprocessor/ptp.zig` — hardware ioctl present | **Conditionally-real** — the code correctly falls back through the clock hierarchy and EXPLAINME.adoc honestly states "sub-microsecond requires a NIC with PTP hardware clock." The claim is true only with specific hardware. The Zig NIF exists but is described in STATE.a2ml as "hardware validation pending I210 arrival" | M — hardware procurement + measurement; then the claim becomes accurate |
| Four topology modes | `server/lib/burble/topology.ex` (capability flags), `topology/transition.ex` (stub fork) | **Partially-real** — the topology enum and capability query are real. Monarchic and Serverless work end-to-end. Oligarchic (VeriSimDB federation, distributed Erlang clustering) and Distributed (cross-server Avow, Vext chain forking) are implemented as configuration flags without the supporting federation runtime | L — implement actual VeriSimDB federation handoff and cross-server room routing |
| Mumble/Murmur bridge | `server/lib/burble/bridges/mumble.ex` — substantive implementation; EXPLAINME.adoc honest about ACL gaps | **Real** — code present, documented caveats are honest (no full ACL mirroring). Not CI-tested against a real Murmur instance | M — add CI test with embedded Murmur; verify positional audio axis remapping |
| SIP bridge | `server/lib/burble/bridges/sip.ex` (1,400+ lines) — `opus_to_pcm_stub` at line 1397, DNS SRV `:not_implemented` at line 1306 | **Partially-real** — SIP call flows and DTMF are wired; transcoding is silenced (returns 160 zeroed samples, not decoded audio); DNS SRV lookup is explicitly not implemented | L — wire real Opus decode via libopus NIF or existing Zig path |
| Erlang/OTP fault isolation | `server/lib/burble/application.ex`, `media/peer.ex` — DynamicSupervisor per-room structure present | **Real** — this is genuine OTP, not marketing | S |
| Embeddable client library | `client/lib/src/BurbleClient.affine`, `IDApTIKVoice.affine` | **Partially-real** — files ported to AffineScript; no verified build output or published package | M |
| Idris2 ABI proofs | `src/Burble/ABI/MediaPipeline.idr` line 65 (`postulate resampleFrame`) | **Partially-real** — proofs exist and are structurally sound; `resampleFrame` is a postulate (justified but unproven); `prim__registerCallback` safety deferred (`Foreign.idr:232`); no `just build-proofs` recipe in Justfile | M — write the Justfile target, resolve the postulate or document it as accepted axiom |
| AffineScript migration complete | `client/web/src/*.affine` (28 files), `tools/affinescript` submodule | **Aspirational** — files syntactically ported; STATE.a2ml says "runtime AffineScript compilation verification" is a remaining blocker; AffineScript is described in the broader ecosystem as an in-development language. No CI step compiles the `.affine` files | L — verify affinec compiler produces valid JS output for each file |
| Burble Bolt | `server/lib/burble/bolt/packet.ex`, `listener.ex`, `naptr.ex`, `bolt_channel.ex` | **Real** — complete implementation with WoL-compatible wire format, DNS NAPTR/SRV, browser channel | S |
| One-command container deploy | `containers/compose.toml` — four services (server, web, verisimdb, coturn) | **Conditionally-real** — compose file is well-formed; VeriSimDB builds from the submodule; the svalinn policy block is commented out ("when Stapeln stack is ready"). Coturn image pulls from `coturn/coturn:latest` (not Chainguard-pinned) | M — pin coturn image, verify compose stack actually starts cleanly |
| VeriSimDB provenance/temporal | `tools/nextgen-databases/verisimdb/` — substantial Rust implementation | **Real** — VeriSimDB is a real, substantially implemented database with Rust core, Elixir orchestration, and 8 modality stores | S — for Burble's use; VeriSimDB itself is a separate project scope |

---

## 4. Definition Recommendation

Target definition **(A) Code-complete**.

(B) adds the hardware constraint — the I210 NIC for PTP sub-microsecond measurement is not a software problem, it is a procurement and lab-setup problem. It also requires standing up real Mumble/SIP servers in CI. These are tractable but outside the software effort proper.

(C) is currently blocked on tools that do not exist in the Burble working tree. The cerro-torre `.ctp` signing tool, svalinn gateway, and vordr runtime monitor are referenced in compose files and the Trustfile, but none are installed or invocable within Burble. The MUST.contractile note that "svalinn edge gateway, vordr runtime monitoring" is required for production is honest, but those tools are themselves under development. Targeting (C) means waiting on tooling that is outside this project's control.

Code-complete (A) means: every stub returns real output, every topology mode executes an end-to-end scenario, the AffineScript client compiles, the Idris2 proofs build via a named Justfile target, the SIP bridge transcodes real audio (not silence), and CI is green. This is achievable in software alone and would leave the project in a state where (B) is a measurement exercise and (C) is a tooling integration exercise.

---

## 5. Phase Plan

**Phase 0 — CI and Build Integrity** (1 week)
- Deliverable: CI passes on every PR. `just test` passes locally without manual prerequisite steps.
- Tasks: Verify `.github/workflows/elixir-ci.yml` produces a green run; add `just build-proofs` Justfile recipe that invokes idris2 on `src/Burble/ABI/`; audit AffineScript compiler submodule to confirm `affinec` produces valid JS from at least one `.affine` file; pin coturn image digest in compose.toml; document exact quicer/msquic system prerequisites for the CI runner.

**Phase 1 — Stub Elimination** (2 weeks)
- Deliverable: No function returns `:not_implemented` or silent zeros in a reachable code path. Stubs that must remain (e.g., Opus transcode gated behind libopus) are tested to fail loudly with a clear error and documented.
- Tasks: Wire real Opus decode in SIP bridge `opus_to_pcm_stub` — either link libopus via Zig NIF or route through the existing coprocessor path; implement DNS SRV lookup in SIP bridge (`sip.ex:1306`); implement `fork_vext_chain` in `topology/transition.ex` (currently `{:ok, :stub}`); wire Discord xsalsa20_poly1305 path to a real implementation or error loudly; audit every `{:error, :not_implemented}` return in production paths and ensure each has a test that exercises the error.

**Phase 2 — Topology Modes Runtime** (2 weeks)
- Deliverable: All four topology modes run a demonstrable end-to-end scenario. Oligarchic: two Elixir nodes join a cluster, a room spans both, state is shared. Distributed: two rooms on separate instances exchange Avow attestations. Serverless: already working (P2P).
- Tasks: Implement distributed Erlang cookie setup and `dns_cluster_query` in `cluster/distributed.ex`; wire VeriSimDB replication calls for Oligarchic mode; implement `fork_vext_chain` with actual Vext genesis block creation; add integration tests for each mode in `server/test/burble/topology/`.

**Phase 3 — Client Verification** (2 weeks)
- Deliverable: `just build-client` produces a deployable web client from AffineScript sources. The embeddable library exports a usable API.
- Tasks: Verify `tools/affinescript` compiler submodule compiles against all 28 `.affine` files; fix any compilation errors; add CI step that runs `affinec` and checks output; document the embedding API for IDApTIK and PanLL integrators; ensure `client/lib/src/` exports are importable.

**Phase 4 — Integration Test Coverage for Bridges** (2 weeks)
- Deliverable: Mumble, SIP, Matrix, and Discord bridges each have at least one integration test that exercises a real protocol handshake (loopback or containerized peer).
- Tasks: Add a Murmur container to the test compose stack; write a bridge integration test that connects, sends a frame, and verifies receipt; do the same for SIP (an Asterisk or Kamailio container); for Matrix, use a Synapse container; for Discord, mock the Gateway WebSocket (Discord cannot be tested against the real API in CI without rate limit and token issues).

---

## 6. Critical-Path Dependencies

```
CI green run (Phase 0)
    └── blocks all automated quality gates

just build-proofs recipe
    └── blocks MUST.contractile enforcement (CI will not catch proof regressions)

AffineScript compiler verification
    └── blocks Phase 3 (client build)
    └── AffineScript is itself an in-development language — if affinec has bugs,
        the .affine migration may need partial rollback

Opus NIF / libopus linking
    └── blocks SIP bridge real audio (Phase 1)
    └── blocks Mumble bridge full audio quality
    └── NOT blocked by any external tool — libopus is a standard C library

VeriSimDB submodule Containerfile build
    └── blocks compose stack end-to-end test
    └── VeriSimDB builds from Rust source — requires Rust toolchain in CI

quicer / msquic build
    └── blocks QUIC transport and the test suite runs that require msquic guards
    └── `scripts/ensure-msquic-version.sh` guards this but adds a CI prerequisite

selur-compose tool
    └── `containers/selur-compose.toml` references it; standard compose file also exists
    └── selur-compose is being designed and built in a parallel track
    └── BLOCKS the deploy verification step of Phase 0 (Workstream 0.4 §6.5
        is now scoped to a single `podman pull`, not a stack-wide pull;
        full compose-stack bring-up tests are deferred until selur-compose
        v0.1 ships, since the only existing TOML compose tool — podman-compose
        — is Python and is banned by hyperpolymath language policy)
    └── Does NOT block Phase 0 CI fix, build-proofs, threat-model, AffineScript
        smoke, or quicer/msquic docs — those work without a running stack

cerro-torre / svalinn / vordr
    └── Block definition (C) entirely
    └── Not available; do not plan around them for (A) or (B)

Hardware PTP NIC (Intel I210 or equivalent)
    └── Blocks sub-microsecond measurement validation
    └── Hardware procurement, not a software task
    └── Blocks definition (B) PTP claim
```

---

## 7. Risk Register

**R1 — AffineScript compiler maturity.** AffineScript is described throughout as "in progress" with no public release or stability guarantee. If `affinec` does not produce correct JavaScript from the 28 ported `.affine` files, Phase 3 may require either staying on ReScript output or a partial rollback. The MUST.contractile bans new `.res` files, which creates a one-way door: the migration must work or the language policy must be relaxed. **Severity: High. Likelihood: Medium.**

**R2 — Opus transcoding gap is larger than it appears.** The STATE.a2ml frames Opus as "honest-demotion" — Burble is an E2EE-opaque SFU, so the server does not need to decode Opus in the normal voice path. This is architecturally sound. However, the SIP bridge (which must transcode G.711/G.722 to Opus for PSTN interop) and the recording path both require a real Opus decode. The `opus_to_pcm_stub` in `sip.ex` returns silence, not an error, which means SIP audio is silently broken rather than loudly failing. Callers testing the bridge would hear nothing and might not realize the bridge is non-functional. **Severity: High. Likelihood: Confirmed (stub is in the code).**

**R3 — VeriSimDB Elixir client wiring.** The VeriSimDB submodule is a full Rust + Elixir database with its own port assignment (`8091` for Burble per CLAUDE.md). `Burble.Store` calls it over HTTP. The actual HTTP client calls have not been audited here for completeness — there may be a mismatch between the VeriSimDB REST API and what `Burble.Store` expects. **Severity: Medium. Likelihood: Unknown.**

**R4 — quicer / msquic compilation in CI.** The Justfile includes `./scripts/ensure-msquic-version.sh` and `./scripts/ensure-quicer-prereqs.sh` as prerequisites for `just test-server`. This means the test suite requires a system build of msquic (a C library). If CI runners do not have the prerequisites, the test suite silently skips quicer tests or fails hard. This is a runtime-environment dependency that is non-trivial to pin. **Severity: Medium. Likelihood: Medium.**

**R5 — Topology federation runtime is more than plumbing.** Oligarchic and Distributed topologies are not just configuration flags — they require a correct distributed systems protocol for room state sync, split-brain handling, and cross-server Avow attestation. These are difficult to implement correctly and have no current tests. The `fork_vext_chain` stub returning `{:ok, :stub}` means any test of the distributed transition path silently succeeds without doing anything. **Severity: High. Likelihood: High (the work simply has not been done).**

**R6 — Supply-chain story references tools that do not exist.** cerro-torre, svalinn, and vordr are referenced in the Trustfile, compose files, and container configuration as if they were installable tools. In the Burble working tree, none of them are present, installed, or buildable. This is not a near-term risk to (A) code-complete, but it means the security posture documentation is aspirational. Anyone reading the Trustfile and expecting these controls to be operational will be misled. **Severity: High for (C); None for (A).**

**R7 — THREAT-MODEL.adoc contains unfilled template placeholders.** `docs/architecture/THREAT-MODEL.adoc` lines 8–10 contain `{{PROJECT_NAME}}`, `{{DATE}}`, `{{AUTHOR}}` — it was never instantiated from its template. This is a documentation gap, not a functional bug, but it affects the credibility of security claims. **Severity: Low. Likelihood: Confirmed.**

**R8 — Idris2 postulate for resampleFrame.** The `postulate resampleFrame` at `src/Burble/ABI/MediaPipeline.idr:65` means the most performance-critical audio path (resampling) is unproven. This is acknowledged and justified as a Zig FFI migration path, but it means the "formally proven ABI" claim has a hole. Formally this is an axiom, not a proof. If the Zig implementation diverges from the intended type signature, the Idris2 proof provides no protection. **Severity: Medium. Likelihood: Low (the Zig implementation is likely correct, but verification is the point).**

---

## 8. Parallelizable Workstreams

These eight items have no blocking inter-dependencies and can be dispatched to subagent sessions simultaneously.

1. **CI green run verification and fix.** Read `.github/workflows/elixir-ci.yml`, run the workflow mentally against the Justfile, identify the exact system prerequisites missing on a fresh Ubuntu runner, and write the corrected workflow. Sonnet tier. Target: `elixir-ci.yml` that passes on a vanilla GitHub-hosted runner.

2. **`just build-proofs` Justfile recipe.** Add a `build-proofs` recipe to the Justfile that invokes `idris2 --build` on `src/Burble/ABI/` and fails if any file does not compile. Verify the recipe works. Haiku tier. Target: single Justfile recipe, CI step added to quality.yml.

3. **SIP bridge Opus decode stub replacement.** Replace `opus_to_pcm_stub` in `server/lib/burble/bridges/sip.ex` with a real Opus decode via either a Zig NIF or an Erlang port to libopus. Must not silently return silence. Sonnet tier. Target: SIP G.711 → Opus transcoding produces audible output.

4. **SIP bridge DNS SRV implementation.** Implement the `resolve_via_srv/1` function that currently returns `{:error, :dns_srv_not_implemented}` at line 1306. Use `:inet_res` or equivalent to do a real DNS SRV lookup. Haiku tier. Target: function resolves a real `_sip._udp.example.com` SRV record.

5. **THREAT-MODEL.adoc template instantiation.** Fill in all `{{PLACEHOLDER}}` fields in `docs/architecture/THREAT-MODEL.adoc` with Burble-specific content drawn from EXPLAINME.adoc, ARCHITECTURE.adoc, and the Trustfile. Haiku tier.

6. **Compose stack smoke test.** *Deferred.* This workstream originally proposed a `podman-compose` driven smoke test, but `podman-compose` is Python and banned by hyperpolymath language policy. The task is rescheduled to land after `selur-compose` v0.1 ships — at that point, replace with `selur-compose -f containers/compose.toml up -d` + health-check polling + teardown. Until then, individual service builds can still be smoke-tested via direct `podman build` + `podman run` invocations on a per-service basis.

7. **Oligarchic topology skeleton.** Implement a minimal working version of the oligarchic clustering path: two Elixir nodes connected via distributed Erlang, sharing a `Phoenix.PubSub` topic for room events, with a basic `Burble.Cluster.Distributed` heartbeat confirming peer membership. No VeriSimDB federation required in this slice — just the clustering layer. Sonnet tier.

8. **AffineScript compiler smoke test.** Attempt to compile `client/web/src/Main.affine` using the `tools/affinescript` submodule's compiler binary (`affinec`). Document the exact command, any compilation errors, and whether the output is valid JavaScript. Do not fix the compiler — only report the compilation status so Phase 3 is accurately scoped. Haiku tier.

---

## 9. Out of Scope

For this definition (A) effort — explicitly out of scope:

- **selur-compose design and build.** Tracked in parallel docs (`2026-05-07-selur-compose-design.md`, `…-implementation-plan.md`). Note: the Burble Phase 0-4 plan **cannot** rely on `podman-compose` as originally framed, because it is Python and banned by hyperpolymath language policy. Until `selur-compose` v0.1 ships, any Phase 0-4 task that needs a running compose stack is deferred or rescoped to per-service `podman` invocations.
- **cerro-torre, svalinn, vordr integration.** These tools are not available. All supply-chain work is deferred to definition (C).
- **Hardware PTP validation.** Requires an Intel I210 or equivalent NIC. A procurement and lab task, not a software task.
- **WCAG AA/AAA accessibility compliance on the client.** ROADMAP.adoc lists sign language interpreters, Braille hardware support, and eye tracking — these are substantial UX engineering projects, not completions of existing code.
- **Blockchain anchoring for tamper-proof logs.** Listed in ROADMAP as aspirational. EXPLAINME.adoc notes VeriSimDB provenance makes external blockchain anchoring redundant. No action needed.
- **Kubernetes HPA integration and automated zero-downtime rolling deployments.** Operational tooling; outside the code-complete definition.
- **Jitsi and Matrix federation (as bridge targets).** Matrix bridge is partially implemented but untested; Jitsi is listed as planned. Both are Phase 4+ work.
- **Post-quantum cipher suites.** Listed in ROADMAP. The Trustfile describes Kyber1024 + Dilithium5, but these are aspirational policy statements, not implemented code paths in Burble's TLS layer.
- **EXLA GPU acceleration, WebAssembly client builds, Livebook integration.** Explicitly marked aspirational in ROADMAP.adoc.
- **VeriSimDB internals.** VeriSimDB is a dependency managed via submodule; its internal completeness is a separate project concern. Burble only needs the HTTP API to work correctly against the compose-deployed instance.

---

## Notes on the MASK subsystem and `Foreign.idr`

`server/lib/burble/coprocessor/voice_mask.ex` implements real-time voice transformation for privacy — pitch shifting, formant manipulation, and spectral reshaping via a pure Elixir FFT/IFFT pipeline. It is a complete, functioning implementation with 7 built-in masks and a custom parameter path. The one architectural concern is that the FFT computation in `compute_spectrum` is a naive O(n²) DFT loop, not the SIMD FFT from the Zig coprocessor — meaning for large frames, the privacy guarantee has an unexpected performance cost. The Zig FFT path is wired in the coprocessor pipeline but not called from VoiceMask.

`src/interface/abi/Types.idr` defines ABI types for the coprocessor (Result codes, platform detection, audio frame types). It includes `prim__registerCallback` which is commented as deferred pending resolution of idris2#3182 — an upstream Idris2 compiler issue with foreign callback safety. This is an honest boundary condition, not a design flaw, but it means the formal callback safety proof for the NIF event system cannot be completed until the upstream issue is resolved.
