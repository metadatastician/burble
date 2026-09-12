#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Callers supply a reviewed immutable URL and a SHA-256 committed with it.
# Never fetch the expected digest alongside the installer at runtime.
run_verified_installer() (
  local url="$1" digest="$2" staging
  case "$url" in https://*) ;; *) echo 'Installer URL must use HTTPS' >&2; return 1 ;; esac
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid installer SHA-256' >&2; return 1; }
  umask 077
  staging="$(mktemp -d)" || return
  trap 'rm -rf -- "$staging"' EXIT

  curl --proto '=https' --tlsv1.2 -fsSL -o "$staging/install.sh" "$url" || return
  if ! printf '%s  %s\n' "$digest" "$staging/install.sh" | sha256sum --check --status; then
    echo 'Installer checksum mismatch; refusing execution' >&2
    return 1
  fi
  sh "$staging/install.sh"
)
