#!/bin/bash
# Linear Attachment Cache Library
# Downloads and caches files/images from uploads.linear.app URLs
# found in issue descriptions and comment bodies.
#
# Auth: Linear upload URLs require `Authorization: $LINEAR_API_KEY` (raw key, no Bearer prefix).
#
# Cache layout:
#   .cache/linear/attachments/
#     manifest.json          - URL → local metadata mapping
#     files/<hash>_<filename> - Downloaded files

set -euo pipefail

linear_attach_canonical_existing_dir() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    (cd "$path" && pwd -P)
}

linear_attach_project_root() {
    if [[ -n "${CACHE_PROJECT_ROOT:-}" ]]; then
        linear_attach_canonical_existing_dir "$CACHE_PROJECT_ROOT"
        return
    fi
    if [[ -n "${PROJECT_ROOT:-}" ]]; then
        linear_attach_canonical_existing_dir "$PROJECT_ROOT"
        return
    fi

    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)"
    linear_attach_canonical_existing_dir "$root"
}

ATTACH_CACHE_PROJECT_ROOT="$(linear_attach_project_root)"
ATTACH_DIR="$ATTACH_CACHE_PROJECT_ROOT/.cache/linear/attachments"
ATTACH_FILES_DIR="$ATTACH_DIR/files"
ATTACH_MANIFEST="$ATTACH_DIR/manifest.json"

# Viewable file types (agents can read these directly)
ATTACH_VIEWABLE_EXTENSIONS="png|jpg|jpeg|gif|webp|svg|pdf|md|txt|rs|ts|js|py|sh|json|toml|yaml|yml|csv|log|html|css|ron"

attach_ensure_dir() {
    mkdir -p "$ATTACH_FILES_DIR"
    [[ -f "$ATTACH_MANIFEST" ]] || echo '{}' > "$ATTACH_MANIFEST"
}

# Extract all uploads.linear.app URLs from text
# Usage: attach_extract_urls "markdown text"
# Returns one URL per line
attach_extract_urls() {
    local text="$1"
    # Match markdown image/link syntax and bare URLs (ERE for macOS compat)
    # grep returns 1 on no match — guard with || true to avoid set -e abort
    echo "$text" | grep -oE 'https://uploads\.linear\.app/[^[:space:])"]+' | sort -u || true
}

