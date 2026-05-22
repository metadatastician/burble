#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Fails fast when the local environment cannot build quicer/msquic from source.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICER_DIR="${REPO_ROOT}/server/deps/quicer"
missing=0

if [ ! -d "${QUICER_DIR}" ]; then
    echo "[quicer-guard] ${QUICER_DIR} not present yet; skipping guard."
    echo "[quicer-guard] (run after deps are fetched/compiled)"
    exit 0
fi

if ! command -v perl >/dev/null 2>&1; then
    echo "[quicer-guard] missing tool: perl"
    missing=1
elif ! perl -MFindBin -e '1;' >/dev/null 2>&1; then
    echo "[quicer-guard] missing Perl module: FindBin.pm"
    echo "[quicer-guard] quicer source builds require Perl core modules for OpenSSL."
    missing=1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "[quicer-guard] missing tool: cmake"
    missing=1
fi

if ! command -v make >/dev/null 2>&1 && ! command -v ninja >/dev/null 2>&1; then
    echo "[quicer-guard] missing build tool: install either make or ninja"
    missing=1
fi

if [ "${missing}" -ne 0 ]; then
    echo "[quicer-guard] prerequisites are incomplete; aborting before mix/quicer compile."
    exit 1
fi

if git -C "${QUICER_DIR}" describe --tags --exact-match >/dev/null 2>&1; then
    exact_tag="$(git -C "${QUICER_DIR}" describe --tags --exact-match)"
    echo "[quicer-guard] quicer is on release tag ${exact_tag} (prebuilt download path may work)."
else
    desc="$(git -C "${QUICER_DIR}" describe --tags --always)"
    echo "[quicer-guard] quicer checkout ${desc} is not an exact release tag; source build path is expected."
fi

echo "[quicer-guard] prerequisite check passed."
