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

# LINEAR_CACHE_ROOT is the caller's redirect — the cache, and the attachment
# store beside it, live under the directory it names. It is read before
# anything derived from where the process is standing, so a caller that sets it
# cannot be overruled by the repository it happens to be in.
#
# PROJECT_ROOT is not that channel and cannot become one: common.sh assigns it
# from `git rev-parse` on every source, so a caller's value never survives to
# be read here. It also means something else — several orch scripts export it
# as "the repository the orchestrator is driving" — and reading that as a cache
# location would move a real cache underneath them.
#
# A set value naming no directory is refused, not ignored, and an empty string
# names no directory: falling back to the git root is exactly the failure the
# redirect exists to prevent.
linear_cache_project_root() {
    if [[ -n "${LINEAR_CACHE_ROOT+x}" ]]; then
        if ! linear_cache_canonical_existing_dir "$LINEAR_CACHE_ROOT"; then
            jq -cn --arg root "$LINEAR_CACHE_ROOT" \
                '{error: ("LINEAR_CACHE_ROOT is not an existing directory: " + $root)}' >&2
            return 1
        fi
        return 0
    fi

    if [[ -n "${PROJECT_ROOT:-}" ]]; then
        linear_cache_canonical_existing_dir "$PROJECT_ROOT"
        return
    fi

    # The assignment sits in the condition on purpose (KEN-1193): `git
    # rev-parse` exits 128 outside a repository, and under `set -e` a bare
    # assignment carries that status out of the function before this refusal
    # can print. Each branch above names its own cause, so this one does too.
    local root=""
    if ! root="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$root" ]]; then
        jq -cn --arg cwd "$PWD" \
            '{error: ("Could not resolve a cache root: LINEAR_CACHE_ROOT is unset and there is no git repository at: " + $cwd)}' >&2
        return 1
    fi
    linear_cache_canonical_existing_dir "$root"
}

# In the condition for the same reason (KEN-1193): a bare assignment carries
# the function's refusal out here, ending the script at that status with the
# cause on stderr but no exit of this script's own. Every branch above has
# already said why, so this one adds nothing.
if ! CACHE_PROJECT_ROOT="$(linear_cache_project_root)"; then
    exit 1
fi
CACHE_DIR="$CACHE_PROJECT_ROOT/.cache/linear"

# The three single-comment helpers below — cache_append_comment,
# cache_update_comment, cache_delete_comment — share this one lock instead of
# one named after each issue. A lock file cannot be removed once used, since
# unlinking it while another process holds it open lets a third lock a fresh
# inode and two writers then each hold "the" lock. So a per-issue lock left a
# permanent .lock beside every issue whose comments were ever written, hundreds
# of them. One lock file cannot accumulate, and comment writes are
# far too rare for serializing them across issues to cost anything.
#
# The bulk writers do NOT take it and never did: cache_store_comments and
# sync.sh's write_comments replace and delete these same files unlocked. A
# comment write is serialized against another comment write, not against a sync.
CACHE_COMMENTS_LOCK="$CACHE_DIR/.comments.lock"

# =============================================================================
# WORKTREE CLOBBER GUARD
# =============================================================================
# A git operation can re-materialize a WORKTREE_SYMLINKS-managed `.cache`
# symlink in a linked worktree as a real, near-empty directory. The resolved
# cache dir then looks exactly like a cold cache, and a full re-sync silently
# re-pulls the entire issue/comment history into the worktree-local dir —
# burning a large slice of the shared Linear API budget. These helpers detect
# that state so sync can fail closed instead.

