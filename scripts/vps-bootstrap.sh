#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# vps-bootstrap.sh — stand up a single always-on Burble instance (Monarchic
# topology, the default) on a fresh VPS: detects hardware/OS, installs
# prerequisites, asks public-internet vs. Tailscale-only, configures
# accordingly (Caddy + real TLS for public; firewall-restricted for
# Tailscale), builds and starts the container stack, and proves it's healthy
# before declaring success.
#
# HONESTY NOTE ON WHAT'S VERIFIED VS. WRITTEN-TO-PATTERN:
#   - Debian/apt path + Tailscale-only mode: every env var and default was
#     checked against the code that reads it (server/config/runtime.exs),
#     and the script itself has been shellcheck-clean and syntax-checked.
#   - Fedora/dnf, Arch/pacman, Alpine/apk package names below are the
#     standard/documented names for each tool on that distro, but this
#     session had no non-Debian VPS to actually run them against. If one
#     of those fails, the error will name the exact failing command.
#   - The public-internet path (Caddy + Let's Encrypt) follows Caddy's
#     standard, extremely well-established automatic-HTTPS pattern, but
#     was not exercised against a real public domain in this session
#     (that requires DNS already pointed at a real box). Test it on a
#     throwaway subdomain before trusting it for anything that matters.
#   - "Default admin password" (sometimes listed in generic self-hosting
#     checklists) does not exist in this codebase — auth is magic-link
#     only — so this script does not pretend to handle it.
#
# Run from the root of a `git clone` of this repo, on the target box:
#   ./scripts/vps-bootstrap.sh
#
# Safe to re-run: it will not overwrite an existing containers/.env, and
# `podman-compose up -d` is idempotent. Re-running will re-ask the
# public/tailscale question only if containers/.env doesn't exist yet.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/verified-installer.sh
source "$REPO_ROOT/scripts/lib/verified-installer.sh"
ENV_FILE="$REPO_ROOT/containers/.env"
COMPOSE_FILE="$REPO_ROOT/containers/selur-compose.toml"
CADDYFILE="/etc/caddy/Caddyfile"

say()  { printf '\n[bootstrap] %s\n' "$*"; }
warn() { printf '\n[bootstrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '\n[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
need_bin() { command -v "$1" >/dev/null 2>&1; }

confirm() { # $1 prompt -> 0 (yes) / 1 (no). Default yes on bare Enter.
  local reply
  read -r -p "[bootstrap] $1 [Y/n] " reply </dev/tty
  case "$reply" in
    ""|[Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

ask() { # $1 prompt, $2 varname (no default; loops until non-empty)
  local reply
  while true; do
    read -r -p "[bootstrap] $1: " reply </dev/tty
    [ -n "$reply" ] && { printf -v "$2" '%s' "$reply"; return; }
    echo "  (can't be empty)"
  done
}

[ -f "$COMPOSE_FILE" ] || die "expected $COMPOSE_FILE — run this from a clone of the burble repo."

# ==============================================================================
# 1. Hardware + OS detection
# ==============================================================================

say "detecting hardware and OS"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) say "architecture: $ARCH (supported — Burble's base images are multi-arch)" ;;
  *) warn "architecture: $ARCH — untested. The Containerfile builds from source" \
          "(Elixir/Rust/OCaml), so it may still work, but this hasn't been checked." ;;
esac

if need_bin free; then
  MEM_MB="$(free -m | awk '/^Mem:/{print $2}')"
  [ "$MEM_MB" -lt 1024 ] && warn "only ${MEM_MB}MiB RAM detected. Elixir + VeriSimDB + " \
    "the web/coturn containers are known to be tight under 1GiB; 2GiB+ is a more " \
    "comfortable floor. Not blocking, but expect to hit swap during the first build."
fi

if need_bin df; then
  # `-BG --output=avail` is GNU-coreutils-only; busybox df (Alpine's default)
  # doesn't support it. 2>/dev/null hides the error text but NOT the exit
  # code, so under `set -e -o pipefail` a failing df here would abort the
  # whole script this early — hence the explicit `|| true`.
  DISK_AVAIL_GB="$(df -BG --output=avail "$REPO_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
  [ -n "${DISK_AVAIL_GB:-}" ] && [ "$DISK_AVAIL_GB" -lt 10 ] && \
    warn "only ${DISK_AVAIL_GB}GiB free on this volume. Container image builds " \
         "(Elixir/Rust/OCaml toolchains in the build stage) can use several GiB " \
         "of scratch space even though the final images are much smaller."
fi

# Package manager detection — the four common VPS distro families.
PKG_MGR=""
if [ -f /etc/debian_version ]; then PKG_MGR=apt
elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then PKG_MGR=dnf
elif [ -f /etc/arch-release ]; then PKG_MGR=pacman
elif [ -f /etc/alpine-release ]; then PKG_MGR=apk
fi
if [ -n "$PKG_MGR" ]; then
  say "OS family: $PKG_MGR-based"
else
  warn "couldn't identify the OS family from /etc/*-release — auto-install of" \
       "missing prerequisites will be skipped; install them yourself if prompted."
fi

pkg_install() { # $@ = canonical (Debian-style) package names; translated per distro
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      sudo apt-get update -qq
      sudo apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    dnf)
      # dnf package names mostly match; the few that don't are mapped here.
      local mapped=() p
      for p in "${pkgs[@]}"; do
        case "$p" in
          python3-pip) mapped+=("python3-pip") ;;
          *) mapped+=("$p") ;;
        esac
      done
      sudo dnf install -y "${mapped[@]}"
      ;;
    pacman)
      local mapped=() p
      for p in "${pkgs[@]}"; do
        case "$p" in
          python3-pip) mapped+=("python-pip") ;;
          *) mapped+=("$p") ;;
        esac
      done
      sudo pacman -Sy --noconfirm "${mapped[@]}"
      ;;
    apk)
      local mapped=() p
      for p in "${pkgs[@]}"; do
        case "$p" in
          python3-pip) mapped+=("py3-pip") ;;
          uidmap) mapped+=("shadow-uidmap") ;;
          *) mapped+=("$p") ;;
        esac
      done
      sudo apk add --no-cache "${mapped[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

