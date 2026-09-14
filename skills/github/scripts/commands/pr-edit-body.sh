#!/usr/bin/env bash
# Update a pull request body via sanitized github.sh routing.

set -euo pipefail

show_help() {
    cat <<'EOF'
Update PR body.

Usage: pr-edit-body <PR-number> --body-file PATH

Arguments:
  PR-number    Pull request number.

Options:
  --body-file PATH  Read body from a file.
  --help, -h        Show this help.
EOF
}

# Refuse a two-argument flag whose operand is absent, before the shift that
# consumes it: under set -e a short `shift 2` ends the script with no
# diagnostic. Arity only, so an empty operand still reaches its own refusal.
require_operand() {
    [ "$2" -ge 2 ] || { echo "pr-edit-body: $1 is required" >&2; exit 2; }
}

main() {
    local pr_num="" body_file=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --body-file)
                require_operand "$1" "$#"
                body_file="$2"
                shift 2
                ;;
            --body-file=*)
                body_file="${1#--body-file=}"
                shift
                ;;
            -*)
                echo "pr-edit-body: unknown flag: $1" >&2
                exit 2
                ;;
            *)
                if [ -z "$pr_num" ]; then
                    pr_num="$1"
                else
                    echo "pr-edit-body: unexpected positional: $1" >&2
                    exit 2
                fi
                shift
                ;;
        esac
    done

    if [ -z "$pr_num" ]; then
        echo "pr-edit-body: <PR-number> is required" >&2
        show_help >&2
        exit 2
    fi
    if [ -z "$body_file" ]; then
        echo "pr-edit-body: --body-file is required" >&2
        show_help >&2
        exit 2
    fi
    if [ ! -r "$body_file" ]; then
        echo "pr-edit-body: --body-file path not readable: $body_file" >&2
        exit 1
    fi

    gh pr edit "$pr_num" --body-file "$body_file"
}

main "$@"
