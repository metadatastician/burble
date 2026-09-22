#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-lock-sync.sh — verify .github/workflows/actions.lock is in sync with the
# workflow YAML, in BOTH directions, including job-level reusable-workflow refs.
#
# Why this exists rather than `gh actions-lock --verify-local` alone:
#   `gh actions-lock` v0.1.6 cannot see a job-level `uses:` (a reusable-workflow
#   call). Measured on this repo, 2026-09-22:
#     * mirror.yml's lock entry was stale by a whole SHA and died at startup with
#       jobs=0, yet --verify-local reported "All 30 workflows have complete
#       lockfile coverage" and fix mode did not repair it;
#     * release.yml's job-level slsa-github-generator ref was absent from the
#       lock, again unreported; and once added, --verify-local calls it `stale`
#       with "no uses: in this workflow references it" — about a ref on line 144.
#   GitHub's own startup enforcement DOES check those refs (that is what killed
#   mirror.yml), so the tool is wrong in both directions and cannot be the
#   authority. This script is.
#
# Exit 0 only when every workflow's `uses:` set equals its lockfile set exactly.
# Any mismatch exits 1. There is no warn-only mode: a desync means GitHub will
# refuse to start the run, so it must fail the job.

set -euo pipefail

WF_DIR="${1:-.github/workflows}"
LOCK="$WF_DIR/actions.lock"

if [ ! -f "$LOCK" ]; then
  echo "check-lock-sync: FATAL: no lockfile at $LOCK" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t WORKFLOWS < <(printf '%s\n' "$WF_DIR"/*.yml "$WF_DIR"/*.yaml | sort -u)
if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
  echo "check-lock-sync: FATAL: no workflow files under $WF_DIR" >&2
  exit 1
fi

awk -v lockfile="$LOCK" '
# owner/repo[/subpath...]@ref  ->  owner/repo@ref   ("" if not an external ref)
function norm(r,   at, path, ref, n, parts) {
  at = 0
  for (n = length(r); n > 0; n--) { if (substr(r, n, 1) == "@") { at = n; break } }
  if (at == 0) return ""
  path = substr(r, 1, at - 1); ref = substr(r, at + 1)
  if (path == "" || ref == "") return ""
  if (substr(path, 1, 2) == "./" || substr(path, 1, 2) == "$/") return ""   # local action
  if (split(path, parts, "/") < 2) return ""
  return parts[1] "/" parts[2] "@" ref
}

# ---------- pass 1: the lockfile ----------
FILENAME == lockfile {
  if ($0 ~ /^workflows:[[:space:]]*$/) { inwf = 1; next }
  if ($0 ~ /^[a-z_]+:/)                { inwf = 0; next }
  if (!inwf) next

  # "    '.github/workflows/x.yml':"  or  "... : []"
  if (match($0, /^    '"'"'([^'"'"']+)'"'"':/, m)) {
    cur = m[1]
    seen_path[cur] = 1
    if ($0 ~ /\[\][[:space:]]*$/) cur_has_inline_empty = 1
    next
  }
  if (match($0, /^        - '"'"'([^'"'"']+)'"'"'[[:space:]]*$/, m) && cur != "") {
    lock[cur, m[1]] = 1
    lockcount[cur]++
    next
  }
  next
}

# ---------- pass 2: the workflow YAML ----------
FNR == 1 { wf = FILENAME }
{
  line = $0
  sub(/[[:space:]]+#.*$/, "", line)              # strip trailing comment
  if (match(line, /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*(.+)$/, m)) {
    raw = m[1]
    gsub(/^["'"'"']|["'"'"']$/, "", raw)
    gsub(/[[:space:]]+$/, "", raw)
    if (raw ~ /^\$\//) { dollar[wf] = dollar[wf] " " raw; next }   # known corruption
    n = norm(raw)
    if (n != "") { uses[wf, n] = 1; useslist[wf] = useslist[wf] " " n }
  }
}

END {
  bad = 0
  for (i = 1; i < ARGC; i++) {
    wf = ARGV[i]
    if (wf == lockfile) continue
    key = wf
    sub(/.*\//, "", key)
    key = ".github/workflows/" key          # the lockfile always uses this canonical path

    if (dollar[wf] != "") {
      printf "FAIL %s\n     invalid local-action rewrite (uses: $/...):%s\n", key, dollar[wf]
      bad = 1
    }

    # --- direction 1: every uses: must be locked under THIS path ---
    nu = split(useslist[wf], u, " ")
    delete uniq; missing = ""
    for (j = 1; j <= nu; j++) {
      if (u[j] == "" || (u[j] in uniq)) continue
      uniq[u[j]] = 1
      if (!((key SUBSEP u[j]) in lock)) missing = missing " " u[j]
    }
    if (missing != "") {
      if (!(key in seen_path))
        printf "FAIL %s\n     not onboarded: no lockfile entry for this path\n     unlocked refs:%s\n", key, missing
      else
        printf "FAIL %s\n     refs missing from the lockfile:%s\n", key, missing
      bad = 1
    }

    # --- direction 2: every lock entry must be referenced by this workflow ---
    orphan = ""
    for (k in lock) {
      split(k, kp, SUBSEP)
      if (kp[1] != key) continue
      if (!((wf SUBSEP kp[2]) in uses)) orphan = orphan " " kp[2]
    }
    if (orphan != "") {
      printf "FAIL %s\n     stale lockfile entries, no uses: references them:%s\n", key, orphan
      bad = 1
    }
  }

  # --- lockfile entries for workflow files that no longer exist ---
  for (p in seen_path) {
    found = 0
    for (i = 1; i < ARGC; i++) {
      q = ARGV[i]; if (q == lockfile) continue
      sub(/.*\//, "", q); q = ".github/workflows/" q
      if (q == p) { found = 1; break }
    }
    if (!found) { printf "FAIL %s\n     lockfile entry for a workflow file that does not exist\n", p; bad = 1 }
  }

  if (bad) {
    print ""
    print "actions.lock is OUT OF SYNC with the workflow YAML."
    print "GitHub refuses such a run at startup: zero jobs are created and the run"
    print "reports \"This run likely failed because of a workflow file issue.\""
    print "Fix: run `gh actions-lock --no-migrate-local-actions`, then review the diff"
    print "(it does not handle job-level reusable-workflow refs, and it can de-pin"
    print "bare SHAs to floating tags - both must be corrected by hand)."
    exit 1
  }
  print "actions.lock is in sync: every uses: is locked under its own workflow path,"
  print "and every lockfile entry is referenced. Job-level reusable-workflow refs included."
}
' "$LOCK" "${WORKFLOWS[@]}"
