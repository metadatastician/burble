#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Opt-in actual GTK window acceptance; needs a local display, no capture devices.
set -euo pipefail
: "${GOSSAMER_CHECKOUT:?Set the existing Gossamer checkout to test}"
: "${PAIRING_ARTIFACT_DIR:?Set an external build/evidence directory}"
: "${ZIG:?Set the absolute Zig 0.15.2 executable path}"

server_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
consumer_dir="$(cd -- "$GOSSAMER_CHECKOUT" && pwd)"
test "$("$ZIG" version)" = 0.15.2
mkdir -p -- "$PAIRING_ARTIFACT_DIR"
artifact_dir="$(cd -- "$PAIRING_ARTIFACT_DIR" && pwd)"
git -C "$server_dir" rev-parse HEAD
git -C "$consumer_dir" rev-parse HEAD
(
  cd -- "$consumer_dir/src/interface/ffi"
  "$ZIG" build -Doptimize=ReleaseSafe --prefix "$artifact_dir/install" \
    --cache-dir "$artifact_dir/zig-cache" --global-cache-dir "$artifact_dir/zig-global-cache"
)
cc -Wall -Wextra -Werror "$consumer_dir/src/interface/ffi/test/groove_host_live.c" \
  -I"$artifact_dir/install/include" \
  -L"$artifact_dir/install/lib" -Wl,-rpath,"$artifact_dir/install/lib" -lgossamer \
  $(pkg-config --cflags --libs webkit2gtk-4.1) \
  -o "$artifact_dir/gossamer-host-driver"
sha256sum "$artifact_dir/install/lib/libgossamer.so" "$artifact_dir/gossamer-host-driver"

export MIX_ENV=test
export MIX_DEPS_PATH="${MIX_DEPS_PATH:-$artifact_dir/burble-deps}"
export MIX_BUILD_PATH="${MIX_BUILD_PATH:-$artifact_dir/burble-build}"
export HEX_HOME="${HEX_HOME:-$artifact_dir/hex}"
export GOSSAMER_HOST_DRIVER="$artifact_dir/gossamer-host-driver"
export GOSSAMER_VOICE_DRIVER="$GOSSAMER_HOST_DRIVER"
# Turn invalid GTK object use into failure, including double-destroy on close.
export G_DEBUG=fatal-criticals
cd -- "$server_dir"
elixir --version
mix deps.get --check-locked
mix test integration/gossamer_voice_test.exs integration/gossamer_host_test.exs
