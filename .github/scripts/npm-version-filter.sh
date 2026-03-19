#!/bin/bash
# =============================================================================
# npm-version-filter.sh
# Helper script to fetch, filter, and process Context7 MCP releases from NPM
# =============================================================================
# Usage: ./npm-version-filter.sh [--max-versions 10] [--filter-beta] [--output json|csv|text]
#
# Features:
#   • Fetch latest N versions from @upstash/context7-mcp
#   • Filter out beta, canary, alpha pre-releases
#   • Sort by semver version
#   • Identify latest stable release
#   • Output as JSON, CSV, or text
#
# Environment Variables:
#   NPM_PACKAGE          Package name (default: @upstash/context7-mcp)
#   NPM_REGISTRY         NPM registry URL (default: https://registry.npmjs.org)
#   FILTER_BETA          Filter beta versions (default: true)
#   OUTPUT_FORMAT        Output format (default: json)
# =============================================================================

set -euo pipefail

# Configuration
NPM_PACKAGE="${NPM_PACKAGE:-@upstash/context7-mcp}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
MAX_VERSIONS="${MAX_VERSIONS:-10}"
FILTER_BETA="${FILTER_BETA:-true}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

# Check if version string contains beta/canary/alpha indicators
is_prerelease() {
    local version="$1"
    [[ "$version" =~ (beta|canary|alpha|rc|pre|dev|next) ]]
}

# Compare two version strings (simple semver comparison)
# Returns: 0 if equal, 1 if v1 > v2, -1 if v1 < v2
compare_versions() {
    local v1="$1" v2="$2"
    
    # Strip pre-release suffixes for comparison
    v1="${v1%%-*}"
    v2="${v2%%-*}"
    
    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi
    
    # Use Python for proper semver comparison
    python3 << PYTHON
from packaging import version
v1_obj = version.parse("$v1")
v2_obj = version.parse("$v2")
if v1_obj > v2_obj:
    exit(1)
elif v1_obj < v2_obj:
    exit(-1)
else:
    exit(0)
PYTHON
}

# ─────────────────────────────────────────────────────────────────────────
# Main Functions
# ─────────────────────────────────────────────────────────────────────────

fetch_npm_metadata() {
    log_info "Fetching package metadata from NPM..."
    
    if ! NPM_DATA=$(curl -s "${NPM_REGISTRY}/${NPM_PACKAGE}"); then
        log_error "Failed to fetch NPM metadata"
        return 1
    fi
    
    if echo "$NPM_DATA" | jq empty 2>/dev/null; then
        echo "$NPM_DATA"
        return 0
    else
        log_error "Invalid JSON response from NPM registry"
        return 1
    fi
}

filter_stable_versions() {
    local npm_data="$1"
    
    log_info "Filtering stable versions..."
    
    # Extract all versions
    local all_versions=$(echo "$npm_data" | jq -r '.versions | keys[]')
    
    # Count total
    local total=$(echo "$all_versions" | wc -l)
    log_info "Total versions available: $total"
    
    # Filter based on settings
    local stable_versions=()
    while IFS= read -r version; do
        if [[ "$FILTER_BETA" == "true" ]]; then
            if ! is_prerelease "$version"; then
                stable_versions+=("$version")
            fi
        else
            stable_versions+=("$version")
        fi
    done <<< "$all_versions"
    
    # Sort in descending order (newest first)
    printf '%s\n' "${stable_versions[@]}" | sort -rV | head -n "$MAX_VERSIONS"
}

get_version_info() {
    local npm_data="$1"
    local version="$2"
    
    echo "$npm_data" | jq --arg ver "$version" -c '.versions[$ver] + {version: $ver}'
}

output_json() {
    local npm_data="$1"
    local versions="$2"
    
    local versions_array=$(echo "$versions" | jq -R '.' | jq -s '.')
    local latest_version=$(echo "$versions" | head -n 1)
    
    local output=$(echo "$npm_data" | jq --argjson versions "$versions_array" --arg latest "$latest_version" -c '{
        package: .name,
        registry: "npmjs.org",
        latest_stable: $latest,
        versions_count: ($versions | length),
        versions: [
            $versions[] |
            {
                version: .,
                published: (.versions[.].time // "unknown"),
                deprecated: (.versions[.].deprecated // false),
                is_latest: (. == ($latest // ""))
            }
        ]
    }')
    
    echo "$output" | jq '.'
}

output_csv() {
    local versions="$1"
    
    echo "version,tag_date,full_tag,promote_latest"
    while IFS= read -r version; do
        local tag_date=$(date +%d%m%Y)
        local full_tag="${version}-${tag_date}"
        local promote=$([ "$version" == "$(echo "$versions" | head -n 1)" ] && echo "true" || echo "false")
        echo "${version},${tag_date},${full_tag},${promote}"
    done <<< "$versions"
}

output_text() {
    local versions="$1"
    
    echo "Stable Context7 MCP Versions (NPM Registry)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local latest=$(echo "$versions" | head -n 1)
    echo "Latest Version: $latest"
    echo "Total Versions: $(echo "$versions" | wc -l)"
    echo ""
    echo "Versions:"
    echo "$versions" | nl
    echo ""
    echo "Build Tags:"
    while IFS= read -r version; do
        local tag_date=$(date +%d%m%Y)
        local full_tag="${version}-${tag_date}"
        local promote=$([ "$version" == "$latest" ] && echo " [LATEST]" || echo "")
        echo "  • ${full_tag}${promote}"
    done <<< "$versions"
}

# ─────────────────────────────────────────────────────────────────────────
# Main Script
# ─────────────────────────────────────────────────────────────────────────

main() {
    log_info "Context7 MCP Version Filter"
    log_info "Package: $NPM_PACKAGE"
    log_info "Registry: $NPM_REGISTRY"
    log_info "Max Versions: $MAX_VERSIONS"
    log_info "Filter Pre-releases: $FILTER_BETA"
    echo ""
    
    # Fetch NPM metadata
    if ! NPM_DATA=$(fetch_npm_metadata); then
        log_error "Failed to fetch NPM metadata"
        return 1
    fi
    
    # Filter versions
    FILTERED_VERSIONS=$(filter_stable_versions "$NPM_DATA")
    
    if [ -z "$FILTERED_VERSIONS" ]; then
        log_error "No versions found after filtering"
        return 1
    fi
    
    log_success "Filtered successfully"
    echo ""
    
    # Output results
    case "$OUTPUT_FORMAT" in
        json)
            output_json "$NPM_DATA" "$FILTERED_VERSIONS"
            ;;
        csv)
            output_csv "$FILTERED_VERSIONS"
            ;;
        text|*)
            output_text "$FILTERED_VERSIONS"
            ;;
    esac
}

# Run main function
main "$@"