# ==============================================================================
# 2. Preflight — install what's missing. A check that can't fail isn't a check.
# ==============================================================================

say "checking prerequisites"

MISSING=()
need_bin podman          || MISSING+=("podman")
need_bin openssl         || MISSING+=("openssl")
need_bin curl            || MISSING+=("curl")
need_bin podman-compose  || MISSING+=("podman-compose")

if [ "${#MISSING[@]}" -gt 0 ]; then
  say "missing: ${MISSING[*]}"
  if [ -n "$PKG_MGR" ] && confirm "Install ${MISSING[*]} via $PKG_MGR now?"; then
    pkg_install podman openssl curl python3-pip uidmap slirp4netns || \
      die "package install failed — install ${MISSING[*]} yourself, then re-run."
    if ! command -v podman-compose >/dev/null 2>&1; then
      # `python3 -m pip` rather than a bare `pip`/`pip3` binary: many distros
      # only ship `python3` + the `pip` MODULE after installing python3-pip,
      # with no `pip`/`pip3` executable on PATH at all, so a bare `pip
      # install` call can fail with "command not found" even though the
      # install would otherwise work fine.
      python3 -m pip install --break-system-packages --user podman-compose 2>/dev/null || \
        python3 -m pip install --user podman-compose || \
        die "podman-compose install failed — 'python3 -m pip install --user podman-compose' yourself, then re-run."
      # `pip install --user` places the binary in ~/.local/bin, which may not
      # be on PATH yet in this shell — without this, the need_bin re-check
      # just below can fail even though the install genuinely succeeded.
      export PATH="$HOME/.local/bin:$PATH"
    fi
    hash -r
  else
    die "install ${MISSING[*]} yourself, then re-run."
  fi
fi

for bin in podman openssl curl podman-compose; do
  need_bin "$bin" || die "still missing after install attempt: $bin"
done

# ==============================================================================
# 3. Deployment mode — public internet or Tailscale-only.
# ==============================================================================

say "deployment mode"
echo "  1) Tailscale-only (private — only people on your tailnet can reach it; simpler, no domain needed)"
echo "  2) Public internet (real domain + automatic HTTPS via Let's Encrypt; reachable by anyone with the URL)"
MODE=""
while true; do
  read -r -p "[bootstrap] Choose 1 or 2: " MODE </dev/tty
  case "$MODE" in 1|2) break ;; *) echo "  enter 1 or 2" ;; esac
