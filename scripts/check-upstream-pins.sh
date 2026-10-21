#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-upstream-pins.sh — are the reusable-workflow pins we call LOCK-CLEAN?
#
# WHY THIS EXISTS
# ---------------
# `uses: org/repo/.github/workflows/x.yml@<sha>` is resolved at workflow
# startup, and GitHub validates every action the CALLEE uses against the
# callee's OWN `.github/workflows/actions.lock` **as that file exists at that
# sha**. If one of those records is unusable, the caller's job dies during
# "Set up job", the run reports `failure` rather than `startup_failure`, and
# the only clue is an annotation naming an action we never referenced:
#
#   Unable to resolve action `erlef/setup-beam@54075bcc...`:
#   invalid lockfile pin. Run `gh actions-lock` to update the lockfile
#
# That is how three of burble's checks (Hypatia scan, Validate Hypatia
# Baseline, Scorecard) were permanently red on `main` in October 2026 while
# nothing in this repository was wrong: the pins `hyperpolymath/standards`
# @0f2d9b54 and @9f68971b, and those commits' lockfiles, recorded 13 and 16
# actions whose `ref:` was the commit SHA itself. A `ref:` that is a 40-hex SHA
# is rejected by the runner (standards#1271) — the lock is only valid when
# `ref:` is the tag or branch the SHA was resolved from.
#
# `scripts/check-lock-sync.sh` cannot see this: it checks OUR lock against OUR
# workflows, and both were consistent. The defect lives one hop away, in the
# repository we call. This script is that hop.
#
# WHAT IT CHECKS, per pinned reusable workflow:
#   1. the callee's lock exists at that sha (absent = NO-LOCK: not fatal, but
#      reported, per hyperpolymath/standards scripts/lock-selfcheck.sh);
#   2. every action the callee's workflow uses has a record in that lock
#      (a missing record is a dangling edge — also rejected at startup);
#   3. no such record has `ref:` equal to its own 40-hex commit SHA.
#
# Anything in 2 or 3 fails the job. That is the whole point: the failure it
# prevents is invisible in this repository's own files.
#
# USAGE
#   scripts/check-upstream-pins.sh                     # fetch from GitHub (CI)
#   STANDARDS_SRC=/path/to/standards scripts/check-upstream-pins.sh
#                                                      # offline: read that repo's
#                                                      # git objects instead
#   WF_DIR=.github/workflows (default)
#
# Exit: 0 clean (or nothing pinned), 1 a pin is poisoned, 2 on misuse.
# A fetch that fails for network reasons is a warning, not a verdict: this gate
# must not manufacture red from a flaky mirror. If you need certainty, run it
# with STANDARDS_SRC against a checkout.

set -uo pipefail

WF_DIR="${WF_DIR:-.github/workflows}"
STANDARDS_SRC="${STANDARDS_SRC:-}"

if [ ! -d "$WF_DIR" ]; then
  echo "check-upstream-pins: FATAL: no workflow directory at $WF_DIR" >&2
  exit 2
fi

# fetch <owner/repo> <sha> <path-in-repo>
# Prints the file and returns 0, or returns 1 without printing.
fetch() {
  local repo="$1" sha="$2" path="$3"
  if [ -n "$STANDARDS_SRC" ] && [ "$repo" = "hyperpolymath/standards" ]; then
    git -C "$STANDARDS_SRC" cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
    git -C "$STANDARDS_SRC" show "${sha}:${path}" 2>/dev/null
    return $?
  fi
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --max-time 30 \
    "https://raw.githubusercontent.com/${repo}/${sha}/${path}" 2>/dev/null
}

