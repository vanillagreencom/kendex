#!/bin/bash
# Name the cause of a pr-merge refusal.
# Usage: ci-classify-refusal <PR_NUMBER>
#
# Re-runs pr-merge's safety checks and reduces the refusal to one primary
# `cause:` word, so callers route on a name instead of re-deriving the
# diagnosis from raw `gh pr checks` output (which mixes superseded runs into
# the current head's rollup and cannot be read as a merge gate).
#
# Output (stdout, one item per line):
#   cause: <word>          primary cause — fetch_error | merge_conflict |
#                          changes_requested | threads | ci_failed |
#                          ci_pending | computing | merged | closed | none
#   issue: <raw>           every refusal issue, verbatim
#   head-run: <ids>        (ci_failed/ci_pending only) run ids the CI
#                          classification was scoped to; "none" when no
#                          run-correlated checks exist
#   fail: ...              (ci_failed only) each failing check with its
#                          state, workflow, and run id
#   superseded: ...        (ci_failed only) runs on the head whose checks
#                          were NOT counted — a failure someone read from
#                          raw `gh pr checks` output may belong here
#
# `cause: none` means the checks pass now: the refusal was not produced by
# these gates (or has cleared since) — re-run the refusing command.
#
# Exit codes:
#   0   classified (including cause: none)
#   1   the check run itself failed to produce parseable JSON
#   2   usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared with pr-merge.sh and orch ci-wait, so this diagnosis and the merge
# gate cannot disagree about which run is current.
# shellcheck source=../lib/ci-run-correlation.sh
source "$SCRIPT_DIR/../lib/ci-run-correlation.sh"

# The leading comment block is the contract, printed by shape rather than by
# line number so --help cannot drift as that block grows.
show_help() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

pr_num=""
while [ $# -gt 0 ]; do
    case "$1" in
    --help | -h)
        show_help
        exit 0
        ;;
    [0-9]*)
        pr_num="$1"
        shift
        ;;
    *)
        echo "Error: Unknown option: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$pr_num" ]; then
    echo "Error: PR number required" >&2
    exit 2
fi

# pr-merge --check prints its own verdict lines on stderr; only its JSON is
# input here. A run that produces no parseable object is this script's own
# failure, never a classification.
check_json=$(bash "$SCRIPT_DIR/pr-merge.sh" "$pr_num" --check 2>/dev/null) || true
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$check_json"; then
    echo "Error: pr-merge --check produced no parseable JSON for PR #$pr_num" >&2
    exit 1
fi

state=$(jq -r '.state // "UNKNOWN"' <<<"$check_json")
if [ "$state" = "MERGED" ]; then
    echo "cause: merged"
    exit 0
fi
if [ "$state" = "CLOSED" ]; then
    echo "cause: closed"
    exit 0
fi

# Primary cause by priority: an unreadable GitHub answer taints every other
# signal, then the permanent blockers, then the ones that clear on their own.
cause=$(jq -r '
    def matched(re): any(.issues[]?; test(re));
    if (.issues // [] | length) == 0 then "none"
    elif matched("^(not_found|gh_error|ci_fetch_failed|review_threads_fetch_failed|review_fetch_failed):") then "fetch_error"
    elif matched("^conflicts:") then "merge_conflict"
    elif matched("^changes_requested:") then "changes_requested"
    elif matched("^unresolved_threads:") then "threads"
    elif matched("^ci_failed:") then "ci_failed"
    elif matched("^ci_pending:") then "ci_pending"
    elif matched("^unknown:") then "computing"
    else "none"
    end
' <<<"$check_json")

echo "cause: $cause"
jq -r '.issues[]? | "issue: " + .' <<<"$check_json"

if [ "$cause" = "none" ]; then
    echo "note: checks pass now — the refusal did not come from these gates (or has cleared); re-run the refusing command"
    exit 0
fi

case "$cause" in
ci_failed | ci_pending) ;;
*) exit 0 ;;
esac

echo "head-run: $(jq -r '.head_runs // [] | if length == 0 then "none" else map(tostring) | join(",") end' <<<"$check_json")"

[ "$cause" = "ci_failed" ] || exit 0

# Correlate each failing check with its run, and name the runs on this head
# whose checks were dropped as superseded — the run a raw `gh pr checks`
# failure line usually belongs to when it disagrees with the gate.
ci_json=$(gh pr checks "$pr_num" --json name,state,bucket,link,workflow 2>&1) || true
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ci_json"; then
    echo "detail: could not fetch checks for run correlation — $(head -1 <<<"$ci_json")"
    exit 0
fi

scoped_json=$(echo "$ci_json" | scope_current_run)
echo "$scoped_json" | jq -r '
    def bucket:
        (.bucket // (
            if (.state == "SUCCESS") then "pass"
            elif (.state == "SKIPPED") then "skipping"
            elif ((.state // "") | IN("PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "EXPECTED")) then "pending"
            elif (.state == "CANCELLED") then "cancel"
            else "fail"
            end
        ));
    .[]
    | select((bucket != "pass") and (bucket != "skipping") and (bucket != "pending"))
    | "fail: \(.name) state=\(.state // "?") workflow=\(if (.workflow // "") == "" then "-" else .workflow end) run=\(((.link // "") | (capture("/actions/runs/(?<r>[0-9]+)")? | .r)) // "none")"
'

jq -n --argjson raw "$ci_json" --argjson scoped "$scoped_json" '
    def runid: ((.link // "") | (capture("/actions/runs/(?<r>[0-9]+)")? | .r) // null);
    ([$scoped[] | runid | select(. != null)] | unique) as $kept
    | $raw
    | map(select((.workflow // "") != "") | {workflow, run: runid} | select(.run != null))
    | unique
    | map(select(.run as $r | ($kept | index($r)) | not))
    | .[]
    | "superseded: workflow=\(.workflow) run=\(.run) (checks from this run were not counted)"
' -r
