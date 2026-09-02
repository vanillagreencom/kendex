#!/bin/bash
# Runtime initialization deferred until command dispatch has ruled out help.

linear_init() {
    [[ "$LINEAR_INITIALIZED" == 1 ]] && return 0

    local project_root_raw
    project_root_raw="$(git rev-parse --show-toplevel 2>/dev/null)"
    PROJECT_ROOT="$(linear_canonical_existing_dir "$project_root_raw")"

    _CALLER_LINEAR_API_KEY="${LINEAR_API_KEY:-}"
    unset LINEAR_API_KEY
    _CALLER_LINEAR_TEAM_SET="${LINEAR_TEAM+x}"
    _CALLER_LINEAR_TEAM="${LINEAR_TEAM:-}"

    kendex_load_project_env "$PROJECT_ROOT"

    _PROJECT_LINEAR_API_KEY="${LINEAR_API_KEY:-}"
    if [[ -n "${LINEAR_API_KEY_OVERRIDE:-}" ]]; then
        LINEAR_API_KEY="$LINEAR_API_KEY_OVERRIDE"
        export LINEAR_API_KEY
        LINEAR_API_KEY_SOURCE="override"
    elif [[ -n "$_PROJECT_LINEAR_API_KEY" ]]; then
        LINEAR_API_KEY_SOURCE="project-config"
    elif [[ -n "$_CALLER_LINEAR_API_KEY" ]]; then
        LINEAR_API_KEY="$_CALLER_LINEAR_API_KEY"
        export LINEAR_API_KEY
        LINEAR_API_KEY_SOURCE="environment"
    else
        LINEAR_API_KEY_SOURCE="unset"
    fi

    LINEAR_API_KEY_ENV_SHADOWED=0
    LINEAR_API_KEY_ENV_FINGERPRINT=""
    LINEAR_API_KEY_PROJECT_FINGERPRINT=""
    if [[ "$LINEAR_API_KEY_SOURCE" == "project-config" && -n "$_CALLER_LINEAR_API_KEY" &&
        "$_CALLER_LINEAR_API_KEY" != "$_PROJECT_LINEAR_API_KEY" ]]; then
        LINEAR_API_KEY_ENV_SHADOWED=1
        LINEAR_API_KEY_ENV_FINGERPRINT="$(linear_key_fingerprint "$_CALLER_LINEAR_API_KEY")"
        LINEAR_API_KEY_PROJECT_FINGERPRINT="$(linear_key_fingerprint "$_PROJECT_LINEAR_API_KEY")"
    fi

    if [[ -n "$_CALLER_LINEAR_TEAM" ]]; then
        LINEAR_TEAM_SOURCE="environment"
    elif [[ -n "${LINEAR_TEAM:-}" ]]; then
        LINEAR_TEAM_SOURCE="project-config"
    else
        LINEAR_TEAM_SOURCE="unset"
    fi

    if [[ -n "$_CALLER_LINEAR_TEAM_SET" && -z "$_CALLER_LINEAR_TEAM" ]]; then
        LINEAR_TEAM_ENV_BLANK=1
    else
        LINEAR_TEAM_ENV_BLANK=0
    fi

    unset _CALLER_LINEAR_API_KEY _PROJECT_LINEAR_API_KEY _CALLER_LINEAR_TEAM _CALLER_LINEAR_TEAM_SET

    DEFAULT_TEAM="${LINEAR_TEAM:-}"
    DEFAULT_FORMAT="${LINEAR_FORMAT:-safe}"
    DEFAULT_PREFIX="${LINEAR_TEAM_PREFIX:-PROJ}"
    LINEAR_TEAM_TARGET="$DEFAULT_TEAM"

    if [[ "$LINEAR_RESOLVE_API_KEY" == 1 ]]; then
        resolve_linear_api_key || return 1
    fi
    LINEAR_INITIALIZED=1
}

linear_cache_init() {
    [[ -n "$CACHE_DIR" ]] && return 0
    linear_init
    CACHE_PROJECT_ROOT="$(linear_cache_project_root)"
    CACHE_DIR="$CACHE_PROJECT_ROOT/.cache/linear"
}

linear_attachments_init() {
    [[ -n "$ATTACH_DIR" ]] && return 0
    linear_cache_init
    ATTACH_CACHE_PROJECT_ROOT="$(linear_attach_project_root)"
    ATTACH_DIR="$ATTACH_CACHE_PROJECT_ROOT/.cache/linear/attachments"
    ATTACH_FILES_DIR="$ATTACH_DIR/files"
    ATTACH_MANIFEST="$ATTACH_DIR/manifest.json"
}
