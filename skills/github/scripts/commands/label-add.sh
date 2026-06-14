#!/usr/bin/env bash
# GitHub label add wrapper.
# Runs `gh pr edit --add-label` or `gh issue edit --add-label`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/label-activity.sh
source "$SCRIPT_DIR/../lib/label-activity.sh"
# shellcheck source=../lib/gh-auth.sh
source "$SCRIPT_DIR/../lib/gh-auth.sh"

show_help() {
    cat <<'EOF'
Add a label to a PR or issue.

Usage: label-add.sh <pr-or-issue-ref> <label> [--reason TEXT] [--issue]

Arguments:
  pr-or-issue-ref   PR number, branch ref, or issue number. Empty
                    string defers to gh's current-branch resolution.
  label             Label name to add (single label per call).

Options:
  --reason TEXT     Human-readable reason recorded in activity details.
  --issue           Treat the ref as an issue (default: PR).
  --pr              Treat the ref as a PR (default).
  --help, -h        Show this help.

Examples:
  label-add.sh 44 defer-ci --reason "skip heavy CI"
  label-add.sh 123 needs-triage --issue
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
                echo "label-add: unknown flag: $1" >&2
                exit 2
                ;;
            *)
                case "$positional" in
                    0) ref="$1"; positional=1 ;;
                    1) label="$1"; positional=2 ;;
                    *) echo "label-add: unexpected positional: $1" >&2; exit 2 ;;
                esac
                shift
                ;;
        esac
    done

    if [ -z "$label" ]; then
        echo "label-add: <label> is required" >&2
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
        gh issue edit "$ref" --add-label "$label" || rc=$?
    else
        gh pr edit "$ref" --add-label "$label" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi

    emit_label_activity add "$kind" "$ref" "$label" "$reason" || true
    exit 0
}

main "$@"
