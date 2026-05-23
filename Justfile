# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble — voice-first communications platform
# https://just.systems/man/en/

set shell := ["bash", "-uc"]
set dotenv-load := true
set positional-arguments := true

import? "contractile.just"

project := "burble"
version := "1.0.0"

# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT & HELP
# ═══════════════════════════════════════════════════════════════════════════════

# Show all available recipes
default:
    @just --list --unsorted

# Show project info
info:
    @echo "Project: {{project}} {{version}}"
    @echo "Server:  Elixir/Phoenix (server/)"
    @echo "FFI:     Zig SIMD coprocessor (ffi/zig/)"
    @echo "Client:  WebRTC + AI data channel (client/web/) — migrating to AffineScript"
    @echo "P2P:     burble-ai-bridge.js on :6474 + p2p-voice.html"

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD
# ═══════════════════════════════════════════════════════════════════════════════

# Build everything (FFI + server deps)
build: build-ffi build-server

# Resolve the Erlang NIF include dir in the *shell* (where erlef/setup-beam's
# PATH reliably applies, unlike a subprocess spawned from inside `zig build`)
# and echo it. build.zig keeps its own detection as a fallback.
_erl-include:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v erl >/dev/null 2>&1; then
      root=$(erl -noshell -eval 'io:format("~s",[code:root_dir()]),halt().' 2>/dev/null || true)
      vsn=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(version)]),halt().' 2>/dev/null || true)
      for d in "$root/usr/include" "$root/erts-$vsn/include"; do
        if [ -f "$d/erl_nif.h" ]; then echo "$d"; exit 0; fi
      done
    fi
    echo ""

# Build Zig coprocessor NIFs
build-ffi:
    #!/usr/bin/env bash
    set -euo pipefail
    erl_inc="$(just _erl-include)"
    cd ffi/zig
    if [ -n "$erl_inc" ]; then
      zig build -Doptimize=ReleaseFast -Derl-include="$erl_inc"
    else
      zig build -Doptimize=ReleaseFast
    fi
    cp zig-out/lib/libburble_coprocessor.so ../../server/priv/ 2>/dev/null || true

# Build Zig coprocessor (debug mode)
build-ffi-debug:
    #!/usr/bin/env bash
    set -euo pipefail
    erl_inc="$(just _erl-include)"
    cd ffi/zig
    if [ -n "$erl_inc" ]; then
      zig build -Derl-include="$erl_inc"
    else
      zig build
    fi
    cp zig-out/lib/libburble_coprocessor.so ../../server/priv/ 2>/dev/null || true

# Fetch Elixir deps and compile server
build-server:
    cd server && mix deps.get && mix compile

# Build Idris2 ABI proofs (src/Burble/ABI/*)
# Module collision note: src/interface/abi/ also declares Burble.ABI.Types
# and is excluded from this recipe (deferred to Phase 1 module-path cleanup).
build-proofs:
    # idris2 binaries built elsewhere bake in a wrong prefix; derive it
    # from the idris2 on PATH (override with IDRIS2_PREFIX if needed).
    cd src/Burble/ABI && IDRIS2_PREFIX="${IDRIS2_PREFIX:-$(dirname "$(dirname "$(command -v idris2)")")}" idris2 --build burble-abi.ipkg

# Build web client
build-client:
    cd client/web && deno task build

# ═══════════════════════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════════════════════

# Quick start — install, start server, open browser client
start:
    ./burble-launcher.sh --start

# Install desktop + menu shortcuts
install:
    ./burble-launcher.sh --install

# Uninstall shortcuts
uninstall:
    ./burble-launcher.sh --uninstall

# Open the quick-join voice client in browser (server must be running)
join:
    xdg-open "file://{{justfile_directory()}}/client/web/quick-join.html"

# P2P voice — no server needed, just share a code
p2p:
    xdg-open "file://{{justfile_directory()}}/client/web/p2p-voice.html"

# Start AI bridge (lets Claude Code send/receive via curl)
ai-bridge:
    deno run --allow-net client/web/burble-ai-bridge.js