done

PUBLIC_HOSTNAME=""
PHX_HOST_VALUE=""
BASE_URL_SCHEME="http"

if [ "$MODE" = "1" ]; then
  # ---- Tailscale path -------------------------------------------------------
  if ! need_bin tailscale; then
    if confirm "Tailscale isn't installed. Install it now (verified official installer)?"; then
      # Review and update the immutable source URL and digest together.
      run_verified_installer \
        'https://raw.githubusercontent.com/tailscale/tailscale/5208e6d7f1abb282d19a480c8a5579c435ab2658/scripts/installer.sh' \
        '805e85ed6f6f81a7ea2e70d52d47e7d5290863299e5c922b2787d71aa312f22e' \
        || die "Tailscale installer failed verification or installation."
    else
      die "tailscale is required for this mode — install it, then re-run."
    fi
  fi
  if ! tailscale ip -4 >/dev/null 2>&1; then
    say "tailscale is installed but not connected."
    if confirm "Run 'sudo tailscale up' now? (opens a login URL you'll need to visit)"; then
      sudo tailscale up
    else
      die "not connected — run 'sudo tailscale up' yourself, then re-run this script."
    fi
  fi
  PHX_HOST_VALUE="$(tailscale ip -4 2>/dev/null || true)"
  [ -n "$PHX_HOST_VALUE" ] || die "tailscale still isn't reporting an address — check 'tailscale status'."
  say "tailscale is up: $PHX_HOST_VALUE"
else
  # ---- Public path ------------------------------------------------------
  BASE_URL_SCHEME="https"
  say "Public mode needs a domain name that ALREADY resolves (A/AAAA record) to this box's public IP."
  PUBLIC_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
  [ -n "$PUBLIC_IP" ] && say "this box's public IP (as seen from the outside): $PUBLIC_IP"
  ask "Domain name to serve Burble on (e.g. burble.example.com)" PUBLIC_HOSTNAME
  if need_bin dig; then
    RESOLVED="$(dig +short "$PUBLIC_HOSTNAME" A | tail -1)"
    if [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
      warn "$PUBLIC_HOSTNAME currently resolves to '${RESOLVED:-nothing}', not this box's" \
           "IP ($PUBLIC_IP). Let's Encrypt issuance will fail until DNS is fixed and has" \
           "propagated — you can still continue and fix DNS afterward."
      confirm "Continue anyway?" || die "fix DNS, then re-run."
    fi
  fi
  PHX_HOST_VALUE="$PUBLIC_HOSTNAME"

  if ! need_bin caddy; then
    if [ -n "$PKG_MGR" ] && confirm "Caddy (reverse proxy + automatic HTTPS) isn't installed. Install it now?"; then
      case "$PKG_MGR" in
        apt)
          sudo apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
          sudo apt-get update -qq
          sudo apt-get install -y caddy
          ;;
        dnf)
          sudo dnf install -y 'dnf-command(copr)'
          sudo dnf copr enable -y @caddy/caddy
          sudo dnf install -y caddy
          ;;
        pacman)
          sudo pacman -Sy --noconfirm caddy
          ;;
        apk)
          sudo apk add --no-cache caddy
          ;;
      esac
      hash -r
    else
      die "Caddy is required for the public path (or set up your own reverse proxy + TLS manually), then re-run."
    fi
  fi
fi

# ==============================================================================
# 4. Secrets — generated once, never overwritten, never committed.
#
# Every name here is read directly by server/config/runtime.exs or
# containers/selur-compose.toml.
# ==============================================================================

if [ -f "$ENV_FILE" ]; then
  say "containers/.env already exists — leaving your existing secrets alone."
  # shellcheck disable=SC1091
  # sed, not grep -P: busybox grep (Alpine's default) has no -P support.
  EXISTING_PHX_HOST="$(sed -n 's/^PHX_HOST=//p' "$ENV_FILE" | head -1)"
  [ -n "$EXISTING_PHX_HOST" ] && PHX_HOST_VALUE="$EXISTING_PHX_HOST"
