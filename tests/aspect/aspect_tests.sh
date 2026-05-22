#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

use_rg=false
if command -v rg >/dev/null 2>&1; then
    use_rg=true
fi

echo "--- Aspect: License headers ---"
if [ "${use_rg}" = true ]; then
    rg -n -m 1 "SPDX-License-Identifier" . \
        --glob '!**/.git/**' \
        --glob '!**/node_modules/**' \
        --glob '!**/_build/**' \
        >/dev/null
else
    grep -Rsm1 "SPDX-License-Identifier" . \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=_build \
        >/dev/null
fi

echo "--- Aspect: No secrets in source ---"
if [ "${use_rg}" = true ]; then
    candidate_hits="$(
        rg -n -S "AI_KEY|API_KEY|SECRET_KEY|SECRET_KEY_BASE|GUARDIAN_SECRET|VERISIMDB_API_KEY" . \
            --glob '!**/.git/**' \
            --glob '!**/node_modules/**' \
            --glob '!**/_build/**' || true
    )"
else
    candidate_hits="$(
        grep -RsnE "AI_KEY|API_KEY|SECRET_KEY|SECRET_KEY_BASE|GUARDIAN_SECRET|VERISIMDB_API_KEY" . \
            --exclude-dir=.git \
            --exclude-dir=node_modules \
            --exclude-dir=_build || true
    )"
fi

candidate_hits="$(
    printf "%s\n" "${candidate_hits}" | grep -Ev \
        "PLACEHOLDER|EXAMPLE|System\\.get_env|get_env\\(|phx\\.gen\\.secret|defaults to|missing\\.|<mix|^\\s*#|^\\s*//" || true
)"
secret_hits="$(
    printf "%s\n" "${candidate_hits}" | grep -E \
        "(=|:)[[:space:]]*['\"][^'\"]{8,}['\"]|=[[:space:]]*[A-Za-z0-9_+\\/=.-]{16,}" || true
)"
if [ -n "${secret_hits}" ]; then
    echo "Potential secrets found:"
    printf "%s\n" "${secret_hits}"
    exit 1
fi

echo "--- Aspect: No Node.js artifacts ---"
[ ! -d "node_modules" ]
[ ! -f "package-lock.json" ]

echo "--- Aspect: Deno security ---"
if [ -f "deno.json" ]; then
    grep -q "allow-" deno.json || echo "No Deno permissions found"
fi

echo "All aspect checks passed!"
