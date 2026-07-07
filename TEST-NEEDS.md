# Test & Benchmark Requirements

## CRG Grade: D (targeting C — blocked on #100)

Authoritative grade lives in `.machine_readable/descriptiles/STATE.a2ml` (`[crg]`).
The provisional C claimed 2026-04-04/2026-04-21 is withdrawn per ADR-0007:
the CI test gate is disarmed (`continue-on-error: true`, issue #100), and a
grade cannot rest on a gate that does not gate.

**Honest test state (2026-05-20 local evidence, OTP 25):** the full suite is
~707 tests with 134–165 failures (nondeterministic; OTP25-local vs OTP27-CI
skew — see STATE.a2ml session history). The "222+ tests, 100% pass" figure
below is a historical curated-subset claim retained for context only.

CRG C artefact checklist:
- Unit tests: 222+ ExUnit tests (curated subset; full suite has known failures — #100)
- Smoke tests: coprocessor + server self-test covered
- P2P/property-based: StreamData property tests in `server/test/burble/property/room_property_test.exs`
- E2E/reflexive: voice pipeline and participant lifecycle tests in `server/test/burble/e2e/`
- Contract tests: auth and API contract coverage across existing test suite
- Aspect tests: security hardening, accessibility, diagnostics covered
- Benchmarks: Criterion-style benchmarks in `server/test/burble/coprocessor/benchmark_test.exs`

## Current State (Updated 2026-04-16)

### Elixir server tests
- Unit tests: 222+ Elixir tests green as a curated subset; **the full suite
  (~707 tests) carries 134–165 failures and the CI gate is disarmed — #100**
- Zig FFI tests: **Coprocessor integration tests — 100% PASS** (this build
  step IS a real CI gate)
- E2E voice pipeline and participant lifecycle tests — PASS
- **Signaling E2E:** 19 existing + 6 new safety-contract regression tests in `signaling_test.exs`
  - Session creation, WebRTC relay, voice state transitions, UserSocket auth
  - **Channel safety contract (added 2026-04-16):** 6 tests asserting catch-all handle_in/handle_info for malformed events, empty text, unknown events, participant_joined/left PubSub, and unexpected messages — no crashes.
- **Session property tests:** 8 StreamData properties in `session_property_test.exs` — PASS
- **Session concurrency tests:** 13 tests in `session_concurrency_test.exs` — PASS
- **Opus contract tests (added 2026-04-16):** 6 tests in `opus_contract_test.exs` — opus_transcode returns :not_implemented on all 3 backends; audio_encode round-trips raw PCM; bitrate parameter is provably ignored.
- panic-attack scan: Ready via `just assail`.

### P2P AI bridge tests (Deno)
- **Round-trip tests (added 2026-04-16):** in `client/web/tests/ai_bridge_roundtrip_test.js`
  - A → B message round-trip, B → A reverse, heartbeat keep-alive
  - **100-message burst ordering:** all 100 arrive in seq order, no drops
  - **Reconnect-resume:** queue survives WS disconnect; message still drainable after reconnect

### Resolved (channel safety)
- [x] RoomChannel catch-all handle_in — **FIXED 2026-04-09 (167d46d)**. Tests flipped from `@tag :known_gap` to affirmative assertions (2026-04-16).
- [x] RoomChannel handle_info for :participant_joined/:left — **FIXED 2026-04-09 (167d46d)**. Tests added 2026-04-16.
- [x] P2P AI bridge receive leg — **FIXED 2026-04-16 (8e17a4b)**. Dead `setupAIChannelWithBridge` replaced with inline forwarding in `setupAIChannel`.

## What's Missing

### Resilience
- **Circuit Breaker Validation:** Simulate LLM service failures to verify QUIC → TCP fallback (Phase 2b — secondary).
- **SDP Barrier Test:** Attempt unauthorised access without SPA packets to verify firewall rejection.

### Client
- **Client (ReScript → AffineScript):** 8 Deno-based test files at `client/web/tests/`:
  - **3 NEW (2026-05-30, target real source modules):**
    - `room_test.js` — `Room.generateRoomName` + `Room.isValidRoomName` (8 tests, exhaustive shape + variety coverage)
    - `webrtc_offer_answer_test.js` — WebRTC SDP cycle against stubbed `RTCPeerConnection` (caller + callee happy paths, ICE-gathering, data channel + addTrack sanity)
    - `signaling_relay_test.js` — `Signaling.Relay` HTTP API against stubbed `fetch` (PUT/GET offer/answer + 2-side e2e sequences)
  - **5 EXISTING (pre-2026-05-30, stale imports):** `signaling_test.js`, `voice_test.js`, `ai_bridge_test.js`, `ai_bridge_roundtrip_test.js`, `client_test.js`. These import from `BurbleSignaling.res.mjs` / `BurbleVoice.res.mjs` under `client/web/lib/src/` — neither the modules nor the directory exist in current source (actual modules are `Signaling.res` / `WebRTC.res` / `Room.res` under `src/`). They fail at import; the workflow runs in advisory mode (`continue-on-error: true`) until they are either rewritten against the real modules or moved out of `tests/`.
  - Wired into CI via `.github/workflows/web-client-tests.yml` (advisory) — closes #48 acceptance bullet 2.
  - Migration to running against `.affine` output is gated by STATE.a2ml Phase 5 closure (`affinescript-canary.yml` is the compilation canary today).
- **Desktop (Ephapax, 5 .eph files):** ZERO test files. Carry-forward.

### End-to-End
- **Accessibility E2E:** Screen reader focus trap testing and ARIA live region announcement verification.
- **Multi-region Routing:** PTP clock sync drift over high-latency links (Phase 4).

### Aspect Tests
- [ ] Security (Full OpenSSF Scorecard audit)
- [ ] Performance (Multi-region latency under load)
- [ ] Accessibility (WCAG 2.3 AAA compliance audit)

### Benchmarks Needed
- Audio latency measurement (mic-to-speaker)
- Concurrent participant scaling (Target: 500+)
- Jitter buffer performance under heavy AWOL redundancy

## Priority
- **CRITICAL** — P2P AI bridge reliability (Phase 2 — receive leg fixed, ordering + reconnect tested, protocol doc written).
- **HIGH** — Phase 1 audio: neural model gating, jitter sync, comfort noise, REMB, Avow hash-chain.
- **MEDIUM** — Client testing: add tests alongside AffineScript migration (Phase 3/5).
- **LOW** — Chaos testing on Layline algorithm; resilience tests for server-side LLM (Phase 2b).