# Extract URLs from all cached issues and comments
# Usage: attach_extract_all_urls
# Returns JSON: [{"url": "...", "source": "CC-XXX", "context": "description|comment"}]
attach_extract_all_urls() {
    local cache_dir="$ATTACH_CACHE_PROJECT_ROOT/.cache/linear"
    local issues_file="$cache_dir/issues.json"
    local results="[]"

    if [[ ! -f "$issues_file" ]]; then
        echo "[]"
        return
    fi

    # URLs from issue descriptions
    local desc_urls
    desc_urls=$(jq -r '.[] | select(.description != null and .description != "") |
        .identifier as $id |
        .description | capture("(?<url>https://uploads\\.linear\\.app/[^\\s)\"]+)"; "g") |
        {url: .url, source: $id, context: "description"}' "$issues_file" 2>/dev/null || true)

    if [[ -n "$desc_urls" ]]; then
        results=$(echo "$desc_urls" | jq -s '.')
    fi

    # URLs from cached comments
    for comment_file in "$cache_dir"/comments/*.json; do
        [[ -f "$comment_file" ]] || continue
        local issue_id
        issue_id=$(basename "$comment_file" .json)
        local comment_urls
        comment_urls=$(jq -r --arg id "$issue_id" '.[] | select(.body != null and .body != "") |
            .body | capture("(?<url>https://uploads\\.linear\\.app/[^\\s)\"]+)"; "g") |
            {url: .url, source: $id, context: "comment"}' "$comment_file" 2>/dev/null || true)
        if [[ -n "$comment_urls" ]]; then
            results=$(echo "$results" "$(echo "$comment_urls" | jq -s '.')" | jq -s 'add | unique_by(.url)')
        fi
    done

    echo "$results"
}

# Get short hash for URL (first 12 chars of sha256)
attach_url_hash() {
    echo -n "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12
}

# Download a single file from uploads.linear.app
# Usage: attach_download_url "https://uploads.linear.app/..." "CC-XXX" "description"
# Returns JSON: {"url": "...", "local_path": "...", "filename": "...", ...} or empty on failure
attach_download_url() {
    local url="$1"
    local source_id="${2:-unknown}"
    local context="${3:-unknown}"

    attach_ensure_dir

    # Check manifest - skip if already downloaded (return 2 = already cached)
    local existing
    existing=$(jq -r --arg url "$url" '.[$url].local_path // empty' "$ATTACH_MANIFEST" 2>/dev/null)
    if [[ -n "$existing" && -f "$existing" ]]; then
        return 2
    fi

    # Source API key from project config/secrets.
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        local lib_dir
        lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # shellcheck source=vstack-env.sh
        source "$lib_dir/vstack-env.sh"
        vstack_load_project_env "$ATTACH_CACHE_PROJECT_ROOT"
    fi

    if ! resolve_linear_api_key; then
        echo "Warning: failed to resolve LINEAR_API_KEY, skipping attachment download" >&2
        return 1
    fi

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        echo "Warning: LINEAR_API_KEY not set, skipping attachment download" >&2
        return 1
    fi

    # Download to temp file, capture headers alongside (single request)
    local tmp_file tmp_headers
    tmp_file=$(mktemp)
    tmp_headers=$(mktemp)
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" -D "$tmp_headers" \
        -H "Authorization: $LINEAR_API_KEY" \
        "$url") || { rm -f "$tmp_file" "$tmp_headers"; return 1; }

    if [[ "$http_code" != "200" ]]; then
        rm -f "$tmp_file" "$tmp_headers"
        echo "Warning: Failed to download $url (HTTP $http_code)" >&2
        return 1
    fi

    # Extract filename from URL, falling back to Content-Disposition header
    local filename
    filename=$(basename "$url" | sed 's/?.*//')
    # If filename is a UUID, try to get a better name from headers
    if [[ "$filename" =~ ^[0-9a-f-]+$ ]]; then
        local cd_filename
        cd_filename=$(grep -i 'content-disposition' "$tmp_headers" | sed -n 's/.*filename="\{0,1\}\([^";]*\).*/\1/p' | tr -d '\r' || true)
        [[ -n "$cd_filename" ]] && filename="$cd_filename"
    fi
    rm -f "$tmp_headers"

    # Determine content type from file
    local content_type
    content_type=$(file -b --mime-type "$tmp_file" 2>/dev/null || echo "application/octet-stream")
    local file_size
    file_size=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)

    # Build local path: <hash>_<filename>
    local url_hash
    url_hash=$(attach_url_hash "$url")
    local local_filename="${url_hash}_${filename}"
    local local_path="$ATTACH_FILES_DIR/$local_filename"

    mv "$tmp_file" "$local_path"

    # Update manifest
    local entry
    entry=$(jq -n \
        --arg url "$url" \
        --arg path "$local_path" \
        --arg name "$filename" \
        --arg type "$content_type" \
        --argjson size "$file_size" \
        --arg source "$source_id" \
        --arg ctx "$context" \
        --arg ts "$(date -Iseconds)" \
        '{
            local_path: $path,
            filename: $name,
            content_type: $type,
            size: $size,
            source: $source,
            context: $ctx,
            downloaded_at: $ts
        }')

    (
        flock 203
        local manifest
        manifest=$(cat "$ATTACH_MANIFEST")
        echo "$manifest" | jq --arg url "$url" --argjson entry "$entry" '. + {($url): $entry}' > "$ATTACH_MANIFEST.tmp"
        mv "$ATTACH_MANIFEST.tmp" "$ATTACH_MANIFEST"
    ) 203>"$ATTACH_MANIFEST.lock"
}

# Download all new attachments found in cached issues/comments
# Usage: attach_sync [--quiet]
# Returns count of newly downloaded files
attach_sync() {
    local quiet="false"
    [[ "${1:-}" == "--quiet" ]] && quiet="true"

    attach_ensure_dir

    local all_urls
    all_urls=$(attach_extract_all_urls)
    local total
    total=$(echo "$all_urls" | jq 'length')

    if (( total == 0 )); then
        [[ "$quiet" == "false" ]] && echo "No attachment URLs found" >&2
        echo 0
        return
    fi

    # Filter to only new URLs (not in manifest or file missing)
    local new_count=0
    local download_count=0
    local fail_count=0

    for (( i=0; i<total; i++ )); do
        local url source context
        url=$(echo "$all_urls" | jq -r ".[$i].url")
        source=$(echo "$all_urls" | jq -r ".[$i].source")
        context=$(echo "$all_urls" | jq -r ".[$i].context")

        # Check if already cached
        local existing_path
        existing_path=$(jq -r --arg url "$url" '.[$url].local_path // empty' "$ATTACH_MANIFEST" 2>/dev/null)
        if [[ -n "$existing_path" && -f "$existing_path" ]]; then
            continue
        fi

        (( new_count++ )) || true

        local rc=0
        attach_download_url "$url" "$source" "$context" || rc=$?
        if (( rc == 0 )); then
            (( download_count++ )) || true
        elif (( rc == 1 )); then
            (( fail_count++ )) || true
        fi
        # rc 2 = already cached (skip)
    done

    if [[ "$quiet" == "false" ]]; then
        if (( new_count > 0 )); then
            echo "Attachments: $download_count downloaded" \
                 "$(( fail_count > 0 ? fail_count : 0 )) failed" \
                 "(${total} total URLs)" >&2
        fi
    fi

    echo "$download_count"
}

