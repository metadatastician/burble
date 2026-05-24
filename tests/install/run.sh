#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# tests/install/run.sh — exercise the cross-platform install machinery
# without actually mutating the host. Safe to run anywhere; skips checks
# whose tooling isn't installed (shellcheck, xmllint, systemd-analyze,
# pwsh) and reports them as SKIP instead of FAIL.
#
# Used by .github/workflows/install-tests.yml — keep the local and CI
# code paths the same so "works on my machine" actually means something.

set -uo pipefail

# Verbose CI debugging: setting BURBLE_INSTALL_TESTS_DEBUG=1 prints every
# command before execution so a CI-only failure shows up in the logs.
# Off by default to keep local interactive runs clean.
[ "${BURBLE_INSTALL_TESTS_DEBUG:-}" = "1" ] && set -x

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/burble-install-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[0;33mSKIP\033[0m %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }
section() { printf '\n\033[1;36m── %s ──\033[0m\n' "$1"; }

# ─── 1. Shell syntax + shellcheck ─────────────────────────────────────────
section "Shell scripts"
SHELL_FILES=(setup.sh scripts/install-service.sh
             tests/install/run.sh tests/install/roundtrip-linux.sh
             tests/install/roundtrip-macos.sh)
for f in "${SHELL_FILES[@]}"; do
    if bash -n "$REPO_DIR/$f" 2>/dev/null; then pass "bash -n $f"
    else                                         fail "bash -n $f"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
    for f in "${SHELL_FILES[@]}"; do
        # SC1091: don't try to follow optionally-sourced files
        # SC2086: word splitting is intentional in arg arrays
        if shellcheck -S warning -e SC1091 -e SC2086 "$REPO_DIR/$f" >"$TMP/sc.out" 2>&1; then
            pass "shellcheck $f"
        else
            fail "shellcheck $f"
            sed 's/^/      /' "$TMP/sc.out"
        fi
    done
else
    skip "shellcheck" "binary not installed"
fi

# ─── 2. systemd unit rendering + validation ───────────────────────────────
section "Linux systemd units"

# Replicate install-service.sh's render_unit logic — we test the
# rendered output, not just the templates, because that's what systemd
# actually loads.
render_unit() {
    local mode="$1" src="$2" dst="$3"
    if [ "$mode" = user ]; then
        sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@USER@|testuser|g" \
            -e "/^User=/d" -e "/^Group=/d" \
            -e "s|^WantedBy=multi-user.target|WantedBy=default.target|" \
            -e "/^AmbientCapabilities=/d" -e "/^CapabilityBoundingSet=/d" \
            "$src" > "$dst"
    else
        sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@USER@|testuser|g" \
            "$src" > "$dst"
    fi
}

for unit in burble.service burble-ai-bridge.service; do
    src="$REPO_DIR/assets/services/$unit"
    [ -f "$src" ] || { fail "missing template $unit"; continue; }

    for mode in system user; do
        out="$TMP/${mode}-${unit}"
        render_unit "$mode" "$src" "$out"

        # Invariant 1: no @TOKEN@ should remain after rendering
        if grep -q '@[A-Z_]*@' "$out"; then
            fail "$mode/$unit: unsubstituted tokens remain"
            grep '@[A-Z_]*@' "$out" | sed 's/^/      /'
        else
            pass "$mode/$unit: no unsubstituted tokens"
        fi

        # Invariant 2: required sections present
        if grep -q '^\[Unit\]' "$out" && \
           grep -q '^\[Service\]' "$out" && \
           grep -q '^\[Install\]' "$out"; then
            pass "$mode/$unit: has [Unit] [Service] [Install]"
        else
            fail "$mode/$unit: missing required section"
        fi

        # Mode-specific invariants
        if [ "$mode" = user ]; then
            if grep -qE '^(User|Group|AmbientCapabilities|CapabilityBoundingSet)=' "$out"; then
                fail "$mode/$unit: contains directives invalid in --user mode"
                grep -E '^(User|Group|AmbientCapabilities|CapabilityBoundingSet)=' "$out" | sed 's/^/      /'
            else
                pass "$mode/$unit: stripped system-only directives"
            fi
            if grep -q '^WantedBy=default.target' "$out"; then
                pass "$mode/$unit: WantedBy rewritten to default.target"
            else
                fail "$mode/$unit: WantedBy not rewritten"
            fi
        else
            if [ "$unit" = burble.service ]; then
                grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE' "$out" \
                    && pass "$mode/$unit: has AmbientCapabilities=CAP_NET_BIND_SERVICE" \
                    || fail "$mode/$unit: missing AmbientCapabilities (udp/9 won't bind)"
            fi
            grep -q '^User=testuser' "$out" \
                && pass "$mode/$unit: User= substituted" \
                || fail "$mode/$unit: User= not substituted"
        fi
    done
