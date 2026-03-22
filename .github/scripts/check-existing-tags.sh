#!/usr/bin/env bash
set -euo pipefail

FORCE_BUILD="${FORCE_BUILD:-false}"
GHCR_REPO="${GHCR_REPO:-}"
VERSION="${VERSION:-}"

if [[ -z "$GHCR_REPO" || -z "$VERSION" ]]; then
    echo "Missing required inputs. Expected GHCR_REPO and VERSION" >&2
    exit 1
fi

if [[ "$FORCE_BUILD" == "true" ]]; then
    echo "skip_build=false"
    exit 0
fi

if docker manifest inspect "${GHCR_REPO}:${VERSION}" >/dev/null 2>&1; then
    echo "Image version already present in GHCR; skipping build"
    echo "skip_build=true"
else
    echo "Image version not found in GHCR; building"
    echo "skip_build=false"
fi
