#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Burble deploy smoke check. Called by `just smoke-deploy` AFTER the stack is up.
#
# Lives as a standalone script (not inline in the Justfile) because podman's
# `--format '{{.Field}}'` Go-templates collide with `just`'s own `{{ }}`
# interpolation — `just` parses recipe bodies before the shell sees them, so
# inline brace templates fail at parse time. A separate file is not processed
# by `just` at all.
#
# Asserts the deploy is ACTUALLY healthy (restarts + HTTP 200), not merely
# "no nxdomain string" — see the Justfile smoke-deploy block for the why.
#
# Exit 0 = healthy. Exit 1 = unhealthy (with diagnostics on stdout).

set -uo pipefail

fail=0

rc=$(podman inspect burble_server --format '{{.RestartCount}}' 2>/dev/null || echo 999)
st=$(podman inspect burble_server --format '{{.State.Status}}' 2>/dev/null || echo missing)
case "$rc" in ''|*[!0-9]*) rc=999 ;; esac   # guard non-numeric
echo "burble_server: state=$st restarts=$rc"
if [ "$st" != "running" ] || [ "$rc" -gt 2 ]; then
  echo "FAIL: server unstable (state=$st restarts=$rc — expected running, restarts<=2)"
  fail=1
fi

code=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST http://localhost:6473/api/v1/auth/guest \
  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)
echo "POST /api/v1/auth/guest -> HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: guest auth returned $code (expected 200 — server not serving)"
  fail=1
fi

if podman logs --tail 200 burble_server 2>&1 | grep -q nxdomain; then
  echo "FAIL: nxdomain in server logs (WS-1.6 DNS regression)"
  fail=1
fi

# Migration must have actually applied (or been already-applied/idempotent).
# Bounded poll, NOT a single fixed-offset grep: on a cold full-rebuild the
# migrator only connects to VeriSimDB ~40s after container start, then takes
# ~14s more to apply v1, so "Migration v1 applied" can be written just after
# the `sleep 40` settle window. A one-shot grep here false-WARNs on a
# perfectly healthy deploy (observed 2026-05-15 against the OTP-25 merge).
# Wait up to 60s, polling every 3s, before deciding the migrator is silent.
mig_deadline=$((SECONDS + 60))
mig_ok=0
while [ "$SECONDS" -lt "$mig_deadline" ]; do
  if podman logs --tail 200 burble_server 2>&1 | grep -qE "Migration v1 (applied|already)"; then
    mig_ok=1
    break
  fi
  sleep 3
done
if [ "$mig_ok" -eq 1 ]; then
  echo "OK: migration v1 applied/idempotent"
else
  echo "WARN: no 'Migration v1 applied/already' line after 60s — check migrator"
  # Not a hard fail on its own; the restarts<=2 + HTTP 200 checks above
  # already gate on the server actually working.
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: server stable, serving, no nxdomain"
  exit 0
else
  echo "SMOKE FAILED"
  exit 1
fi
