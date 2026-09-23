#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/verified-installer.sh
source "$REPO_DIR/scripts/lib/verified-installer.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
export INSTALL_TEST_MARKER="$TEST_DIR/executed"
export INSTALL_TEST_PAYLOAD="$TEST_DIR/payload.sh"
export INSTALL_TEST_CURL_EXIT=0
export TMPDIR="$TEST_DIR/staging"
mkdir -p "$TEST_DIR/bin" "$TMPDIR"
cat > "$INSTALL_TEST_PAYLOAD" <<'SCRIPT'
printf 'executed\n' >> "$INSTALL_TEST_MARKER"
SCRIPT
cat > "$TEST_DIR/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    cp "$INSTALL_TEST_PAYLOAD" "$2"
    exit "$INSTALL_TEST_CURL_EXIT"
  fi
  shift
done
exit 99
SCRIPT
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"
DIGEST="$(sha256sum "$INSTALL_TEST_PAYLOAD")"
DIGEST="${DIGEST%% *}"
URL=https://example.invalid/immutable-installer.sh

run_verified_installer "$URL" "$DIGEST"
test "$(cat "$INSTALL_TEST_MARKER")" = executed
rm "$INSTALL_TEST_MARKER"

printf '# tampered\n' >> "$INSTALL_TEST_PAYLOAD"
if run_verified_installer "$URL" "$DIGEST"; then
  echo 'FAIL: tampered installer was accepted' >&2; exit 1
fi
test ! -e "$INSTALL_TEST_MARKER"

# A downloader can write a complete file and still fail; never execute it.
DIGEST="$(sha256sum "$INSTALL_TEST_PAYLOAD")"
DIGEST="${DIGEST%% *}"
export INSTALL_TEST_CURL_EXIT=22
if run_verified_installer "$URL" "$DIGEST"; then
  echo 'FAIL: failed download was accepted' >&2; exit 1
fi
test ! -e "$INSTALL_TEST_MARKER"
export INSTALL_TEST_CURL_EXIT=0

printf 'exit 17\n' > "$INSTALL_TEST_PAYLOAD"
DIGEST="$(sha256sum "$INSTALL_TEST_PAYLOAD")"
DIGEST="${DIGEST%% *}"
status=0
run_verified_installer "$URL" "$DIGEST" || status=$?
test "$status" -eq 17

if run_verified_installer http://example.invalid/installer.sh "$DIGEST"; then
  echo 'FAIL: HTTP installer was accepted' >&2; exit 1
fi
if run_verified_installer "$URL" invalid; then
  echo 'FAIL: invalid digest was accepted' >&2; exit 1
fi
test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
echo 'PASS: verified execution, tamper/download rejection, exit propagation, input validation, and cleanup'
