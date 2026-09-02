#!/bin/bash
# Classify help before any project-controlled configuration is read.

linear_help_requested() {
    local caller="$1" arg="" previous=""
    shift || true

    if [[ $# -eq 0 ]]; then
        case "$caller" in
        */commands/*) [[ "${LINEAR_EMPTY_RUNS:-0}" != 1 ]] ;;
        *) return 1 ;;
        esac
        return
    fi
    case "${1:-}" in help | --help | -h) return 0 ;; esac

    for arg in "$@"; do
        case "$arg" in
        --help | -h)
            case "$previous" in
            --*=*) return 0 ;;
            --*) previous=""; continue ;;
            *) return 0 ;;
            esac
            ;;
        esac
        previous="$arg"
    done
    return 1
}

linear_prepare_invocation() {
    local caller="$1"
    shift || true
    LINEAR_HELP_ONLY=0
    if linear_help_requested "$caller" "$@"; then
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
        unset LINEAR_API_KEY LINEAR_API_KEY_OVERRIDE
        _CALLER_LINEAR_API_KEY=""
    fi
    unset LINEAR_HELP_ONLY
}
