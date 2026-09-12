#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Reproducible Linux/POSIX native-library acceptance gate; no deployment.
set -euo pipefail
: "${GOSSAMER_CHECKOUT:?Set the existing Gossamer checkout to test}"
: "${PAIRING_ARTIFACT_DIR:?Set an external build/evidence directory}"
: "${ZIG:?Set the absolute Zig 0.15.2 executable path}"

server_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
consumer_dir="$(cd -- "$GOSSAMER_CHECKOUT" && pwd)"
test "$("$ZIG" version)" = 0.15.2
mkdir -p -- "$PAIRING_ARTIFACT_DIR"
artifact_dir="$(cd -- "$PAIRING_ARTIFACT_DIR" && pwd)"
test -f "$consumer_dir/src/interface/ffi/test/groove_live.c"
printf 'Burble baseline: '
git -C "$server_dir" rev-parse HEAD
printf 'Gossamer baseline: '
git -C "$consumer_dir" rev-parse HEAD

(
  cd -- "$consumer_dir/src/interface/ffi"
  "$ZIG" build -Doptimize=ReleaseSafe --prefix "$artifact_dir/install" \
    --cache-dir "$artifact_dir/zig-cache" --global-cache-dir "$artifact_dir/zig-global-cache"
)
cc -Wall -Wextra -Werror "$consumer_dir/src/interface/ffi/test/groove_live.c" \
  -L"$artifact_dir/install/lib" -Wl,-rpath,"$artifact_dir/install/lib" -lgossamer \
  -o "$artifact_dir/gossamer-live-driver"
cc -Wall -Wextra -Werror "$consumer_dir/src/interface/ffi/test/groove_voice_live.c" \
  -I"$artifact_dir/install/include" \
  -L"$artifact_dir/install/lib" -Wl,-rpath,"$artifact_dir/install/lib" -lgossamer \
  -o "$artifact_dir/gossamer-voice-driver"
sha256sum "$artifact_dir/install/lib/libgossamer.so" "$artifact_dir/gossamer-live-driver" "$artifact_dir/gossamer-voice-driver"

export MIX_ENV=test
export MIX_DEPS_PATH="${MIX_DEPS_PATH:-$artifact_dir/burble-deps}"
export MIX_BUILD_PATH="${MIX_BUILD_PATH:-$artifact_dir/burble-build}"
export HEX_HOME="${HEX_HOME:-$artifact_dir/hex}"
export GOSSAMER_PAIRING_DRIVER="$artifact_dir/gossamer-live-driver"
export GOSSAMER_VOICE_DRIVER="$artifact_dir/gossamer-voice-driver"
cd -- "$server_dir"
elixir --version
mix deps.get --check-locked
mix test integration/gossamer_pairing_test.exs integration/gossamer_voice_test.exs