# P2P voice + AI bridge together
p2p-ai:
    deno run --allow-net client/web/burble-ai-bridge.js &
    sleep 1
    xdg-open "file://{{justfile_directory()}}/client/web/p2p-voice.html"

# Start signaling relay (room-name discovery — run on any reachable machine)
relay:
    deno run --allow-net --allow-env signaling/relay.js

# Full stack: relay + AI bridge + P2P voice (run this on the host machine)
full:
    deno run --allow-net --allow-env signaling/relay.js &
    deno run --allow-net client/web/burble-ai-bridge.js &
    sleep 1
    xdg-open "file://{{justfile_directory()}}/client/web/p2p-voice.html"

# Start the Elixir server (dev mode)
server:
    cd server && mix phx.server

# ─── Background-service install (cross-platform, no terminal window) ──────
# systemd --user on Linux/WSL, launchd LaunchAgent on macOS. Windows host
# users should also run scripts\wsl-bolt-udp-forward.ps1 -Install from a
# Windows PowerShell to forward Bolt udp/7373+9 into WSL — windowless.

# Install Burble as a background service (no terminal window pops up)
service-install:
    scripts/install-service.sh install

# Remove the Burble background service
service-uninstall:
    scripts/install-service.sh uninstall

service-start:    ; scripts/install-service.sh start
service-stop:     ; scripts/install-service.sh stop
service-restart:  ; scripts/install-service.sh restart
service-status:   ; scripts/install-service.sh status
service-logs:     ; scripts/install-service.sh logs

# Start the web client dev server
client:
    cd client/web && deno task dev

# Build the selur-compose binary from the tools/selur-compose/ workspace.
# Once selur-compose ships as a submodule with a published crate, this becomes
# 'cargo install selur-compose' or 'cargo binstall selur-compose'.
build-selur-compose:
    #!/usr/bin/env bash
    set -euo pipefail
    SELUR="{{justfile_directory()}}/tools/selur-compose"
    if [[ ! -d "$SELUR" ]]; then
        echo "ERROR: tools/selur-compose not found."
        echo "Run: git submodule update --init tools/selur-compose"
        exit 1
    fi
    echo "Building selur-compose (release)…"
    cargo build --release --manifest-path "$SELUR/Cargo.toml" -p selur-compose
    echo "Built: $SELUR/target/release/selur-compose"

# Start containers via selur-compose (Rust, TOML-native — no Python).
# Builds selur-compose from tools/selur-compose/ if the binary is missing.
# Once selur-compose is published and installed system-wide, the build
# guard becomes a no-op (the binary will already exist on PATH).
up:
    #!/usr/bin/env bash
    set -euo pipefail
    SELUR_BIN="{{justfile_directory()}}/tools/selur-compose/target/release/selur-compose"
    if [[ ! -x "$SELUR_BIN" ]]; then
        echo "selur-compose binary not found; building from tools/selur-compose/ first…"
        just build-selur-compose
    fi
    # Run from containers/ so build.context = ".." in compose.toml resolves
    # against the compose file's directory (burble root), per compose spec.
    # selur-compose v0.1 does not yet resolve relative paths against the
    # compose file location — TODO file an issue and remove the cd once fixed.
    cd "{{justfile_directory()}}/containers"
    # --no-pull: selur-compose v0.1 pulls image-based services unconditionally
    # (no pull_policy=missing). ghcr.io/hyperpolymath/verisimdb:latest is not
    # published yet (the publish-verisimdb.yml workflow has not run), so a pull
    # 403s and aborts `up`. The image exists locally (built + tagged from the
    # nextgen-databases source earlier; coturn pinned-digest already pulled).
    # Remove --no-pull once (a) the GHCR image is published AND (b) selur-compose
    # v0.2 implements pull_policy=missing. Tracked in selur-compose v0.2 backlog.
    exec "$SELUR_BIN" -f compose.toml up -d --no-pull

