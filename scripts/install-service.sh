#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# install-service.sh — install Burble as a background service so it stops
# popping a terminal window every time you launch it.
#
# What gets installed (per platform):
#   Linux         systemd *system* unit by default (sudo): burble.service +
#                 burble-ai-bridge.service in /etc/systemd/system/. The
#                 system unit is required to bind udp/9 (privileged port)
#                 via AmbientCapabilities=CAP_NET_BIND_SERVICE — systemd
#                 --user instances cannot grant capabilities.
#                 Pass --user to install as a user unit instead (no sudo,
#                 but udp/9 won't bind without --setcap).
#   macOS         launchd LaunchAgents in ~/Library/LaunchAgents/
#                 (`launchctl bootstrap gui/$UID …`)
#   WSL/Windows   For the WSL2 NAT case, registers a true Windows Service
#                 on the host via scripts/wsl-bolt-udp-forward.ps1 -Install
#                 (must be re-run from elevated PowerShell — we just print
#                 the exact command here).
#
# Usage:
#   scripts/install-service.sh install                  # system unit (sudo)
#   scripts/install-service.sh install --user           # user unit, no sudo
#   scripts/install-service.sh install --setcap         # also setcap BEAM for udp/9
#   scripts/install-service.sh install --no-ai-bridge   # just the Elixir server
#   scripts/install-service.sh uninstall                # stop + remove
#   scripts/install-service.sh start | stop | restart | status | logs

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-help}"; shift || true

INCLUDE_AI_BRIDGE=true
LINUX_MODE=system           # system | user
DO_SETCAP=false
for arg in "$@"; do
    case "$arg" in
        --no-ai-bridge) INCLUDE_AI_BRIDGE=false ;;
        --user)         LINUX_MODE=user ;;
        --system)       LINUX_MODE=system ;;
        --setcap)       DO_SETCAP=true ;;
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

# ─── Linux (systemd) ───────────────────────────────────────────────────────
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SYSTEMD_SYS_DIR="/etc/systemd/system"

linux_units() {
    # Echoes the list of unit filenames for the current mode/options.
    local units=("burble.service")
    $INCLUDE_AI_BRIDGE && units+=("burble-ai-bridge.service")
    printf '%s\n' "${units[@]}"
}

# Locate the active BEAM binary so we can setcap it. Pattern lifted from
# the Justfile's `_erl-include` recipe.
locate_beam() {
    command -v erl >/dev/null 2>&1 || return 1
    local root vsn
    root=$(erl -noshell -eval 'io:format("~s",[code:root_dir()]),halt().' 2>/dev/null) || return 1
    vsn=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(version)]),halt().' 2>/dev/null) || return 1
    local beam="$root/erts-$vsn/bin/beam.smp"
    [ -f "$beam" ] && { echo "$beam"; return 0; }
    return 1
}

setcap_beam() {
    local beam; beam=$(locate_beam) || {
        warn "Could not locate beam.smp via erl(1) — install Erlang/Elixir first, then re-run with --setcap."
        return 1
    }
    log "  · setcap CAP_NET_BIND_SERVICE+eip on $beam"
    sudo setcap 'cap_net_bind_service=+eip' "$beam"
    log "  ✓ BEAM can now bind privileged ports without root. Re-runs of erl after"
    log "    an Erlang reinstall will silently drop this — re-run --setcap if needed."
}

# Render a unit file: substitute @REPO_DIR@ and @USER@. For --user mode,
# also strip User=/Group= (forbidden in user units) and rewrite WantedBy.
render_unit() {
    local src="$1" dst="$2"
    if [ "$LINUX_MODE" = user ]; then
        sed -e "s|@REPO_DIR@|$REPO_DIR|g" \
            -e "/^User=/d" -e "/^Group=/d" \
            -e "s|^WantedBy=multi-user.target|WantedBy=default.target|" \
            -e "/^AmbientCapabilities=/d" -e "/^CapabilityBoundingSet=/d" \
            "$src" > "$dst"
    else
        sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@USER@|$USER|g" \
            "$src" > "$dst"
    fi
}

