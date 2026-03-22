#!/usr/bin/env bash
set -euo pipefail

REQUESTED_ACTION="${REQUESTED_ACTION:-auto-check}"
MANUAL_VERSIONS_RAW="${MANUAL_VERSIONS_RAW:-}"
NPM_PACKAGE="${NPM_PACKAGE:-@upstash/context7-mcp}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
MAX_VERSIONS="${MAX_VERSIONS:-10}"

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
    echo "GITHUB_OUTPUT is required" >&2
    exit 1
fi

DATE_TAG="$(date +%d%m%Y)"
echo "date_tag=$DATE_TAG" >> "$GITHUB_OUTPUT"

if [[ -n "$MANUAL_VERSIONS_RAW" && "$REQUESTED_ACTION" == "build-versions" ]]; then
    VERSIONS_NEWEST="$({
        echo "$MANUAL_VERSIONS_RAW" \
            | tr ',' '\n' \
            | sed 's/^ *//; s/ *$//' \
            | sed '/^$/d' \
            | grep -Evi '(beta|canary)'
    } || true)"

    if [[ -z "$VERSIONS_NEWEST" ]]; then
        echo "versions_json=[]" >> "$GITHUB_OUTPUT"
        echo "latest_version=" >> "$GITHUB_OUTPUT"
        echo "should_build=false" >> "$GITHUB_OUTPUT"
        exit 0
    fi

    LATEST_VERSION="$(echo "$VERSIONS_NEWEST" | head -n1)"
else
    curl -fsSL "${NPM_REGISTRY}/${NPM_PACKAGE}" -o npm-package.json

    VERSIONS_NEWEST="$({
        jq -r '.versions | keys[]' npm-package.json \
            | grep -Evi '(beta|canary)' \
            | sort -Vr \
            | head -n "$MAX_VERSIONS"
    } || true)"

    if [[ -z "$VERSIONS_NEWEST" ]]; then
        echo "versions_json=[]" >> "$GITHUB_OUTPUT"
        echo "latest_version=" >> "$GITHUB_OUTPUT"
        echo "should_build=false" >> "$GITHUB_OUTPUT"
        exit 0
    fi

    DIST_TAG_LATEST="$(jq -r '."dist-tags".latest // ""' npm-package.json)"
    if [[ -n "$DIST_TAG_LATEST" ]] && echo "$VERSIONS_NEWEST" | grep -qx "$DIST_TAG_LATEST"; then
        LATEST_VERSION="$DIST_TAG_LATEST"
    else
        LATEST_VERSION="$(echo "$VERSIONS_NEWEST" | head -n1)"
    fi
fi

VERSIONS_OLDEST="$(echo "$VERSIONS_NEWEST" | sort -V)"
VERSIONS_JSON="$(echo "$VERSIONS_OLDEST" | jq -R -s -c --arg date "$DATE_TAG" --arg latest "$LATEST_VERSION" '
  split("\n")
  | map(select(length > 0))
  | map({
      version: .,
      image_tag: (. + "-" + $date),
      promote_latest: (. == $latest)
    })
')"

echo "versions_json=$VERSIONS_JSON" >> "$GITHUB_OUTPUT"
echo "latest_version=$LATEST_VERSION" >> "$GITHUB_OUTPUT"
echo "should_build=true" >> "$GITHUB_OUTPUT"

echo "Stable versions selected for build (oldest first):"
echo "$VERSIONS_OLDEST"
echo "Latest stable: $LATEST_VERSION"
