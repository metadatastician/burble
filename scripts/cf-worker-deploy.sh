#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# cf-worker-deploy.sh — deploy the Burble signaling relay (Cloudflare Worker)
# via the Cloudflare API. No wrangler dependency.
#
# Provisions:
#   * KV namespace named "ROOMS" (idempotent — finds an existing one first)
#   * Worker script "burble-relay" with ROOMS bound to it
#   * Workers.dev subdomain route enabled (the worker is reachable at
#     https://burble-relay.<your-subdomain>.workers.dev/health right after
#     deploy). Optional: configure a custom route via Cloudflare dashboard.
#
# Requirements:
#   * curl, jq
#   * CF_API_TOKEN with these scopes:
#       - Account:Workers Scripts:Edit
#       - Account:Workers KV Storage:Edit
#   * CF_ACCOUNT_ID — Cloudflare account id (visible in dashboard URL)
#
# Usage:
#   CF_API_TOKEN=xxx CF_ACCOUNT_ID=yyy ./scripts/cf-worker-deploy.sh
#
# Dry-run preview:
#   DRY_RUN=1 ./scripts/cf-worker-deploy.sh

set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
SCRIPT_NAME="${SCRIPT_NAME:-burble-relay}"
KV_NAMESPACE="${KV_NAMESPACE:-ROOMS}"
WORKER_FILE="${WORKER_FILE:-signaling/worker.js}"
CF_API="https://api.cloudflare.com/client/v4"

if [[ "$DRY_RUN" != "1" ]]; then
  : "${CF_API_TOKEN:?error: CF_API_TOKEN not set}"
  : "${CF_ACCOUNT_ID:?error: CF_ACCOUNT_ID not set}"
fi

if [[ ! -f "$WORKER_FILE" ]]; then
  echo "error: worker source not found at $WORKER_FILE" >&2
  echo "       (run from the burble repo root)" >&2
  exit 64
fi

echo "[worker] script: ${SCRIPT_NAME}"
echo "[worker] kv namespace: ${KV_NAMESPACE}"
echo "[worker] source: ${WORKER_FILE} ($(wc -l < "$WORKER_FILE") lines)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[worker] DRY_RUN=1 — exiting before API calls"
  echo "[worker] would upload ${WORKER_FILE} as Worker '${SCRIPT_NAME}' with KV binding ROOMS -> ${KV_NAMESPACE}"
  exit 0
fi

cf() {
  curl -fsS \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "$@"
}

# ---- KV namespace --------------------------------------------------------

echo "[worker] looking up KV namespace '${KV_NAMESPACE}'..."
NS_ID=$(cf "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
        | jq -r --arg n "$KV_NAMESPACE" '.result[] | select(.title == $n) | .id' | head -n1)

if [[ -z "$NS_ID" ]]; then
  echo "[worker] creating KV namespace..."
  NS_ID=$(cf -X POST "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
          -H "Content-Type: application/json" \
          --data "{\"title\":\"${KV_NAMESPACE}\"}" \
          | jq -r '.result.id')
fi

if [[ -z "$NS_ID" || "$NS_ID" == "null" ]]; then
  echo "error: failed to provision KV namespace" >&2
  exit 67
fi
echo "[worker] kv namespace id: ${NS_ID}"

# ---- Worker script upload ------------------------------------------------

# Multipart form upload: the script body in one part, metadata (binding
# config) in another. This is the documented API contract for module-syntax
# workers (https://developers.cloudflare.com/api/operations/worker-script-upload-worker-module).

metadata=$(jq -n \
  --arg ns_id "$NS_ID" \
  --arg ns_name "$KV_NAMESPACE" \
  '{
    main_module: "worker.js",
    bindings: [
      { type: "kv_namespace", name: $ns_name, namespace_id: $ns_id }
    ],
    compatibility_date: "2026-05-01"
  }')

echo "[worker] uploading script..."
upload=$(cf -X PUT "${CF_API}/accounts/${CF_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}" \
  -F "metadata=${metadata};type=application/json" \
  -F "worker.js=@${WORKER_FILE};type=application/javascript+module")
echo "$upload" | jq -r '"[worker] upload success=" + (.success|tostring) + " errors=" + (.errors|tostring)'

# ---- Enable workers.dev subdomain route ---------------------------------

echo "[worker] ensuring workers.dev route is enabled..."
cf -X POST "${CF_API}/accounts/${CF_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/subdomain" \
  -H "Content-Type: application/json" \
  --data '{"enabled":true}' \
  | jq -r '"[worker] workers.dev enabled=" + (.success|tostring)' || true

# Get the account's workers.dev subdomain so we can print the public URL.
SUB=$(cf "${CF_API}/accounts/${CF_ACCOUNT_ID}/workers/subdomain" | jq -r '.result.subdomain // empty')

echo
echo "[worker] deployed."
if [[ -n "$SUB" ]]; then
  echo "[worker] public URL: https://${SCRIPT_NAME}.${SUB}.workers.dev"
  echo "[worker] verify:     curl https://${SCRIPT_NAME}.${SUB}.workers.dev/health"
fi
echo
echo "[worker] to point a custom hostname (relay.jewell.nexus) at it:"
echo "  1. Cloudflare dashboard -> jewell.nexus -> Workers Routes -> Add Route"
echo "     route: relay.jewell.nexus/*  ->  worker: ${SCRIPT_NAME}"
echo "  2. Add a CNAME bolt.jewell.nexus -> ${SCRIPT_NAME}.${SUB:-<your-subdomain>}.workers.dev"
echo "     (proxied / orange-cloud OK for the HTTPS signaling endpoint)"
