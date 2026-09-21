# shellcheck shell=bash
#
# The merge-queue disarm/dequeue GraphQL verb, owned in one place and shared by
# the github skill's pr-merge admin-credential route and orch's queue-wait
# late-findings guard, so the two cannot drift. Both must disarm classic
# auto-merge BEFORE dequeuing: an armed PR re-enters the queue the moment its
# requirements go green, so a bare dequeue can be raced straight back in.
#
# dequeuePullRequest's input field is named `id` but takes the PULL REQUEST
# node id (schema-verified), not the mergeQueueEntry id; enqueue's is
# `pullRequestId`.
#
# Source this file; do not execute it directly.

# Run one merge-queue mutation and verify its response. HTTP success is not
# enough: a body carrying an `errors` key, or missing the mutation's own
# payload, is a failure. On failure the reason (the GraphQL error messages, or
# the captured stderr when the body carried none) is printed to stdout and the
# function returns 1; an unknown mutation name returns 2.
#
# Args: <mutation-name> <pr-node-id> [gh-stderr-file]
kendex_merge_queue_mutation() {
    local what="$1" node_id="$2" err_file="${3:-/dev/null}" mutation resp status reason
    case "$what" in
    dequeuePullRequest)
        mutation='mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { mergeQueueEntry { id } } }' ;;
    disablePullRequestAutoMerge)
        mutation='mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId } }' ;;
    *)
        return 2 ;;
    esac
    resp=$(gh api graphql -f query="$mutation" -F id="$node_id" 2>"$err_file")
    status=$?
    if [ "$status" -eq 0 ] \
        && jq -e --arg m "$what" 'type == "object" and (has("errors") | not) and (.data[$m] != null)' >/dev/null 2>&1 <<<"$resp"; then
        return 0
    fi
    reason=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp" 2>/dev/null) || reason=""
    [ -n "$reason" ] || reason="$(head -c 200 "$err_file" 2>/dev/null | tr '\n' ' ')"
    printf '%s' "$reason"
    return 1
}
