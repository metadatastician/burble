#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
wf="$fixture/repo/.github/workflows"
mkdir -p "$wf"
passed=0
edit_file() {
  local expression=$1 file=$2
  sed -E "$expression" "$file" > "$fixture/edited"
  mv "$fixture/edited" "$file"
}
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
cat > "$wf/actions.lock" <<'LOCK'
version: 'v0.0.3'
workflows:
    '.github/workflows/probe.yml': []
dependencies: {}
LOCK
rm "$fixture/repo/.github/actions/local/action.yml"
expect 1 'missing local action metadata is fatal'
cat > "$wf/probe.yml" <<'YAML'
jobs:
  child:
    uses: ./.github/workflows/missing.yml
YAML
expect 1 'missing local reusable workflow is fatal'
for scalar in '|' '>-'; do
  cat > "$wf/probe.yml" <<YAML
jobs:
  test:
    steps:
      - run: $scalar
          echo 'sample generated YAML'
          uses: ./.github/actions/example-only
YAML
  expect 0 "sample local use in block scalar is ignored: $scalar"
  printf '      - uses: ./.github/actions/actually-missing\n' >> "$wf/probe.yml"
  expect 1 "real local use after block scalar is enforced: $scalar"
done
printf 'jobs: {}\n' > "$wf/probe.yml"
for value in null '' false '[null]'; do
  printf "workflows:\n    '.github/workflows/probe.yml': %s\ndependencies: {}\n" "$value" > "$wf/actions.lock"
  expect 1 "malformed workflow value is refused: $value"
done
printf "workflows:\n    '.github/workflows/probe.yml': []\ndependencies: {}\n" > "$wf/actions.lock"
for suffix in yml yaml; do
  mkdir -p "$fixture/repo/.github/actions/valid.$suffix"
  printf 'runs:\n  using: composite\n  steps: []\n' > "$fixture/repo/.github/actions/valid.$suffix/action.yml"
  printf 'jobs:\n  test:\n    steps:\n      - uses: ./.github/actions/valid.%s\n' "$suffix" > "$wf/probe.yml"
  expect 0 "local action directory may end in .$suffix"
done
action_workflow
for field in ref commit owner_id repo_id; do
  good_lock
  edit_file "/^        $field:/d" "$wf/actions.lock"
  expect 1 "missing required record field: $field"
done
good_lock
edit_file "s/^    'example\/action@v1':$/    'example\/action@v1': null/; /^        (ref|commit|owner_id|repo_id):/d" "$wf/actions.lock"
expect 1 'null dependency record'
good_lock
edit_file "s/^        commit:.*/        commit: 'sha1-short'/" "$wf/actions.lock"
expect 1 'malformed commit digest'
good_lock
edit_file "s/^        owner_id:.*/        owner_id: '1'/" "$wf/actions.lock"
expect 1 'quoted owner id is not an integer'
good_lock
edit_file "/^        ref:/p" "$wf/actions.lock"
expect 1 'duplicate required record field'
good_lock
edit_file 's/example\/action@v1/example\/action@Release@2026/g' "$wf/probe.yml"
edit_file 's/example\/action@v1/example\/action@Release@2026/g' "$wf/actions.lock"
edit_file "s/ref: 'v1'/ref: 'Release@2026'/" "$wf/actions.lock"
expect 0 'embedded at-sign preserves the complete ref'
edit_file "s/^    'example\/action@Release@2026':/    'example\/action@release@2026':/" "$wf/actions.lock"
expect 1 'embedded at-sign does not hide a ref-case mismatch'
action_workflow
good_lock
edit_file '/^        (ref|commit|owner_id|repo_id):/s/$/ # provenance/' "$wf/actions.lock"
expect 0 'inline comments on required fields are accepted'
edit_file 's/example\/action@v1/example\/action@v#1/g' "$wf/probe.yml"
good_lock
edit_file "s/example\/action@v1/example\/action@v#1/g; s/ref: 'v1'/ref: 'v#1' # literal hash/" "$wf/actions.lock"
expect 0 'hash inside a quoted ref is preserved'
action_workflow
for value in "'''" "'unclosed" '"v1"junk' '"\q"' '"\U00110000"' '"\uD800"'; do
  good_lock
  edit_file '/^        ref:/d' "$wf/actions.lock"
  printf '        ref: %s\n' "$value" >> "$wf/actions.lock"
  expect 1 "malformed quoted scalar is refused: $value"
done
good_lock
edit_file '/^        ref:/d' "$wf/actions.lock"
printf '        ref: "%s"\n' '\u0076\u0031' >> "$wf/actions.lock"
expect 0 'valid escaped Unicode ref scalar is accepted'
good_lock
printf 'dependencies: {}\n' >> "$wf/actions.lock"
expect 1 'duplicate dependency section is refused'
good_lock
printf 'workflows: {}\n' >> "$wf/actions.lock"
expect 1 'duplicate workflow section is refused'
good_lock
printf "        uses: ['example/helper@v2']\n" >> "$wf/actions.lock"
expect 1 'flow-style transitive dependency cannot omit its record'
cat >> "$wf/actions.lock" <<'LOCK'
    'example/helper@v2':
        ref: 'v2'
        commit: 'sha1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        owner_id: 1
        repo_id: 3
LOCK
expect 0 'flow-style transitive dependency with its record passes'
good_lock
cat >> "$wf/probe.yml" <<'YAML'
        with:
          uses: ./ordinary-input-data
env:
  uses: ./ordinary-environment-data
YAML
expect 0 'ordinary uses keys in environment and action inputs are ignored'
printf "workflows:\n    '.github/workflows/probe.yml': []\ndependencies: {}\n" > "$wf/actions.lock"
for scalar in '|' '>-'; do
  cat > "$wf/probe.yml" <<YAML
jobs:
  test:
    steps:
      - run: $scalar
          echo 'sample YAML'
          uses: example/not-a-dependency@v1
YAML
  expect 0 "sample external use in block scalar is ignored: $scalar"
done
action_workflow
good_lock
edit_file "s/^    'example\/action@v1':/    'example\/action\/subdir@v1':/" "$wf/actions.lock"
expect 1 'dependency record keys cannot include action subpaths'
good_lock
edit_file 's/uses: example\/action@v1/uses: example\/action\/subdir@v1/' "$wf/probe.yml"
expect 0 'action uses may include a subpath with a repository-owned record'
action_workflow
good_lock
edit_file "s/^    'example\/action@v1':/    'example\/act!on@v1':/" "$wf/actions.lock"
expect 1 'dependency record repository names use coordinate syntax'
good_lock
printf 'jobs:\n  test:\n    steps:\n      - uses: ./\n' > "$wf/probe.yml"
printf 'runs:\n  using: composite\n  steps:\n    - uses: example/action@v1\n' > "$fixture/repo/action.yml"
expect 0 'root local composite contributes its remote references'
sed '/^dependencies:/,$d' "$wf/actions.lock" > "$fixture/cut"
mv "$fixture/cut" "$wf/actions.lock"
printf 'dependencies: {}\n' >> "$wf/actions.lock"
expect 1 'root composite cannot hide a missing remote dependency record'
rm "$fixture/repo/action.yml"
printf "workflows:\n    '.github/workflows/probe.yml': []\ndependencies: {}\n" > "$wf/actions.lock"
expect 1 'root local action without metadata is refused'
printf 'passed %s controls\n' "$passed"
