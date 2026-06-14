#!/bin/bash
# Create PR as bot account with safety checks
# Usage: pr-create [--title TITLE] [--body BODY | --body-file PATH] [--base BASE] [--head HEAD] [--draft] [--dry-run]
#
# Prefer --body-file for any PR body that may contain Markdown backticks,
# heredoc fences, or shell metacharacters. Passing such content via --body
# is unsafe when the caller built the value with an unquoted heredoc and the
# backticks command-substitute before reaching this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library for load_bot_token (also sets PROJECT_ROOT)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Create PR as bot account with safety checks

Usage: pr-create [options]

Options:
  --title TITLE    PR title (default: last commit message)
  --body BODY      PR body (inline; unsafe for Markdown with backticks)
  --body-file PATH PR body read from a file (preferred for any non-trivial body)
  --base BASE      Base branch (default: main)
  --head HEAD      Head branch (default: current branch)
  --label LABEL    Add label (repeatable: --label foo --label bar)
  --draft          Create as draft PR
  --force          Skip safety checks
  --dry-run        Show what would be created without creating

Safety Checks (run by default):
  1. Not creating PR from main/master branch
  2. Head branch has commits ahead of base
  3. Branch has been pushed to remote

The command uses GH_BOT_TOKEN from project config/secrets to create PRs as the bot account.
If token is not configured, falls back to current user's gh authentication.

Examples:
  # Inline body (only safe for simple, backtick-free strings)
  github.sh pr-create --title "feat: Add feature" --body "Simple summary line"

  # Body from file (safe for full Markdown with backticks/code fences)
  cat > tmp/pr-body.md <<'EOF'
  ## Summary
  - Added `WindowKind` enum.
  - Validation: \`cargo test\` + \`./tools/validate\`.
  EOF
  github.sh pr-create --title "feat: Add feature" --body-file tmp/pr-body.md

  github.sh pr-create --draft --label defer-ci  # Defer CI until ready
  github.sh pr-create --dry-run  # Preview without creating
EOF
}

# Run safety checks
run_safety_checks() {
    local head="$1"
    local base="$2"
    local all_passed=true

    echo "Running safety checks..." >&2

    # 1. Check not creating from main/master
    if [ "$head" = "main" ] || [ "$head" = "master" ]; then
        echo "  ✗ ERROR: Cannot create PR from $head branch" >&2
        echo "    Create a feature branch first: git checkout -b feature/my-feature" >&2
        all_passed=false
    else
        echo "  ✓ Head branch is not main/master" >&2
    fi

    # 2. Check branch has commits ahead
    local ahead
    ahead=$(git rev-list --count "$base..$head" 2>/dev/null || echo "0")
    if [ "$ahead" = "0" ]; then
        echo "  ✗ ERROR: No commits ahead of $base" >&2
        all_passed=false
    else
        echo "  ✓ $ahead commit(s) ahead of $base" >&2
    fi

    # 3. Check branch is pushed
    local remote_ref
    remote_ref=$(git ls-remote --heads origin "$head" 2>/dev/null | head -1)
    if [ -z "$remote_ref" ]; then
        echo "  ⚠ WARNING: Branch not pushed to origin" >&2
        echo "    Run: git push -u origin $head" >&2
        echo "    If GH_TOKEN/GITHUB_TOKEN is an unresolved op:// reference, run: env -u GH_TOKEN -u GITHUB_TOKEN git push -u origin $head" >&2
        # Don't fail - gh pr create can push
    else
        echo "  ✓ Branch exists on remote" >&2
    fi

    if [ "$all_passed" = true ]; then
        echo "All safety checks passed." >&2
        return 0
    else
        echo "Safety checks failed. Use --force to override." >&2
        return 1
    fi
}

main() {
    local title="" body="" body_file="" base="main" head="" draft=false dry_run=false force=false
    local body_set=false body_file_set=false
    local -a labels=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; body_set=true; shift 2 ;;
            --body-file) body_file="$2"; body_file_set=true; shift 2 ;;
            --base) base="$2"; shift 2 ;;
            --head) head="$2"; shift 2 ;;
            --label) labels+=("$2"); shift 2 ;;
            --draft) draft=true; shift ;;
            --force) force=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    # Track flag presence separately from value so empty arguments fail loudly
    # (`--body-file ""` must not be silently ignored).
    if [ "$body_set" = true ] && [ "$body_file_set" = true ]; then
        echo "Error: --body and --body-file are mutually exclusive. Pick one." >&2
        exit 1
    fi
    if [ "$body_file_set" = true ]; then
        if [ -z "$body_file" ]; then
            echo "Error: --body-file requires a non-empty path argument." >&2
            exit 1
        fi
        if [ ! -f "$body_file" ]; then
            echo "Error: --body-file path not found: $body_file" >&2
            exit 1
        fi
    fi

    # Default title to last commit message
    if [ -z "$title" ]; then
        title=$(git log -1 --format=%s)
    fi

    # Default head to current branch
    if [ -z "$head" ]; then
        head=$(git branch --show-current)
    fi

    # Run safety checks unless --force
    if [ "$force" = false ]; then
        if ! run_safety_checks "$head" "$base"; then
            exit 1
        fi
    else
        echo "⚠ WARNING: --force specified, skipping safety checks" >&2
    fi

    local token
    token=$(load_bot_token)

    if [ "$dry_run" = true ]; then
        local token_status="not configured (will use current user)"
        [ -n "$token" ] && token_status="configured"
        local body_preview="(none)"
        if [ "$body_file_set" = true ]; then
            body_preview="(from file: $body_file)"
        elif [ "$body_set" = true ]; then
            body_preview="$body"
        fi
        echo ""
        echo "Would create PR:"
        echo "  Title: $title"
        echo "  Body: $body_preview"
        echo "  Base: $base"
        echo "  Head: $head"
        echo "  Labels: ${labels[*]:-(none)}"
        echo "  Draft: $draft"
        echo "  Token: $token_status"
        exit 0
    fi

    # Build gh command. Prefer --body-file when supplied so callers can avoid
    # shell-interpolation hazards entirely (gh reads the file verbatim).
    local -a cmd=(gh pr create --title "$title" --base "$base" --head "$head")
    if [ "$body_file_set" = true ]; then
        cmd+=(--body-file "$body_file")
    elif [ "$body_set" = true ]; then
        cmd+=(--body "$body")
    fi
    for label in "${labels[@]}"; do cmd+=(--label "$label"); done
    [ "$draft" = true ] && cmd+=(--draft)

    # Execute with bot token if available
    if [ -n "$token" ]; then
        GH_TOKEN="$token" "${cmd[@]}"
    else
        echo "Warning: GH_BOT_TOKEN not configured, using current user" >&2
        "${cmd[@]}"
    fi
}

main "$@"
