#!/usr/bin/env bash
set -euo pipefail

DOCKERHUB_REPO="${DOCKERHUB_REPO:-}"
GHCR_REPO="${GHCR_REPO:-}"
TAGS="${TAGS:-}"

if [[ -z "$DOCKERHUB_REPO" || -z "$GHCR_REPO" || -z "$TAGS" ]]; then
    echo "Missing required inputs. Expected DOCKERHUB_REPO, GHCR_REPO, TAGS" >&2
    exit 1
fi

run_with_retry() {
    local description="$1"
    shift
    local attempts=5
    local delay=2
    local attempt
    local err_file
    err_file="$(mktemp)"

    for attempt in $(seq 1 "$attempts"); do
        if "$@" 2>"$err_file"; then
            rm -f "$err_file"
            return 0
        fi

        if [[ "$attempt" -lt "$attempts" ]]; then
            echo "Retry ${attempt}/${attempts} for ${description} failed. Sleeping ${delay}s..." >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    echo "${description} failed after ${attempts} attempts" >&2
    if [[ -s "$err_file" ]]; then
        echo "Last stderr output:" >&2
        cat "$err_file" >&2
    fi
        if grep -qiE '429|toomanyrequests|rate limit' "$err_file"; then
            echo "Rate limit detected for ${description}" >&2
            rm -f "$err_file"
            return 2
        fi
    rm -f "$err_file"
    return 1
}

run_with_retry_output() {
    local description="$1"
    shift
    local attempts=5
    local delay=2
    local attempt
    local err_file
    local out
    err_file="$(mktemp)"

    for attempt in $(seq 1 "$attempts"); do
        if out="$("$@" 2>"$err_file")"; then
            rm -f "$err_file"
            printf '%s' "$out"
            return 0
        fi

        if [[ "$attempt" -lt "$attempts" ]]; then
            echo "Retry ${attempt}/${attempts} for ${description} failed. Sleeping ${delay}s..." >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    echo "${description} failed after ${attempts} attempts" >&2
    if [[ -s "$err_file" ]]; then
        echo "Last stderr output:" >&2
        cat "$err_file" >&2
    fi
        if grep -qiE '429|toomanyrequests|rate limit' "$err_file"; then
            echo "Rate limit detected for ${description}" >&2
            rm -f "$err_file"
            return 2
        fi
    rm -f "$err_file"
    return 1
}

inspect_with_retry() {
    local ref="$1"
    run_with_retry_output "inspect ${ref}" docker buildx imagetools inspect "$ref"
}

get_platform_set() {
    local ref="$1"
    local inspect_text
    local rc

    set +e
    inspect_text="$(inspect_with_retry "$ref")"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        return "$rc"
    fi

    echo "$inspect_text" | awk '/Platform:/{print $2}' | sort -u | tr '\n' ',' | sed 's/,$//'
}

tag_exists() {
    local ref="$1"
    docker buildx imagetools inspect "$ref" >/dev/null 2>&1
}