# Stop containers via selur-compose.
# Builds selur-compose from tools/selur-compose/ if the binary is missing.
down:
    #!/usr/bin/env bash
    set -euo pipefail
    SELUR_BIN="{{justfile_directory()}}/tools/selur-compose/target/release/selur-compose"
    if [[ ! -x "$SELUR_BIN" ]]; then
        echo "selur-compose binary not found; building from tools/selur-compose/ first…"
        just build-selur-compose
    fi
    cd "{{justfile_directory()}}/containers"
    exec "$SELUR_BIN" -f compose.toml down

# Full deploy: build selur-compose if needed, then bring the stack up.
# Equivalent to 'just up' but makes the build step explicit.
deploy: build-selur-compose up

# Smoke-test the full deploy: clean slate, `just up`, wait 40s, then assert the
# stack is ACTUALLY healthy — not merely "no nxdomain string". A grep for the
# absence of one error string false-passes when a deeper error crash-loops the
# server (learned 2026-05-15: WS-1.6 fixed nxdomain but a migrator bug kept the
# server looping while smoke reported PASS). Real criteria:
#   1. burble_server RestartCount low (≤2) and state=running
#   2. POST /api/v1/auth/guest returns HTTP 200 (server actually serving)
#   3. no nxdomain in logs (regression guard for WS-1.6)
# The `down` makes this idempotent — selur-compose v0.1 cannot recreate an
# existing-named container (no --replace logic), so a leftover from a prior
# partial run would 125-error `up`. `-` prefix: `down` errors when nothing runs.
smoke-deploy:
    -just down
    just up
    sleep 40
    bash scripts/smoke-check.sh

# ═══════════════════════════════════════════════════════════════════════════════
# TEST
# ═══════════════════════════════════════════════════════════════════════════════

# Run all tests
test: test-server test-ffi

# Run E2E tests (server + client + FFI integration)
e2e:
    just test
    @echo "E2E validation passed"

# Run aspect-oriented tests
aspect:
    #!/usr/bin/env bash
    set -euo pipefail
    bash tests/aspect/aspect_tests.sh

# Run Elixir server tests
test-server:
    ./scripts/ensure-msquic-version.sh
    ./scripts/ensure-quicer-prereqs.sh
    cd server && mix test --no-start

# Guard check: fail fast if embedded msquic is on the wrong tag
guard-msquic:
    ./scripts/ensure-msquic-version.sh --check-only

# Guard check: fail fast if quicer source-build prerequisites are missing
guard-quicer-prereqs:
    ./scripts/ensure-quicer-prereqs.sh

# Run Zig FFI unit tests
test-ffi:
    cd ffi/zig && zig build test

# Run coprocessor benchmarks (Elixir vs Zig)
bench:
    cd server && mix bench.coprocessor

# ═══════════════════════════════════════════════════════════════════════════════
# QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

# Format all code
fmt:
    cd server && mix format
    cd ffi/zig && zig fmt src/

# Run Elixir linter
lint:
    cd server && mix credo --strict

# Type-check Elixir (Dialyzer)
dialyzer:
    cd server && mix dialyzer

# Run panic-attack static analysis
scan:
    panic-attack assail .

# ═══════════════════════════════════════════════════════════════════════════════
# RELEASE
# ═══════════════════════════════════════════════════════════════════════════════

# Build a release
release: build
    cd server && MIX_ENV=prod mix release

# Build container images
container-build:
    cd containers && podman build -f Containerfile.server -t burble-server ..
    cd containers && podman build -f Containerfile.web -t burble-web ../client/web

# ═══════════════════════════════════════════════════════════════════════════════
# CLEAN
# ═══════════════════════════════════════════════════════════════════════════════

# Clean all build artifacts
clean:
    cd server && mix clean
    cd ffi/zig && rm -rf zig-out .zig-cache
    rm -f server/priv/libburble_coprocessor.so

# Run panic-attacker pre-commit scan
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"

# ═══════════════════════════════════════════════════════════════════════════════
# ONBOARDING & DIAGNOSTICS
# ═══════════════════════════════════════════════════════════════════════════════

