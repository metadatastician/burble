#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# tests/install/roundtrip-linux.sh — full install→activate→stop→uninstall
# cycle for the Linux --user systemd path.
#
# Strategy:
#   * stub `mix` and `deno` with a script that sleeps forever, so the
#     unit's ExecStart succeeds without needing the Elixir/Deno toolchain
#   * inject the stub dir into the systemd --user instance's PATH via
#     `systemctl --user import-environment`
#   * install via scripts/install-service.sh install --user
#   * assert both units reach `active`
#   * uninstall, assert both are gone
#
# Safe-ish locally: it WILL mutate ~/.config/systemd/user/ and start
# burble.service in your user-systemd session for the duration of the
# test. The uninstall step undoes both even on failure (trap EXIT).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="$REPO_DIR/tests/install/stubs"
TMPLOG="$(mktemp -t burble-roundtrip-linux.XXXXXX.log)"
# shellcheck disable=SC2154  # ec is assigned inside the trap body
trap 'ec=$?; cleanup; exit $ec' EXIT

PASS=0; FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
hdr()  { printf '\n\033[1;36m── %s ──\033[0m\n' "$1"; }

cleanup() {
    echo
    hdr "Cleanup"
    "$REPO_DIR/scripts/install-service.sh" uninstall >>"$TMPLOG" 2>&1 || true
    rm -f "$TMPLOG"
}

# ─── Preflight ────────────────────────────────────────────────────────────
hdr "Preflight"
command -v systemctl >/dev/null || { echo "systemctl required"; exit 2; }
[ -x "$STUBS/mix" ] && [ -x "$STUBS/deno" ] || { echo "missing stubs/"; exit 2; }

# Need a user systemd session. `systemctl --user` requires either an
# interactive login (which CI lacks) or `loginctl enable-linger`. If we
# don't have a working bus, abort with a clear message.
CUR_USER="${USER:-$(id -un)}"
if ! systemctl --user is-system-running >/dev/null 2>&1 && \
   ! systemctl --user list-units >/dev/null 2>&1; then
    echo "No working systemd --user instance for $CUR_USER."
    echo "On CI: sudo loginctl enable-linger $CUR_USER && sleep 2"
    echo "On a dev box, log in interactively or run 'systemctl --user start default.target'"
    exit 2
fi
pass "systemd --user instance reachable"

# ─── Inject stub PATH into the user-systemd environment ───────────────────
hdr "Stub PATH"
export PATH="$STUBS:$PATH"
systemctl --user import-environment PATH
pass "PATH=$STUBS:... imported into user-systemd env"

# ─── Install ──────────────────────────────────────────────────────────────
hdr "Install (--user)"
if "$REPO_DIR/scripts/install-service.sh" install --user >>"$TMPLOG" 2>&1; then
    pass "install --user exit 0"
else
    fail "install --user exit $?"
    tail -20 "$TMPLOG" | sed 's/^/      /'
fi

# Give systemd a moment to actually start the services.
sleep 2

# ─── Assert active ────────────────────────────────────────────────────────
hdr "Assert active"
for unit in burble.service burble-ai-bridge.service; do
    state=$(systemctl --user is-active "$unit" 2>/dev/null || echo unknown)
    if [ "$state" = "active" ]; then
        pass "$unit is active"
    else
        fail "$unit state=$state (expected active)"
        systemctl --user status "$unit" --no-pager 2>&1 | sed 's/^/      /' | head -15
    fi
done

# ─── Assert restart-on-failure works ──────────────────────────────────────
hdr "Restart-on-failure"
# Kill the burble.service main process; systemd should respawn it
# within RestartSec=5 because of Restart=on-failure.
mainpid=$(systemctl --user show -p MainPID --value burble.service 2>/dev/null)
if [ -n "$mainpid" ] && [ "$mainpid" != "0" ]; then
    kill -9 "$mainpid" 2>/dev/null || true
    sleep 8
    newpid=$(systemctl --user show -p MainPID --value burble.service 2>/dev/null)
    if [ -n "$newpid" ] && [ "$newpid" != "0" ] && [ "$newpid" != "$mainpid" ]; then
        pass "burble.service respawned after kill (pid $mainpid -> $newpid)"
    else
        fail "burble.service did not respawn (pid still $newpid)"
    fi
else
    fail "burble.service has no MainPID — cannot test restart"
fi

# ─── Uninstall ────────────────────────────────────────────────────────────
hdr "Uninstall"
if "$REPO_DIR/scripts/install-service.sh" uninstall >>"$TMPLOG" 2>&1; then
    pass "uninstall exit 0"
else
    fail "uninstall exit $?"
    tail -20 "$TMPLOG" | sed 's/^/      /'
fi

sleep 1

# ─── Assert gone ──────────────────────────────────────────────────────────
hdr "Assert removed"
for unit in burble.service burble-ai-bridge.service; do
    if [ -f "$HOME/.config/systemd/user/$unit" ]; then
        fail "$unit file still present after uninstall"
    else
        pass "$unit file removed"
    fi
done

# ─── Summary ──────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
printf 'Results: \033[0;32m%d pass\033[0m, \033[0;31m%d fail\033[0m\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
