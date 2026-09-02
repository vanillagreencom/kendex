#!/bin/bash
# Get CI failure logs for a PR
# Usage: ci-logs <PR_NUMBER> [--lines N] [--format=safe|text]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat <<'EOF'
Get CI failure logs for a PR

Usage: ci-logs <PR_NUMBER> [options]

Options:
  --lines N       Number of log lines to show (default: 100)
  --format=safe   JSON output with metadata (default)
  --format=text   Human-readable text output

Fetches the first failed workflow run for the PR and returns:
  - Job name (rust, etc.)
  - Error type (based on job name heuristics)
  - Run ID for further investigation
  - Failed log output (last N lines)

Examples:
  github.sh ci-logs 42               # JSON output with metadata
  github.sh ci-logs 42 --lines 200   # More log lines (JSON)
  github.sh ci-logs 42 --format=text # Human-readable text
EOF
}

classify_error_type() {
    local job_name="$1"
    local logs="$2"

    # Each grep reads a here-string, never a pipe: `grep -q` exits on its first
    # match, and past the 64KB pipe buffer that SIGPIPEs the writer, which
    # `pipefail` reports as a 141 a condition reads as no-match (KEN-1143).
    # `--lines` caps lines and never bytes, so no default holds the scanned
    # window under the buffer.
    if grep -qi 'cargo fmt\|Diff in' <<<"$logs"; then
        echo "fmt"
    elif grep -qi 'clippy' <<<"$logs"; then
        echo "clippy"
    elif grep -qi 'cargo test\|test result:\|FAILED' <<<"$logs"; then
        echo "test"
    elif grep -qi 'error\[E\|cannot find\|unresolved\|build failed' <<<"$logs"; then
        echo "build"
    else
        # Fallback to job name heuristics
        case "$job_name" in
        *fmt* | *format*) echo "fmt" ;;
        *clippy* | *lint*) echo "clippy" ;;
        *test*) echo "test" ;;
        *build*) echo "build" ;;
        *) echo "unknown" ;;
        esac
    fi
}

count_failed_checks() {
    local checks_json="$1"

    echo "$checks_json" | jq 'map(select(.state == "FAILURE" or .bucket == "fail")) | length'
}

