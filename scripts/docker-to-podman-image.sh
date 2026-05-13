#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
#
# docker-to-podman-image.sh — copy a locally-built docker image into
# podman's local store. Needed when an image was built with docker (e.g.
# because rootless podman has cgroup issues on the host — see WSL2
# pidfd bug) but burble's compose.toml uses podman-compose.
#
# Two routes, fastest first:
#
#   1. Pipe save/load — no temp file, no disk overhead.
#      docker save IMAGE | podman load
#
#   2. Save to tarball then load — survives across machines via scp.
#      docker save -o image.tar IMAGE
#      podman load -i image.tar
#
# This script does (1) by default, (2) when --tarball is passed.
#
# Usage:
#   ./scripts/docker-to-podman-image.sh ghcr.io/hyperpolymath/verisimdb:latest
#   ./scripts/docker-to-podman-image.sh --tarball /tmp/img.tar ghcr.io/...
#
# Verification:
#   podman images | grep verisimdb

set -euo pipefail

TARBALL=""
if [[ "${1:-}" == "--tarball" ]]; then
  TARBALL="${2:-}"
  shift 2
fi

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  echo "usage: $0 [--tarball PATH] <image:tag>" >&2
  echo "example: $0 ghcr.io/hyperpolymath/verisimdb:latest" >&2
  exit 64
fi

if ! command -v docker >/dev/null; then
  echo "error: docker not found" >&2
  exit 65
fi
if ! command -v podman >/dev/null; then
  echo "error: podman not found" >&2
  exit 65
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "error: image not present in docker — build it first?" >&2
  echo "       docker images | grep ${IMAGE%%:*}" >&2
  exit 66
fi

echo "[bridge] source (docker):  ${IMAGE}"
echo "[bridge] target (podman):  ${IMAGE}"

if [[ -n "$TARBALL" ]]; then
  echo "[bridge] mode: tarball at ${TARBALL}"
  docker save -o "$TARBALL" "$IMAGE"
  podman load -i "$TARBALL"
else
  echo "[bridge] mode: pipe save | load"
  docker save "$IMAGE" | podman load
fi

echo
echo "[bridge] verification:"
podman images --filter "reference=${IMAGE}" --format "  {{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}"
echo
echo "[bridge] done. burble compose can now use this image:"
echo "  cd ~/dev/burble/containers && podman-compose -f compose.toml up"
