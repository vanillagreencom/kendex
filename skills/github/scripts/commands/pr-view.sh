#!/bin/bash
# View PR details for current branch or specified PR
# Usage: pr-view [PR_NUMBER] [--json FIELDS]

set -euo pipefail

COMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pr-branch.sh
source "$COMMAND_DIR/../lib/pr-branch.sh"
# shellcheck source=../lib/gh-auth.sh
source "$COMMAND_DIR/../lib/gh-auth.sh"

json_error() {
    local status="$1"
    local message="$2"
    local detail="${3:-}"
    local exit_code="${4:-1}"

    jq -nc \
        --arg status "$status" \
        --arg error "$message" \
        --arg detail "$detail" \
        --argjson exit_code "$exit_code" \
        '{status: $status, error: $error, detail: $detail, exit_code: $exit_code, number: null}'
}

emit_error_result() {
    local status="$1"
    local message="$2"
    local detail="${3:-}"
    local exit_code="${4:-1}"

    printf 'pr-view: %s\n' "$message" >&2
    if [ -n "$detail" ]; then
        printf '%s\n' "$detail" >&2
    fi
    json_error "$status" "$message" "$detail" "$exit_code"
}

classify_gh_error() {
    local detail_lc
    detail_lc="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

    case "$detail_lc" in
        *"no pull requests found"*|*"no pull request found"*|*"no open pull requests found"*|*"no pull requests"*found*)
            printf '%s' "no_pr"
            ;;
        *"authentication"*|*"not logged in"*|*"bad credentials"*|*"http 401"*|*"unauthorized"*|*"gh auth login"*)
            printf '%s' "auth_error"
            ;;
        *)
            printf '%s' "gh_error"
            ;;
    esac
}

show_help() {
    cat << 'EOF'
View PR details

Usage: pr-view [PR_NUMBER] [options]

Arguments:
  PR_NUMBER    PR number (optional, defaults to current branch's PR)

Options:
  --json FIELDS    Output specific fields as JSON (e.g., --json number,title)
  --help           Show this help

Errors:
  Emits structured JSON with status=no_pr, auth_error, token_resolution_failed,
  token_resolution_timeout, token_resolution_unavailable, auth_timeout,
  gh_timeout, or gh_error and exits nonzero. Raw gh/op detail is preserved in
  stderr and the JSON detail field.

Examples:
  github.sh pr-view              # View PR for current branch
  github.sh pr-view 68           # View PR #68
  github.sh pr-view --json number   # Check if PR exists (returns JSON or fails)
  github.sh -C /path/to/worktree pr-view --json number
EOF
}

main() {
    local pr_num=""
    local json_fields=""
    local -a extra_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)
                json_fields="$2"
                shift 2
                ;;
            --json=*)
                json_fields="${1#--json=}"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                extra_args+=("$1")
                shift
                ;;
            *)
                if [ -z "$pr_num" ]; then
                    pr_num="$1"
                else
                    extra_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    local -a cmd=(gh pr view)
    [ -n "$pr_num" ] && cmd+=("$pr_num")
    [ -n "$json_fields" ] && cmd+=(--json "$json_fields")
    [ ${#extra_args[@]} -gt 0 ] && cmd+=("${extra_args[@]}")

    local auth_out auth_err pr_out pr_err
    PR_VIEW_TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${PR_VIEW_TMP_DIR:-}"' EXIT
    auth_out="$PR_VIEW_TMP_DIR/auth.out"
    auth_err="$PR_VIEW_TMP_DIR/auth.err"
    pr_out="$PR_VIEW_TMP_DIR/pr.out"
    pr_err="$PR_VIEW_TMP_DIR/pr.err"

    local auth_timeout="${VSTACK_GITHUB_AUTH_TIMEOUT:-10}"
    local auth_status=0
    vstack_github_auth_status_capture "$auth_timeout" "$auth_out" "$auth_err" || auth_status=$?
    if [ "$auth_status" -ne 0 ]; then
        local auth_detail
        auth_detail="$(cat "$auth_out" "$auth_err" 2>/dev/null | head -c 1000)"
        if [ "$auth_status" -eq 124 ]; then
            emit_error_result "auth_timeout" "GitHub auth preflight timed out after ${auth_timeout}s" "$auth_detail" 124
            exit 124
        fi
        if [ -n "${VSTACK_GITHUB_TOKEN_ERROR_TYPE:-}" ]; then
            local token_detail="${VSTACK_GITHUB_TOKEN_ERROR_DETAIL:-$auth_detail}"
            emit_error_result "$VSTACK_GITHUB_TOKEN_ERROR_TYPE" "${VSTACK_GITHUB_TOKEN_ERROR:-GitHub token resolution failed}" "$token_detail" 3
            exit 3
        fi
        emit_error_result "auth_error" "GitHub auth preflight failed" "$auth_detail" 3
        exit 3
    fi

    local pr_timeout="${VSTACK_GITHUB_PR_VIEW_TIMEOUT:-30}"
    local output status=0
    vstack_github_run_bounded_capture "$pr_timeout" "$pr_out" "$pr_err" "${cmd[@]}" || status=$?
    output="$(cat "$pr_out")"
    if [ "$status" -ne 0 ]; then
        local detail error_status message exit_status
        detail="$(cat "$pr_err" "$pr_out" 2>/dev/null | head -c 1000)"
        if [ "$status" -eq 124 ]; then
            emit_error_result "gh_timeout" "gh pr view timed out after ${pr_timeout}s" "$detail" 124
            exit 124
        fi
        error_status="$(classify_gh_error "$detail")"
        case "$error_status" in
            no_pr)
                message="No pull request found for the current branch"
                exit_status=1
                ;;
            auth_error)
                message="GitHub auth failed during gh pr view"
                exit_status=3
                ;;
            *)
                message="gh pr view failed"
                exit_status="$status"
                ;;
        esac
        emit_error_result "$error_status" "$message" "$detail" "$exit_status"
        exit "$exit_status"
    fi
    if [ -n "$output" ]; then
        printf '%s\n' "$output"
    fi
    emit_checks_activity "$json_fields" "$pr_num" "$output"
}

# Dashboard activity emission was removed.
emit_checks_activity() { return 0; }

main "$@"