# True when the resolved cache root is a linked worktree whose `.cache` is a
# real directory while the main checkout's `.cache` exists — the symlink
# convention is configured but broken here. When WORKTREE_SYMLINKS is set
# (loaded from project config by common.sh) and does NOT manage `.cache`, the
# repo has explicitly opted its worktrees into local caches and the guard
# stands down. Sets CACHE_WORKTREE_MAIN_ROOT for the refusal message.
CACHE_WORKTREE_MAIN_ROOT=""
cache_worktree_cache_clobbered() {
    local root="$CACHE_PROJECT_ROOT" common_dir="" main_root="" entry=""
    CACHE_WORKTREE_MAIN_ROOT=""
    [[ -n "$root" ]] || return 1
    # Healthy states exit fast: `.cache` missing (a cold checkout) or a
    # symlink (the convention is intact and writes reach the shared cache).
    [[ -d "$root/.cache" && ! -L "$root/.cache" ]] || return 1
    common_dir="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [[ -n "$common_dir" ]] || return 1
    [[ "$common_dir" == /* ]] || common_dir="$root/$common_dir"
    main_root="$(linear_cache_canonical_existing_dir "$(dirname "$common_dir")")" || return 1
    [[ "$main_root" != "$root" ]] || return 1
    [[ -e "$main_root/.cache" ]] || return 1
    if [[ -n "${WORKTREE_SYMLINKS:-}" ]]; then
        local manages_cache=false stripped=""
        for entry in ${WORKTREE_SYMLINKS}; do
            # The worktree config normalizer strips ANY number of trailing
            # slashes; match it, or ".cache//" would read as an opt-out.
            stripped="$entry"
            while [[ "$stripped" == */ ]]; do stripped="${stripped%/}"; done
            if [[ "$stripped" == ".cache" ]]; then
                manages_cache=true
                break
            fi
        done
        [[ "$manages_cache" == true ]] || return 1
    fi
    CACHE_WORKTREE_MAIN_ROOT="$main_root"
    return 0
}

cache_worktree_clobber_refusal() {
    {
        printf 'Sync-refused: worktree=%s cache=%s expected=%s\n' \
            "$CACHE_PROJECT_ROOT" "$CACHE_PROJECT_ROOT/.cache" "$CACHE_WORKTREE_MAIN_ROOT/.cache"
        echo "Sync refused: cache dir is a worktree-local real directory (kendex#1032)."
        echo "  Worktree:       $CACHE_PROJECT_ROOT"
        echo "  Cache dir here: $CACHE_PROJECT_ROOT/.cache (real directory)"
        echo "  Expected:       .cache -> $CACHE_WORKTREE_MAIN_ROOT/.cache (WORKTREE_SYMLINKS-managed symlink)"
        echo "  A git operation re-materialized the symlink. Syncing here would re-pull the full"
        echo "  Linear history into this worktree instead of the shared cache, silently burning"
        echo "  the shared API budget. Repair the link from the main checkout, then re-run sync:"
        echo "    cd '$CACHE_WORKTREE_MAIN_ROOT' && $(cache_worktree_repair_script) fix-links '$CACHE_PROJECT_ROOT'"
    } >&2
}

# The worktree script lives at .agents/skills/... in a consumer install and
# at skills/... in the source repo — point the repair guidance at whichever
# exists so it can be pasted as-is (consumer spelling when neither resolves).
cache_worktree_repair_script() {
    local rel=""
    for rel in ".agents/skills/worktree/scripts/worktree" "skills/worktree/scripts/worktree"; do
        if [[ -x "$CACHE_WORKTREE_MAIN_ROOT/$rel" ]]; then
            printf '%s\n' "$rel"
            return 0
        fi
    done
    printf '%s\n' ".agents/skills/worktree/scripts/worktree"
}

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
# The sync lock serializes one sync against another and nothing else. A
# write-through from another session runs during a sync, so the collection
# rewrites below take a lock of their own, one per file.

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

# The refusal for a cache file that is present but cannot be read as JSON.
# `path` names the file so a caller can tell this from a lookup that matched
# nothing, which carries no `path`. The repair is a full sync: a plain sync
# rewrites only what changed since the last one, so a corrupt comment file
# survives it, and a corrupt issues.json or projects.json makes the merge
# refuse with this error rather than merge over it. Only `sync --full`
# replaces the file whole.
cache_unreadable_error() {
    jq -cn --arg path "$1" \
        '{error: ("Cache file is not readable as JSON: " + $path + " — the cache is corrupt, not empty. Re-run: linear.sh sync --full"), path: $path}' >&2
}

# Read one cache file through jq.
# Usage: cache_jq_file <path> <default-when-absent> [jq args...] <filter>
# An absent file is a cold cache, and the default is the truthful answer for it —
# `cache_exists` / `cache_missing_error` gate the commands that need a warm one.
# A file that is present but unparseable is a corrupt cache: it fails loudly,
# because returning the same empty default would report a broken cache as "no
# results" and every caller downstream would treat that as a real answer.
cache_jq_file() {
    local path="$1" absent_default="$2"
    shift 2
    if [[ ! -f "$path" ]]; then
        printf '%s\n' "$absent_default"
        return 0
    fi
    local out
    if ! out=$(jq "$@" "$path"); then
        cache_unreadable_error "$path"
        return 1
    fi
    printf '%s\n' "$out"
}