# Every `uses:` in a workflow that calls a reusable workflow, as
# "<owner/repo> <sha> <path-in-repo>", de-duplicated.
pins() {
  grep -hE "^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/" \
    "$WF_DIR"/*.yml "$WF_DIR"/*.yaml 2>/dev/null \
  | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/["'\'']//g; s/[[:space:]]+$//' \
  | awk -F'@' '
      # mawk (the default on Debian and Ubuntu) has no interval expressions
      # while gawk does, so spell the 40-hex test out: same meaning on both.
      NF == 2 && length($2) == 40 && $2 ~ /^[0-9a-f]+$/ {
        n = split($1, p, "/")
        if (n < 5) next
        repo = p[1] "/" p[2]
        wf = p[3]
        for (i = 4; i <= n; i++) wf = wf "/" p[i]
        print repo, $2, wf
      }' \
  | sort -u
}

# The actions a callee workflow uses, normalised to "<owner/repo>@<sha>".
# Sub-path actions collapse to their repository: the lock keys repositories.
# (github/codeql-action/upload-sarif@X -> github/codeql-action@X)
callee_actions() {
  awk '
    /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/["\047]/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^\.\// || line ~ /^docker:\/\//) next
      if (index(line, "@") == 0) next
      n = split(line, parts, "@")
      ref = parts[n]
      path = line
      sub(/@[^@]*$/, "", path)
      m = split(path, seg, "/")
      if (m < 2) next
      if (path ~ /\.ya?ml$/) next      # a nested reusable call, not an action
      print tolower(seg[1] "/" seg[2] "@" ref)
    }'
}

# The `ref:` the lock records for a dependency key (empty if unrecorded).
lock_ref_for() {
  local lock="$1" key="$2"
  printf '%s\n' "$lock" | KEY="$key" awk '
    /^dependencies:/ { in_dep = 1; next }
    /^[a-zA-Z_]+:/ { in_dep = 0; cur = ""; next }
    !in_dep { next }
    /^    [^ ].*:$/ {
      cur = $0
      sub(/^    /, "", cur)
      sub(/:$/, "", cur)
      gsub(/["\047]/, "", cur)
      cur = tolower(cur)
      next
    }
    /^        ref:/ && cur == tolower(ENVIRON["KEY"]) {
      r = $0
      sub(/^        ref:[[:space:]]*/, "", r)
      gsub(/["\047]/, "", r)
      sub(/[[:space:]]+$/, "", r)
      print r
      exit
    }'
}

status=0
checked=0
declare -a pin_list=()
while IFS= read -r line; do
  [ -n "$line" ] && pin_list+=("$line")
done < <(pins)

if [ "${#pin_list[@]}" -eq 0 ]; then
  echo "check-upstream-pins: no reusable-workflow pins under $WF_DIR — nothing to check."
  exit 0
fi

echo "check-upstream-pins: examining ${#pin_list[@]} reusable-workflow pin(s)"
if [ -n "$STANDARDS_SRC" ]; then
  echo "                      reading hyperpolymath/standards from $STANDARDS_SRC (offline mode)"
else
  echo "                      reading lockfiles from raw.githubusercontent.com"
fi

for entry in "${pin_list[@]}"; do
  read -r repo sha wf <<<"$entry"
  short="${sha:0:12}"
  checked=$((checked + 1))
  echo
  echo "── ${repo}/${wf}@${short}"

  if ! body="$(fetch "$repo" "$sha" "$wf")"; then
    echo "   ⚠ could not fetch the called workflow at this sha (network, or the sha is gone)."
    echo "     Not a verdict — re-run, or set STANDARDS_SRC to a local checkout to be sure."
    continue
  fi

  if ! lock="$(fetch "$repo" "$sha" ".github/workflows/actions.lock")"; then
    echo "   ⚠ NO-LOCK: ${repo} has no actions.lock at this sha."
    echo "     Not startup-fatal (there is nothing to validate against), but callers"
    echo "     pinned here get no action-pinning guarantee either."
    continue
  fi

  bad=0
  while IFS= read -r action; do
    [ -n "$action" ] || continue
    ref="$(lock_ref_for "$lock" "$action")"
    if [ -z "$ref" ]; then
      echo "   ✗ ${action}: used by the callee, not recorded in its lock (dangling edge)"
      bad=$((bad + 1))
    elif printf '%s' "$ref" | grep -qE '^[0-9a-fA-F]{40}$'; then
      echo "   ✗ ${action}: lock records ref: '${ref}' — a self-SHA ref, which the"
      echo "     runner rejects as an invalid lockfile pin (standards#1271)"
      bad=$((bad + 1))
    fi
  done < <(printf '%s\n' "$body" | callee_actions | sort -u)

  if [ "$bad" -gt 0 ]; then
    echo "   VERDICT: POISON — ${bad} problem(s). This pin cannot start a job."
    echo "            Fix: pin a lock-clean commit. Candidate shas can be checked with"
    echo "                 STANDARDS_SRC=<checkout> $0"
    status=1
  else
    echo "   VERDICT: OK — every action the callee uses is keyed and tag-ref'd."
  fi
done

echo
if [ "$status" -eq 0 ]; then
  echo "check-upstream-pins: ${checked} pin(s) clean"
else
  echo "check-upstream-pins: FAILED — at least one pin is poisoned upstream" >&2
fi
exit "$status"
