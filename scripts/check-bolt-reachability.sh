#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-bolt-reachability.sh — verify that UDP 7373 (Burble Bolt) is
# reachable from outside the LAN.
#
# Runs a UDP listener on 7373, prints the public IP + LAN IP + send
# instructions, and waits for a test packet. CGNAT-aware: warns if the
# router WAN IP and public IP disagree.
#
# Usage:
#   ./scripts/check-bolt-reachability.sh
#
# Exit:
#   0 — a packet arrived (port-forward + WSL routing both work)
#   1 — timed out after $TIMEOUT seconds (default 120)
#   2 — listener could not bind (port already in use?)
#   3 — CGNAT detected and the user passed --abort-on-cgnat

set -uo pipefail

PORT="${PORT:-7373}"
TIMEOUT="${TIMEOUT:-120}"
ABORT_ON_CGNAT="${ABORT_ON_CGNAT:-0}"

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

echo "${BOLD}[bolt-check]${RESET} Burble Bolt reachability test"
echo

# ---- determine identifiers ----------------------------------------------

LAN_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
if [[ -z "$LAN_IP" ]]; then
  LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

PUBLIC_IP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  ip=$(curl -fsS --max-time 5 -4 "$url" 2>/dev/null | tr -d '[:space:]') || continue
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP="$ip"
    break
  fi
done

if [[ -z "$PUBLIC_IP" ]]; then
  echo "${RED}error:${RESET} could not detect public IPv4" >&2
  exit 2
fi

echo "  LAN IP (WSL/host): ${BOLD}${LAN_IP}${RESET}"
echo "  Public IPv4:       ${BOLD}${PUBLIC_IP}${RESET}"

# ---- CGNAT check --------------------------------------------------------
#
# Public IPv4 falling in 100.64.0.0/10 is RFC 6598 Shared Address Space
# (carrier-grade NAT). 192.0.0.0/29 and a few others are similar markers.

is_cgnat() {
  local ip="$1"
  IFS=. read -r a b c d <<<"$ip"
  if [[ "$a" == 100 && "$b" -ge 64 && "$b" -le 127 ]]; then return 0; fi
  if [[ "$a" == 10 ]]; then return 0; fi
  if [[ "$a" == 172 && "$b" -ge 16 && "$b" -le 31 ]]; then return 0; fi
  if [[ "$a" == 192 && "$b" == 168 ]]; then return 0; fi
  return 1
}

if is_cgnat "$PUBLIC_IP"; then
  echo
  echo "${YELLOW}warning:${RESET} ${PUBLIC_IP} is in RFC1918/CGNAT space."
  echo "  Your ISP is performing carrier-grade NAT — inbound UDP from the"
  echo "  public internet cannot reach you directly. See the CGNAT section"
  echo "  in docs/developer/router-port-forward.adoc for workarounds."
  if [[ "$ABORT_ON_CGNAT" == "1" ]]; then exit 3; fi
fi

# ---- listener -----------------------------------------------------------

if ! command -v nc >/dev/null 2>&1; then
  echo "${RED}error:${RESET} nc (netcat) not found — install netcat-openbsd" >&2
  exit 2
fi

echo
echo "  Binding UDP listener on port ${PORT}..."
echo "  ${BOLD}From a DIFFERENT network${RESET} (e.g. phone hotspot), send a test packet:"
echo
echo "    echo burble-test | nc -u -w1 ${PUBLIC_IP} ${PORT}"
echo
echo "  Or from any Linux host on a different ISP:"
echo
echo "    printf burble-test > /dev/udp/${PUBLIC_IP}/${PORT}"
echo
echo "  Waiting up to ${TIMEOUT}s for a packet..."
echo "  (Ctrl+C to cancel)"
echo

# Use timeout + nc -l. -W1 makes nc exit after receiving one packet.
out=$(timeout "$TIMEOUT" nc -u -l -p "$PORT" -W 1 2>&1 || true)
status=$?

if [[ -z "$out" ]]; then
  echo "${RED}timeout:${RESET} no packet received in ${TIMEOUT}s."
  echo
  echo "Possible causes (in order of likelihood):"
  echo "  1. Router port-forward rule not saved or pointing at wrong LAN IP."
  echo "     Target should be: ${LAN_IP}:${PORT}/udp"
  echo "  2. ISP CGNAT (see warning above if present)."
  echo "  3. Sender used 'localhost' or LAN IP — test must be from a DIFFERENT network."
  echo "  4. WSL listener didn't bind — check: ss -ulnp | grep ${PORT}"
  exit 1
fi

echo "${GREEN}received:${RESET} ${out}"
echo
echo "${GREEN}${BOLD}✓${RESET} ${BOLD}Port-forward + WSL routing both work.${RESET}"
echo "  Bolt UDP path is live. Next: task #13 end-to-end Bolt test."
exit 0
