#!/bin/bash
# GitHub API - Run one merge-queue mutation on a pull request
# Usage: merge-queue-mutation.sh <disablePullRequestAutoMerge|dequeuePullRequest> <pr-node-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge-queue.sh
source "$SCRIPT_DIR/../lib/merge-queue.sh"

show_help() {
    cat << 'EOF'
Run One Merge-Queue Mutation

Usage: merge-queue-mutation.sh <disablePullRequestAutoMerge|dequeuePullRequest> <pr-node-id>

Arguments:
  mutation     disablePullRequestAutoMerge or dequeuePullRequest. Disarm
               before dequeuing: an armed pull request re-enters the queue
               the moment its requirements pass.
  pr-node-id   The pull request's GraphQL node id (PR_...), for either.

The mutation is done only where gh answers and the body carries the
mutation's payload and no errors key.

Exit status: 0 done; 1 not done, the reason (GitHub's error messages, else
gh's stderr) on stdout; 2 usage.
EOF
}

case "${1:-}" in
    --help|-h) show_help; exit 0 ;;
esac
[ "$#" -eq 2 ] || { show_help >&2; exit 2; }
err="$(mktemp)" || { echo "merge-queue-mutation: scratch=mktemp-failed" >&2; exit 1; }
trap 'rm -f -- "$err"' EXIT
status=0
kendex_merge_queue_mutation "$1" "$2" "$err" || status=$?
[ "$status" -ne 2 ] || { show_help >&2; exit 2; }
exit "$status"
