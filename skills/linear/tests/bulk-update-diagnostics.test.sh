#!/usr/bin/env bash
# Regression test: bulk-update must emit an aggregate diagnostic even when an
# individual issue update exits nonzero under set -e.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_SH="$SCRIPT_DIR/../scripts/commands/issues.sh"

set +e
out="$(
    LINEAR_API_KEY_OVERRIDE=test-token bash -euo pipefail -c '
        issues_sh="$1"
        # shellcheck disable=SC1090
        source "$issues_sh"

        update_issue() {
            case "$1" in
            CC-519)
                printf "{\"success\":true,\"identifier\":\"CC-519\"}\n"
                ;;
            CC-524)
                printf "{\"error\":\"state not found\"}\n" >&2
                return 1
                ;;
            CC-525)
                return 1
                ;;
            *)
                printf "{\"error\":\"unexpected test id %s\"}\n" "$1" >&2
                return 1
                ;;
            esac
        }

        bulk_update_issues CC-519 CC-524 CC-525 --state Todo
    ' _ "$ISSUES_SH" 2>&1
)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "FAIL bulk_update_issues returned success despite failed item"
    exit 1
fi

if ! jq -e '
    .success == false
    and .partial == true
    and .updated == 1
    and .failed == 2
    and (.results | length) == 3
    and (.results[] | select(.identifier == "CC-519" and .success == true))
    and (.results[] | select(.identifier == "CC-524" and .success == false and (.error | contains("state not found"))))
    and (.results[] | select(.identifier == "CC-525" and .success == false and (.error | contains("without output"))))
' >/dev/null <<<"$out"; then
    echo "FAIL unexpected bulk-update diagnostic:"
    echo "$out"
    exit 1
fi


# A success-path warning on stderr must not flip a committed update to failure.
# update_issue emits advisory warnings while still succeeding (sub-issue
# sort-order note, skipped label); merging them into stdout broke the .success
# parse and reported the committed update as a failure.
set +e
warn_out="$(
    LINEAR_API_KEY_OVERRIDE=test-token bash -euo pipefail -c '
        issues_sh="$1"
        # shellcheck disable=SC1090
        source "$issues_sh"

        update_issue() {
            printf "WARN: %s is a sub-issue of CC-1 — sort order has no effect on sub-issues\n" "$1" >&2
            printf "Warning: Label not found: '"'"'agent:rust'"'"' (skipped)\n" >&2
            printf "{\"success\":true,\"identifier\":\"%s\"}\n" "$1"
        }

        bulk_update_issues CC-600 CC-601 --state Todo
    ' _ "$ISSUES_SH" 2>/dev/null
)"
warn_rc=$?
warn_err="$(
    LINEAR_API_KEY_OVERRIDE=test-token bash -euo pipefail -c '
        issues_sh="$1"
        # shellcheck disable=SC1090
        source "$issues_sh"

        update_issue() {
            printf "WARN: %s is a sub-issue of CC-1 — sort order has no effect on sub-issues\n" "$1" >&2
            printf "{\"success\":true,\"identifier\":\"%s\"}\n" "$1"
        }

        bulk_update_issues CC-600 --state Todo
    ' _ "$ISSUES_SH" 2>&1 >/dev/null
)"
set -e

if [ "$warn_rc" -ne 0 ]; then
    echo "FAIL bulk_update_issues returned nonzero for updates that only warned"
    echo "$warn_out"
    exit 1
fi

if ! jq -e '
    .success == true
    and .partial == false
    and .updated == 2
    and .failed == 0
    and (.results | map(.success) | all)
' >/dev/null <<<"$warn_out"; then
    echo "FAIL a success-path warning was reported as a failed update:"
    echo "$warn_out"
    exit 1
fi

if ! grep -q "sort order has no effect" <<<"$warn_err"; then
    echo "FAIL the success-path warning was swallowed instead of relayed to stderr:"
    echo "$warn_err"
    exit 1
fi

echo "all pass"
