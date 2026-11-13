#!/bin/bash
# Linear GraphQL API - One read document, sent as written
# Usage: graphql.sh --query DOC [--variables JSON]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
One GraphQL read

Usage: linear.sh graphql --query DOC [--variables JSON]

Sends one document that opens with `query` and prints Linear's `data` as one
JSON line. Any other document is refused before a request: a write goes
through the command that holds its checks.

Select `pageInfo { hasNextPage }` on every connection: an answer with a
connection left open is refused naming its path, never printed as whole.

Exit: 0 answered, 2 the entity the document names does not exist, 1 otherwise.

Example:
  linear.sh graphql --query 'query { issue(id: "PROJ-42") { description state { name type } } }'
  linear.sh graphql --query 'query Item($id: String!) { issue(id: $id) { title } }' --variables '{"id":"PROJ-42"}'
EOF
}
case "${1:-help}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"

query="" variables="" given=0
while [[ $# -gt 0 ]]; do
    case "$1" in
    --query | --variables)
        linear_require_option_value "$@" || exit 1
        if [[ "$1" == --query ]]; then
            query="$2"
            given=$((given + 1))
        else
            variables="$2"
        fi
        shift 2
        ;;
    *)
        jq -cn --arg arg "$1" '{error: ("graphql: unknown argument " + $arg)}' >&2
        exit 1
        ;;
    esac
done
if [[ "$given" -ne 1 ]]; then
    echo '{"error": "graphql takes exactly one --query"}' >&2
    exit 1
fi

if ! [[ "$query" =~ $LINEAR_READ_PATTERN ]]; then
    echo 'linear-graphql: read-only' >&2
    exit 1
fi

rc=0
data=$(graphql_request "$query" "$variables") || rc=$?
[[ "$rc" -eq 0 ]] || exit "$rc"

open=$(jq -r '[paths(objects | select(.pageInfo.hasNextPage? == true))] | first // empty | map(tostring) | join(".")' <<<"$data") || exit 1
if [[ -n "$open" ]]; then
    printf 'linear-graphql: open path=%s\n' "$open" >&2
    exit 1
fi
printf '%s\n' "$data"
