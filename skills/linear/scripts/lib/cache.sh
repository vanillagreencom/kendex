#!/bin/bash
# Linear API Local Cache Library
# Source this file in command scripts that need cache access
# Cache location: .cache/linear/ (relative to project root)

set -euo pipefail

_CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

linear_cache_canonical_existing_dir() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    (cd "$path" && pwd -P)
}

linear_cache_project_root() {
    if [[ -n "${PROJECT_ROOT:-}" ]]; then
        linear_cache_canonical_existing_dir "$PROJECT_ROOT"
        return
    fi

    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)"
    linear_cache_canonical_existing_dir "$root"
}

CACHE_PROJECT_ROOT="$(linear_cache_project_root)"
CACHE_DIR="$CACHE_PROJECT_ROOT/.cache/linear"

# =============================================================================
# DIRECTORY & LIFECYCLE
# =============================================================================

cache_ensure_dir() {
    mkdir -p "$CACHE_DIR" "$CACHE_DIR/comments" "$CACHE_DIR/attachments/files"
}

cache_exists() {
    [[ -f "$CACHE_DIR/meta.json" ]]
}

cache_missing_error() {
    jq -cn \
        --arg cache_dir "$CACHE_DIR" \
        --arg meta_path "$CACHE_DIR/meta.json" \
        '{error: "No cache found. Run: linear.sh sync", cache_dir: $cache_dir, meta_path: $meta_path}' >&2
}

