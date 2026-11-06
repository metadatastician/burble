#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# Keep aligned with elixir-ci.yml and joinery-native.yml. Zig's build API is
# versioned: presence alone, or `zig --version`, does not establish compatibility.
expected=0.15.2
if ! actual=$(zig version 2>/dev/null); then
  printf '  [FAIL] Zig — unable to run zig version (need %s)\n' "$expected" >&2
  exit 1
fi
if [[ "$actual" != "$expected" ]]; then
  printf '  [FAIL] Zig — %s installed; tested toolchain is %s\n' "$actual" "$expected" >&2
  exit 1
fi
printf '  [OK]   Zig — %s\n' "$actual"
