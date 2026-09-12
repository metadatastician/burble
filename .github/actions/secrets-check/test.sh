#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name 'Secret scan test'
printf '%s\n' 'ordinary configuration' > "$fixture/config.txt"
git -C "$fixture" add config.txt
git -C "$fixture" commit -qm fixture

GITHUB_WORKSPACE=$fixture "$here/check.sh"

{
  printf '%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----'
  printf '%s\n' \
    'controlled-positive-marker-not-real-key-material' \
    '-----END OPENSSH PRIVATE KEY-----'
} > "$fixture/leaked.key"
if GITHUB_WORKSPACE=$fixture "$here/check.sh"; then
  echo 'planted private-key marker unexpectedly passed' >&2
  exit 1
fi

echo 'secrets-check controls passed'
