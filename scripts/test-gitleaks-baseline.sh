#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the real scanner, including a different key in the same vector file.
set -euo pipefail
baseline="${1:?Pass the pinned Standards estate-baseline.toml}"
scanner="${2:-gitleaks}"
root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/source/.machine_readable/test-vectors" "$fixture/source/server/test/burble_web/plugs"
cp "$root/.gitleaks.toml" "$fixture/.gitleaks.toml"
cp "$baseline" "$fixture/.gitleaks-estate.toml"
cp "$root/.machine_readable/test-vectors/ble-spa-v1.json" "$fixture/source/.machine_readable/test-vectors/ble-spa-v1.json"
cp "$root/server/test/burble_web/plugs/input_sanitizer_test.exs" "$fixture/source/server/test/burble_web/plugs/"
cd "$fixture"
"$scanner" detect --no-git --source source --config .gitleaks.toml --redact --verbose --exit-code 1
# A generated, non-live credential-shaped canary is NOT one of the five
# published conformance values. Appending it to that exact file detects any
# accidental path-wide or general-hex allowlist. Never print its value.
canary="$(openssl rand -hex 32)"
printf '\n{"room_secret_hex":"%s"}\n' "$canary" >> source/.machine_readable/test-vectors/ble-spa-v1.json
set +e
"$scanner" detect --no-git --source source --config .gitleaks.toml --redact --exit-code 1 --report-format json --report-path report.json
status=$?
set -e
test "$status" -eq 1
jq -e 'length == 1 and .[0].RuleID == "generic-api-key" and (.[0].File | endswith("ble-spa-v1.json"))' report.json >/dev/null
echo 'PASS: published fixtures accepted; another key in the same file rejected.'