# Check all required toolchain dependencies and report health
doctor:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Burble Doctor — Toolchain Health Check"
    echo "═══════════════════════════════════════════════════"
    echo ""
    PASS=0; FAIL=0; WARN=0
    check() {
        local name="$1" cmd="$2" min="$3"
        if command -v "$cmd" >/dev/null 2>&1; then
            VER=$("$cmd" --version 2>&1 | head -1)
            echo "  [OK]   $name — $VER"
            PASS=$((PASS + 1))
        else
            echo "  [FAIL] $name — not found (need $min+)"
            FAIL=$((FAIL + 1))
        fi
    }
    check "just"              just      "1.25"
    check "git"               git       "2.40"
    check "Zig"               zig       "0.13"
    check "cmake"             cmake     "3.20"
    check "perl"              perl      "5.30"
    check "make"              make      "4.0"
    check "idris2"            idris2    "0.7"
    check "podman"            podman    "4.0"
    # Optional tools
    if command -v panic-attack >/dev/null 2>&1; then
        echo "  [OK]   panic-attack — available"
        PASS=$((PASS + 1))
    else
        echo "  [WARN] panic-attack — not found (pre-commit scanner)"
        WARN=$((WARN + 1))
    fi
    echo ""
    echo "  Result: $PASS passed, $FAIL failed, $WARN warnings"
    if [ "$FAIL" -gt 0 ]; then
        echo "  Run 'just heal' to attempt automatic repair."
        exit 1
    fi
    echo "  All required tools present."

# Attempt to automatically install missing tools
heal:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Burble Heal — Automatic Tool Installation"
    echo "═══════════════════════════════════════════════════"
    echo ""
    if ! command -v just >/dev/null 2>&1; then
        echo "Installing just..."
        cargo install just 2>/dev/null || echo "Install just from https://just.systems"
    fi
    echo ""
    echo "Heal complete. Run 'just doctor' to verify."

# Guided tour of the project structure and key concepts
tour:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Burble — Guided Tour"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo '// SPDX-License-Identifier: MPL-2.0'
    echo ""
    echo "Key directories:"
    echo "  src/                      Source code" 
    echo "  ffi/                      Foreign function interface (Zig)" 
    echo "  src/abi/                  Idris2 ABI definitions" 
    echo "  server/                   Server-side code" 
    echo "  client/                   Client-side code" 
    echo "  docs/                     Documentation" 
    echo "  tests/                    Test suite" 
    echo "  .github/workflows/        CI/CD workflows" 
    echo "  contractiles/             Must/Trust/Dust contracts" 
    echo "  .machine_readable/        Machine-readable metadata" 
    echo "  container/                Container configuration" 
    echo "  examples/                 Usage examples" 
    echo ""
    echo "Quick commands:"
    echo "  just doctor    Check toolchain health"
    echo "  just heal      Fix missing tools"
    echo "  just help-me   Common workflows"
    echo "  just default   List all recipes"
    echo ""
    echo "Read more: README.adoc, EXPLAINME.adoc"

# Show help for common workflows
help-me:
    #!/usr/bin/env bash
    echo "═══════════════════════════════════════════════════"
    echo "  Burble — Common Workflows"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "FIRST TIME SETUP:"
    echo "  just doctor           Check toolchain"
    echo "  just heal             Fix missing tools"
    echo "" 
    echo "PRE-COMMIT:"
    echo "  just assail           Run panic-attacker scan"
    echo ""
    echo "LEARN:"
    echo "  just tour             Guided project tour"
    echo "  just default          List all recipes" 


# Print the current CRG grade (reads from READINESS.md '**Current Grade:** X' line)
crg-grade:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    echo "$$grade"

# Generate a shields.io badge markdown for the current CRG grade
# Looks for '**Current Grade:** X' in READINESS.md; falls back to X
crg-badge:
    @grade=$$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$$grade" ] && grade="X"; \
    case "$$grade" in \
      A) color="brightgreen" ;; B) color="green" ;; C) color="yellow" ;; \
      D) color="orange" ;; E) color="red" ;; F) color="critical" ;; \
      *) color="lightgrey" ;; esac; \
    echo "[![CRG $$grade](https://img.shields.io/badge/CRG-$$grade-$$color?style=flat-square)](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)"
