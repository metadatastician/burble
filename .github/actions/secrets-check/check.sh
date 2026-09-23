#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

root=${GITHUB_WORKSPACE:-.}
if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo '::error::Private-key scan requires a Git working tree.'
  exit 1
fi

pattern='-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'
findings=$(git -C "$root" grep --untracked -I -n -E -e "$pattern" -- . \
  ':(exclude)actions/secrets-check/**' || true)

if [[ -n "$findings" ]]; then
  echo '::error::Private-key material detected in the working tree:'
  printf '%s\n' "$findings"
  exit 1
fi

echo 'No PEM/OpenSSH private-key material detected in tracked or untracked files.'
echo '::notice::This focused gate does not replace GitHub secret scanning or a full history scanner.'
