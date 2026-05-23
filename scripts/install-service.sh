#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# install-service.sh — install Burble as a background service so it stops
# popping a terminal window every time you launch it.
#
# What gets installed (per platform):
#   Linux         systemd --user units: burble.service + burble-ai-bridge.service
#                 (`systemctl --user enable --now burble{,-ai-bridge}.service`)
#   macOS         launchd LaunchAgents in ~/Library/LaunchAgents/
#                 (`launchctl bootstrap gui/$UID …`)
#   WSL/Windows   For the WSL2 NAT case, registers a hidden scheduled task on
#                 the Windows host via scripts/wsl-bolt-udp-forward.ps1 -Install
#                 (must be re-run from PowerShell on the host side itself —
#                 we just print the exact command here).
#
# Usage:
#   scripts/install-service.sh install         # install + start
#   scripts/install-service.sh uninstall       # stop + remove
#   scripts/install-service.sh start | stop | restart | status | logs
#   scripts/install-service.sh install --no-ai-bridge   # just the Elixir server

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-help}"; shift || true

INCLUDE_AI_BRIDGE=true
for arg in "$@"; do
    case "$arg" in
        --no-ai-bridge) INCLUDE_AI_BRIDGE=false ;;
    esac
done

log()  { printf '\033[0;32m[burble-service]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[burble-service]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[burble-service]\033[0m %s\n' "$*" >&2; }

detect_os() {
    case "$(uname -s)" in
        Linux*)  if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl"
                 else echo "linux"; fi ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}
OS="$(detect_os)"

# ─── Linux (systemd --user) ─────────────────────────────────────────────────
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
LINUX_UNITS=("burble.service")
$INCLUDE_AI_BRIDGE && LINUX_UNITS+=("burble-ai-bridge.service")

linux_install() {
    command -v systemctl >/dev/null || { err "systemctl not found — non-systemd Linux unsupported."; exit 1; }
    mkdir -p "$SYSTEMD_USER_DIR"
    for unit in "${LINUX_UNITS[@]}"; do
        sed "s|@REPO_DIR@|$REPO_DIR|g" "$REPO_DIR/assets/services/$unit" \
            > "$SYSTEMD_USER_DIR/$unit"
        log "  + wrote $SYSTEMD_USER_DIR/$unit"
    done
    systemctl --user daemon-reload
    for unit in "${LINUX_UNITS[@]}"; do
        systemctl --user enable --now "$unit"
        log "  + enabled+started $unit"
    done
    log "✓ Burble is now a systemd --user service. No terminal window will pop up."
    log "  Logs:   journalctl --user -u burble -f"
    log "  Status: scripts/install-service.sh status"
}

linux_uninstall() {
    for unit in "${LINUX_UNITS[@]}"; do
        systemctl --user disable --now "$unit" 2>/dev/null || true
        rm -f "$SYSTEMD_USER_DIR/$unit" && log "  - removed $SYSTEMD_USER_DIR/$unit"
    done
    systemctl --user daemon-reload 2>/dev/null || true
    log "✓ Burble service removed."
}

linux_ctl() { for unit in "${LINUX_UNITS[@]}"; do systemctl --user "$1" "$unit" || true; done; }
linux_logs() { journalctl --user -u burble -u burble-ai-bridge -f; }

# ─── macOS (launchd LaunchAgents) ───────────────────────────────────────────
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
MACOS_AGENTS=("com.hyperpolymath.burble.plist")
$INCLUDE_AI_BRIDGE && MACOS_AGENTS+=("com.hyperpolymath.burble.ai-bridge.plist")

macos_install() {
    mkdir -p "$LAUNCHD_DIR"
    for plist in "${MACOS_AGENTS[@]}"; do
        sed "s|@REPO_DIR@|$REPO_DIR|g" "$REPO_DIR/assets/services/$plist" \
            > "$LAUNCHD_DIR/$plist"
        launchctl bootstrap "gui/$UID" "$LAUNCHD_DIR/$plist" 2>/dev/null \
          || launchctl load -w "$LAUNCHD_DIR/$plist"
        log "  + loaded $plist"
    done
    log "✓ Burble loaded as a launchd LaunchAgent."
    log "  Logs:   tail -F /tmp/burble.out.log /tmp/burble.err.log"
}

macos_uninstall() {
    for plist in "${MACOS_AGENTS[@]}"; do
        local label="${plist%.plist}"
        launchctl bootout "gui/$UID/$label" 2>/dev/null \
          || launchctl unload "$LAUNCHD_DIR/$plist" 2>/dev/null || true
        rm -f "$LAUNCHD_DIR/$plist" && log "  - removed $plist"
    done
    log "✓ Burble LaunchAgents removed."
}

macos_ctl() {
    for plist in "${MACOS_AGENTS[@]}"; do
        local label="${plist%.plist}"
        case "$1" in
            start)   launchctl kickstart -k "gui/$UID/$label" ;;
            stop)    launchctl kill SIGTERM "gui/$UID/$label" ;;
            restart) launchctl kickstart -k "gui/$UID/$label" ;;
            status)  launchctl print "gui/$UID/$label" | sed -n '1,12p' ;;
        esac
    done
}
macos_logs() { tail -F /tmp/burble.out.log /tmp/burble.err.log /tmp/burble-ai-bridge.out.log /tmp/burble-ai-bridge.err.log 2>/dev/null; }

# ─── WSL / Windows host (Bolt UDP forwarder only) ───────────────────────────
wsl_install() {
    cat <<'EOF'
You are inside WSL. The Burble Elixir server still runs here as a regular
process, but inbound Bolt udp/7373+9 has to be forwarded from the Windows
host. Run this command in a *Windows* PowerShell:

  cd \\wsl$\Ubuntu\home\user\burble    (or wherever you cloned)
  .\scripts\wsl-bolt-udp-forward.ps1 -Install            # windowless, runs at logon

For an elevated shell, add inbound firewall rules too:
  .\scripts\wsl-bolt-udp-forward.ps1 -Install -Firewall

Then, on the WSL side, install the Elixir server as a systemd --user unit:
  scripts/install-service.sh install        # this is what installs the server
EOF
    # Still run the Linux install for the Elixir server inside WSL.
    log "Installing the WSL-side Elixir service now..."
    linux_install
}

# ─── Dispatch ───────────────────────────────────────────────────────────────
case "$ACTION" in
    install)
        case "$OS" in
            linux)   linux_install ;;
            macos)   macos_install ;;
            wsl)     wsl_install ;;
            *)       err "Unsupported OS: $(uname -s)"; exit 1 ;;
        esac ;;
    uninstall|remove)
        case "$OS" in
            linux|wsl) linux_uninstall ;;
            macos)     macos_uninstall ;;
        esac ;;
    start|stop|restart|status)
        case "$OS" in
            linux|wsl) linux_ctl "$ACTION" ;;
            macos)     macos_ctl "$ACTION" ;;
        esac ;;
    logs)
        case "$OS" in
            linux|wsl) linux_logs ;;
            macos)     macos_logs ;;
        esac ;;
    help|--help|-h|"")
        sed -n '2,22p' "$0" ; exit 0 ;;
    *)
        err "Unknown action: $ACTION"
        sed -n '2,22p' "$0" ; exit 2 ;;
esac
