#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

root=${GITHUB_WORKSPACE:-.}
required=${CITATION_REQUIRED:-false}
cff=$root/CITATION.cff

if [[ ! -f "$cff" ]]; then
  if [[ "$required" == "true" ]]; then
    echo "::error::CITATION.cff is required for this repository."
    exit 1
  fi
  echo "::notice::CITATION.cff is not applicable to this repository."
  exit 0
fi

fail=0
for field in cff-version message title; do
  if ! grep -qE "^${field}:[[:space:]]*[^[:space:]]" "$cff"; then
    echo "::error::CITATION.cff is missing the required top-level '$field' field."
    fail=1
  fi
done

if ! grep -qE '^authors:[[:space:]]*$' "$cff"; then
  echo "::error::CITATION.cff is missing the required top-level 'authors' sequence."
  fail=1
fi

if ! grep -qE '^[[:space:]]+-[[:space:]]+(family-names|name):[[:space:]]*[^[:space:]]' "$cff"; then
  echo "::error::CITATION.cff has no named author entry."
  fail=1
fi

if (( fail )); then
  exit 1
fi

echo 'CITATION.cff core-field validation passed.'
