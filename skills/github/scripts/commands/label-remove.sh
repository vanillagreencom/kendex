#!/usr/bin/env bash
# GitHub label remove wrapper.
# Runs `gh pr edit --remove-label` or `gh issue edit --remove-label`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gh-auth.sh
source "$SCRIPT_DIR/../lib/gh-auth.sh"

show_help() {
    cat <<'EOF'
Remove a label from a PR or issue.

Usage: label-remove.sh <pr-or-issue-ref> <label> [--issue]

Arguments:
  pr-or-issue-ref   PR number, branch ref, or issue number. Empty
                    string defers to gh's current-branch resolution.
  label             Label name to remove (single label per call).

Options:
  --issue           Treat the ref as an issue (default: PR).
  --pr              Treat the ref as a PR (default).
  --help, -h        Show this help.

Configuration:
  Direct execution loads the current project's kendex.settings.toml,
  .kendex/settings.toml, and .env.local before selecting auth. Parent-process
  values keep precedence.

Examples:
  label-remove.sh 44 needs-qa
  label-remove.sh 123 needs-triage --issue
EOF
}

main() {
    local ref="" label="" kind="pr"
    local positional=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
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
    kendex_github_load_project_env_preserving_caller "$project_root"
    kendex_github_apply_selected_auth_token router || true
    kendex_github_sanitize_gh_env

    local rc=0
    if [ "$kind" = "issue" ]; then
        gh issue edit "$ref" --remove-label "$label" || rc=$?
    else
        gh pr edit "$ref" --remove-label "$label" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi

    exit 0
}

main "$@"
