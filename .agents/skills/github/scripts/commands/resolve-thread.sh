#!/bin/bash
# GitHub API - Resolve review thread(s)
# Usage: resolve-thread.sh <thread-id> [<thread-id>...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Resolve Review Thread(s)

Usage: resolve-thread.sh <thread-id> [<thread-id>...]

Arguments:
  thread-id    GraphQL thread ID (PRRT_...) - can specify multiple

Options:
  --dry-run    Show what would be done without executing

Output:
{
  "success": true,
  "resolved": ["PRRT_...", "PRRT_..."],
  "failed": []
}

Examples:
  # Single thread
  resolve-thread.sh PRRT_kwDONRcYOs6D8dg9

  # Multiple threads
  resolve-thread.sh PRRT_... PRRT_... PRRT_...

  # From stdin (one per line)
  echo "PRRT_..." | resolve-thread.sh --stdin
EOF
}

resolve_threads() {
    local thread_ids=()
    local dry_run="false"
    local from_stdin="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --stdin)
                from_stdin="true"
                shift
                ;;
            PRRT_*)
                thread_ids+=("$1")
                shift
                ;;
            *)
                echo "{\"error\": \"Invalid thread ID: $1 (must start with PRRT_)\"}" >&2
                exit 1
                ;;
        esac
    done

    # Read from stdin if requested. The `|| [ -n "$line" ]` guard keeps a final
    # id that arrives without a trailing newline.
    if [ "$from_stdin" = "true" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" == PRRT_* ]] && thread_ids+=("$line")
        done
    fi

    if [ ${#thread_ids[@]} -eq 0 ]; then
        echo '{"error": "No thread IDs provided"}' >&2
        exit 1
    fi

    # Dry run - just report
    if [ "$dry_run" = "true" ]; then
        printf '{"dry_run": true, "would_resolve": %s}\n' \
            "$(printf '%s\n' "${thread_ids[@]}" | jq -R . | jq -s .)"
        exit 0
    fi

    # Single thread - simple mutation
    if [ ${#thread_ids[@]} -eq 1 ]; then
        local query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { id isResolved }
  }
}'
        local result
        result=$(gh_graphql "$query" -F threadId="${thread_ids[0]}") || {
            jq -nc --arg id "${thread_ids[0]}" '{success: false, resolved: [], failed: [$id]}'
            exit 1
        }

        local resolved
        resolved=$(echo "$result" | jq -r '.resolveReviewThread.thread.isResolved // false')
        if [ "$resolved" = "true" ]; then
            jq -nc --arg id "${thread_ids[0]}" '{success: true, resolved: [$id], failed: []}'
        else
            jq -nc --arg id "${thread_ids[0]}" '{success: false, resolved: [], failed: [$id]}'
            exit 1
        fi
        return
    fi

    # Multiple threads - batch mutation with aliases. Thread ids are bound as
    # GraphQL variables rather than pasted into the query text, so an id can
    # never terminate the string literal and extend the mutation.
    local var_decls=() mutation_parts=() gh_args=()
    local idx=0
    for tid in "${thread_ids[@]}"; do
        var_decls+=("\$t${idx}: ID!")
        mutation_parts+=("t${idx}: resolveReviewThread(input: {threadId: \$t${idx}}) { thread { id isResolved } }")
        gh_args+=(-F "t${idx}=$tid")
        idx=$((idx + 1))
    done

    local batch_query
    batch_query="mutation($(IFS=,; echo "${var_decls[*]}")) { $(printf '%s ' "${mutation_parts[@]}") }"

    local result
    result=$(gh_graphql "$batch_query" "${gh_args[@]}") || {
        printf '%s\n' "${thread_ids[@]}" | jq -R . | jq -sc '{success: false, resolved: [], failed: .}'
        exit 1
    }

    # Parse results
    local resolved=()
    local failed=()
    idx=0
    for tid in "${thread_ids[@]}"; do
        local is_resolved
        is_resolved=$(echo "$result" | jq -r ".t${idx}.thread.isResolved // false")
        if [ "$is_resolved" = "true" ]; then
            resolved+=("$tid")
        else
            failed+=("$tid")
        fi
        idx=$((idx + 1))
    done

    # Output result. A jq failure here must not read as "nothing resolved":
    # the encoding is allowed to fail loudly instead of degrading to [].
    local resolved_json failed_json
    resolved_json=$(printf '%s\n' "${resolved[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')
    failed_json=$(printf '%s\n' "${failed[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')

    jq -nc \
        --argjson resolved "$resolved_json" \
        --argjson failed "$failed_json" \
        '{success: ($failed | length) == 0, resolved: $resolved, failed: $failed}'
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

resolve_threads "$@"
