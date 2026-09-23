#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

GITHUB_WORKSPACE=$fixture CITATION_REQUIRED=false "$here/check.sh"

if GITHUB_WORKSPACE=$fixture CITATION_REQUIRED=true "$here/check.sh"; then
  echo 'required-but-absent citation unexpectedly passed' >&2
  exit 1
fi

printf '%s\n' 'cff-version: 1.2.0' > "$fixture/CITATION.cff"
if GITHUB_WORKSPACE=$fixture CITATION_REQUIRED=true "$here/check.sh"; then
  echo 'malformed citation unexpectedly passed' >&2
  exit 1
fi

printf '%s\n' \
  'cff-version: 1.2.0' \
  'message: "Please cite this software."' \
  'title: "Controlled fixture"' \
  'authors:' \
  '  - family-names: "Example"' \
  '    given-names: "Ada"' \
  > "$fixture/CITATION.cff"
GITHUB_WORKSPACE=$fixture CITATION_REQUIRED=true "$here/check.sh"

echo 'referencing-check controls passed'