cache_is_fresh() {
    local max_age_minutes="${1:-60}"
    local meta="$CACHE_DIR/meta.json"
    [[ -f "$meta" ]] || return 1
    local last
    last=$(jq -r '.synced_at' "$meta")
    [[ -n "$last" && "$last" != "null" ]] || return 1
    local last_epoch
    last_epoch=$(date -d "$last" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S%z" "$last" +%s 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local age_minutes=$(( (now_epoch - last_epoch) / 60 ))
    (( age_minutes < max_age_minutes ))
}

cache_status() {
    if [[ ! -f "$CACHE_DIR/meta.json" ]]; then
        echo '{"cached": false}'
        return
    fi
    local meta
    meta=$(cat "$CACHE_DIR/meta.json")
    local synced_at
    synced_at=$(echo "$meta" | jq -r '.synced_at // "unknown"')
    local now_epoch
    now_epoch=$(date +%s)
    local last_epoch
    last_epoch=$(date -d "$synced_at" +%s 2>/dev/null || echo "$now_epoch")
    local age_minutes=$(( (now_epoch - last_epoch) / 60 ))

    jq -n \
        --argjson meta "$meta" \
        --argjson age "$age_minutes" \
        '$meta + {cached: true, age_minutes: $age}'
}

# =============================================================================
# SYNC LOCKING
# =============================================================================

cache_lock() {
    local lockfile="$CACHE_DIR/.sync.lock"
    cache_ensure_dir
    exec 200>"$lockfile"
    if ! flock -n 200; then
        echo "Sync in progress, waiting..." >&2
        if ! flock -w 30 200; then
            echo "Sync lock timeout after 30s" >&2
            return 1
        fi
        # Another process just finished syncing — check if cache is now fresh
        if cache_is_fresh 1; then
            echo "Cache fresh (synced by another process), skipped" >&2
            exec 200>&- || true
            return 2  # Signal: lock acquired but sync unnecessary
        fi
    fi
}

cache_unlock() {
    exec 200>&- || true
}

# =============================================================================
# READ OPERATIONS
# =============================================================================

cache_read() {
    local file="$1" filter="${2:-.}"
    local path="$CACHE_DIR/$file"
    [[ -f "$path" ]] || { echo "[]"; return; }
    jq "$filter" "$path" 2>/dev/null || echo "[]"
}

cache_read_issues() { cache_read "issues.json" "${1:-.}"; }
cache_read_projects() { cache_read "projects.json" "${1:-.}"; }
cache_read_cycles() { cache_read "cycles.json" "${1:-.}"; }
cache_read_initiatives() { cache_read "initiatives.json" "${1:-.}"; }
cache_read_labels() { cache_read "labels.json" "${1:-.}"; }

cache_get_issue() {
    local id="$1"
    jq --arg id "$id" '[.[] | select(.id == $id or .identifier == $id)] | first // empty' \
        "$CACHE_DIR/issues.json" 2>/dev/null
}

cache_get_children() {
    local parent="$1"
    jq --arg p "$parent" '[.[] | select(.parent.identifier == $p)]' \
        "$CACHE_DIR/issues.json" 2>/dev/null || echo "[]"
}

cache_get_children_recursive() {
    local parent="$1" max_depth="${2:-3}"
    # Returns flat array with depth field. Emits both `id` and `identifier`
    # so consumers reading either field (raw cache vs formatted output)
    # work consistently.
    jq --arg p "$parent" --argjson max "$max_depth" '
        . as $all |
        def descendants($pid; depth):
            if depth >= $max then [] else
                [$all[] | select(.parent.identifier == $pid)] |
                map(. as $c |
                    {
                        id: $c.identifier,
                        identifier: $c.identifier,
                        uuid: $c.id,
                        title: ($c.title // ""),
                        description: ($c.description // ""),
                        state: ($c.state.name // ""),
                        state_type: ($c.state.type // ""),
                        assignee: ($c.assignee.name // ""),
                        agent: ((([($c.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
                        labels: [($c.labels.nodes // [])[] | .name],
                        priority: ($c.priority // 0),
                        estimate: ($c.estimate // 0),
                        depth: depth,
                        parent_id: ($c.parent.identifier // ""),
                        blocks: [($c.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
                        blocked_by: [($c.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier]
                    }
                ) |
                . + (map(.id) | map(. as $cid | $all | descendants($cid; depth + 1)) | flatten)
            end;
        descendants($p; 0)
    ' "$CACHE_DIR/issues.json" 2>/dev/null || echo "[]"
}

cache_get_project() {
    local id="$1"
    jq --arg id "$id" '[.[] | select(.id == $id or .name == $id)] | first // empty' \
        "$CACHE_DIR/projects.json" 2>/dev/null
}

cache_get_comments() {
    local issue_id="$1"
    local comment_file="$CACHE_DIR/comments/$issue_id.json"
    if [[ -f "$comment_file" ]]; then
        cat "$comment_file"
    else
        echo "[]"
    fi
}

# =============================================================================
# MERGE (for incremental sync)
# =============================================================================

cache_merge() {
    local file="$1" delta_file="$2"
    local existing="$CACHE_DIR/$file"
    [[ -f "$existing" ]] || { cp "$delta_file" "$existing"; return; }

    # Validate existing file is a non-empty JSON array before merging
    local existing_count
    existing_count=$(jq 'if type == "array" then length else -1 end' "$existing" 2>/dev/null || echo -1)
    if (( existing_count < 0 )); then
        echo "cache_merge: $file is not a valid JSON array, replacing with delta" >&2
        cp "$delta_file" "$existing"
        return
    fi

    # Merge by .id — delta overwrites existing entries
    jq -s '(.[0] + .[1]) | group_by(.id) | map(.[-1])' \
        "$existing" "$delta_file" > "$existing.tmp"

    # Safety: verify merge didn't lose entries (result >= existing count unless reconciliation ran)
    local result_count
    result_count=$(jq 'length' "$existing.tmp" 2>/dev/null || echo 0)
    if (( result_count < existing_count )); then
        echo "cache_merge: result ($result_count) < existing ($existing_count), aborting merge" >&2
        rm -f "$existing.tmp"
        return 1
    fi

    mv "$existing.tmp" "$existing"
}

# =============================================================================
# WRITE-THROUGH (after API mutations)
# =============================================================================

cache_upsert_issue() {
    local issue_json="$1"
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0
    local id
    id=$(echo "$issue_json" | jq -r '.id')
    [[ -n "$id" && "$id" != "null" ]] || return 0
    (
        flock 201
        jq --argjson new "$issue_json" \
            '[.[] | select(.id != $new.id)] + [$new]' \
            "$cache_file" > "$cache_file.tmp"
        mv "$cache_file.tmp" "$cache_file"
    ) 201>"$cache_file.lock"
}

cache_touch_issue() {
    local issue_id="$1"
    local timestamp="$2"
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0
    [[ -n "$issue_id" && "$issue_id" != "null" ]] || return 0
    [[ -n "$timestamp" && "$timestamp" != "null" ]] || return 0
    (
        flock 201
        jq --arg id "$issue_id" --arg ts "$timestamp" \
            '[.[] | if (.id == $id or .identifier == $id) then .updatedAt = $ts else . end]' \
            "$cache_file" > "$cache_file.tmp"
        mv "$cache_file.tmp" "$cache_file"
    ) 201>"$cache_file.lock"
}

cache_patch_relation_snapshots() {
    local issue_json="$1"
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0

    local uuid state_name state_type title
    uuid=$(echo "$issue_json" | jq -r '.id')
    state_name=$(echo "$issue_json" | jq -r '.state.name // empty')
    state_type=$(echo "$issue_json" | jq -r '.state.type // empty')
    title=$(echo "$issue_json" | jq -r '.title // empty')
    [[ -n "$uuid" && "$uuid" != "null" ]] || return 0
    [[ -n "$state_name" ]] || return 0

    (
        flock 201
        jq --arg uid "$uuid" --arg sn "$state_name" --arg st "$state_type" --arg t "$title" '
        [.[] |
            .relations.nodes = [(.relations.nodes // [])[] |
                if .relatedIssue.id == $uid then
                    .relatedIssue.state = {name: $sn, type: $st} |
                    if $t != "" then .relatedIssue.title = $t else . end
                else . end
            ] |
            .inverseRelations.nodes = [(.inverseRelations.nodes // [])[] |
                if .issue.id == $uid then
                    .issue.state = {name: $sn, type: $st} |
                    if $t != "" then .issue.title = $t else . end
                else . end
            ]
        ]' "$cache_file" > "$cache_file.tmp"
        mv "$cache_file.tmp" "$cache_file"
    ) 201>"$cache_file.lock"
}

cache_upsert_project() {
    local project_json="$1"
    local cache_file="$CACHE_DIR/projects.json"
    [[ -f "$cache_file" ]] || return 0
    local id
    id=$(echo "$project_json" | jq -r '.id')
    [[ -n "$id" && "$id" != "null" ]] || return 0
    (
        flock 201
        # Merge: $old + $new preserves relations/inverseRelations from sync
        # when mutation response (which lacks them) overwrites base fields
        jq --argjson new "$project_json" \
            '([.[] | select(.id == $new.id)] | first // {}) as $old |
            ($old + $new) as $merged |
            [.[] | select(.id != $new.id)] + [$merged]' \
            "$cache_file" > "$cache_file.tmp"
        mv "$cache_file.tmp" "$cache_file"
    ) 201>"$cache_file.lock"
}

cache_remove_project() {
    local project_id="$1"
    local cache_file="$CACHE_DIR/projects.json"
    [[ -f "$cache_file" ]] || return 0
    (
        flock 201
        jq --arg id "$project_id" '[.[] | select(.id != $id)]' \
            "$cache_file" > "$cache_file.tmp"
        mv "$cache_file.tmp" "$cache_file"
    ) 201>"$cache_file.lock"
}

cache_remove_issue() {
    local issue_id="$1"
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0

    # Look up identifier before removal (for comment cleanup)
    local identifier
    identifier=$(jq -r --arg id "$issue_id" '
        [.[] | select(.id == $id or .identifier == $id)] | first | .identifier // empty
    ' "$cache_file" 2>/dev/null)

    (
        flock 201
        jq --arg id "$issue_id" '[.[] | select(.id != $id and .identifier != $id)]' \
            "$cache_file" > "$cache_file.tmp"
        mv "$cache_file.tmp" "$cache_file"
    ) 201>"$cache_file.lock"

    # Clean up comment file
    if [[ -n "$identifier" ]]; then
        rm -f "$CACHE_DIR/comments/$identifier.json" "$CACHE_DIR/comments/$identifier.json.lock"
    fi
}

cache_append_comment() {
    local issue_id="$1" comment_json="$2"
    local comment_file="$CACHE_DIR/comments/$issue_id.json"
    cache_ensure_dir
    (
        flock 202
        if [[ -f "$comment_file" ]]; then
            jq --argjson new "$comment_json" '. + [$new]' \
                "$comment_file" > "$comment_file.tmp"
        else
            echo "$comment_json" | jq '[ . ]' > "$comment_file.tmp"
        fi
        mv "$comment_file.tmp" "$comment_file"
    ) 202>"$comment_file.lock"
}

cache_update_comment() {
    local issue_id="$1" comment_json="$2"
    local comment_file="$CACHE_DIR/comments/$issue_id.json"
    [[ -f "$comment_file" ]] || return 0
    local comment_id
    comment_id=$(echo "$comment_json" | jq -r '.id')
    [[ -n "$comment_id" && "$comment_id" != "null" ]] || return 0
    (
        flock 202
        # Merge: existing comment fields preserved, updated fields overwritten
        jq --argjson upd "$comment_json" \
            '[.[] | if .id == $upd.id then (. + $upd) else . end]' \
            "$comment_file" > "$comment_file.tmp"
        mv "$comment_file.tmp" "$comment_file"
    ) 202>"$comment_file.lock"
}

cache_delete_comment() {
    local comment_id="$1"
    # Search comment files for the comment UUID and remove it
    for f in "$CACHE_DIR"/comments/*.json; do
        [[ -f "$f" ]] || continue
        if jq -e --arg id "$comment_id" 'any(.[]; .id == $id)' "$f" >/dev/null 2>&1; then
            (
                flock 202
                jq --arg id "$comment_id" '[.[] | select(.id != $id)]' "$f" > "$f.tmp"
                mv "$f.tmp" "$f"
            ) 202>"$f.lock"
            return 0
        fi
    done
}

cache_store_comments() {
    local issue_id="$1" comments_json="$2"
    cache_ensure_dir
    echo "$comments_json" > "$CACHE_DIR/comments/$issue_id.json"
}

cache_refresh_issues() {
    # Re-fetch specific issues by UUID and upsert into cache.
    # Used after relation mutations to get updated relations/inverseRelations.
    local uuids=("$@")
    [[ ${#uuids[@]} -gt 0 ]] || return 0
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0

    # Build id list for filter
    local id_list
    id_list=$(printf '%s\n' "${uuids[@]}" | jq -R . | jq -s .)

    local query="
    query RefreshIssues(\$filter: IssueFilter!, \$includeArchived: Boolean) {
        issues(filter: \$filter, first: 50, includeArchived: \$includeArchived) {
            nodes {
                id identifier title description
                state { name type }
                assignee { name }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                parent { id identifier title }
                labels { nodes { name } }
                priority estimate url
                createdAt updatedAt archivedAt trashed
                relations { nodes { id type relatedIssue { id identifier title state { name type } } } }
                inverseRelations { nodes { id type issue { id identifier title state { name type } } } }
            }
        }
    }"

    source "$_CACHE_LIB_DIR/common.sh" 2>/dev/null || true
    local result
    result=$(graphql_query "$query" "{\"filter\": {\"id\": {\"in\": $id_list}}, \"includeArchived\": true}")
    local nodes
    nodes=$(echo "$result" | jq '.issues.nodes // []')
    local count
    count=$(echo "$nodes" | jq 'length')
    for (( i=0; i<count; i++ )); do
        local issue
        issue=$(echo "$nodes" | jq ".[$i]")
        cache_upsert_issue "$issue"
    done
}
