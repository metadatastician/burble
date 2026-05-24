#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# tests/install/roundtrip-macos.sh — full install→activate→uninstall
# cycle for the macOS launchd LaunchAgent path.
#
# Strategy mirrors roundtrip-linux.sh: stub mix/deno on PATH so the
# LaunchAgent's program survives long enough to be Active before we
# tear it down. The stub PATH is baked into the rendered plist via
# pre-rendering — launchd doesn't import the user shell's environment.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="$REPO_DIR/tests/install/stubs"
TMPLOG="$(mktemp -t burble-roundtrip-macos.XXXXXX.log)"
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
    # Undo the PATH-injection hack if we used it.
    git -C "$REPO_DIR" checkout -- assets/services/*.plist 2>/dev/null || true
}

# ─── Preflight ────────────────────────────────────────────────────────────
hdr "Preflight"
[ "$(uname -s)" = Darwin ] || { echo "macOS only"; exit 2; }
command -v launchctl >/dev/null || { echo "launchctl required"; exit 2; }
[ -x "$STUBS/mix" ] && [ -x "$STUBS/deno" ] || { echo "missing stubs/"; exit 2; }
pass "launchctl present, stubs ready"

# ─── Inject stub PATH into the plists ─────────────────────────────────────
# launchd ignores the user shell's PATH, so add EnvironmentVariables.PATH
# directly into the plist source. The render step in install-service.sh
# will copy it verbatim into ~/Library/LaunchAgents/.
hdr "Patch plists with stub PATH"
patch_plist() {
    local plist="$1"
    if grep -q '<key>PATH</key>' "$plist"; then return 0; fi
    # Insert PATH=… into the EnvironmentVariables dict. If the dict
    # doesn't exist, create one.
    if grep -q '<key>EnvironmentVariables</key>' "$plist"; then
        # Append <key>PATH</key>… inside the existing dict.
        sed -i.bak "s|<key>EnvironmentVariables</key>\\
  <dict>|<key>EnvironmentVariables</key>\\
  <dict>\\
    <key>PATH</key>\\
    <string>$STUBS:/usr/bin:/bin</string>|" "$plist"
    else
        # Insert before </dict> at the top level.
        sed -i.bak "/<\/dict>/i\\
  <key>EnvironmentVariables</key>\\
  <dict>\\
    <key>PATH</key>\\
    <string>$STUBS:/usr/bin:/bin</string>\\
  </dict>" "$plist"
    fi
}
for p in "$REPO_DIR/assets/services/com.hyperpolymath.burble.plist" \
         "$REPO_DIR/assets/services/com.hyperpolymath.burble.ai-bridge.plist"; do
    patch_plist "$p"
    plutil -lint "$p" >/dev/null 2>&1 && pass "$(basename "$p") still valid after patch" \
                                       || fail "$(basename "$p") invalid after patch"
done

# ─── Install ──────────────────────────────────────────────────────────────
hdr "Install"
if "$REPO_DIR/scripts/install-service.sh" install >>"$TMPLOG" 2>&1; then
    pass "install exit 0"
else
    fail "install exit $?"
    tail -20 "$TMPLOG" | sed 's/^/      /'
fi

sleep 2

# ─── Assert loaded ────────────────────────────────────────────────────────
hdr "Assert loaded"
for label in com.hyperpolymath.burble com.hyperpolymath.burble.ai-bridge; do
    if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
        pass "$label loaded in gui/$UID"
    else
        fail "$label not loaded"
        launchctl print "gui/$UID/$label" 2>&1 | head -10 | sed 's/^/      /'
    fi
done

# ─── Uninstall ────────────────────────────────────────────────────────────
hdr "Uninstall"
if "$REPO_DIR/scripts/install-service.sh" uninstall >>"$TMPLOG" 2>&1; then
    pass "uninstall exit 0"
else
    fail "uninstall exit $?"
fi

sleep 1

# ─── Assert gone ──────────────────────────────────────────────────────────
hdr "Assert removed"
for label in com.hyperpolymath.burble com.hyperpolymath.burble.ai-bridge; do
    if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
        fail "$label still loaded after uninstall"
    else
        pass "$label gone"
    fi
    plist="$HOME/Library/LaunchAgents/$label.plist"
    if [ -f "$plist" ]; then
        fail "$plist still on disk"
    else
        pass "$plist removed from disk"
    fi
done

# ─── Summary ──────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
printf 'Results: \033[0;32m%d pass\033[0m, \033[0;31m%d fail\033[0m\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
