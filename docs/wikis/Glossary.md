<!-- SPDX-License-Identifier: MPL-2.0 -->
# Glossary

Burble-specific terminology and the names of the cross-project tools it depends on. Alphabetical.

## A

**a2ml** — *AI-Annotated Markup Language*. Burble's machine-readable manifest format. Every directory carries a `0.X-AI-MANIFEST.a2ml` where `X` is depth from the repo root. Source of truth for tooling/agents; humans read the sibling `README.adoc`.

**ADR** — *Architecture Decision Record*. Numbered, append-only design decision. Burble's ADRs are in [`docs/decisions/`](https://github.com/hyperpolymath/burble/tree/main/docs/decisions).

**AffineScript** — Burble's web-client language, a ReScript superset that adds affine types (used once, dropped) for resource-safety guarantees. Migration in progress (Phase 5 ≈ 95%); `.affine` and `.res` siblings coexist during the migration.

**Avow** — One of the seven Idris2 ABI proof modules ([`src/Burble/ABI/Avow.idr`](https://github.com/hyperpolymath/burble/blob/main/src/Burble/ABI/Avow.idr)). Proves attestation-chain non-circularity.

## B

**BEAM** — The Erlang virtual machine. Hosts the Elixir control plane.

**Bolt** — Burble's lightweight "incoming call" signal. A small UDP datagram on port 7373 (with a WoL-compat poke on UDP 9). Distinct from full WebRTC signaling; used for cold contact + presence.

**burble-ai-bridge** — Deno HTTP/WS bridge on `:6474` + `:6475` that lets Claude Code (and similar AI tools) send/receive messages over the in-browser P2P data channel.

## C

**CLAUDE.md** — Project instructions consumed by Claude Code (the AI tool) when run in this repo. Not enforced for humans; just for the AI agent.

**CRG** — *Claims-Reality Gap*. Burble's self-audit method: every claim in the README maps to a code path + test, or is labelled experimental. Grades A (excellent) → F (failing). Burble currently targets C. See [`docs/governance/CRG-CRITERIA.adoc`](https://github.com/hyperpolymath/burble/blob/main/docs/governance/CRG-CRITERIA.adoc).

**Contractile** — A self-validating contract document. Lives under `.machine_readable/contractiles/`. Types: ADJUST, INTENT, MUST, TRUST.

## E

**E2EE** — End-to-end encryption. Optional in Burble (per-room keys, forward secrecy via `Burble.Security.KeyRotation`).

**EXPLAINME** — Burble's "show me the receipts" document. Each feature claim paired with the code path that implements it and honest caveats.

## G

**Gossamer** — Sibling project for ambient/peripheral presence. Not Burble itself — Burble *integrates with* Gossamer via the Groove discovery surface.

**Groove** — Burble's `.well-known/groove` discovery endpoint. Lets sibling services (Gossamer, PanLL, etc.) advertise capabilities and form a health mesh. Source: `server/lib/burble/groove*`.

## H

**Hypatia** — Neurosymbolic CI/CD security scanner. The bot that posts security-scan comments on PRs. Findings are *advisory* at the workflow layer; the gate is delegated to branch protection.

## I

**Idris2** — Dependently-typed language used for Burble's ABI proofs in `src/Burble/ABI/`. Compiles to type-checking only today (per ADR-0008 Option C); runtime enforcement is roadmap.

## K

**k9 / k9-svc** — Nickel-based deployment-component spec. Trust levels: Kennel (data only), Yard (evaluation), Hunt (full execution).

## L

**LMDB** — Burble's per-room ephemeral playout buffer backend. Lives at `server/lib/burble/media/lmdb_playout.ex`.

## M

**Membrane** — Elixir media framework Burble uses for the SFU.

**msquic** — Microsoft's QUIC C library. Optional dependency for `:quicer` (which itself is optional). When missing, Burble's LLM transport drops to TCP+TLS fallback on 8085.

## N

**NNTPS** — Burble's persistent threaded-message backend. The text-channel store. Source: `server/lib/burble/text/`.

## P

**Palimpsest Plasma** — Cross-project standards repo Burble references for shared standards. Lives at [`standards/palimpsest-plasma/`](https://github.com/hyperpolymath/burble/tree/main/standards) as a vendored copy.

**PanLL** — Sibling project for distributed compute (mentioned in Groove discovery context). Not Burble itself.

**PTP** — IEEE 1588 *Precision Time Protocol*. Burble uses it for multi-node playout alignment when available (`Burble.Timing.PTP`); falls back to OS clock otherwise.

## Q

**quicer** — Erlang NIF wrapping `msquic`. Optional dependency in `mix.exs`. Burble's LLM transport uses it when present; gracefully drops to TCP otherwise.

## R

**ReScript** — Sound, statically typed language compiling to JavaScript. Burble's existing web-client source (`*.res` files); being migrated to AffineScript.

**RSR** — *Rhodium Standard Repository*. Burble's repo-structure template. See `docs/decisions/0001-adopt-rsr-standard.adoc`.

**RTSP** — Real Time Streaming Protocol. Burble uses it for broadcast/stage rooms and screen-share streams (port 8554, plus dynamic UDP RTP ports). Source: `server/lib/burble/transport/rtsp.ex`.

## S

**selur-compose** — Container orchestration with zero-copy IPC for co-located services. Reads `compose.toml`. Falls back to standard Podman Compose. Repo not yet published — tracked in [#49](https://github.com/hyperpolymath/burble/issues/49).

**SFU** — *Selective Forwarding Unit*. WebRTC media topology where the server forwards (not transcodes) media to all participants. Burble's SFU is built on Membrane.

**SNIF** — *Sandboxed NIF*. WASM-runtime crash-isolated alternative to direct Zig NIFs, gated on `wasmex` availability. Falls back to ZigBackend when unavailable; ZigBackend falls back to pure Elixir.

**stapeln** — Layer-based container build chain (German *to stack*). Each layer is independently cacheable, verifiable, signable. Burble's manifest is at `stapeln.toml`.

**SVALINN** (svalinn) — Stapeln-ecosystem policy-driven reverse proxy. Reads `.gatekeeper.yaml`.

## T

**TSDM** — *Theory-Sourced Development Method*. Burble's project-governance method. See `docs/governance/TSDM.adoc`.

## V

**Vext** — Idris2 ABI proof module ([`src/Burble/ABI/Vext.idr`](https://github.com/hyperpolymath/burble/blob/main/src/Burble/ABI/Vext.idr)). Proves hash-chain integrity + capability subsumption.

**VeriSimDB** — Burble's persistent store backend. Optional in tests (`offline_ok: true` lets boot continue when unreachable).

**vordr** — Stapeln-ecosystem runtime container monitor. Reads `vordr.toml`.

## W

**Wolfi** — Chainguard's minimal CVE-free base image distribution. All Burble Containerfiles build on `cgr.dev/chainguard/wolfi-base`.

## Z

**Zig** — Systems language used for Burble's SIMD media hot-path NIFs (`ffi/zig/`). Current target: 0.15.x.

**ZigBackend** — Wrapper for the Zig NIFs (`server/lib/burble/coprocessor/zig_backend.ex`). Probes for `.so` presence at startup; falls back to pure Elixir when unavailable.