cache_get_children_recursive() {
    local parent="$1" max_depth="${2:-3}"
    # Returns flat array with depth field. Emits both `id` and `identifier`
    # so consumers reading either field (raw cache vs formatted output)
    # work consistently.
    cache_jq_file "$CACHE_DIR/issues.json" "[]" --arg p "$parent" --argjson max "$max_depth" "$ISSUE_RELATION_JQ"'
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
                        blocks: issue_blocks_ids($c.relations.nodes),
                        blocked_by: issue_blocked_by_ids($c.inverseRelations.nodes),
                        blocked_by_open: issue_blocked_by_open_ids($c.inverseRelations.nodes)
                    }
                ) |
                . + (map(.id) | map(. as $cid | $all | descendants($cid; depth + 1)) | flatten)
            end;
        descendants($p; 0)
    '
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
# COLLECTION REWRITES
# =============================================================================
# Every writer of issues.json and projects.json rewrites the file through
# cache_write or cache_merge: the file's own lock (fd 201 on <file>.lock), a
# unique temp file beside the target, one rename into place. Two writers that
# shared one temp path (<file>.tmp) each opened it with O_TRUNC and wrote from
# offset zero, so the shorter output was followed by the longer one's tail,
# and whichever renamed first installed that as the cache: a JSON array with
# trailing bytes no reader parses. The sync lock never covered a write-through
# from another session, which is how a merge met an upsert on that path.

# cache_with_file_lock <path> <command...>: runs the command with <path>'s
# lock held. The command runs in a subshell, so the lock is released when it
# returns whatever its status. Never nest it: a second open of the lock file is
# a second open file description, and flock blocks it against the first.
cache_with_file_lock() {
    local path="$1"
    shift
    (
        if ! flock 201; then
            echo "cache: could not lock $path.lock" >&2
            exit 1
        fi
        "$@"
    ) 201>"$path.lock"
}

# cache_install_output <target> <command...>: replaces <target> with the
# command's stdout, written to a unique temp file beside it and renamed into
# place. The caller holds the file's lock. A failed command leaves the target
# untouched and returns its failure; a partial output never becomes the cache.
cache_install_output() {
    local target="$1"
    shift
    local tmp
    if ! tmp=$(mktemp "$target.XXXXXX"); then
        echo "cache: could not create a temp file beside $target" >&2
        return 1
    fi
    if ! "$@" > "$tmp"; then
        rm -f -- "${tmp:?}"
        return 1
    fi
    mv -f -- "$tmp" "$target"
}

# cache_write <file> <command...>: cache_install_output on $CACHE_DIR/<file>
# under that file's lock. The command reads the file itself; every
# write-through below is one jq rewrite through here.
cache_write() {
    local file="$1"
    shift
    cache_with_file_lock "$CACHE_DIR/$file" cache_install_output "$CACHE_DIR/$file" "$@"
}

