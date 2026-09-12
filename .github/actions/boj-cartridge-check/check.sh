#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

root=${GITHUB_WORKSPACE:-.}
required=${BOJ_CARTRIDGE_REQUIRED:-false}
found=

for candidate in cartridge.json cartridge.yml cartridge.yaml; do
  if [[ -f "$root/$candidate" ]]; then
    found=$candidate
    break
  fi
done
if [[ -z "$found" && -d "$root/.cartridges" ]]; then
  found=.cartridges/
fi

if [[ -z "$found" ]]; then
  if [[ "$required" == "true" ]]; then
    echo '::error::A BoJ cartridge is required but no canonical cartridge path exists.'
    exit 1
  fi
  echo '::notice::BoJ cartridge is not applicable to this repository.'
  exit 0
fi

echo "BoJ cartridge present at $found."
