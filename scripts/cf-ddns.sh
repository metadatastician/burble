#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
#
# cf-ddns.sh — Cloudflare Dynamic DNS for the Burble Bolt host record.
#
# Detects the host's current public IPv4 and updates the A record for a
# given FQDN if (and only if) the value has changed. Designed to run on a
# short cron interval (5 min default) so residential IP changes are picked
# up before a Bolt sender's NAPTR resolution caches stale data.
#
# Idempotent: no-op when the public IP already matches the record.
#
# Requirements:
#   * curl, jq
#   * CF_API_TOKEN env var with these scopes on the zone:
#       - Zone:Zone:Read   (zone id lookup)
#       - Zone:DNS:Edit    (read + update the A record)
#
# Usage:
#   CF_API_TOKEN=xxx ./scripts/cf-ddns.sh jewell.nexus bolt.jewell.nexus
#
# Args:
#   $1 — zone (e.g. jewell.nexus)
#   $2 — FQDN of the A record to keep current (e.g. bolt.jewell.nexus)
#
# Dry-run preview (no API calls):
#   DRY_RUN=1 ./scripts/cf-ddns.sh jewell.nexus bolt.jewell.nexus
#
# Recommended cron entry (every 5 min):
#   */5 * * * * CF_API_TOKEN=... /home/.../scripts/cf-ddns.sh \
#                 jewell.nexus bolt.jewell.nexus \
#                 >> /var/log/burble-ddns.log 2>&1

set -euo pipefail

ZONE="${1:-}"
RECORD="${2:-}"
DRY_RUN="${DRY_RUN:-0}"
TTL="${TTL:-300}"
CF_API="https://api.cloudflare.com/client/v4"

# Bolt needs UDP/7373 to reach the origin, so the record MUST be DNS-only
# (grey-cloud); Cloudflare's HTTP proxy doesn't forward UDP.
PROXIED="false"

if [[ -z "$ZONE" || -z "$RECORD" ]]; then
  echo "usage: $0 <zone> <record-fqdn>" >&2
  echo "example: $0 jewell.nexus bolt.jewell.nexus" >&2
  exit 64
fi

if [[ "$DRY_RUN" != "1" && -z "${CF_API_TOKEN:-}" ]]; then
  echo "error: CF_API_TOKEN not set (export it or pass DRY_RUN=1)" >&2
  exit 65
fi

# ---- detect current public IPv4 -----------------------------------------
# Try a few independent providers; first one to answer wins. Each is a
# plain-text "1.2.3.4" body, no JSON parsing needed.

detect_ip() {
  local ip
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com" \
    "https://ipv4.icanhazip.com"
  do
    ip=$(curl -fsS --max-time 5 -4 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "error: could not detect public IPv4 from any provider" >&2
  return 1
}

CURRENT_IP=$(detect_ip)
echo "[ddns] public ipv4: ${CURRENT_IP}"
echo "[ddns] target: ${RECORD} in zone ${ZONE}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[ddns] DRY_RUN=1 — exiting before Cloudflare API calls"
  echo "[ddns] would PUT ${RECORD} A ${CURRENT_IP} (ttl ${TTL}, proxied ${PROXIED})"
  exit 0
fi

cf() {
  curl -fsS \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

# ---- look up zone --------------------------------------------------------

ZONE_ID=$(cf "${CF_API}/zones?name=${ZONE}" | jq -r '.result[0].id')
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
  echo "error: zone '${ZONE}' not found in this Cloudflare account" >&2
  exit 66
fi

# ---- look up existing record --------------------------------------------

record_lookup=$(cf "${CF_API}/zones/${ZONE_ID}/dns_records?type=A&name=${RECORD}")
RECORD_ID=$(echo "$record_lookup" | jq -r '.result[0].id // empty')
RECORD_IP=$(echo "$record_lookup" | jq -r '.result[0].content // empty')

if [[ -z "$RECORD_ID" ]]; then
  # No record yet — create it.
  echo "[ddns] no existing A record for ${RECORD}; creating..."
  payload=$(jq -n \
    --arg name "$RECORD" \
    --arg ip "$CURRENT_IP" \
    --argjson ttl "$TTL" \
    --argjson proxied "$PROXIED" \
    '{type:"A", name:$name, content:$ip, ttl:$ttl, proxied:$proxied}')
  cf -X POST "${CF_API}/zones/${ZONE_ID}/dns_records" --data "$payload" \
    | jq -r '"[ddns] created: " + .success + " " + (.result.name // "?") + " -> " + (.result.content // "?")'
  exit 0
fi

if [[ "$RECORD_IP" == "$CURRENT_IP" ]]; then
  echo "[ddns] no change (${RECORD_IP}); exit"
  exit 0
fi

echo "[ddns] updating ${RECORD}: ${RECORD_IP} -> ${CURRENT_IP}"
payload=$(jq -n \
  --arg name "$RECORD" \
  --arg ip "$CURRENT_IP" \
  --argjson ttl "$TTL" \
  --argjson proxied "$PROXIED" \
  '{type:"A", name:$name, content:$ip, ttl:$ttl, proxied:$proxied}')
cf -X PUT "${CF_API}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" --data "$payload" \
  | jq -r '"[ddns] updated: " + .success + " " + (.result.name // "?") + " -> " + (.result.content // "?")'
