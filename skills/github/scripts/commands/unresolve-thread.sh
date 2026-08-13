#!/bin/bash
# GitHub API - Unresolve review thread(s)
# Usage: unresolve-thread.sh <thread-id> [<thread-id>...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Unresolve Review Thread(s)

Usage: unresolve-thread.sh <thread-id> [<thread-id>...]

Arguments:
  thread-id    GraphQL thread ID (PRRT_...) - can specify multiple

Options:
  --dry-run    Show what would be done without executing

Output:
{
  "success": true,
  "unresolved": ["PRRT_...", "PRRT_..."],
  "failed": []
}

Examples:
  # Single thread
  unresolve-thread.sh PRRT_kwDONRcYOs6D8dg9

  # Multiple threads
  unresolve-thread.sh PRRT_... PRRT_...
EOF
}

unresolve_threads() {
    local thread_ids=()
    local dry_run="false"

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

    if [ ${#thread_ids[@]} -eq 0 ]; then
        echo '{"error": "No thread IDs provided"}' >&2
        exit 1
    fi

    # Dry run
    if [ "$dry_run" = "true" ]; then
        printf '{"dry_run": true, "would_unresolve": %s}\n' \
            "$(printf '%s\n' "${thread_ids[@]}" | jq -R . | jq -s .)"
        exit 0
    fi

    # Single thread
    if [ ${#thread_ids[@]} -eq 1 ]; then
        local query='
mutation($threadId: ID!) {
  unresolveReviewThread(input: {threadId: $threadId}) {
    thread { id isResolved }
  }
}'
        local result
        result=$(gh_graphql "$query" -F threadId="${thread_ids[0]}") || {
            jq -nc --arg id "${thread_ids[0]}" '{success: false, unresolved: [], failed: [$id]}'
            exit 1
        }

        # Success if thread is now unresolved (isResolved=false)
        local is_resolved
        is_resolved=$(echo "$result" | jq -r 'if .unresolveReviewThread.thread.isResolved == false then "false" elif .unresolveReviewThread.thread.isResolved == true then "true" else "null" end')
        if [ "$is_resolved" = "false" ]; then
            jq -nc --arg id "${thread_ids[0]}" '{success: true, unresolved: [$id], failed: []}'
        else
            jq -nc --arg id "${thread_ids[0]}" '{success: false, unresolved: [], failed: [$id]}'
            exit 1
        fi
        return
    fi

    # Multiple threads - batch mutation. Thread ids are bound as GraphQL
    # variables rather than pasted into the query text, so an id can never
    # terminate the string literal and extend the mutation.
    local var_decls=() mutation_parts=() gh_args=()
    local idx=0
    for tid in "${thread_ids[@]}"; do
        var_decls+=("\$t${idx}: ID!")
        mutation_parts+=("t${idx}: unresolveReviewThread(input: {threadId: \$t${idx}}) { thread { id isResolved } }")
        gh_args+=(-F "t${idx}=$tid")
        idx=$((idx + 1))
    done

    local batch_query
    batch_query="mutation($(IFS=,; echo "${var_decls[*]}")) { $(printf '%s ' "${mutation_parts[@]}") }"

    local result
    result=$(gh_graphql "$batch_query" "${gh_args[@]}") || {
        printf '%s\n' "${thread_ids[@]}" | jq -R . | jq -sc '{success: false, unresolved: [], failed: .}'
        exit 1
    }

    # Parse results
    local unresolved=()
    local failed=()
    idx=0
    for tid in "${thread_ids[@]}"; do
        local is_resolved
        is_resolved=$(echo "$result" | jq -r "if .t${idx}.thread.isResolved == false then \"false\" else \"true\" end")
        if [ "$is_resolved" = "false" ]; then
            unresolved+=("$tid")
        else
            failed+=("$tid")
        fi
        idx=$((idx + 1))
    done

    # Output. A jq failure here must not read as "nothing unresolved": the
    # encoding is allowed to fail loudly instead of degrading to [].
    local unresolved_json failed_json
    unresolved_json=$(printf '%s\n' "${unresolved[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')
    failed_json=$(printf '%s\n' "${failed[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')

    jq -nc \
        --argjson unresolved "$unresolved_json" \
        --argjson failed "$failed_json" \
        '{success: ($failed | length) == 0, unresolved: $unresolved, failed: $failed}'
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

unresolve_threads "$@"