sync_tag() {
    local tag="$1"
    local dh_ref="${DOCKERHUB_REPO}:${tag}"
    local ghcr_ref="${GHCR_REPO}:${tag}"

    local dh_exists="no"
    local ghcr_exists="no"

    if tag_exists "$dh_ref"; then
        dh_exists="yes"
    fi

    if tag_exists "$ghcr_ref"; then
        ghcr_exists="yes"
    fi

    if [[ "$ghcr_exists" == "no" && "$dh_exists" == "yes" ]]; then
        echo "Syncing $tag: Docker Hub -> GHCR (backfill mode)"
        set +e
        run_with_retry "sync ${tag} dockerhub->ghcr" docker buildx imagetools create -t "$ghcr_ref" "$dh_ref" >/dev/null
        create_rc=$?
        set -e

        if [[ "$create_rc" -eq 2 ]]; then
            echo "::warning::Skipping tag $tag backfill due to Docker Hub rate limiting" >&2
            return 0
        fi
        if [[ "$create_rc" -ne 0 ]]; then
            return "$create_rc"
        fi
    elif [[ "$ghcr_exists" == "no" && "$dh_exists" == "no" ]]; then
        echo "Tag $tag: not found in either registry - skipping"
        return 0
    elif [[ "$ghcr_exists" == "yes" && "$dh_exists" == "no" ]]; then
        echo "Syncing $tag: GHCR -> Docker Hub"
        set +e
        run_with_retry "sync ${tag} ghcr->dockerhub" docker buildx imagetools create -t "$dh_ref" "$ghcr_ref" >/dev/null
        create_rc=$?
        set -e

        if [[ "$create_rc" -eq 2 ]]; then
            echo "::warning::Skipping tag $tag mirror push due to Docker Hub rate limiting" >&2
            return 0
        fi
        if [[ "$create_rc" -ne 0 ]]; then
            return "$create_rc"
        fi
    else
        local ghcr_platforms dh_platforms
        set +e
        ghcr_platforms="$(get_platform_set "$ghcr_ref")"
        ghcr_rc=$?
        set -e
        if [[ "$ghcr_rc" -ne 0 ]]; then
            echo "::error::Failed to inspect GHCR platforms for $tag" >&2
            return 1
        fi

        set +e
        dh_platforms="$(get_platform_set "$dh_ref")"
        dh_rc=$?
        set -e
        if [[ "$dh_rc" -eq 2 ]]; then
            echo "::warning::Skipping tag $tag sync parity check due to Docker Hub rate limiting" >&2
            return 0
        fi
        if [[ "$dh_rc" -ne 0 ]]; then
            echo "::error::Failed to inspect Docker Hub platforms for $tag" >&2
            return 1
        fi

        if [[ -n "$ghcr_platforms" && -n "$dh_platforms" && "$ghcr_platforms" == "$dh_platforms" ]]; then
            echo "Tag $tag: platform manifests already match across registries - skipping"
            return 0
        fi

        echo "Syncing $tag: mismatch detected, GHCR -> Docker Hub"
        set +e
        run_with_retry "sync ${tag} mismatch ghcr->dockerhub" docker buildx imagetools create -t "$dh_ref" "$ghcr_ref" >/dev/null
        create_rc=$?
        set -e

        if [[ "$create_rc" -eq 2 ]]; then
            echo "::warning::Skipping tag $tag mismatch sync due to Docker Hub rate limiting" >&2
            return 0
        fi
        if [[ "$create_rc" -ne 0 ]]; then
            return "$create_rc"
        fi
    fi

    local ghcr_platforms_final dh_platforms_final
    set +e
    ghcr_platforms_final="$(get_platform_set "$ghcr_ref")"
    ghcr_final_rc=$?
    set -e
    if [[ "$ghcr_final_rc" -ne 0 ]]; then
        echo "::error::Post-sync inspect failed for GHCR tag $tag" >&2
        return 1
    fi

    set +e
    dh_platforms_final="$(get_platform_set "$dh_ref")"
    dh_final_rc=$?
    set -e
    if [[ "$dh_final_rc" -eq 2 ]]; then
        echo "::warning::Skipping post-sync verification for tag $tag due to Docker Hub rate limiting" >&2
        return 0
    fi
    if [[ "$dh_final_rc" -ne 0 ]]; then
        echo "::error::Post-sync inspect failed for Docker Hub tag $tag" >&2
        return 1
    fi

    if [[ -z "$ghcr_platforms_final" || -z "$dh_platforms_final" ]]; then
        echo "::error::Sync verification failed for $tag (missing platform metadata)" >&2
        return 1
    fi

    if [[ "$ghcr_platforms_final" != "$dh_platforms_final" ]]; then
        echo "::error::Sync verification failed for $tag (platform sets differ between GHCR and Docker Hub)" >&2
        echo "GHCR platforms: $ghcr_platforms_final" >&2
        echo "Docker Hub platforms: $dh_platforms_final" >&2
        return 1
    fi

    echo "Verified $tag: Docker Hub matches GHCR platform set"
    return 0
}

IFS=',' read -ra TAG_ARRAY <<< "$TAGS"
declare -A SEEN_TAGS

for tag in "${TAG_ARRAY[@]}"; do
    clean_tag="$(echo "$tag" | xargs)"
    if [[ -z "$clean_tag" ]]; then
        continue
    fi

    echo "Processing tag: $clean_tag"

    if [[ -n "${SEEN_TAGS[$clean_tag]:-}" ]]; then
        echo "Tag $clean_tag: duplicate in input list - skipping duplicate"
        continue
    fi

    SEEN_TAGS[$clean_tag]=1
    sync_tag "$clean_tag"
done
