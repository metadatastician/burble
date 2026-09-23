#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

root=${GITHUB_WORKSPACE:-.}
required=${AFFIRMATION_REQUIRED:-false}
aff_file=

for candidate in AFFIRMATION.adoc AFFIRMATION.md AFFIRMATION; do
  if [[ -f "$root/$candidate" ]]; then
    aff_file=$candidate
    break
  fi
done

if [[ -z "$aff_file" ]]; then
  if [[ "$required" == "true" ]]; then
    echo "::error::AFFIRMATION.adoc is required by the declared governance-tier capability."
    exit 1
  fi
  echo "::notice::AFFIRMATION is not applicable: governance-tier was not required."
  exit 0
fi

path=$root/$aff_file
echo "Found AFFIRMATION document: $aff_file"

substantive_lines=$(awk '!/^[[:space:]]*(#|\/\/|;|$)/ { count++ } END { print count + 0 }' "$path")
if (( substantive_lines < 5 )); then
  echo "::error::$aff_file has only $substantive_lines substantive lines; it is a stub, not an affirmation."
  exit 1
fi

if grep -qiE '\{\{|TODO: update|<PROJECT|YOUR_PROJECT|lorem ipsum|example\.com' "$path"; then
  echo "::error::$aff_file contains template placeholders."
  exit 1
fi

# The signature is the signature on the commit containing this content. Text
# such as "Signed:" inside the document proves nothing. Shallow checkouts may
# not contain the file-changing commit, so report that limitation honestly.
signature=N
last_update_ts=
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  signature=$(git -C "$root" log -1 --format='%G?' -- "$aff_file" 2>/dev/null || true)
  last_update_ts=$(git -C "$root" log -1 --format='%at' -- "$aff_file" 2>/dev/null || true)
fi

case "$signature" in
  G) echo "Affirmation commit signature verified with a trusted key." ;;
  U) echo "::notice::Affirmation commit has a valid signature from an untrusted or locally unknown key." ;;
  B|R|E) echo "::error::Affirmation commit signature is bad, revoked, or failed verification."; exit 1 ;;
  *) echo "::notice::Affirmation commit signature could not be verified from the available Git history." ;;
esac

# A dated affirmation is a frozen receipt, not a claim that remains current
# forever. Report age without invalidating historical evidence or forcing an
# empty monthly rewrite.
if [[ -n "$last_update_ts" ]]; then
  current_ts=$(date +%s)
  age_days=$(( (current_ts - last_update_ts) / 86400 ))
  if (( age_days > 28 )); then
    echo "::warning::$aff_file is a $age_days-day-old snapshot; verify its anchor before relying on it as current."
  else
    echo "$aff_file snapshot age: $age_days days."
  fi
fi

echo "AFFIRMATION document validation passed."
