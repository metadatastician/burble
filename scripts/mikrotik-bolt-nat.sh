#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# mikrotik-bolt-nat.sh — provision Burble Bolt port-forward rules on a
# MikroTik RouterOS device over SSH. Idempotent.
#
# Adds two NAT rules:
#   * dst-nat udp/7373 -> $TARGET_LAN_IP:7373  (Burble Bolt primary)
#   * dst-nat udp/9    -> $TARGET_LAN_IP:9     (Burble Bolt WoL compat)
#
# Skips creation if a Burble-comment'd rule for the same dst-port already
# exists, so re-running is safe.
#
# Requirements:
#   * sshpass  (apt install sshpass) — only if using password auth
#   * OR an SSH key pre-installed on the router (/user ssh-keys add)
#
# Auth options (pick one):
#   1. Password via env:  export MIKROTIK_PASS='your-pass'
#   2. SSH key:           SSH_KEY=~/.ssh/router_key (no MIKROTIK_PASS)
#
# Usage:
#   MIKROTIK_PASS=xxx ./scripts/mikrotik-bolt-nat.sh
#   SSH_KEY=~/.ssh/router_key ./scripts/mikrotik-bolt-nat.sh
#   DRY_RUN=1 ./scripts/mikrotik-bolt-nat.sh        # print commands only
#
# Env (all optional):
#   MIKROTIK_HOST   — router address (default: detected default gateway)
#   MIKROTIK_USER   — RouterOS username (default: admin)
#   TARGET_LAN_IP   — internal target for the port-forward (default: detected eth0 IPv4)
#   SSH_PORT        — RouterOS SSH port (default: 22)

set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
MIKROTIK_USER="${MIKROTIK_USER:-admin}"
SSH_PORT="${SSH_PORT:-22}"

# ---- auto-detect target host + LAN IP -----------------------------------

if [[ -z "${MIKROTIK_HOST:-}" ]]; then
  MIKROTIK_HOST=$(ip route | awk '/^default/ {print $3; exit}')
fi
if [[ -z "${TARGET_LAN_IP:-}" ]]; then
  TARGET_LAN_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
  if [[ -z "$TARGET_LAN_IP" ]]; then
    TARGET_LAN_IP=$(hostname -I | awk '{print $1}')
  fi
fi

if [[ -z "$MIKROTIK_HOST" || -z "$TARGET_LAN_IP" ]]; then
  echo "error: could not auto-detect router host or LAN IP — set MIKROTIK_HOST + TARGET_LAN_IP" >&2
  exit 64
fi

echo "[mt-nat] router:     ${MIKROTIK_HOST}:${SSH_PORT} (user: ${MIKROTIK_USER})"
echo "[mt-nat] target LAN: ${TARGET_LAN_IP}"

# ---- commands to send to RouterOS ---------------------------------------
# Quoting note: we want the comment field to contain a literal string with
# spaces. RouterOS accepts double-quoted values; bash here-doc preserves them.

read -r -d '' ROUTEROS_SCRIPT <<EOF || true
:if ([:len [/ip firewall nat find comment="Burble Bolt UDP"]] = 0) do={
  /ip firewall nat add chain=dstnat protocol=udp dst-port=7373 action=dst-nat to-addresses=${TARGET_LAN_IP} to-ports=7373 comment="Burble Bolt UDP"
  :put "[mt-nat] added rule: dst-nat udp/7373 -> ${TARGET_LAN_IP}:7373"
} else={
  :put "[mt-nat] skip: 'Burble Bolt UDP' rule already exists"
}
:if ([:len [/ip firewall nat find comment="Burble Bolt WoL compat"]] = 0) do={
  /ip firewall nat add chain=dstnat protocol=udp dst-port=9 action=dst-nat to-addresses=${TARGET_LAN_IP} to-ports=9 comment="Burble Bolt WoL compat"
  :put "[mt-nat] added rule: dst-nat udp/9 -> ${TARGET_LAN_IP}:9"
} else={
  :put "[mt-nat] skip: 'Burble Bolt WoL compat' rule already exists"
}
:put "[mt-nat] verification:"
/ip firewall nat print where comment~"Burble"
EOF

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[mt-nat] DRY_RUN=1 — would send the following script to ${MIKROTIK_HOST} over SSH:"
  echo "---"
  echo "$ROUTEROS_SCRIPT"
  echo "---"
  exit 0
fi

# ---- ssh execution ------------------------------------------------------

SSH_BASE_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=yes
  -o ConnectTimeout=10
  -p "$SSH_PORT"
)

if [[ -n "${SSH_KEY:-}" ]]; then
  # Key-based auth path. RouterOS expects no BatchMode prompts and uses the
  # standard ssh client just fine.
  echo "[mt-nat] auth: ssh key (${SSH_KEY})"
  exec_ssh() {
    ssh -i "$SSH_KEY" "${SSH_BASE_OPTS[@]}" \
      "${MIKROTIK_USER}@${MIKROTIK_HOST}" "$@"
  }
elif [[ -n "${MIKROTIK_PASS:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "error: sshpass not installed (apt install sshpass) — required for password auth" >&2
    echo "       (or use SSH_KEY=... instead)" >&2
    exit 65
  fi
  echo "[mt-nat] auth: password from \$MIKROTIK_PASS"
  # sshpass needs BatchMode off so the password prompt works
  SSH_BASE_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -p "$SSH_PORT"
  )
  exec_ssh() {
    sshpass -e ssh "${SSH_BASE_OPTS[@]}" \
      "${MIKROTIK_USER}@${MIKROTIK_HOST}" "$@"
  }
  export SSHPASS="$MIKROTIK_PASS"
else
  echo "error: no auth method — set either MIKROTIK_PASS or SSH_KEY" >&2
  echo "       (or pass DRY_RUN=1 to just preview)" >&2
  exit 66
fi

echo "[mt-nat] connecting..."
echo "$ROUTEROS_SCRIPT" | exec_ssh
echo
echo "[mt-nat] done. next:"
echo "  ./scripts/check-bolt-reachability.sh   # verify end-to-end"
