#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for the CI configuration hardened in PR #232.
# These checks intentionally use only POSIX text-processing tools so they can
# run in a clean checkout without installing a YAML parser.

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

workflow_refs() {
    local workflow="$1" action="$2"

    awk -v prefix="$action@" '
        $1 == "uses:" && index($2, prefix) == 1 { print $2 }
    ' "$REPO_DIR/$workflow"
}

assert_exact_workflow_ref() {
    local description="$1" workflow="$2" action="$3" expected_sha="$4"
    local actual

    actual="$(workflow_refs "$workflow" "$action")"
    assert_equals "$description" "$action@$expected_sha" "$actual"
}

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

assert_exact_workflow_ref \
    "CodeQL checkout stays on the reviewed revision" \
    ".github/workflows/codeql.yml" \
    "actions/checkout" \
    "3d3c42e5aac5ba805825da76410c181273ba90b1"
assert_exact_workflow_ref \
    "CodeQL initialization stays on the reviewed revision" \
    ".github/workflows/codeql.yml" \
    "github/codeql-action/init" \
    "cdf488f595d80d6e07e03d4674febd5ab45fa938"
assert_exact_workflow_ref \
    "CodeQL analysis uses the same reviewed revision" \
    ".github/workflows/codeql.yml" \
    "github/codeql-action/analyze" \
    "cdf488f595d80d6e07e03d4674febd5ab45fa938"
assert_equals \
    "CodeQL checkout disables persisted credentials exactly once" \
    "false" \
    "$(checkout_persist_credentials_values)"

assert_exact_workflow_ref \
    "governance uses its reviewed reusable workflow revision" \
    ".github/workflows/governance.yml" \
    "hyperpolymath/standards/.github/workflows/governance-reusable.yml" \
    "8f31a5a4ba591d544b65f91f6d78b136e07756f0"
assert_exact_workflow_ref \
    "Hypatia uses its reviewed reusable workflow revision" \
    ".github/workflows/hypatia-scan.yml" \
    "hyperpolymath/standards/.github/workflows/hypatia-scan-reusable.yml" \
    "cc58c0cb23f73fc2019ce85a56a468e5248a93b3"
assert_exact_workflow_ref \
    "Scorecard uses its reviewed reusable workflow revision" \
    ".github/workflows/scorecard.yml" \
    "hyperpolymath/standards/.github/workflows/scorecard-reusable.yml" \
    "8750b94ac1bbe8c51ad13fe106669b13478f0b62"

# Negative/regression coverage: a tag, branch, shortened SHA, or a second
# duplicate reference in any affected workflow must fail this test.
for workflow in \
    .github/workflows/codeql.yml \
    .github/workflows/governance.yml \
    .github/workflows/hypatia-scan.yml \
    .github/workflows/scorecard.yml
do
    assert_all_workflow_refs_are_sha_pinned "$workflow"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
