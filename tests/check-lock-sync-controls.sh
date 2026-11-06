#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
wf="$fixture/repo/.github/workflows"
mkdir -p "$wf"
passed=0
expect() {
  local wanted=$1 label=$2 status=0
  bash "$repo/scripts/check-lock-sync.sh" "$wf" > "$fixture/output" 2>&1 || status=$?
  if [[ "$status" != "$wanted" ]]; then
    cat "$fixture/output" >&2
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$wanted" "$status" >&2
    exit 1
  fi
  passed=$((passed + 1))
  printf 'PASS %s\n' "$label"
}
action_workflow() {
  cat > "$wf/probe.yml" <<'YAML'
name: probe
on: push
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: example/action@v1
YAML
}
good_lock() {
  cat > "$wf/actions.lock" <<'LOCK'
version: 'v0.0.3'
workflows:
    '.github/workflows/probe.yml':
        - 'example/action@v1'
dependencies:
    'example/action@v1':
        ref: 'v1'
        commit: 'sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        owner_id: 1
        repo_id: 2
LOCK
}
action_workflow
good_lock
expect 0 'complete action lock'
sed '/^dependencies:/,$d' "$wf/actions.lock" > "$fixture/cut"
mv "$fixture/cut" "$wf/actions.lock"
printf 'dependencies: {}\n' >> "$wf/actions.lock"
expect 1 'missing direct dependency record'
good_lock
cat >> "$wf/actions.lock" <<'LOCK'
        uses:
            - 'example/helper@v2'
LOCK
expect 1 'missing transitive dependency record'
cat >> "$wf/actions.lock" <<'LOCK'
    'example/helper@v2':
        ref: 'v2'
        commit: 'sha1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        owner_id: 1
        repo_id: 3
LOCK
expect 0 'complete transitive dependency record'
good_lock
printf 'name: empty\non: push\njobs: {}\n' > "$wf/empty.yml"
expect 1 'unlisted zero-action workflow'
rm -- "$wf/empty.yml"
cat > "$wf/probe.yml" <<'YAML'
name: probe
on: push
jobs:
  child:
    uses: example/action/.github/workflows/child.yml@v1
YAML
cat > "$wf/actions.lock" <<'LOCK'
version: 'v0.0.3'
workflows:
    '.github/workflows/probe.yml': []
dependencies: {}
LOCK
expect 0 'omitted reusable call uses its callee-owned lock'
cat >> "$wf/probe.yml" <<'YAML'
  inline:
    runs-on: ubuntu-24.04
    steps:
      - uses: example/action@v1
YAML
expect 1 'reusable call cannot hide an unlocked step at the same coordinate'
action_workflow
good_lock
mkdir -p "$fixture/repo/.github/actions/local"
cat > "$wf/probe.yml" <<'YAML'
name: probe
on: push
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: ./.github/actions/local
YAML
cat > "$fixture/repo/.github/actions/local/action.yml" <<'YAML'
name: local
runs:
  using: composite
  steps:
    - uses: example/action@v1
YAML
expect 0 'local composite dependency remains locked under its caller'
sed '/^dependencies:/,$d' "$wf/actions.lock" > "$fixture/cut"
mv "$fixture/cut" "$wf/actions.lock"
printf 'dependencies: {}\n' >> "$wf/actions.lock"
expect 1 'local composite cannot hide a missing dependency record'
printf 'passed %s controls\n' "$passed"