# cache_array_length <path>: prints the element count of the one JSON array
# <path> holds. Fails, printing nothing, when the file does not parse, holds
# more than one document, or holds something other than an array. A parse
# error is not a count: a default in its place once read a corrupt file as
# the two lines "383" and "0" and let the rename that follows install it.
cache_array_length() {
    local len
    len=$(jq 'if type == "array" then length else empty end' "$1" 2>/dev/null) || return 1
    [[ "$len" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$len"
}

# =============================================================================
# MERGE (for incremental sync)
# =============================================================================

cache_merge() {
    local file="$1" delta_file="$2"
    cache_with_file_lock "$CACHE_DIR/$file" cache_merge_locked "$file" "$delta_file"
}

# The body of cache_merge, run with the file's lock held so the count it
# compares against is the count it merges over.
cache_merge_locked() {
    local file="$1" delta_file="$2"
    local existing="$CACHE_DIR/$file"

    # A malformed delta means the query failed or returned partial data —
    # never something to install or merge over a cache
    if ! cache_array_length "$delta_file" >/dev/null; then
        echo "cache_merge: delta for $file is not a valid JSON array, aborting merge" >&2
        return 1
    fi

    if [[ ! -f "$existing" ]]; then
        cache_install_output "$existing" cat "$delta_file"
        return
    fi

    # A cache that does not parse is corrupt, not empty: installing the delta
    # over it would report a delta's worth of issues as the whole set.
    local existing_count
    if ! existing_count=$(cache_array_length "$existing"); then
        cache_unreadable_error "$existing"
        return 1
    fi

    # Merge by .id — delta overwrites existing entries
    local merged
    if ! merged=$(mktemp "$existing.XXXXXX"); then
        echo "cache_merge: could not create a temp file beside $existing" >&2
        return 1
    fi
    if ! jq -s '(.[0] + .[1]) | group_by(.id) | map(.[-1])' \
        "$existing" "$delta_file" > "$merged"; then
        echo "cache_merge: merge of $file failed, aborting merge" >&2
        rm -f -- "${merged:?}"
        return 1
    fi

    # Safety: verify merge didn't lose entries (result >= existing count unless reconciliation ran)
    local result_count
    if ! result_count=$(cache_array_length "$merged"); then
        echo "cache_merge: merge result for $file is not a single JSON array, aborting merge" >&2
        rm -f -- "${merged:?}"
        return 1
    fi
    if (( result_count < existing_count )); then
        echo "cache_merge: result ($result_count) < existing ($existing_count), which usually means the query returned an incomplete or empty result (transient API failure), aborting merge" >&2
        rm -f -- "${merged:?}"
        return 1
    fi

    mv -f -- "$merged" "$existing"
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
    cache_write "issues.json" jq --argjson new "$issue_json" \
        '[.[] | select(.id != $new.id)] + [$new]' \
        "$cache_file"
}

cache_touch_issue() {
    local issue_id="$1"
    local timestamp="$2"
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0
    [[ -n "$issue_id" && "$issue_id" != "null" ]] || return 0
    [[ -n "$timestamp" && "$timestamp" != "null" ]] || return 0
    cache_write "issues.json" jq --arg id "$issue_id" --arg ts "$timestamp" \
        '[.[] | if (.id == $id or .identifier == $id) then .updatedAt = $ts else . end]' \
        "$cache_file"
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

    cache_write "issues.json" jq --arg uid "$uuid" --arg sn "$state_name" --arg st "$state_type" --arg t "$title" '
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
        ]' "$cache_file"
}

cache_upsert_project() {
    local project_json="$1"
    local cache_file="$CACHE_DIR/projects.json"
    [[ -f "$cache_file" ]] || return 0
    local id
    id=$(echo "$project_json" | jq -r '.id')
    [[ -n "$id" && "$id" != "null" ]] || return 0
    # Merge inputs while preserving relations and inverseRelations from sync
    # when mutation response (which lacks them) overwrites base fields
    cache_write "projects.json" jq --argjson new "$project_json" \
        '([.[] | select(.id == $new.id)] | first // {}) as $old |
        ($old + $new) as $merged |
        [.[] | select(.id != $new.id)] + [$merged]' \
        "$cache_file"
}

cache_remove_project() {
    local project_id="$1"
    local cache_file="$CACHE_DIR/projects.json"
    [[ -f "$cache_file" ]] || return 0
    cache_write "projects.json" jq --arg id "$project_id" '[.[] | select(.id != $id)]' \
        "$cache_file"
}

cache_remove_issue() {
    local issue_id="$1"
    local cache_file="$CACHE_DIR/issues.json"
    [[ -f "$cache_file" ]] || return 0

    # Look up identifier before removal (for comment cleanup)
    local identifier
    identifier=$(cache_jq_file "$cache_file" "" -r --arg id "$issue_id" '
        [.[] | select(.id == $id or .identifier == $id)] | first | .identifier // empty
    ')

    cache_write "issues.json" jq --arg id "$issue_id" '[.[] | select(.id != $id and .identifier != $id)]' \
        "$cache_file"

    # Clean up comment file
    if [[ -n "$identifier" ]]; then
        rm -f "$CACHE_DIR/comments/$identifier.json"
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
    ) 202>"$CACHE_COMMENTS_LOCK"
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
    ) 202>"$CACHE_COMMENTS_LOCK"
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
            ) 202>"$CACHE_COMMENTS_LOCK"
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
                team { name }
                labels { nodes { name } }
                priority estimate url
                createdAt updatedAt archivedAt trashed
$ISSUE_RELATION_FIELDS
            }
        }
    }"

    # Command scripts have already sourced common.sh; re-sourcing it would
    # re-run the API-key precedence block against an environment it has itself
    # rewritten. Load it only when the wire helper is genuinely absent, and let
    # a failure there abort — a swallowed source leaves graphql_query undefined.
    if ! declare -F graphql_query >/dev/null; then
        # shellcheck source=common.sh
        source "$_CACHE_LIB_DIR/common.sh"
    fi
    local vars result
    vars=$(jq -cn --argjson ids "$id_list" '{filter: {id: {in: $ids}}, includeArchived: true}')
    result=$(graphql_query "$query" "$vars")
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
