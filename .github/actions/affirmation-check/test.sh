#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=false "$here/check.sh"

if GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=true "$here/check.sh"; then
  echo "required-but-absent affirmation unexpectedly passed" >&2
  exit 1
fi

printf '= AFFIRMATION\n' > "$fixture/AFFIRMATION.adoc"
if GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=true "$here/check.sh"; then
  echo "stub affirmation unexpectedly passed" >&2
  exit 1
fi

printf '%s\n' \
  '= AFFIRMATION — controlled fixture' \
  'This snapshot makes a falsifiable claim.' \
  'The claim is anchored to a named revision.' \
  'Tests were run and their scope is stated.' \
  'Unproved properties are not called proved.' \
  'Later revisions must be assessed separately.' \
  > "$fixture/AFFIRMATION.adoc"
GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=true "$here/check.sh"

echo 'affirmation-check controls passed'
