#!/bin/bash
# Linear GraphQL API - Attachment Operations
# Usage: attachments.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat <<'EOF'
Attachment Operations

Usage: attachments.sh <action> [options]

Actions:
  list <issue-id>              Every file the issue references, read live: its
                               attachment records and the uploads.linear.app
                               links in its description and comments
  fetch <url> --output <path>  Download one uploads.linear.app file to <path>

List output: one JSON array, one object per URL:
  {url, source, context, filename, repo_path}
  context is attachment, description or comment; repo_path is the repository
  path an attachment record's title names, else null. A URL both a record and
  a link name appears once, as the record.

Fetch writes only <path>, through a temporary file beside it, and prints
{"local_path": <path>}. It refuses a URL on any other host before sending a
credential, and leaves <path> untouched when the download fails.

Examples:
  attachments.sh list PROJ-42
  attachments.sh fetch https://uploads.linear.app/... --output tmp/plan.md
EOF
}
case "${1:-help}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"

list_attachments() {
    local issue_ref="${1:-}"
    if [[ -z "$issue_ref" || "$#" -ne 1 ]]; then
        echo '{"error": "Usage: attachments.sh list <issue-id>"}' >&2
        return 1
    fi
    # The comments selection is the one lib/pages.sh continues an open
    # comments connection with, so every page has one shape.
    local query='
    query IssueAttachments($id: String!) {
        issue(id: $id) {
            id
            identifier
            description
            attachments {
                pageInfo { hasNextPage endCursor }
                nodes { id url title }
            }
            comments {
                pageInfo { hasNextPage endCursor }
                nodes { id body createdAt updatedAt user { name } }
            }
        }
    }'
    local variables result
    variables=$(jq -cn --arg id "$issue_ref" '{id: $id}') || return 1
    result=$(graphql_query "$query" "$variables") || return 1
    if ! jq -e '.issue.id | strings | select(length > 0)' <<<"$result" >/dev/null; then
        jq -cn --arg id "$issue_ref" '{error: ("Issue not found: " + $id)}' >&2
        return 1
    fi
    # A bare link drops the prose punctuation that ends a sentence around it,
    # the characters GitHub Flavored Markdown leaves out of an autolink, and
    # the semicolon; a Markdown link destination is the URL as written.
    jq '.issue as $issue
        | def links($text; $context):
            [($text // "") | capture("(?<destination>\\]\\(<?)?(?<url>https://uploads\\.linear\\.app/[^[:space:])>\"]+)"; "g")
             | if .destination then .url else .url | sub("[?!.,:;*_~]+$"; "") end
             | {url: ., source: $issue.identifier, context: $context,
                filename: (split("?")[0] | split("/") | last), repo_path: null}];
        [$issue.attachments.nodes[] | select(.url | startswith("https://uploads.linear.app/"))
         | {url, source: $issue.identifier, context: "attachment",
            filename: ((.title // "") | split("/") | last),
            repo_path: (if (.title // "") | contains("/") then .title else null end)}] as $records
        | ($records | map(.url)) as $recorded
        | $records + ([links($issue.description; "description"),
            ($issue.comments.nodes[] | links(.body; "comment"))]
            | add // [] | unique_by(.url) | map(select(.url as $u | $recorded | index($u) | not)))' <<<"$result"
}

# A subshell, so the EXIT trap removes the temporary file on every path.
fetch_attachment() (
    local url="${1:-}" output authorization header url_quote raw code headers renewed=0 attempt=1 temp
    local delimiter="___HTTP_CODE___"
    if [[ "$#" -ne 3 || "${2:-}" != --output || -z "${3:-}" ]]; then
        echo '{"error": "Usage: attachments.sh fetch <url> --output <path>"}' >&2
        return 1
    fi
    output="$3"
    # Linear serves its uploads from this host with the API credential; any
    # other host would receive that credential.
    if [[ "$url" != https://uploads.linear.app/* ]]; then
        jq -cn --arg url "$url" '{error: ("Refusing a download from outside https://uploads.linear.app/: " + $url)}' >&2
        return 1
    fi
    authorization=$(linear_authorization) || return 1
    header=$(curl_config_quote "Authorization: $authorization") || return 1
    url_quote=$(curl_config_quote "$url") || return 1
    temp=$(mktemp -- "$output.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    while true; do
        # The body goes to the temporary file and the header blocks to stdout,
        # ahead of the status.
        if ! raw=$(printf '%s\n' "url = $url_quote" "header = $header" 'dump-header = "-"' |
            curl -s -o "$temp" -w "${delimiter}%{http_code}" -K -); then
            raw="${delimiter}000"
        fi
        code="${raw##*"$delimiter"}"
        headers="${raw%"$delimiter"*}"
        # An app token Linear's upload server refuses is renewed once, as the
        # GraphQL transport renews it.
        if [[ "$code" == 401 && "$LINEAR_AUTH_KIND" == app && "$renewed" == 0 ]]; then
            authorization=$(linear_authorization renew) || return 1
            header=$(curl_config_quote "Authorization: $authorization") || return 1
            renewed=1
            continue
        fi
        if linear_retry_wait "$code" "$attempt" "$headers"; then
            attempt=$((attempt + 1))
            continue
        fi
        break
    done
    if [[ "$code" == 429 ]]; then
        linear_rate_limited "$headers"
        return 1
    elif [[ "$code" != 200 ]]; then
        if [[ "$code" == 401 ]]; then
            linear_auth_unauthorized
        fi
        jq -cn --arg url "$url" --arg code "$code" '{error: ("Download failed (HTTP " + $code + "): " + $url)}' >&2
        return 1
    fi
    mv -f -- "$temp" "$output" || return 1
    jq -cn --arg path "$output" '{local_path: $path}'
)

action="${1:-help}"
shift || true

case "$action" in
    list) list_attachments "$@" ;;
    fetch) fetch_attachment "$@" ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'attachments.sh --help' for usage." >&2
        exit 1
        ;;
esac
