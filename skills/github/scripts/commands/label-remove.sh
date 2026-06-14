#!/usr/bin/env bash
# GitHub label remove wrapper.
# Runs `gh pr edit --remove-label` or `gh issue edit --remove-label`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/label-activity.sh
source "$SCRIPT_DIR/../lib/label-activity.sh"
# shellcheck source=../lib/gh-auth.sh
source "$SCRIPT_DIR/../lib/gh-auth.sh"

show_help() {
    cat <<'EOF'
Remove a label from a PR or issue.

Usage: label-remove.sh <pr-or-issue-ref> <label> [--reason TEXT] [--issue]

Arguments:
  pr-or-issue-ref   PR number, branch ref, or issue number. Empty
                    string defers to gh's current-branch resolution.
  label             Label name to remove (single label per call).

Options:
  --reason TEXT     Human-readable reason recorded in activity details.
  --issue           Treat the ref as an issue (default: PR).
  --pr              Treat the ref as a PR (default).
  --help, -h        Show this help.

Examples:
  label-remove.sh 44 defer-ci --reason "CI passed; re-enable"
  label-remove.sh 123 needs-triage --issue
EOF
}

main() {
    local ref="" label="" reason="" kind="pr"
    local positional=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --reason) reason="${2:-}"; shift 2 ;;
            --reason=*) reason="${1#--reason=}"; shift ;;
            --issue) kind="issue"; shift ;;
            --pr) kind="pr"; shift ;;
            --) shift; break ;;
            -*)
                echo "label-remove: unknown flag: $1" >&2
                exit 2
                ;;
            *)
                case "$positional" in
                    0) ref="$1"; positional=1 ;;
                    1) label="$1"; positional=2 ;;
                    *) echo "label-remove: unexpected positional: $1" >&2; exit 2 ;;
                esac
                shift
                ;;
        esac
    done

    if [ -z "$label" ]; then
        echo "label-remove: <label> is required" >&2
        show_help >&2
        exit 2
    fi

    local project_root
    project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    vstack_github_load_project_env_preserving_caller "$project_root"
    vstack_github_apply_selected_auth_token router || true
    vstack_github_sanitize_gh_env

    local rc=0
    if [ "$kind" = "issue" ]; then
        gh issue edit "$ref" --remove-label "$label" || rc=$?
    else
        gh pr edit "$ref" --remove-label "$label" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi

    emit_label_activity remove "$kind" "$ref" "$label" "$reason" || true
    exit 0
}

main "$@"
