#!/bin/bash
# Wait for GitHub to finish computing a PR's merge state.
# Usage: await-mergeable <PR_NUMBER> [--interval SECS] [--max-iter N] [--quiet]
#
# Terminates successfully when:
#   - state in {MERGED, CLOSED}, OR
#   - mergeStateStatus is anything other than UNKNOWN
#     (CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, HAS_HOOKS)
#
# Never gates on `mergeable` alone. After merge, `mergeable` becomes
# permanently UNKNOWN — polling on it loops forever.
#
# Exit codes:
#   0   resolved
#   1   bad args / PR not found
#   124 timed out (default 60 iterations × 5s = 5 min)
#
# Stdout (on success): single-line JSON
#   {"state":"MERGED","mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN","iterations":3}

set -euo pipefail

show_help() {
    cat <<'EOF'
Wait for GitHub to finish computing a PR's merge state.

Usage: await-mergeable <PR_NUMBER> [options]

Options:
  --interval SECS  Poll interval (default: 5)
  --max-iter N     Max iterations before timeout (default: 60 = 5 min)
  --quiet          Suppress progress output on stderr

Resolution rules:
  - state == "MERGED" or "CLOSED"     → resolved
  - mergeStateStatus != "UNKNOWN"     → resolved (CLEAN/BLOCKED/BEHIND/DIRTY/UNSTABLE/HAS_HOOKS)
  - mergeable alone is NEVER used    (stays UNKNOWN permanently after merge)

Exit codes:
  0    resolved (state printed as JSON on stdout)
  1    bad args / PR not found
  124  timed out

Examples:
  github.sh await-mergeable 42
  github.sh await-mergeable 42 --interval 3 --max-iter 100
  STATE=$(github.sh await-mergeable 42 | jq -r '.state')
EOF
}

main() {
    local pr_num=""
    local interval=5
    local max_iter=60
    local quiet=false

    while [ $# -gt 0 ]; do
        case "$1" in
        --interval)
            if ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                echo "Error: --interval requires a non-negative integer" >&2
                exit 1
            fi
            interval="$2"
            shift 2
            ;;
        --max-iter)
            if ! [[ "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --max-iter requires a positive integer" >&2
                exit 1
            fi
            max_iter="$2"
            shift 2
            ;;
        --quiet)
            quiet=true
            shift
            ;;
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
            exit 1
            ;;
        esac
    done

    if [ -z "$pr_num" ]; then
        echo '{"error": "PR number required"}' >&2
        exit 1
    fi

    # Quick validation — fail fast on missing PR rather than looping.
    if ! gh pr view "$pr_num" --json number >/dev/null 2>&1; then
        echo "{\"error\": \"PR #$pr_num not found\"}" >&2
        exit 1
    fi

    local i=0
    local view state msstatus mergeable
    local fetch_failures=0 last_fetch_error=""
    while [ "$i" -lt "$max_iter" ]; do
        i=$((i + 1))

        if ! view=$(gh pr view "$pr_num" --json state,mergeStateStatus,mergeable 2>&1); then
            fetch_failures=$((fetch_failures + 1))
            last_fetch_error=$(printf '%s' "$view" | tr '\n' ' ' | head -c 200)
            view='{}'
        fi
        state=$(echo "$view" | jq -r '.state // "UNKNOWN"')
        msstatus=$(echo "$view" | jq -r '.mergeStateStatus // "UNKNOWN"')
        mergeable=$(echo "$view" | jq -r '.mergeable // "UNKNOWN"')

        # Terminal: PR is closed/merged.
        if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
            jq -n -c \
                --arg state "$state" \
                --arg msstatus "$msstatus" \
                --arg mergeable "$mergeable" \
                --argjson iterations "$i" \
                '{state:$state, mergeStateStatus:$msstatus, mergeable:$mergeable, iterations:$iterations}'
            return 0
        fi

        # Terminal: GitHub finished computing merge state.
        # Anything that isn't UNKNOWN is a resolved state the caller can branch on.
        if [ "$msstatus" != "UNKNOWN" ] && [ -n "$msstatus" ]; then
            jq -n -c \
                --arg state "$state" \
                --arg msstatus "$msstatus" \
                --arg mergeable "$mergeable" \
                --argjson iterations "$i" \
                '{state:$state, mergeStateStatus:$msstatus, mergeable:$mergeable, iterations:$iterations}'
            return 0
        fi

        if [ "$quiet" != true ]; then
            echo "  await-mergeable: PR #$pr_num iter $i/$max_iter — state=$state mergeStateStatus=$msstatus" >&2
        fi

        sleep "$interval"
    done

    echo "Error: timed out after $max_iter iterations × ${interval}s waiting for PR #$pr_num to resolve" >&2
    echo "  last seen: state=$state mergeStateStatus=$msstatus mergeable=$mergeable" >&2
    # A timeout spent entirely on failed reads is an API problem, not a slow
    # merge-state computation; say which one the operator is looking at.
    if [ "$fetch_failures" -gt 0 ]; then
        echo "  $fetch_failures of $max_iter polls failed to read the PR; last error: $last_fetch_error" >&2
    fi
    exit 124
}

main "$@"