select_failed_actions_check() {
    local checks_json="$1"

    echo "$checks_json" |
        jq -c '[.[] | select(.state == "FAILURE" or .bucket == "fail")
            | select((.link // "") | test("/actions/runs/[0-9]+"))] | .[0] // empty'
}

main() {
    local pr_num="" lines=100 format="safe"

    while [ $# -gt 0 ]; do
        case "$1" in
        --lines)
            if ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                echo "Error: --lines requires a non-negative integer" >&2
                exit 1
            fi
            lines="$2"
            shift 2
            ;;
        --format=*)
            format="${1#--format=}"
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
        echo "Error: PR number required" >&2
        exit 1
    fi

    # Validate before any API work so an unusable format is not discovered
    # after the fetches, and so early-exit paths agree with the final switch.
    case "$format" in
    safe | json) format="safe" ;;
    text) ;;
    *)
        echo "Error: Unknown format: $format. Use: safe, text" >&2
        exit 1
        ;;
    esac

    # Check PR exists
    if ! gh pr view "$pr_num" --json title >/dev/null 2>&1; then
        echo "Error: PR #$pr_num not found" >&2
        exit 1
    fi

    # Get failed checks
    local checks_json
    if ! checks_json=$(json_or_default '[]' array gh pr checks "$pr_num" --json name,state,link,workflow,bucket); then
        if [ "$format" = "safe" ]; then
            jq -n --arg pr "$pr_num" '{error: "ci_fetch_failed", details: ("Failed to fetch CI checks for PR #" + $pr)}'
            exit 0
        fi
        echo "Error: failed to fetch CI checks for PR #$pr_num" >&2
        exit 1
    fi

    # Find the first failed GitHub Actions check. External providers (for example
    # Codecov) do not expose a workflow run ID that `gh run view` can inspect.
    local failed_check failed_count
    failed_count=$(count_failed_checks "$checks_json")
    failed_check=$(select_failed_actions_check "$checks_json")

    if [ -z "$failed_check" ]; then
        if [ "$failed_count" -eq 0 ]; then
            if [ "$format" = "safe" ]; then
                jq -n '{error: "No failed checks found for this PR"}'
            else
                echo "No failed checks found for PR #$pr_num"
            fi
        else
            if [ "$format" = "safe" ]; then
                jq -n '{error: "No failed GitHub Actions checks found for this PR"}'
            else
                echo "No failed GitHub Actions checks found for PR #$pr_num"
            fi
        fi
        exit 0
    fi

    local run_id="" job_id="" job_name workflow_name check_link
    job_name=$(echo "$failed_check" | jq -r '.name')
    workflow_name=$(echo "$failed_check" | jq -r 'if (.workflow | type) == "object" then .workflow.name // empty else .workflow // empty end')
    check_link=$(echo "$failed_check" | jq -r '.link // empty')

    if [[ "$check_link" =~ /actions/runs/([0-9]+)/jobs/([0-9]+) ]]; then
        run_id="${BASH_REMATCH[1]}"
        job_id="${BASH_REMATCH[2]}"
    elif [[ "$check_link" =~ /actions/runs/([0-9]+) ]]; then
        run_id="${BASH_REMATCH[1]}"
        job_id=""
    fi

    if [ -z "$run_id" ]; then
        echo "Error: unable to extract workflow run ID from check link: $check_link" >&2
        exit 1
    fi

    # Fetch failed logs. A fetch failure must not be handed back as if it were
    # log content: gh's error text would otherwise flow into classify_error_type
    # and be reported as a real error_type with exit 0.
    local logs log_status=0
    if [ -n "$job_id" ]; then
        logs=$(gh run view "$run_id" --job "$job_id" --log-failed 2>&1) || log_status=$?
    else
        logs=$(gh run view "$run_id" --log-failed 2>&1) || log_status=$?
    fi

    if [ "$log_status" -ne 0 ]; then
        # Clipped in-shell, and clipped BEFORE flattening: `| head -c 300`
        # SIGPIPEs `tr` past the pipe buffer and this assignment has no guard,
        # so errexit takes down the branch that reports the failure (KEN-1143);
        # `${var//…}` over a whole multi-megabyte log is quadratic, so the 300
        # characters that survive are the ones that get replaced. Newline for
        # space is one character for one, so the order does not change the text.
        local log_detail
        log_detail="${logs:0:300}"
        log_detail="${log_detail//$'\n'/ }"
        if [ "$format" = "safe" ]; then
            jq -n --arg run_id "$run_id" --arg detail "$log_detail" \
                '{error: "log_fetch_failed", run_id: $run_id, details: $detail}'
        else
            echo "Error: failed to fetch logs for run $run_id: $log_detail" >&2
        fi
        exit 1
    fi

    logs=$(printf '%s\n' "$logs" | tail -n "$lines")

    # Classify error type
    local error_type
    error_type=$(classify_error_type "$job_name" "$logs")

    case "$format" in
    safe | json)
        # The log reaches jq on stdin, never in argv: a single argument over
        # MAX_ARG_STRLEN (128KB) is refused by the kernel, and `--arg logs`
        # dropped the whole result — no error_type, no run_id, nothing on
        # stdout — for the large logs this command exists to report (KEN-1143).
        # `-Rs` slurps that raw text into the one string `.`. jq reads to EOF,
        # so nothing here closes on a writer.
        printf '%s' "$logs" | jq -Rs \
            --arg run_id "$run_id" \
            --arg job "$job_name" \
            --arg workflow "$workflow_name" \
            --arg error_type "$error_type" \
            '{run_id: $run_id, job: $job, workflow: $workflow, error_type: $error_type, logs: .}'
        ;;
    text)
        echo "Job: $job_name"
        echo "Workflow: $workflow_name"
        echo "Error type: $error_type"
        echo "Run ID: $run_id"
        echo ""
        echo "--- Failed logs (last $lines lines) ---"
        echo "$logs"
        ;;
    *)
        echo "Error: Unknown format: $format. Use: safe, text" >&2
        exit 1
        ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