linux_install() {
    command -v systemctl >/dev/null || { err "systemctl not found — non-systemd Linux unsupported."; exit 1; }
    local units; mapfile -t units < <(linux_units)

    if [ "$LINUX_MODE" = system ]; then
        log "Installing as system unit (sudo) — required for udp/9 privileged bind."
        sudo mkdir -p "$SYSTEMD_SYS_DIR"
        for unit in "${units[@]}"; do
            local tmp; tmp=$(mktemp)
            render_unit "$REPO_DIR/assets/services/$unit" "$tmp"
            sudo install -m 0644 "$tmp" "$SYSTEMD_SYS_DIR/$unit"
            rm -f "$tmp"
            log "  + wrote $SYSTEMD_SYS_DIR/$unit"
        done
        sudo systemctl daemon-reload
        for unit in "${units[@]}"; do
            sudo systemctl enable --now "$unit"
            log "  + enabled+started $unit"
        done
        log "✓ Burble installed as a systemd system service (user=$USER)."
        log "  Logs:   journalctl -u burble -f"
    else
        log "Installing as systemd --user unit (no sudo)."
        mkdir -p "$SYSTEMD_USER_DIR"
        for unit in "${units[@]}"; do
            render_unit "$REPO_DIR/assets/services/$unit" "$SYSTEMD_USER_DIR/$unit"
            log "  + wrote $SYSTEMD_USER_DIR/$unit"
        done
        systemctl --user daemon-reload
        for unit in "${units[@]}"; do
            systemctl --user enable --now "$unit"
            log "  + enabled+started $unit"
        done
        log "✓ Burble installed as a systemd --user service."
        log "  Logs:   journalctl --user -u burble -f"
        warn "  Note: udp/9 (Bolt WoL-compat poke) won't bind in --user mode without"
        warn "        capabilities. Re-run with --setcap, or use the system install."
    fi

    $DO_SETCAP && setcap_beam || true
}

linux_uninstall() {
    local units; mapfile -t units < <(linux_units)
    # Try BOTH locations — handles the case where the user installed one
    # mode previously and is now removing without remembering which.
    for unit in "${units[@]}"; do
        if [ -f "$SYSTEMD_SYS_DIR/$unit" ]; then
            sudo systemctl disable --now "$unit" 2>/dev/null || true
            sudo rm -f "$SYSTEMD_SYS_DIR/$unit" && log "  - removed $SYSTEMD_SYS_DIR/$unit"
        fi
        if [ -f "$SYSTEMD_USER_DIR/$unit" ]; then
            systemctl --user disable --now "$unit" 2>/dev/null || true
            rm -f "$SYSTEMD_USER_DIR/$unit" && log "  - removed $SYSTEMD_USER_DIR/$unit"
        fi
    done
    sudo systemctl daemon-reload 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    log "✓ Burble service removed."
}

# linux_ctl/logs auto-detect whether we're driving the system or user
# instance based on which one is registered.
linux_each_active() {
    local units; mapfile -t units < <(linux_units)
    for unit in "${units[@]}"; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            echo "system $unit"
        elif systemctl --user cat "$unit" >/dev/null 2>&1; then
            echo "user $unit"
        fi
    done
}
linux_ctl() {
    while read -r scope unit; do
        [ -z "${unit:-}" ] && continue
        if [ "$scope" = system ]; then sudo systemctl "$1" "$unit" || true
        else                            systemctl --user "$1" "$unit" || true
        fi
    done < <(linux_each_active)
}
linux_logs() {
    # Show whichever scope has units installed.
    if systemctl cat burble.service >/dev/null 2>&1; then
        sudo journalctl -u burble -u burble-ai-bridge -f
    else
        journalctl --user -u burble -u burble-ai-bridge -f
    fi
}

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
        sed -n '2,28p' "$0" ; exit 0 ;;
    *)
        err "Unknown action: $ACTION"
        sed -n '2,28p' "$0" ; exit 2 ;;
esac
