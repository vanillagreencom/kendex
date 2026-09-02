#!/bin/bash
# Classify help before any project-controlled configuration is read.

linear_help_requested() {
    local arg="" skip_value=0

    case "${1:-}" in
    help | --help | -h) return 0 ;;
    esac

    # Skip values consumed by options so literal "--help" data keeps its
    # normal meaning.
    for arg in "$@"; do
        if [[ "$skip_value" == 1 ]]; then
            skip_value=0
            continue
        fi
        case "$arg" in
        --help | -h) return 0 ;;
        --after | --agent | --assignee | --attach | --before | --blocked-by | \
            --blocks | --body | --body-file | --by | --color | --content | \
            --created-since | --cycle | --description | --description-file | \
            --duplicate | --end | --estimate | --format | --health | --id | \
            --if-stale | --include | --include-children-of | --label | \
            --labels | --limit | --milestone | --name | --parent | --position | \
            --priority | --project | --project-id | --reason | --related | \
            --research-days | --search | --sort-order | --start | --state | \
            --status | --summary | --summary-file | --target-date | --team | \
            --title | --type | --updated-since) skip_value=1 ;;
        esac
    done
    return 1
}

linear_prepare_invocation() {
    LINEAR_HELP_ONLY=0
    if linear_help_requested "$@"; then
        LINEAR_HELP_ONLY=1
        PROJECT_ROOT="$(linear_canonical_existing_dir "$PWD")"
        return
    fi

    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)"
    PROJECT_ROOT="$(linear_canonical_existing_dir "$root")"
}

linear_load_invocation_env() {
    if [[ "$LINEAR_HELP_ONLY" == 0 ]]; then
        kendex_load_project_env "$PROJECT_ROOT"
    else
        # An unrecognized help position must fail before any inherited
        # credential can reach the API.
        unset LINEAR_API_KEY LINEAR_API_KEY_OVERRIDE
        _CALLER_LINEAR_API_KEY=""
    fi
    unset LINEAR_HELP_ONLY
}
