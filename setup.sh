#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble — Universal Setup Script
# Detects platform and shell, installs just, then hands off to Justfile.

set -euo pipefail

echo "═══════════════════════════════════════════════════"
echo "  Burble — Setup"
echo "═══════════════════════════════════════════════════"
echo ""

# Platform detection
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "Platform: $OS $ARCH"

# Shell detection
CURRENT_SHELL="$(basename "$SHELL" 2>/dev/null || echo "unknown")"
echo "Shell: $CURRENT_SHELL"
echo ""

# Check for just
if ! command -v just >/dev/null 2>&1; then
    echo "just (command runner) is required but not installed."
    echo ""
    case "$OS" in
        Linux)
            if command -v cargo >/dev/null 2>&1; then
                echo "Installing just via cargo..."
                cargo install just
            elif command -v brew >/dev/null 2>&1; then
                echo "Installing just via Homebrew..."
                brew install just
            else
                echo "Install just from: https://just.systems/man/en/installation.html"
                exit 1
            fi
            ;;
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                echo "Installing just via Homebrew..."
                brew install just
            else
                echo "Install Homebrew first: https://brew.sh"
                echo "Then: brew install just"
                exit 1
            fi
            ;;
        *)
            echo "Install just from: https://just.systems/man/en/installation.html"
            exit 1
            ;;
    esac
    echo ""
fi

# Submodules: tools/affinescript (compiler) and tools/nextgen-databases
# (parent of verisimdb, built by containers/selur-compose.toml). Container
# bring-up will fail to resolve VeriSimDB's build context without this.
if [ -f .gitmodules ]; then
    echo "Initialising git submodules..."
    git submodule update --init --recursive
    echo ""
fi

echo "Running diagnostics..."
# `just doctor` exits non-zero on any missing tool; treat as advisory so
# the service-install handoff below still runs.
just doctor || echo "  (doctor reported warnings — continuing)"

# ─── Background-service install (OS-aware) ────────────────────────────────
# Replaces the "burble launches and pops a terminal" experience with proper
# per-OS service units. On WSL we also print the exact PowerShell command
# the user needs to run on the *Windows host* for the UDP forwarder — we
# can't elevate Windows from Linux, but we can hand it off cleanly.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
detect_target() {
    case "$(uname -s)" in
        Linux*)  if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl"
                 else echo "linux"; fi ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}
TARGET="$(detect_target)"

preflight_warn() {
    local missing=()
    case "$TARGET" in
        linux|wsl)
            command -v systemctl >/dev/null || missing+=("systemctl (systemd)")
            command -v mix       >/dev/null || missing+=("mix (Elixir)")
            command -v deno      >/dev/null || missing+=("deno")
            ;;
        macos)
            command -v launchctl >/dev/null || missing+=("launchctl")
            command -v mix       >/dev/null || missing+=("mix (Elixir)")
            command -v deno      >/dev/null || missing+=("deno")
            ;;
    esac
    if [ "${#missing[@]}" -gt 0 ]; then
        echo ""
        echo "  Preflight warnings (service will install but may fail to start):"
        for m in "${missing[@]}"; do echo "    · missing: $m"; done
    fi
}

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Background-service install ($TARGET)"
echo "═══════════════════════════════════════════════════"
preflight_warn

INSTALL_SERVICE="${BURBLE_INSTALL_SERVICE:-}"
INSTALL_MODE="${BURBLE_INSTALL_MODE:-}"   # system | user
if [ -z "$INSTALL_SERVICE" ] && [ -t 0 ]; then
    read -rp "Install Burble as a background service now? (no terminal will pop up at launch) [Y/n] " ans
    case "${ans:-Y}" in Y|y|"") INSTALL_SERVICE=yes ;; *) INSTALL_SERVICE=no ;; esac
fi

if [ "$INSTALL_SERVICE" = "yes" ] && [ "$TARGET" != "macos" ] && [ -z "$INSTALL_MODE" ] && [ -t 0 ]; then
    echo ""
    echo "  Install mode:"
    echo "    [S] system unit (needs sudo, binds udp/9 cleanly) — recommended"
    echo "    [u] --user unit (no sudo, but udp/9 won't bind without --setcap)"
    read -rp "  Choice [S/u] " mode
    case "${mode:-S}" in u|U) INSTALL_MODE=user ;; *) INSTALL_MODE=system ;; esac
fi

if [ "$INSTALL_SERVICE" = "yes" ]; then
    install_args=("install")
    [ "$INSTALL_MODE" = user ] && install_args+=("--user")
    [ "$INSTALL_MODE" = user ] && command -v setcap >/dev/null 2>&1 && install_args+=("--setcap")
    "$REPO_DIR/scripts/install-service.sh" "${install_args[@]}" || {
        echo ""
        echo "  Service install failed. You can retry with: just service-install"
    }
else
    echo "  Skipped. Install later with: just service-install"
fi

if [ "$TARGET" = "wsl" ]; then
    # UNC path to this repo from the Windows side — works on all recent WSL
    # builds; \\wsl.localhost\ replaced \\wsl$\ in 2022+ but both still
    # resolve. Use the newer form.
    DISTRO="${WSL_DISTRO_NAME:-$(wslpath -w / 2>/dev/null | sed -n 's#^\\\\wsl[.$]localhost\\\([^\\]*\\\).*#\1#p')}"
    DISTRO="${DISTRO:-Ubuntu}"
    WIN_REPO="\\\\wsl.localhost\\${DISTRO}${REPO_DIR}"
    echo ""
    echo "  ─── Windows-host step (do this from the Windows side) ──────────"
    echo "  You're in WSL2. Inbound Bolt udp/7373+9 still needs to be"
    echo "  forwarded from the Windows host. Open an ELEVATED PowerShell"
    echo "  and run:"
    echo ""
    echo "      Set-ExecutionPolicy -Scope Process -Force Bypass"
    echo "      & '${WIN_REPO}\\scripts\\wsl-bolt-udp-forward.ps1' -Install -Firewall"
    echo ""
    echo "  Or, equivalently, from this WSL shell (will pop a UAC prompt):"
    echo ""
    echo "      powershell.exe -Command \"Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','${WIN_REPO}\\scripts\\wsl-bolt-udp-forward.ps1','-Install','-Firewall'\""
    echo ""
    echo "  After that completes, this WSL distro will be fully reachable"
    echo "  on udp/7373 from the LAN."
fi

echo ""
echo "Setup complete. Run 'just help-me' for common workflows."
