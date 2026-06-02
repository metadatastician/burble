<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->
<!-- Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Open-issue triage — 2026-06-02

> Companion record to the self-audit issue #106 (concern 3). Snapshot
> of all 7 open issues at audit time, grouped by theme with a
> recommendation per issue.

## Snapshot

Taken 2026-06-02 against `origin/main` HEAD `7727ceb`. `gh issue list
--state open --limit 50` returned 7 open issues.

| # | Title (abbreviated) | Labels | Recommendation |
|---|---------------------|--------|----------------|
| 100 | re-arm Elixir test gate (split from #35) | enhancement, cicd | **Keep** — Earn-the-Core sub-issue |
| 91  | 19 Critical/High panic-attack findings need human triage (Track C) | — | **Keep, elevate** — human-triage action |
| 77  | 4 RTSP tests fail in series — order/isolation, missing Session: header | — | **Keep, P0** — realtime-path correctness |
| 55  | Earn-core: formal-proof runtime-enforcement PoC (ADR-0008 Option C) | enhancement, earn-the-core | **Keep** — keystone |
| 53  | Earn the Core — foundational hardening (tracking) | enhancement, earn-the-core | **Keep** — epic |
| 52  | Earn-core: validate <10ms / 500+ concurrent headlines | enhancement, earn-the-core | **Keep** — keystone |
| 49  | Earn-core: reproducible one-command deploy | enhancement, earn-the-core, cicd | **Keep** — keystone |

## Themes

### Theme 1: Earn-the-Core epic (5 of 7)

`#53` is the tracking epic. `#49`, `#52`, `#55`, `#100` are coherent
sub-issues under it. **No action** beyond business-as-usual.

### Theme 2: Realtime-path correctness (1 of 7)

`#77` (RTSP test ordering / missing Session header) is the only
realtime-correctness issue currently open. It sits adjacent to
self-audit concern 4 — both point at weak realtime test discipline.

**Recommendation:** add a `realtime` label (does not currently exist
in this repo's label set — would need to be created by an owner).
Cross-reference `#77` from `#53` so the epic captures realtime
correctness as a workstream.

### Theme 3: Security-finding triage (1 of 7)

`#91` (19 Critical/High panic-attack findings) has been open since
2026-05-26. This is human-judgement work that cannot be auto-resolved.

**Recommendation:** surface in next maintainer sync; add a
`security-triage-needed` label if/when the owner creates one.

## No closures, no merges

All 7 open issues are distinct concerns. None overlap, none are
stale, none can be closed without owner-grade analysis. No merges
recommended.

## Suggested label additions (owner discretion)

Two labels would help future triage but require owner approval:

- `realtime` — for realtime-path / signaling / SFU / RTSP correctness.
- `security-triage-needed` — for findings awaiting human judgement.

This document **does not** create those labels — that's a separate
owner action via `gh label create`.

## Cross-links

- Self-audit issue: #106
- Realtime test-coverage PR (self-audit concern 4): PR adding
  `signaling_failure_modes_test.exs`.
- Protocol publication PR (self-audit concern 1): PR adding
  `docs/PROTOCOL.md`.
- Self-hosting hardening PR (self-audit concern 2): PR adding
  `docs/SECURITY-DEPLOY.md`.

## Methodology note

This triage was generated from a fresh `origin/main` clone with no
local in-flight working-tree state, per estate policy on
SPDX/PMPL-in-flight sweeps. The triage is therefore reproducible by
re-running the same `gh issue list` command at the same SHA.
