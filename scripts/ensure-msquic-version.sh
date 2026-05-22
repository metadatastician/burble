#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Ensures quicer's embedded msquic checkout is at the required tag.
# This avoids late-stage build failures like:
#   undesired_msquic_version, required=v2.3.8, got=<commit>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICER_DIR="${REPO_ROOT}/server/deps/quicer"
MSQUIC_DIR="${REPO_ROOT}/server/deps/quicer/msquic"
REQUIRED_TAG="${REQUIRED_MSQUIC_TAG:-v2.3.8}"
CHECK_ONLY="${1:-}"

if [ ! -e "${MSQUIC_DIR}/.git" ]; then
    echo "[msquic-guard] ${MSQUIC_DIR} not present yet; skipping guard."
    echo "[msquic-guard] (run after deps are fetched/compiled)"
    exit 0
fi

# If the repository was moved, quicer's CMake cache can point at old paths
# and fail with "source does not match the source used to generate cache".
CMAKE_CACHE="${QUICER_DIR}/c_build/CMakeCache.txt"
if [ -f "${CMAKE_CACHE}" ]; then
    if ! grep -Fq "${QUICER_DIR}" "${CMAKE_CACHE}"; then
        echo "[msquic-guard] stale quicer CMake cache detected; removing c_build/"
        rm -rf "${QUICER_DIR}/c_build"
    fi
fi

current_version="$(git -C "${MSQUIC_DIR}" describe --tags --exact-match 2>/dev/null || true)"
if [ -z "${current_version}" ]; then
    current_version="$(git -C "${MSQUIC_DIR}" rev-parse --short HEAD)"
fi

if [ "${current_version}" = "${REQUIRED_TAG}" ]; then
    echo "[msquic-guard] OK: msquic is at ${REQUIRED_TAG}"
    exit 0
fi

echo "[msquic-guard] mismatch: required=${REQUIRED_TAG}, current=${current_version}"

if [ "${CHECK_ONLY}" = "--check-only" ]; then
    echo "[msquic-guard] check-only mode: failing."
    exit 1
fi

# Ensure required tag exists locally; fetch just that tag if needed.
if ! git -C "${MSQUIC_DIR}" rev-parse "${REQUIRED_TAG}^{commit}" >/dev/null 2>&1; then
    echo "[msquic-guard] required tag not found locally, fetching ${REQUIRED_TAG}..."
    git -C "${MSQUIC_DIR}" fetch --depth 1 origin "refs/tags/${REQUIRED_TAG}:refs/tags/${REQUIRED_TAG}"
fi

echo "[msquic-guard] aligning msquic checkout to ${REQUIRED_TAG}..."
git -C "${MSQUIC_DIR}" checkout --detach "${REQUIRED_TAG}"
git -C "${MSQUIC_DIR}" submodule update --init --recursive --depth 1 --recommend-shallow

after_version="$(git -C "${MSQUIC_DIR}" describe --tags --exact-match 2>/dev/null || true)"
if [ -z "${after_version}" ]; then
    after_version="$(git -C "${MSQUIC_DIR}" rev-parse --short HEAD)"
fi

if [ "${after_version}" != "${REQUIRED_TAG}" ]; then
    echo "[msquic-guard] failed to align msquic to ${REQUIRED_TAG}; now at ${after_version}"
    exit 1
fi

echo "[msquic-guard] aligned successfully to ${REQUIRED_TAG}"
