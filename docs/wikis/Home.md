<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Burble

**Voice first. Friction last. Complexity optional.**

A modern self-hostable voice-first communications platform with sub-10ms latency, no telemetry, browser-native joining, and optional E2EE.

This wiki is the *signpost* — the canonical docs live in the repo. Edit `docs/wikis/*.md` in the repo, then sync to the wiki (this isn't a duplicate-or-fork situation, it's a mirror).

---

## Start here

| If you want to… | Go to |
|---|---|
| Make a P2P voice call with a friend in 60 seconds | [QUICKSTART-USER](https://github.com/hyperpolymath/burble/blob/main/QUICKSTART-USER.adoc) |
| Clone, build, and run the server locally | [QUICKSTART-DEV](https://github.com/hyperpolymath/burble/blob/main/QUICKSTART-DEV.adoc) |
| Operate Burble in production / release process | [QUICKSTART-MAINTAINER](https://github.com/hyperpolymath/burble/blob/main/QUICKSTART-MAINTAINER.adoc) |
| Understand the architecture | [docs/architecture/ARCHITECTURE.adoc](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/ARCHITECTURE.adoc) |
| See the threat model | [docs/architecture/THREAT-MODEL.adoc](https://github.com/hyperpolymath/burble/blob/main/docs/architecture/THREAT-MODEL.adoc) |
| Browse all documentation by topic | [docs/INDEX.adoc](https://github.com/hyperpolymath/burble/blob/main/docs/INDEX.adoc) |
| See what's verified vs claimed | [READINESS.adoc](https://github.com/hyperpolymath/burble/blob/main/READINESS.adoc) |
| See what's coming | [ROADMAP.adoc](https://github.com/hyperpolymath/burble/blob/main/ROADMAP.adoc) |

## What Burble is

- **Self-hostable**: one container, one command. No SaaS dependency.
- **Voice-first**: WebRTC media plane with Membrane SFU, Zig SIMD NIFs for the hot path.
- **Low latency**: target <10ms end-to-end (status: kernel benchmarks done; full mic-to-speaker bench pending — see [#52](https://github.com/hyperpolymath/burble/issues/52)).
- **Browser-native**: no downloads. Open the page, allow mic, paste a code.
- **P2P optional**: full peer-to-peer mode via the `p2p-voice.html` client + WebRTC data channel. No server required for two-party calls.
- **AI-aware**: the data channel doubles as a bridge for AI tools (see Claude Code instructions in [CLAUDE.md](https://github.com/hyperpolymath/burble/blob/main/CLAUDE.md)).
- **MPL-2.0 licensed**: file-level copyleft, friendly to commercial integration.

## Component map

| Layer | Tech |
|---|---|
| Control plane | Elixir / Phoenix (`server/`) |
| Media plane | Membrane SFU (`server/lib/burble/media/`) |
| Coprocessor | Zig NIF + WASM SNIF fallback (`ffi/zig/`) |
| ABI proofs | Idris2 (`src/Burble/ABI/`) |
| Web client | ReScript → AffineScript (`client/web/`) |
| Signaling relay | Deno (`signaling/`) |
| AI bridge | Deno (`client/web/burble-ai-bridge.js`) |
| Bolt incoming-call signal | UDP 7373 + WoL-compat UDP 9 |

## Important domain terms

See [Glossary](Glossary).

## Related projects

- [palimpsest-plasma](https://github.com/hyperpolymath/palimpsest-plasma) — cross-project standards repo Burble references.
- [hypatia](https://github.com/hyperpolymath/hypatia) — neurosymbolic CI/CD security scanner (the bot that comments on PRs here).
- [affinescript](https://github.com/hyperpolymath/affinescript) — ReScript-superset client compiler.
- [selur-compose](https://github.com/hyperpolymath/selur-compose) — container orchestration used in `container/` and `containers/`. (Note: tag `v0.1.0` pending — tracked in [#49](https://github.com/hyperpolymath/burble/issues/49).)
- [stapeln ecosystem](https://github.com/hyperpolymath/stapeln) — layer-based container build chain (`stapeln.toml`).

## Project status

- **License**: MPL-2.0.
- **Code of Conduct**: [CODE_OF_CONDUCT.md](https://github.com/hyperpolymath/burble/blob/main/CODE_OF_CONDUCT.md).
- **Security policy**: [SECURITY.md](https://github.com/hyperpolymath/burble/blob/main/SECURITY.md). Vulnerabilities → maintainer email there, *not* a public issue.
- **CRG grade**: D provisional, targeting C — see [READINESS.adoc](https://github.com/hyperpolymath/burble/blob/main/READINESS.adoc) and [docs/governance/CRG-AUDIT-2026-04-18.adoc](https://github.com/hyperpolymath/burble/blob/main/docs/governance/CRG-AUDIT-2026-04-18.adoc).
- **Machine-readable governance**: 6-verb contractiles complete (`must/trust/bust/adjust/dust/intend`), `bot_directives/` methodology layer, `svc/k9/` self-validation — see [`.machine_readable/`](https://github.com/hyperpolymath/burble/tree/main/.machine_readable).
- **Open issues**: [github.com/hyperpolymath/burble/issues](https://github.com/hyperpolymath/burble/issues).
- **Contributing**: [CONTRIBUTING.md](https://github.com/hyperpolymath/burble/blob/main/CONTRIBUTING.md).

## How to keep this wiki current

1. Edit the source files at [`docs/wikis/`](https://github.com/hyperpolymath/burble/tree/main/docs/wikis) in the main repo.
2. Sync to the wiki (manual `git push` from `.wiki.git`, or whatever sync tooling we adopt).
3. Don't edit pages directly in the wiki UI — they'll be overwritten on the next sync.

The wiki is a *mirror*, not a fork.
