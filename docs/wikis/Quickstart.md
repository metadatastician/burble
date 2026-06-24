<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Quickstart

Burble has three audience-specific quickstarts. Pick the one that matches what you're trying to do — they don't repeat each other.

## I want to call a friend in 60 seconds (no server)

Use the P2P mode. No clone, no install — just open the page.

1. One side opens `client/web/p2p-voice.html` in their browser (or visit the hosted copy).
2. They click **Join Room**, then **Generate Offer**, and send the code.
3. The other side opens the same page, pastes the code, clicks **Generate Reply**, and sends *that* code back.
4. First side pastes the reply. Connected.

Full guide: [QUICKSTART-USER.adoc](https://github.com/hyperpolymath/burble/blob/main/QUICKSTART-USER.adoc).

If you also want Claude Code (or another AI tool) to talk over the same channel, run the AI bridge:

```bash
deno run --allow-net --allow-env client/web/burble-ai-bridge.js
```

…then the page picks it up automatically (look for the green "bridge online" dot in the **AI Channel** card).

## I want to build and run the server locally

```bash
git clone --recurse-submodules https://github.com/hyperpolymath/burble
cd burble
./setup.sh                # OS-aware preflight + service install
just server               # or: cd server && mix phx.server
```

Or as a background service so no terminal window stays open:

```bash
just service-install      # systemd --user / launchd / Windows Service
```

Full guide: [QUICKSTART-DEV.adoc](https://github.com/hyperpolymath/burble/blob/main/QUICKSTART-DEV.adoc).

If you're on Windows host + WSL2, also run from an elevated PowerShell on the Windows side:

```powershell
.\setup.ps1               # forwards Bolt udp/7373+9 from host into WSL
```

## I'm operating Burble in production

See [QUICKSTART-MAINTAINER.adoc](https://github.com/hyperpolymath/burble/blob/main/QUICKSTART-MAINTAINER.adoc) for the release process, CI surface, and operator runbooks.

## What's in each directory

| Path | What it is |
|---|---|
| `server/` | Elixir / Phoenix control plane |
| `ffi/zig/` | Zig SIMD NIFs (audio hot-path) |
| `src/Burble/ABI/` | Idris2 ABI proofs |
| `client/web/` | Browser client (ReScript → AffineScript) |
| `signaling/` | Deno signaling relay |
| `container/` | Single-binary canonical container build |
| `containers/` | Multi-service deployment (server + web + nginx + coturn) |
| `scripts/` | Operational scripts (install-service, WSL forwarder, etc.) |
| `tests/install/` | Cross-platform install-machinery validation |
| `docs/` | Long-form docs ([INDEX](https://github.com/hyperpolymath/burble/blob/main/docs/INDEX.adoc)) |
| `.machine_readable/` | Tooling / agent manifests (don't hand-edit) |

## Common commands

```bash
just                      # list all recipes
just doctor               # toolchain health check
just test                 # full test suite
just service-install      # install as background service
just service-status       # check service health
just service-logs         # tail logs
just changelog            # regenerate CHANGELOG.md
```

## Where to ask

- Issues: <https://github.com/hyperpolymath/burble/issues>
- Security: see [SECURITY.md](https://github.com/hyperpolymath/burble/blob/main/SECURITY.md) (don't open a public issue for vulnerabilities)
- Code-of-conduct concerns: see [CODE_OF_CONDUCT.md](https://github.com/hyperpolymath/burble/blob/main/CODE_OF_CONDUCT.md)