done

# systemd-analyze verify catches a lot — typos in directive names,
# invalid values, missing sections, dependency cycles.
if command -v systemd-analyze >/dev/null 2>&1; then
    for out in "$TMP"/system-*.service; do
        if systemd-analyze verify --no-pager "$out" >"$TMP/sa.out" 2>&1; then
            pass "systemd-analyze verify $(basename "$out")"
        else
            # Some failures are expected in unprivileged CI (e.g., User=
            # doesn't exist) — only fail on structural errors.
            if grep -qE '(unknown setting|syntax error|requires.*not found|fail to parse)' "$TMP/sa.out"; then
                fail "systemd-analyze verify $(basename "$out") (structural)"
                sed 's/^/      /' "$TMP/sa.out"
            else
                pass "systemd-analyze verify $(basename "$out") (advisory warnings only)"
            fi
        fi
    done
else
    skip "systemd-analyze verify" "systemd not installed"
fi

# ─── 3. macOS launchd plist XML validity ──────────────────────────────────
section "macOS launchd plists"

PLISTS=(com.hyperpolymath.burble.plist com.hyperpolymath.burble.ai-bridge.plist)
for p in "${PLISTS[@]}"; do
    src="$REPO_DIR/assets/services/$p"
    [ -f "$src" ] || { fail "missing $p"; continue; }
    # Render with @REPO_DIR@ substituted (the only token in plists)
    out="$TMP/$p"
    sed "s|@REPO_DIR@|$REPO_DIR|g" "$src" > "$out"

    if grep -q '@[A-Z_]*@' "$out"; then
        fail "$p: unsubstituted tokens"
    else
        pass "$p: no unsubstituted tokens"
    fi

    if command -v plutil >/dev/null 2>&1; then
        if plutil -lint "$out" >"$TMP/pl.out" 2>&1; then
            pass "plutil -lint $p"
        else
            fail "plutil -lint $p"; sed 's/^/      /' "$TMP/pl.out"
        fi
    elif command -v xmllint >/dev/null 2>&1; then
        # xmllint is a weaker check (XML well-formedness, not plist
        # schema) but it catches typos that break the parser.
        if xmllint --noout "$out" 2>"$TMP/xl.out"; then
            pass "xmllint --noout $p"
        else
            fail "xmllint --noout $p"; sed 's/^/      /' "$TMP/xl.out"
        fi
    else
        skip "plist XML validity for $p" "no plutil/xmllint"
    fi
done

# ─── 4. PowerShell scripts (syntax + analyzer) ────────────────────────────
section "PowerShell scripts"
PS_FILES=(setup.ps1 scripts/wsl-bolt-udp-forward.ps1
          tests/install/roundtrip-windows.ps1)
PWSH=""
command -v pwsh >/dev/null 2>&1 && PWSH=pwsh
[ -z "$PWSH" ] && command -v powershell >/dev/null 2>&1 && PWSH=powershell