else
  say "generating containers/.env"
  mkdir -p "$(dirname "$ENV_FILE")"
  {
    echo "# Generated by scripts/vps-bootstrap.sh on $(date -u +%FT%TZ)"
    echo "# Do not commit this file (it's gitignored) or share these values."
    echo
    echo "# Phoenix endpoint secret — runtime.exs raises at boot if this is unset."
    echo "SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')"
    echo
    echo "# Guardian JWT signing key — falls back to SECRET_KEY_BASE if unset;"
    echo "# generated separately so the two don't do double duty."
    echo "GUARDIAN_SECRET=$(openssl rand -base64 64 | tr -d '\n')"
    echo
    echo "# Bolt subsystem secret (server/config/runtime.exs: BURBLE_BOLT_SECRET)."
    echo "BURBLE_BOLT_SECRET=$(openssl rand -base64 32 | tr -d '\n')"
    echo
    echo "# coturn's shared secret for time-limited TURN credentials."
    echo "TURN_SECRET=$(openssl rand -hex 32)"
    echo "TURN_REALM=${PUBLIC_HOSTNAME:-burble.tailnet}"
    if [ "$MODE" = "2" ]; then
      echo "# Public mode: advertise this box's public IP as the TURN relay candidate."
      echo "TURN_EXTERNAL_IP=${PUBLIC_IP:-}"
    else
      echo "# Tailnet-only: no public relay candidate advertised (omits --external-ip)."
      echo "TURN_EXTERNAL_IP="
    fi
    echo
    echo "# Where Burble thinks it lives — magic-link/invite URLs point here."
    echo "PHX_HOST=$PHX_HOST_VALUE"
    echo "BURBLE_BASE_URL=${BASE_URL_SCHEME}://${PHX_HOST_VALUE}"
    echo
    echo "# Monarchic is already runtime.exs's default if unset; set explicitly anyway."
    echo "BURBLE_TOPOLOGY=monarchic"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "wrote $ENV_FILE (mode 600)"
fi

# ==============================================================================
# 5. Bring the stack up.
# ==============================================================================

say "building and starting the stack (this takes a while the first time)"
set -a
# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"
set +a
podman-compose -f "$COMPOSE_FILE" up -d --build

# ==============================================================================
# 6. Network exposure — mode-specific.
# ==============================================================================

if [ "$MODE" = "1" ]; then
  # ---- Tailscale: firewall port 6473 to the tailnet interface only ----------
  if ! need_bin ufw && [ "$PKG_MGR" = "apt" ]; then
    confirm "ufw (firewall) isn't installed. Install it now so port 6473 can be restricted to the tailnet?" && \
      { pkg_install ufw; hash -r; }
  fi
  if need_bin ufw; then
    if confirm "Restrict port 6473 to the tailnet via ufw (recommended — otherwise it's reachable from the open internet)?"; then
      sudo ufw allow in on tailscale0 to any port 6473 proto tcp comment 'burble web (tailnet only)' || true
      sudo ufw deny 6473/tcp comment 'burble web (deny public)' || true
      say "ufw rules added. If ufw isn't already enabled on this box, review 'sudo ufw" \
          "status' and make sure SSH is allowed before 'sudo ufw enable' — this script" \
          "will not enable ufw for you, to avoid locking you out."
    else
      say "skipped — port 6473 is reachable from the public internet, not just the tailnet."
    fi
  else
    warn "ufw not available: restrict port 6473 to the tailscale interface yourself" \
         "(nftables/iptables), or it is reachable from the public internet."
  fi
else
  # ---- Public: Caddy reverse-proxies 443 -> 127.0.0.1:6473, TLS 1.3 only ----
  say "configuring Caddy for $PUBLIC_HOSTNAME"
  sudo mkdir -p "$(dirname "$CADDYFILE")"
  cat <<CADDYCFG | sudo tee "$CADDYFILE" >/dev/null
$PUBLIC_HOSTNAME {
	reverse_proxy 127.0.0.1:6473
	encode gzip
	header {
		Strict-Transport-Security "max-age=63072000; includeSubDomains"
		X-Content-Type-Options "nosniff"
	}
	tls {
		protocols tls1.3 tls1.3
	}
}
CADDYCFG
  sudo systemctl enable --now caddy 2>/dev/null || true
  sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
  say "Caddy will request a Let's Encrypt certificate for $PUBLIC_HOSTNAME on first" \
      "request — this needs port 80 AND 443 reachable from the public internet" \
      "(the ACME HTTP-01 challenge uses 80 even though the site serves on 443)."

  # NOT optional in public mode: containers/selur-compose.toml publishes the
  # web service on 0.0.0.0:6473 (needed so Tailscale-only mode can reach it
  # over the tailnet interface — that mode has no Caddy in front of it at
  # all). In public mode, Caddy fronts 6473 with TLS 1.3 + HSTS, but if
  # 6473 itself stays reachable, anyone can skip Caddy entirely and hit the
  # app in plaintext — silently defeating the whole point of this branch.
  # Asking first and letting the answer be "no" would leave that door open
  # on a fresh VPS by default, so this one rule is mandatory here, not a
  # confirm() like everything else in this script.
  if ! need_bin ufw && [ "$PKG_MGR" = "apt" ]; then
    say "ufw isn't installed — installing it (mandatory in public mode:" \
        "without it, port 6473 stays reachable in plaintext, bypassing Caddy/TLS entirely)."
    pkg_install ufw
    hash -r
  fi
  if need_bin ufw; then
    sudo ufw allow 80/tcp comment 'caddy ACME + http redirect' || true
    sudo ufw allow 443/tcp comment 'caddy https' || true
    sudo ufw deny 6473/tcp comment 'burble web direct (deny — go through Caddy)' || true
    say "ufw rules added for 80/443, and 6473 is denied directly (Caddy is the only" \
        "path in). Review 'sudo ufw status' and confirm SSH is allowed before" \
        "'sudo ufw enable' if it isn't already — this script will not enable ufw" \
        "for you, to avoid locking you out."
  else
    die "no firewall tool (ufw) available and none could be installed. Refusing to" \
        "finish public-mode setup with port 6473 reachable in plaintext, bypassing" \
        "Caddy/TLS entirely — firewall this box yourself (iptables/nftables: allow" \
        "80/443, deny 6473 from anywhere but 127.0.0.1), then re-run."
  fi
fi

# ==============================================================================
# 7. Health check — don't just print success, prove it.
# ==============================================================================

say "waiting for the stack to become healthy"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:6473/" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  podman-compose -f "$COMPOSE_FILE" logs --tail=40 server || true
  die "the web endpoint never came up on 127.0.0.1:6473 — logs above. Not declaring success."
fi

FINAL_URL="${BASE_URL_SCHEME}://${PHX_HOST_VALUE}"
if [ "$MODE" = "2" ]; then
  say "container stack is up locally. Checking the public URL (Let's Encrypt can take" \
      "up to ~30s on first issuance)..."
  ok2=0
  for _ in $(seq 1 20); do
    if curl -fsS "$FINAL_URL/" >/dev/null 2>&1; then ok2=1; break; fi
    sleep 3
  done
  [ "$ok2" -eq 1 ] || warn "public URL not yet responding — check 'sudo journalctl -u" \
    "caddy -n 50' for ACME issuance errors (usually DNS not pointed here yet, or 80/443 blocked)."
fi

cat <<SUMMARY

────────────────────────────────────────────────────────────────
$([ "$MODE" = "1" ] && echo "Give your friends this address (they must be on the same tailnet):" \
                     || echo "Burble is at:")

    $FINAL_URL

Known rough edge: SMTP isn't configured, so magic-link login emails
are only logged, not sent. To find a link during testing:
    podman-compose -f "$COMPOSE_FILE" logs server | grep -i magic

Secrets live in containers/.env (mode 600) — back it up somewhere
safe; losing it invalidates every session and login token.
$([ "$MODE" = "2" ] && cat <<PUBLICNOTE

Public-mode reminders from docs/SECURITY-DEPLOY.md this script does
NOT automate (no code path for them exists yet, or they're a
provisioning-time decision this script can't retrofit):
  - Storage should be on a full-disk-encrypted volume.
  - Rotate SECRET_KEY_BASE / GUARDIAN_SECRET / TURN_SECRET periodically
    (90/90/no-fixed-cadence per that doc) — this script only generates
    them once.
PUBLICNOTE
)
────────────────────────────────────────────────────────────────
SUMMARY
