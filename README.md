<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2025-2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

[![Green Hosting](https://api.thegreenwebfoundation.org/greencheckimage/jewell.nexus)](https://www.thegreenwebfoundation.org/green-web-check/?url=jewell.nexus)

Voice first. Friction last. Complexity optional.

# What is Burble?

Burble is a **self-hostable voice communications platform** built for
people who care about latency, privacy, and control. Think Mumble’s
audio seriousness meets modern browser-based joining — no downloads, no
accounts, no friction.

**One command to deploy. Sub-second to join. Your server, your rules.**

# Status

Burble is **pre-production** (targeting CRG grade C). The core —
self-hosted WebRTC voice, browser join, OTP fault isolation — is
operational and tested. Per
[ADR-0007](docs/decisions/0007-claims-to-evidence-discipline.adoc),
every claim below maps to code + a test, or is flagged here:

- **Experimental (optional, off by default):** QUIC transport and SNIF
  WASM crash-isolation require optional NIFs (`quicer`/msquic, `wasmex`)
  that are **disabled in the default build**; the runtime degrades
  gracefully without them.

- **Hardware-gated:** sub-microsecond PTP needs a PTP-capable NIC;
  without one the system uses NTP (~1ms). PTP hardware is
  **unvalidated** (I210 pending).

- **Roadmap:** the Idris2 ABI proofs compile and type-check; **runtime**
  enforcement is not yet wired
  ([ADR-0008](docs/decisions/0008-formal-proof-enforcement-vs-scope.adoc),
  Option C; PoC tracked in issue \#55).

- **Not yet benchmarked:** end-to-end mic-to-speaker latency and 500\
  concurrent scale (issue \#52).

Foundational hardening is tracked in the "Earn the Core" epic (issue
\#53).

# Why Burble?

|  | Burble | Mumble | Discord | Jitsi |
|----|----|----|----|----|
| **Self-host** | Yes | Yes | No | Yes |
| **Browser join** | Yes (WebRTC) | No (native only) | Browser + app | Yes |
| **Latency** | \<10ms\* (kernel-path target) | ~15ms | ~50-100ms | ~30ms |
| **Privacy** | E2EE optional, no telemetry | Encrypted, no telemetry | Telemetry, scanning | E2EE optional |
| **Precision timing** | IEEE 1588 PTP (\<1µs)\* | No | No | No |
| **Embeddable** | Yes (game/app integration) | No | No | Partial |

> [!NOTE]
> **Honest status
> ([ADR-0007](docs/decisions/0007-claims-to-evidence-discipline.adoc)):**
> `<10ms` is a Zig kernel-path target — end-to-end mic-to-speaker
> latency and 500+ concurrent scale are **not yet benchmarked** (issue
> \#52). `IEEE` `1588` `PTP` `<1µs` requires a PTP-capable NIC; without
> one the system falls back to NTP (~1ms) and the PTP hardware path
> remains **unvalidated**.

# Key Features

**Audio performance** — Zig SIMD coprocessor NIFs deliver 26,350x
speedup over pure Elixir for LZ4 compression, 62x for echo cancellation,
37x for FFT. Your server doesn’t break a sweat.

**Precision Time Protocol** — IEEE 1588 PTP clock source detection with
graceful fallback (PTP hardware → phc2sys → NTP → system).
Sub-microsecond accuracy when a PTP hardware clock is available; ~1ms
via NTP on typical deployments. Jitter measurement, telemetry, and
multi-node alignment data export built in. Hardware clock NIF is a Phase
4 target.

**Four topology modes** — From single-server (monarchic) to fully
distributed mesh (serverless with mandatory E2EE). Set `BURBLE_TOPOLOGY`
and go.

**Erlang/OTP backbone** — Supervision trees, hot code upgrades, fault
isolation. If a room crashes, everything else keeps running. That’s not
marketing — that’s OTP.

**Bridge interop** — Bidirectional Mumble/Murmur relay. Migrate your
community without forcing everyone to switch at once. Jitsi and Matrix
bridges planned.

**Embeddable client library** — Drop Burble voice into your game,
workspace, or app. Used in IDApTIK (asymmetric co-op game) and PanLL
(panel workspace).

# Quick Start

## One-command container deployment

```bash
git clone --recurse-submodules https://github.com/hyperpolymath/burble && cd burble
just deploy       # builds selur-compose if needed (~3 min first run), then brings up the stack
# Server:     http://localhost:4000
# Web client: http://localhost:8080
# VeriSimDB:  http://localhost:8081
```

`just` `deploy` uses [selur-compose](tools/selur-compose/) — the
TOML-native Rust compose driver developed in-tree. No Python, no Docker
Compose, no `podman-compose`.

To stop the stack:

```bash
just down
```

> [!NOTE]
> `--recurse-submodules` is required. VeriSimDB is integrated as a
> submodule under `tools/nextgen-databases` (paralleling
> `tools/affinescript`) because Burble’s anti-purpose forbids vendoring
> it in-tree. If you already cloned without it, run `git` `submodule`
> `update` `--init` `--recursive` — or just run `./setup.sh`, which now
> does that automatically.

## Development setup

> [!NOTE]
> Building from source requires system packages for the
> `quicer`/`msquic` QUIC transport library (cmake, perl, build tools,
> OpenSSL headers). See
> <a href="CONTRIBUTING.md#building-from-source--system-prerequisites"
> class="md">CONTRIBUTING</a> for the full package list and per-distro
> install commands.

```bash
# Prerequisites: Elixir 1.17+, Zig 0.15+, Deno
# (plus system packages — see CONTRIBUTING.md)

# Build Zig coprocessor
cd ffi/zig && zig build -Doptimize=ReleaseFast
cp zig-out/lib/libburble_coprocessor.so ../../server/priv/

# Start server
cd server && mix deps.get && mix phx.server

# Start web client (separate terminal)
cd client/web && deno task dev
```

## Run tests

```bash
just test          # All tests
just test-server   # Elixir tests (300+)
just test-ffi      # Zig coprocessor tests
just bench         # Elixir vs Zig benchmarks
```

# Coprocessor Benchmarks

SIMD-accelerated audio processing via Zig NIFs:

| Operation      | Elixir | Zig NIF | Speedup |
|----------------|--------|---------|---------|
| LZ4 compress   | 83ms   | 3.1us   | 26,350x |
| Echo cancel    | 19.4ms | 310us   | 62x     |
| FFT (256pt)    | 826us  | 22us    | 37x     |
| Convolution    | 300us  | 11us    | 27x     |
| Neural denoise | 54us   | 9us     | 6x      |

# Wondering How This Works?

If you’re curious about the tech behind these claims — how we hit
26,350x, what PTP actually does, why OTP gives us fault isolation — see
<a href="EXPLAINME.adoc" class="adoc">EXPLAINME</a> for the receipts.

# Documentation

- [**Documentation Index**](docs/INDEX.adoc) — one-page map of every doc
  under `docs/` and at the repo root. Start here if you don’t know where
  to look.

- [Show Me The Receipts](EXPLAINME.adoc) — feature highlights with code
  paths and honest caveats

- [Architecture](docs/architecture/ARCHITECTURE.adoc) — control plane,
  media plane, topology modes, supervision tree

- [Threat Model](docs/architecture/THREAT-MODEL.adoc) — security
  analysis and mitigations

- [ABI/FFI Design](docs/developer/ABI-FFI-README.adoc) — Idris2 proofs +
  Zig implementation

- [Accessibility](docs/accessibility/README.adoc) — accessibility
  features, compliance, and roadmap

- [Decision records (ADRs)](docs/decisions/) — numbered, append-only
  design decisions

- [Wiki](https://github.com/hyperpolymath/burble/wiki) — landing +
  signposts (source in `docs/wikis/`)

# Questions?

Open an issue on
[GitHub](https://github.com/hyperpolymath/burble/issues) or reach out
directly — happy to explain anything in more detail.

# License

SPDX-License-Identifier: CC-BY-SA-4.0

Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
\<[j.d.a.jewell@open.ac](j.d.a.jewell@open.ac).uk\>

See [LICENSE](LICENSE) for full text.
