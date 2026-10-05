#!/bin/bash
# Linear file uploads for --attach: fileUpload, the storage PUT, and
# attachmentCreate. Requires common.sh. Reading attachments is the
# `attachments` command's (commands/attachments.sh), live and with no store.

set -euo pipefail

# The title an issue attachment records for a local file: its path from the
# repository root when the file sits inside the repository, so the record
# names the artifact the same way on every checkout, else its file name.
# Usage: attach_issue_title <path>
attach_issue_title() {
    local path="$1" directory filename canonical_path
    directory=$(cd -- "$(dirname -- "$path")" && pwd -P) || return 1
    filename=$(basename -- "$path") || return 1
    canonical_path="$directory/$filename"
    if [[ "$canonical_path" == "$PROJECT_ROOT/"* ]]; then
        printf '%s\n' "${canonical_path#"$PROJECT_ROOT/"}"
    else
        printf '%s\n' "$filename"
    fi
}

# -----------------------------------------------------------------------------
# Upload path (issues create/update --attach, comments create --attach)
# -----------------------------------------------------------------------------
# Linear's upload flow:
#   1. fileUpload(contentType, filename, size) returns uploadUrl, assetUrl and
#      the exact headers the storage PUT must carry.
#   2. PUT the file bytes to uploadUrl with those headers verbatim (plus
#      Content-Type) — synthesized headers are rejected by the store.
#   3. Reference assetUrl from markdown, or attach it via attachmentCreate.

# Escape a filename for use inside a markdown image/link LABEL: backslashes
# and square brackets escape, newlines collapse to spaces — a name like
# "report].png" must not terminate the label early and mis-reference the
# uploaded asset. Only the label needs this; URLs come from Linear.
attach_markdown_label() {
    printf '%s' "$1" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

# Content type from the file extension: the type must be declared at
# fileUpload time, before any bytes exist server-side to sniff.
attach_upload_content_type() {
    local filename ext
    filename="$(basename "$1")"
    ext="${filename##*.}"
    [[ "$ext" == "$filename" ]] && ext=""
    case "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" in
    png) echo "image/png" ;;
    jpg | jpeg) echo "image/jpeg" ;;
    gif) echo "image/gif" ;;
    webp) echo "image/webp" ;;
    svg) echo "image/svg+xml" ;;
    pdf) echo "application/pdf" ;;
    txt) echo "text/plain" ;;
    *) echo "application/octet-stream" ;;
    esac
}

# Refuse before any API call: every --attach path must be a readable regular
# file. Usage: attach_preflight_files <path>...
attach_preflight_files() {
    local path
    for path in "$@"; do
        if [[ -z "$path" ]]; then
            echo '{"error": "--attach requires a non-empty path argument"}' >&2
            return 1
        fi
        if [[ ! -f "$path" || ! -r "$path" ]]; then
            jq -cn --arg path "$path" '{error: ("--attach path not readable: " + $path)}' >&2
            return 1
        fi
    done
}

# Upload one local file to Linear storage.
# Usage: attach_upload_file <path>
# stdout on success: {"assetUrl": "...", "filename": "...", "contentType": "..."}
# On failure: JSON error on stderr, rc 1, nothing on stdout.
attach_upload_file() {
    local file_path="$1"
    local filename content_type size
    filename="$(basename "$file_path")"
    content_type="$(attach_upload_content_type "$file_path")"
    if ! size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null); then
        jq -cn --arg path "$file_path" \
            '{error: ("Could not determine file size for --attach path: " + $path)}' >&2
        return 1
    fi

    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    local mutation='
    mutation FileUpload($contentType: String!, $filename: String!, $size: Int!) {
        fileUpload(contentType: $contentType, filename: $filename, size: $size) {
            success
            uploadFile {
                uploadUrl
                assetUrl
                headers { key value }
            }
        }
    }'
    local variables result
    variables=$(jq -cn --arg contentType "$content_type" --arg filename "$filename" \
        --argjson size "$size" '{contentType: $contentType, filename: $filename, size: $size}')
    if ! result=$(graphql_query "$mutation" "$variables"); then
        jq -cn --arg path "$file_path" \
            '{error: ("fileUpload request failed for --attach path: " + $path + " (see previous error)")}' >&2
        return 1
    fi

    local upload_url asset_url
    upload_url=$(echo "$result" | jq -r '.fileUpload.uploadFile.uploadUrl // empty')
    asset_url=$(echo "$result" | jq -r '.fileUpload.uploadFile.assetUrl // empty')
    if [[ -z "$upload_url" || -z "$asset_url" ]]; then
        jq -cn --arg path "$file_path" \
            '{error: ("fileUpload returned no uploadUrl/assetUrl for --attach path: " + $path)}' >&2
        return 1
    fi

    # PUT the bytes with EXACTLY the returned headers (plus Content-Type),
    # over the same curl-config-on-stdin transport graphql_query uses so
    # header values never touch process argv.
    # Content-Type and Cache-Control mirror Linear's documented upload
    # example (linear.app/developers/how-to-upload-a-file-to-linear); the
    # response headers below are copied verbatim on top.
    local put_config_lines=(
        "url = $(curl_config_quote "$upload_url")"
        'request = "PUT"'
        "upload-file = $(curl_config_quote "$file_path")"
        "header = $(curl_config_quote "Content-Type: $content_type")"
        "header = $(curl_config_quote "Cache-Control: public, max-age=31536000")"
    )
    local header_line
    while IFS= read -r header_line; do
        [[ -n "$header_line" ]] || continue
        put_config_lines+=("header = $(curl_config_quote "$header_line")")
    done < <(echo "$result" | jq -r '.fileUpload.uploadFile.headers // [] | .[] | "\(.key): \(.value)"')

    local http_code
    if ! http_code=$(printf '%s\n' "${put_config_lines[@]}" | curl -s -o /dev/null -w "%{http_code}" -K -); then
        http_code=000
    fi
    case "$http_code" in
    2??) ;;
    *)
        jq -cn --arg path "$file_path" --arg code "$http_code" \
            '{error: ("Upload PUT failed for --attach path: " + $path + " (HTTP " + $code + ")")}' >&2
        return 1
        ;;
    esac

    jq -cn --arg assetUrl "$asset_url" --arg filename "$filename" --arg contentType "$content_type" \
        '{assetUrl: $assetUrl, filename: $filename, contentType: $contentType}'
}

# Attach an uploaded asset URL to an issue as a real Linear attachment.
# Usage: attach_create_issue_attachment <issue-uuid> <url> <title>
attach_create_issue_attachment() {
    local issue_uuid="$1" url="$2" title="$3"
    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    local mutation='
    mutation AttachmentCreate($input: AttachmentCreateInput!) {
        attachmentCreate(input: $input) {
            success
            attachment { id url title }
        }
    }'
    local variables result
    variables=$(jq -cn --arg issueId "$issue_uuid" --arg url "$url" --arg title "$title" \
        '{input: {issueId: $issueId, url: $url, title: $title}}')
    result=$(graphql_query "$mutation" "$variables") || return 1
    echo "$result" | jq -e '.attachmentCreate.success == true' >/dev/null || return 1
}