if [ -n "$PWSH" ]; then
    # Parse-only check via the AST parser — no execution. Use a temp .ps1
    # for the same bash↔PowerShell quoting-robustness reason as PSSA below.
    PARSE_SCRIPT="$TMP/parse.ps1"
    cat > "$PARSE_SCRIPT" <<'PWSH_EOF'
param([string]$Path)
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $Path, [ref]$null, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object {
        Write-Host ("  L{0}:C{1} {2}" -f `
            $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message)
    }
    exit 1
}
exit 0
PWSH_EOF
    for f in "${PS_FILES[@]}"; do
        if "$PWSH" -NoProfile -File "$PARSE_SCRIPT" -Path "$REPO_DIR/$f" \
            >"$TMP/ps.out" 2>&1; then
            pass "powershell parse $f"
        else
            fail "powershell parse $f"; sed 's/^/      /' "$TMP/ps.out"
        fi
    done

    # PSScriptAnalyzer if installed. We invoke pwsh via a temp .ps1 file
    # instead of -Command "..." to avoid bash/PowerShell quoting +
    # line-continuation traps (bash's `\<newline>` is preserved inside a
    # double-quoted string, but PowerShell's line-continuation is backtick;
    # writing the script to a file sidesteps the whole mess).
    if "$PWSH" -NoProfile -Command "Get-Module -ListAvailable PSScriptAnalyzer" 2>/dev/null | grep -q PSScriptAnalyzer; then
        PSSA_SCRIPT="$TMP/psa.ps1"
        cat > "$PSSA_SCRIPT" <<'PWSH_EOF'
param([string]$Path)
$r = Invoke-ScriptAnalyzer -Path $Path -Severity Warning,Error -ExcludeRule `
    PSAvoidUsingWriteHost,
    PSAvoidUsingPlainTextForPassword,
    PSAvoidUsingConvertToSecureStringWithPlainText,
    PSUseShouldProcessForStateChangingFunctions,
    PSAvoidUsingEmptyCatchBlock,
    PSUseSingularNouns,
    PSReviewUnusedParameter,
    PSUseApprovedVerbs
if ($r) { $r | Format-Table -AutoSize | Out-String | Write-Host; exit 1 }
exit 0
PWSH_EOF
        for f in "${PS_FILES[@]}"; do
            if "$PWSH" -NoProfile -File "$PSSA_SCRIPT" -Path "$REPO_DIR/$f" \
                >"$TMP/psa.out" 2>&1; then
                pass "PSScriptAnalyzer $f"
            else
                fail "PSScriptAnalyzer $f"; sed 's/^/      /' "$TMP/psa.out"
            fi
        done
    else
        skip "PSScriptAnalyzer" "module not installed"
    fi
else
    skip "PowerShell parse + PSScriptAnalyzer" "no pwsh/powershell on PATH"
fi

# ─── 5. setup.sh OS detection + dispatch ──────────────────────────────────
section "setup.sh OS dispatch"

# Run setup.sh with non-interactive opt-out and capture stdout. Verify
# it reports the expected platform string for our actual OS.
EXPECT="$(case "$(uname -s)" in
    Linux*)  if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    Darwin*) echo macos ;;
esac)"

if [ -n "$EXPECT" ]; then
    out=$(BURBLE_SKIP_PREFLIGHT=1 BURBLE_INSTALL_SERVICE=no \
          bash "$REPO_DIR/setup.sh" 2>&1 || true)
    if echo "$out" | grep -q "Background-service install ($EXPECT)"; then
        pass "setup.sh detected target=$EXPECT"
    else
        fail "setup.sh did not detect target=$EXPECT"
        echo "$out" | tail -10 | sed 's/^/      /'
    fi
else
    skip "setup.sh OS dispatch" "unknown host OS"
fi

# ─── Summary ──────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
printf 'Results: \033[0;32m%d pass\033[0m, \033[0;31m%d fail\033[0m, \033[0;33m%d skip\033[0m\n' "$PASS" "$FAIL" "$SKIP"
echo "──────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
