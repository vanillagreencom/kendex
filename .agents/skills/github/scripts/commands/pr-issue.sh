#!/bin/bash
# Extract issue ID from PR branch name
# Usage: pr-issue <PR_NUMBER>

set -euo pipefail

show_help() {
    cat << 'EOF'
Extract issue ID from PR branch name

Usage: pr-issue <PR_NUMBER> [--format=safe|text]

Extracts issue ID from a PR's head branch name using a configurable pattern.
Returns empty string if no issue ID found.

Environment:
  GH_ISSUE_PATTERN   Regex for issue ID extraction (default: '[A-Z]+-[0-9]+')

Options:
  --format=safe   JSON output (default): {"issue": "ABC-150", "branch": "..."}
  --format=text   Plain text output: ABC-150
  --json          Alias for --format=safe (deprecated)

Examples:
  github.sh pr-issue 42               # JSON: {"issue": "ABC-150", "branch": "..."}
  github.sh pr-issue 42 --format=text # Plain: ABC-150

Branch patterns matched (default pattern):
  user/abc-150          → ABC-150
  user/abc-150/feature  → ABC-150
  abc-150-description   → ABC-150
EOF
}

main() {
    local pr_num="" format="safe"

    while [ $# -gt 0 ]; do
        case "$1" in
            --format=*) format="${1#--format=}"; shift ;;
            --json) format="safe"; shift ;;  # Deprecated alias
            --help|-h) show_help; exit 0 ;;
            [0-9]*) pr_num="$1"; shift ;;
            *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    if [ -z "$pr_num" ]; then
        echo "Error: PR number required" >&2
        exit 1
    fi

    # Get branch name from PR
    local branch
    branch=$(gh pr view "$pr_num" --json headRefName --jq '.headRefName' 2>/dev/null) || {
        echo "Error: PR #$pr_num not found" >&2
        exit 1
    }

    # Extract issue ID (case-insensitive match, normalize to uppercase)
    local pattern="${GH_ISSUE_PATTERN:-[A-Z]+-[0-9]+}"
    local issue=""
    issue=$(echo "$branch" | grep -oEi "$pattern" | head -1 | tr '[:lower:]' '[:upper:]') || true

    case "$format" in
        safe|json)
            jq -n --arg issue "$issue" --arg branch "$branch" '{issue: $issue, branch: $branch}'
            ;;
        text)
            echo "$issue"
            ;;
        *)
            echo "Error: Unknown format: $format. Use: safe, text" >&2
            exit 1
            ;;
    esac
}

main "$@"
