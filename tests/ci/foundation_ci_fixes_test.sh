#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for the CI configuration hardened in PR #232.
# These checks intentionally use only POSIX text-processing tools so they can
# run in a clean checkout without installing a YAML parser.
#
# WHAT THIS FILE DOES NOT DO (2026-10-21)
# ---------------------------------------
# It used to pin eight individual `uses:` revisions — e.g. "CodeQL init stays
# on cdf488f5". Every one of those hashes moved, so the file failed 5 of 15
# assertions against a perfectly healthy tree, and nothing ran it, so nobody
# noticed. A test that pins a revision and is not run on every change is just a
# stale copy of the tree.
#
# Revision equality is already enforced, more strictly, by the tools it was
# duplicating:
#   * scripts/check-lock-sync.sh — every `uses:` must be recorded in
#     .github/workflows/actions.lock, both directions;
#   * scripts/check-upstream-pins.sh — every reusable-workflow pin must be
#     lock-clean at its own sha;
#   * tests/ci/workflow_hardening_test.sh — pin shape, `persist-credentials`,
#     workflow_dispatch coverage.
# Both of the first two run in lock-sync-gate.yml, and this file now runs there
# too, so "nobody runs it" cannot recur.
#
# What is left here is the part nothing else checks: the Dependabot volume caps
# and the CodeQL credential setting. Those are policy numbers, not revisions,
# so they do not rot when a pin moves.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() {
    printf 'PASS %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf 'FAIL %s\n' "$1"
    FAIL=$((FAIL + 1))
}

assert_equals() {
    local description="$1" expected="$2" actual="$3"

    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected '$expected', got '${actual:-<missing>}')"
    fi
}

dependabot_limit() {
    local ecosystem="$1"

    awk -v wanted="$ecosystem" '
        /^[[:space:]]*-[[:space:]]+package-ecosystem:/ {
            current = $0
            sub(/^[^:]+:[[:space:]]*/, "", current)
            gsub(/["[:space:]]/, "", current)
            next
        }
        current == wanted && /^[[:space:]]+open-pull-requests-limit:/ {
            value = $0
            sub(/^[^:]+:[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/[[:space:]]/, "", value)
            print value
        }
    ' "$REPO_DIR/.github/dependabot.yml"
}

checkout_persist_credentials_values() {
    awk '
        /^[[:space:]]*-[[:space:]]+name:[[:space:]]+Checkout[[:space:]]*$/ {
            in_checkout = 1
            next
        }
        in_checkout && /^[[:space:]]*-[[:space:]]+name:/ { exit }
        in_checkout && /^[[:space:]]+persist-credentials:/ {
            value = $0
            sub(/^[^:]+:[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/[[:space:]]/, "", value)
            print value
        }
    ' "$REPO_DIR/.github/workflows/codeql.yml"
}

# Workflows that ship a `uses:` pin must use the full forty hex characters: a
# tag or branch can be moved under us, and a shortened sha is not a pin. This is
# deliberately independent of actions.lock — it catches `@v7` even if the
# lockfile was regenerated from the same mistake.
assert_all_workflow_refs_are_sha_pinned() {
    local workflow="$1"
    local count=0 invalid="" ref revision

    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        count=$((count + 1))
        revision="${ref##*@}"
        if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
            invalid="${invalid}${invalid:+, }$ref"
        fi
    done < <(awk '$1 == "uses:" { print $2 }' "$REPO_DIR/$workflow")

    if [ "$count" -eq 0 ]; then
        fail "$workflow contains at least one action reference"
    elif [ -n "$invalid" ]; then
        fail "$workflow uses only immutable 40-character SHA pins ($invalid)"
    else
        pass "$workflow uses only immutable 40-character SHA pins"
    fi
}

assert_equals \
    "GitHub Actions updates are capped at two open pull requests" \
    "2" \
    "$(dependabot_limit github-actions)"
assert_equals \
    "Mix updates are capped at three open pull requests" \
    "3" \
    "$(dependabot_limit mix)"
assert_equals \
    "npm updates are capped at three open pull requests" \
    "3" \
    "$(dependabot_limit npm)"
assert_equals \
    "pip updates are capped at three open pull requests" \
    "3" \
    "$(dependabot_limit pip)"

assert_equals \
    "CodeQL checkout disables persisted credentials exactly once" \
    "false" \
    "$(checkout_persist_credentials_values)"

for workflow in \
    .github/workflows/codeql.yml \
    .github/workflows/governance.yml \
    .github/workflows/hypatia-scan.yml \
    .github/workflows/scorecard.yml \
    .github/workflows/conformance.yml
do
    assert_all_workflow_refs_are_sha_pinned "$workflow"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
