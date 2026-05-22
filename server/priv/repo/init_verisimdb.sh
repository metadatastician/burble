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

# Build auth header if API key is set.
AUTH_HEADER=""
if [ -n "$VERISIMDB_API_KEY" ]; then
  AUTH_HEADER="-H \"Authorization: Bearer ${VERISIMDB_API_KEY}\""
fi

# Health check.
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  ${AUTH_HEADER} \
  "${VERISIMDB_URL}/health" 2>/dev/null || echo "000")

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

RESULT=$(curl -s -w "\n%{http_code}" \
  ${AUTH_HEADER} \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$BODY" \
  "${VERISIMDB_URL}/api/v1/octads" 2>/dev/null || echo "error")

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
