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
#                          ci_pending | computing | merged | closed | none.
#                          An issue prefix outside that vocabulary becomes
#                          the cause word itself, so an additional pr-merge prefix
#                          names itself instead of reading as all-clear
#   issue: <raw>           every refusal issue, verbatim
#   head-run: <ids>        (ci_failed/ci_pending only) run ids the CI
#                          classification was scoped to; "none" when no
#                          run-correlated checks exist
#   fail: ...              (ci_failed only) each failing check with its
#                          state, workflow, and run id
#   superseded: ...        (ci_failed only) runs on the head whose checks
#                          were NOT counted — workflow runs (`workflow=`)
#                          and commit statuses (`status=`) alike. A status
#                          lands here when a newer same-name status
#                          replaced it, and also when it is the latest of
#                          its name but the run it links was retired by the
#                          stale-status rewrite. A failure someone read
#                          from raw `gh pr checks` output may belong here
#
# Every line reads ONE checks snapshot: pr-merge --check embeds the rollup
# it classified in its JSON (`checks`), and this script scopes that instead
# of refetching — cause:/issue: and head-run:/fail:/superseded: cannot
# describe different fetches.
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
# gate cannot disagree about which run is current. CI_RUN_JQ_DEFS carries the
# one runid/bucket implementation for every jq program below.
# shellcheck source=../lib/ci-run-correlation.sh
source "$SCRIPT_DIR/../lib/ci-run-correlation.sh"

# Check and workflow names are chosen by fork PRs and third-party check apps;
# a newline inside one would forge a line in this line-oriented output.
SANITIZE_JQ='def clean: tostring | gsub("[\r\n\t]"; " ");'

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
    *)
        if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$pr_num" ]; then
            pr_num="$1"
            shift
        else
            echo "Error: expected exactly one numeric PR number, got: $1" >&2
            exit 2
        fi
        ;;
    esac
done

if [ -z "$pr_num" ]; then
    echo "Error: PR number required" >&2
    exit 2
fi

# pr-merge --check prints its own verdict lines on stderr; only its JSON is
# input here. A run that produces no parseable object is this script's own
# failure — surfaced with pr-merge's last stderr line, which on a crash is
# the real diagnostic.
check_err="$(mktemp)" || { echo "Error: could not create a temporary file" >&2; exit 1; }
trap 'rm -f "$check_err"' EXIT
check_json=$(bash "$SCRIPT_DIR/pr-merge.sh" "$pr_num" --check 2>"$check_err") || true
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$check_json"; then
    echo "Error: pr-merge --check produced no parseable JSON for PR #$pr_num" >&2
    tail -1 "$check_err" | tr -d '\r' | sed 's/^/  /' >&2
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
# `none` is reserved for an empty issues[] — an issue whose prefix is not in
# this table names itself, so an unlisted pr-merge prefix routes as "report it",
# never as a false all-clear.
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
    else (.issues[0] | split(":")[0] | gsub("[^A-Za-z0-9_-]"; "_"))
    end
' <<<"$check_json")

echo "cause: $cause"
jq -r "$SANITIZE_JQ"' .issues[]? | "issue: " + clean' <<<"$check_json"

if [ "$cause" = "none" ]; then
    echo "note: checks pass now — the refusal did not come from these gates (or has cleared); re-run the refusing command"
    exit 0
fi

if [ "$cause" = "ci_pending" ]; then
    check_head_run_line <<<"$check_json"
    exit 0
fi

[ "$cause" = "ci_failed" ] || exit 0

# Correlate each failing check with its run, and name the runs on this head
# whose checks were dropped as superseded — the run a raw `gh pr checks`
# failure line usually belongs to when it disagrees with the gate. ONE
# snapshot governs the whole classification: the rollup pr-merge --check
# fetched and classified rides in its JSON as `checks`, and the scoping
# re-derives here through the same sourced scope_current_run — a rerun
# starting between two fetches cannot make cause:/issue: and the
# fail:/superseded: detail describe different states.
check_head_run_line <<<"$check_json"

ci_json=$(jq -c '.checks // []' <<<"$check_json")
scoped_json=$(echo "$ci_json" | scope_current_run)

echo "$scoped_json" | jq -r "$CI_RUN_JQ_DEFS$SANITIZE_JQ"'
    .[]
    | select((bucket != "pass") and (bucket != "skipping") and (bucket != "pending"))
    | "fail: \(.name | clean) state=\((.state // "?") | clean) workflow=\(if (.workflow // "") == "" then "-" else (.workflow | clean) end) run=\(runid // "none")"
'

# Superseded covers both record kinds: workflow runs whose checks were
# dropped by run selection, and commit-status records that lost the
# per-name grouping to a newer same-name status. What was kept is head_runs
# itself, not every run id the scoped records mention: a status the rewrite
# held EXPECTED still links the run that rewrite retired, and reading that
# link as kept would leave the retired run on neither list.
jq -n --argjson raw "$ci_json" --argjson scoped "$scoped_json" "$CI_RUN_JQ_DEFS$SANITIZE_JQ"'
    ($scoped | head_runs) as $kept
    | (($raw
        | map(select((.workflow // "") != "")
              | {id: ("workflow=" + (.workflow | clean)), run: runid}
              | select(.run != null)))
       + ($raw
          | map(select((.workflow // "") == "")
                | {id: ("status=" + (.name | clean)), run: runid}
                | select(.run != null))))
    | unique
    | map(select(.run as $r | ($kept | index($r)) | not))
    | .[]
    | "superseded: \(.id) run=\(.run) (checks from this run were not counted)"
' -r
