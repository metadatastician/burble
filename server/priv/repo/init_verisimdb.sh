#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# init_verisimdb.sh — Initialize VeriSimDB for Burble.
#
# This script verifies that VeriSimDB is reachable and creates the migration
# tracking octad. Run this before starting Burble for the first time.
#
# Usage:
#   VERISIMDB_URL=http://localhost:8080 ./priv/repo/init_verisimdb.sh
#
# The script is idempotent — safe to run multiple times.

set -eu

VERISIMDB_URL="${VERISIMDB_URL:-http://localhost:8080}"
VERISIMDB_API_KEY="${VERISIMDB_API_KEY:-}"

echo "==> Checking VeriSimDB connectivity at ${VERISIMDB_URL}..."

# Auth is passed as a real curl argument, not as a string assembled for the
# shell to re-split. POSIX sh removes quotes during PARSING, so the quotes in
# `AUTH_HEADER="-H \"Authorization: ...\""` were literal characters by the time
# the unquoted `${AUTH_HEADER}` reached curl: it received `"Authorization:` and
# `Bearer ..."` as separate words, and the header was malformed whenever a key
# was set. Two functions keep the argument list honest and quote the key.
#
# This also clears a `HardcodedSecret` critical from the security grid, which
# was a false positive: there is no secret here, only an empty default for an
# environment variable. The finding was wrong about the reason and right about
# the line.
curl_health() {
  if [ -n "$VERISIMDB_API_KEY" ]; then
    curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${VERISIMDB_API_KEY}" \
      "${VERISIMDB_URL}/health" 2>/dev/null || echo "000"
  else
    curl -s -o /dev/null -w "%{http_code}" \
      "${VERISIMDB_URL}/health" 2>/dev/null || echo "000"
  fi
}

curl_create_octad() {
  if [ -n "$VERISIMDB_API_KEY" ]; then
    curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer ${VERISIMDB_API_KEY}" \
      -H "Content-Type: application/json" \
      -X POST -d "$1" \
      "${VERISIMDB_URL}/api/v1/octads" 2>/dev/null || echo "error"
  else
    curl -s -w "\n%{http_code}" \
      -H "Content-Type: application/json" \
      -X POST -d "$1" \
      "${VERISIMDB_URL}/api/v1/octads" 2>/dev/null || echo "error"
  fi
}

# Health check.
HTTP_CODE=$(curl_health)

if [ "$HTTP_CODE" = "000" ]; then
  echo "ERROR: Cannot reach VeriSimDB at ${VERISIMDB_URL}"
  echo "Make sure VeriSimDB is running. Example:"
  echo "  podman run -d -p 8080:8080 ghcr.io/hyperpolymath/verisimdb:latest"
  exit 1
fi

if [ "$HTTP_CODE" != "200" ]; then
  echo "WARNING: VeriSimDB health check returned HTTP ${HTTP_CODE} (expected 200)"
  echo "Continuing anyway — the server may still accept requests."
fi

echo "==> VeriSimDB is reachable (HTTP ${HTTP_CODE})"

# Create migration tracking octad (idempotent).
echo "==> Creating migration tracking octad..."
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

BODY=$(cat <<EOJSON
{
  "name": "_migration:burble",
  "description": "Burble migration tracking — do not delete",
  "metadata": {"entity_type": "burble_migration_tracker"},
  "document": {
    "content": "{\"current_version\":1,\"applied_at\":\"${TIMESTAMP}\",\"migrations\":[{\"version\":1,\"description\":\"Initial VeriSimDB schema setup\",\"applied_at\":\"${TIMESTAMP}\"}]}",
    "content_type": "application/json",
    "metadata": {"schema_version": 1}
  }
}
EOJSON
)

RESULT=$(curl_create_octad "$BODY")

RESULT_CODE=$(echo "$RESULT" | tail -1)

case "$RESULT_CODE" in
  201|200)
    echo "==> Migration tracking octad created successfully"
    ;;
  409)
    echo "==> Migration tracking octad already exists (idempotent — OK)"
    ;;
  *)
    echo "WARNING: Unexpected response (HTTP ${RESULT_CODE})"
    echo "The Burble application will attempt migration at startup."
    ;;
esac

echo "==> VeriSimDB initialization complete"
echo ""
echo "You can now start Burble:"
echo "  cd server && MIX_ENV=prod mix release burble"
echo "  _build/prod/rel/burble/bin/burble start"
