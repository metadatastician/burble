#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
#
# cf-bolt-dns.sh — provision NAPTR + SRV records at Cloudflare for Burble Bolt
# discovery on a given zone.
#
# Publishes the two records that `Burble.Bolt.NAPTR.resolve/1` looks for
# (see server/lib/burble/bolt/naptr.ex):
#
#   <zone>            IN NAPTR 10 1 "U" "BURBLE+bolt" "!.*!bolt://<host>:7373!" .
#   _burble._bolt._udp.<zone>  IN SRV 10 1 7373 <host>
#
# Idempotent: looks up existing records and updates them rather than creating
# duplicates.
#
# Requirements:
#   * curl, jq
#   * CF_API_TOKEN env var with these scopes on the zone:
#       - Zone:Zone:Read   (to look up the zone ID)
#       - Zone:DNS:Edit    (to create/update records)
#
# Usage:
#   CF_API_TOKEN=xxx ./scripts/cf-bolt-dns.sh jewell.nexus bolt.jewell.nexus
#
# Args:
#   $1 — zone (e.g. jewell.nexus)
#   $2 — bolt host (FQDN that resolves to the Bolt listener's public IP;
#        kept DDNS-updated by scripts/cf-ddns.sh in task #10)
#
# Dry-run preview (no API calls):
#   DRY_RUN=1 ./scripts/cf-bolt-dns.sh jewell.nexus bolt.jewell.nexus
#

set -euo pipefail

ZONE="${1:-}"
BOLT_HOST="${2:-}"
DRY_RUN="${DRY_RUN:-0}"
BOLT_PORT="${BOLT_PORT:-7373}"
TTL="${TTL:-300}"
CF_API="https://api.cloudflare.com/client/v4"

if [[ -z "$ZONE" || -z "$BOLT_HOST" ]]; then
  echo "usage: $0 <zone> <bolt-host>" >&2
  echo "example: $0 jewell.nexus bolt.jewell.nexus" >&2
  exit 64
fi

if [[ "$DRY_RUN" != "1" && -z "${CF_API_TOKEN:-}" ]]; then
  echo "error: CF_API_TOKEN not set (export it or pass DRY_RUN=1)" >&2
  exit 65
fi

SRV_NAME="_burble._bolt._udp.${ZONE}"
NAPTR_REGEX="!.*!bolt://${BOLT_HOST}:${BOLT_PORT}!"

echo "[bolt-dns] zone=${ZONE} bolt_host=${BOLT_HOST} bolt_port=${BOLT_PORT}"
echo "[bolt-dns] NAPTR: ${ZONE} 10 1 U BURBLE+bolt ${NAPTR_REGEX} ."
echo "[bolt-dns] SRV:   ${SRV_NAME} 10 1 ${BOLT_PORT} ${BOLT_HOST}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[bolt-dns] DRY_RUN=1 — exiting before API calls"
  exit 0
fi

cf() {
  curl -fsS \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

echo "[bolt-dns] looking up zone id..."
ZONE_ID=$(cf "${CF_API}/zones?name=${ZONE}" | jq -r '.result[0].id')
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
  echo "error: zone '${ZONE}' not found in this Cloudflare account" >&2
  exit 66
fi
echo "[bolt-dns] zone id: ${ZONE_ID}"

# ---- NAPTR ---------------------------------------------------------------

naptr_payload=$(jq -n \
  --arg name "$ZONE" \
  --argjson ttl "$TTL" \
  --arg regex "$NAPTR_REGEX" \
  '{
    type: "NAPTR",
    name: $name,
    ttl: $ttl,
    data: {
      order: 10,
      preference: 1,
      flags: "U",
      service: "BURBLE+bolt",
      regex: $regex,
      replacement: "."
    }
  }')

existing_naptr=$(cf "${CF_API}/zones/${ZONE_ID}/dns_records?type=NAPTR&name=${ZONE}" \
                  | jq -r '.result[] | select(.data.service == "BURBLE+bolt") | .id' | head -n1)

if [[ -n "$existing_naptr" ]]; then
  echo "[bolt-dns] updating NAPTR record ${existing_naptr}..."
  cf -X PUT "${CF_API}/zones/${ZONE_ID}/dns_records/${existing_naptr}" \
    --data "$naptr_payload" | jq -r '.success'
else
  echo "[bolt-dns] creating NAPTR record..."
  cf -X POST "${CF_API}/zones/${ZONE_ID}/dns_records" \
    --data "$naptr_payload" | jq -r '.success'
fi

# ---- SRV -----------------------------------------------------------------

srv_payload=$(jq -n \
  --arg name "$SRV_NAME" \
  --arg target "$BOLT_HOST" \
  --argjson port "$BOLT_PORT" \
  --argjson ttl "$TTL" \
  '{
    type: "SRV",
    name: $name,
    ttl: $ttl,
    data: {
      priority: 10,
      weight: 1,
      port: $port,
      target: $target
    }
  }')

existing_srv=$(cf "${CF_API}/zones/${ZONE_ID}/dns_records?type=SRV&name=${SRV_NAME}" \
                | jq -r '.result[0].id // empty')

if [[ -n "$existing_srv" ]]; then
  echo "[bolt-dns] updating SRV record ${existing_srv}..."
  cf -X PUT "${CF_API}/zones/${ZONE_ID}/dns_records/${existing_srv}" \
    --data "$srv_payload" | jq -r '.success'
else
  echo "[bolt-dns] creating SRV record..."
  cf -X POST "${CF_API}/zones/${ZONE_ID}/dns_records" \
    --data "$srv_payload" | jq -r '.success'
fi

echo "[bolt-dns] done. verify with:"
echo "  dig +short NAPTR ${ZONE}"
echo "  dig +short SRV ${SRV_NAME}"
echo "  PowerShell: Resolve-DnsName -Type SRV -Name '${SRV_NAME}'"