# Get cached attachments for a specific issue
# Usage: attach_get_for_issue "CC-XXX"
# Returns JSON array of attachment metadata with local_path
attach_get_for_issue() {
    local issue_id="$1"
    [[ -f "$ATTACH_MANIFEST" ]] || { echo "[]"; return; }
    jq --arg id "$issue_id" \
        '[to_entries[] | select(.value.source == $id) | .value + {url: .key}]' \
        "$ATTACH_MANIFEST" 2>/dev/null || echo "[]"
}

# List all cached attachments
# Usage: attach_list [--format=table|json]
attach_list() {
    local format="${1:-json}"
    [[ -f "$ATTACH_MANIFEST" ]] || { echo "[]"; return; }

    case "$format" in
    table)
        printf "%-10s %-40s %-20s %10s  %s\n" "ISSUE" "FILE" "TYPE" "SIZE" "PATH"
        jq -r 'to_entries[] | "\(.value.source)\t\(.value.filename)\t\(.value.content_type)\t\(.value.size)\t\(.value.local_path)"' \
            "$ATTACH_MANIFEST" | while IFS=$'\t' read -r src fname ctype sz lpath; do
            printf "%-10s %-40s %-20s %10s  %s\n" "$src" "$fname" "$ctype" "$sz" "$lpath"
        done
        ;;
    *)
        jq '[to_entries[] | .value + {url: .key}]' "$ATTACH_MANIFEST"
        ;;
    esac
}

# Get stats about attachment cache
attach_stats() {
    [[ -f "$ATTACH_MANIFEST" ]] || { echo '{"total": 0, "size_bytes": 0}'; return; }
    local total
    total=$(jq 'length' "$ATTACH_MANIFEST")
    local size_bytes=0
    if [[ -d "$ATTACH_FILES_DIR" ]]; then
        # du -sb = Linux, du -sk = macOS fallback (KB, multiply by 1024)
        if size_bytes=$(du -sb "$ATTACH_FILES_DIR" 2>/dev/null | cut -f1); then
            :
        else
            local size_kb
            size_kb=$(du -sk "$ATTACH_FILES_DIR" 2>/dev/null | cut -f1 || echo 0)
            size_bytes=$(( size_kb * 1024 ))
        fi
    fi
    jq -n --argjson total "$total" --argjson size "$size_bytes" \
        '{total: $total, size_bytes: $size, size_human: (if $size > 1048576 then "\($size / 1048576 | floor)MB" elif $size > 1024 then "\($size / 1024 | floor)KB" else "\($size)B" end)}'
}

# Download attachments found in a text field (description or comment body)
# Usage: attach_download_from_text "markdown text" "CC-XXX" "description|comment"
# Lightweight — only processes URLs in the given text, not a full cache scan.
attach_download_from_text() {
    local text="$1"
    local source_id="$2"
    local context="${3:-description}"

    [[ -n "$text" ]] || return 0
    local urls
    urls=$(attach_extract_urls "$text")
    [[ -n "$urls" ]] || return 0

    attach_ensure_dir
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        local _rc=0
        attach_download_url "$url" "$source_id" "$context" 2>/dev/null || _rc=$?
        # rc 0 = downloaded, rc 2 = already cached, rc 1 = failed (non-fatal)
    done <<< "$urls"
}

# Prune manifest entries where local file is missing
attach_prune() {
    [[ -f "$ATTACH_MANIFEST" ]] || return 0
    (
        flock 203
        local pruned=0
        local manifest
        manifest=$(cat "$ATTACH_MANIFEST")
        local cleaned="$manifest"

        while IFS= read -r url; do
            local path
            path=$(echo "$manifest" | jq -r --arg url "$url" '.[$url].local_path')
            if [[ ! -f "$path" ]]; then
                cleaned=$(echo "$cleaned" | jq --arg url "$url" 'del(.[$url])')
                (( pruned++ )) || true
            fi
        done < <(echo "$manifest" | jq -r 'keys[]')

        if (( pruned > 0 )); then
            echo "$cleaned" > "$ATTACH_MANIFEST.tmp"
            mv "$ATTACH_MANIFEST.tmp" "$ATTACH_MANIFEST"
            echo "Pruned $pruned stale manifest entries" >&2
        fi
        echo "$pruned"
    ) 203>"$ATTACH_MANIFEST.lock"
}
