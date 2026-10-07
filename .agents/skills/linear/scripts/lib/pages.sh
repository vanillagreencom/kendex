#!/bin/bash
# Cursor traversal for Linear's Relay connections. Requires common.sh.
set -euo pipefail

# Read the requested connection to its end, or to a caller's total row limit.
# Every page must carry pageInfo. A row limit can leave the chain open, and
# the result's pageInfo.hasNextPage then says rows were left unread.
# Output follows successful traversal to the end or limit. Failures leave stdout empty.
# Rows and cursors go to files under a spool the subshell removes on exit, so
# no shell variable outgrows one page: bash copies a value per here-string,
# and a --max read held the whole backlog several times over.
graphql_pages() (
    local query="$1" variables="$2" path="$3" limit="${4:-0}" initial="${5:-}"
    local result nodes spool cursor='null' next count=0 key collected=0 rows state row
    local complete='all(.. | objects | select(has("nodes") or has("pageInfo"));
        (.nodes | type == "array") and (.pageInfo | type == "object") and
        (.pageInfo.hasNextPage | type == "boolean")) and
        (any(.. | objects | select(has("nodes")); .pageInfo.hasNextPage) | not)'
    key=$(jq -cn --arg path "$path" '$path | split(".")') || return 1
    spool=$(mktemp -d) || return 1
    trap 'rm -rf -- "${spool:?}"' EXIT
    : >"$spool/nodes" && : >"$spool/seen" || return 1
    while true; do
        if [[ -n "$initial" ]]; then
            result="$initial"
            initial=''
        else
            variables=$(jq -cs '.[0] + {after: .[1]}' <<<"$variables"$'\n'"$cursor") || return 1
            result=$(graphql_request "$query" "$variables") || return 1
        fi
        if ! nodes=$(jq -ce --argjson key "$key" '
            getpath($key) | select(.nodes | type == "array") |
            select(.pageInfo.hasNextPage | type == "boolean") | .nodes' <<<"$result"); then
            printf 'linear-pages: incomplete=%s\n' "$path" >&2
            return 1
        fi
        printf '%s\n' "$nodes" >>"$spool/nodes" || return 1
        count=$((count + 1))
        if (( limit > 0 )); then
            rows=$(jq 'length' <<<"$nodes") || return 1
            collected=$((collected + rows))
        fi
        next=$(jq -r --argjson key "$key" 'getpath($key).pageInfo.hasNextPage' <<<"$result") || return 1
        if [[ "$next" == false ]]; then break; fi
        if (( limit > 0 && collected >= limit )); then break; fi
        cursor=$(jq -ce --argjson key "$key" 'getpath($key).pageInfo.endCursor | strings | select(length > 0)' <<<"$result") || {
            printf 'linear-pages: missing-cursor=%s\n' "$path" >&2
            return 1
        }
        next=$(jq -rs --argjson cursor "$cursor" 'index($cursor) != null' "$spool/seen") || return 1
        if [[ "$next" == true ]]; then
            printf 'linear-pages: repeated-cursor=%s\n' "$path" >&2
            return 1
        fi
        printf '%s\n' "$cursor" >>"$spool/seen" || return 1
        # Linear can keep a connection open under concurrent edits. Bound that
        # work without treating a partial result as a complete inventory.
        if (( count >= 400 )); then
            printf 'linear-pages: page-cap=%s\n' "$path" >&2
            return 1
        fi
    done
    printf '%s\n' "$result" >"$spool/last" || return 1
    jq -cn --argjson key "$key" --argjson limit "$limit" '
        input as $result | [inputs[]] as $nodes | $result |
        if $limit > 0 and ($nodes | length) > $limit then
            setpath($key + ["pageInfo", "hasNextPage"]; true) |
            setpath($key + ["nodes"]; $nodes[:$limit])
        else setpath($key + ["nodes"]; $nodes) end' "$spool/last" "$spool/nodes" >"$spool/result" || return 1
    # A result whose collections are all well formed and closed is one
    # linear_complete_result would print unchanged, so it never enters a variable.
    if jq -e "$complete" "$spool/result" >/dev/null; then
        cat -- "$spool/result"
        return
    fi
    # A nested continuation is one entity's collection and completes whole.
    if [[ "$path" == *.* ]] || ! jq -e --arg path "$path" 'keys == [$path]' "$spool/result" >/dev/null; then
        result=$(cat -- "$spool/result") || return 1
        linear_complete_result "$result"
        return
    fi
    # A root collection completes one row at a time, so a backlog with one open
    # row never enters a variable either.
    jq -r --arg path "$path" ".[\$path].nodes[] |
        (if $complete then \"closed\" else \"open\" end) + \"\\t\" + tojson" "$spool/result" >"$spool/split" || return 1
    : >"$spool/rows" || return 1
    while IFS=$'\t' read -r state row; do
        if [[ "$state" == open ]]; then
            row=$(jq -c --arg path "$path" '{($path): {nodes: [.], pageInfo: {hasNextPage: false, endCursor: null}}}' <<<"$row") || return 1
            row=$(linear_complete_result "$row") || return 1
            row=$(jq -c --arg path "$path" '.[$path].nodes[0]' <<<"$row") || return 1
        fi
        printf '%s\n' "$row" >>"$spool/rows" || return 1
    done <"$spool/split"
    jq -cn --arg path "$path" 'input as $result | [inputs] as $rows | $result | .[$path].nodes = $rows' \
        "$spool/result" "$spool/rows" >"$spool/completed" || return 1
    cat -- "$spool/completed"
)

# List bounds, one owner for every list verb: the default row bound, --limit,
# --max and --first, the page size, and the notice a bounded read prints when
# rows were left unread. A verb calls linear_list_reset before its parse, hands
# its bound options to linear_list_option from its own shell (a command
# substitution would lose the bound), and reads through linear_list_read.
LINEAR_LIST_DEFAULT=75
LINEAR_LIST_BOUND=$LINEAR_LIST_DEFAULT

linear_list_reset() {
    LINEAR_LIST_BOUND=$LINEAR_LIST_DEFAULT
}

# The bound is one value: a row count, `all` (--max) or `first` (--first, one
# row the caller asked for alone, so no notice says more rows exist). --limit
# takes digits only, so no value a caller passes can spell a word.
# Usage: linear_list_option --limit N | --max | --first
linear_list_option() {
    case "$1" in
    --max) LINEAR_LIST_BOUND=all ;;
    --first) LINEAR_LIST_BOUND=first ;;
    --limit)
        linear_require_pattern --limit "${2:-}" '^[1-9][0-9]{0,8}$' "a positive whole number" || return 1
        LINEAR_LIST_BOUND="$2"
        ;;
    *)
        printf 'linear-list: unknown-option=%s\n' "$1" >&2
        return 1
        ;;
    esac
}

# The page size a list query asks its root connection for when its verb names
# none, read from the query itself. Linear refuses a query whose complexity
# passes 10,000. A row that selects no connection costs a few points, so it
# takes Linear's largest page, 250. A row that selects one can cost over a
# hundred (measured per row: teams 123, initiatives 131, projects 54, so 250
# rows of teams cost 30,675), so it takes Linear's default page, 50. Every
# connection carries pageInfo (lib/pages.sh completes an open one), so a query
# naming pageInfo more than once has rows that select a connection.
# Usage: page=$(linear_list_page_size QUERY)
linear_list_page_size() {
    local rest="${1#*pageInfo}"
    if [[ "$rest" == *pageInfo* ]]; then
        printf '50'
    else
        printf '250'
    fi
}

# Read the root connection at PATH to the verb's bound. VARIABLES carries no
# `first`; the page size is set here: PAGE when the verb names one, a size
# measured for its own query, else linear_list_page_size's. Linear does not
# price every connection by its rows: issues measured 506 points at any page.
# Usage: linear_list_read QUERY VARIABLES PATH [PAGE]
linear_list_read() {
    local query="$1" variables="$2" path="$3" page="${4:-}" first limit result open
    if [[ -z "$page" ]]; then
        page=$(linear_list_page_size "$query") || return 1
    fi
    case "$LINEAR_LIST_BOUND" in
    all) first=$page limit=0 ;;
    first) first=1 limit=1 ;;
    *) first=$((LINEAR_LIST_BOUND < page ? LINEAR_LIST_BOUND : page)) limit=$LINEAR_LIST_BOUND ;;
    esac
    variables=$(jq -c --argjson first "$first" '. + {first: $first}' <<<"$variables") || return 1
    result=$(graphql_pages "$query" "$variables" "$path" "$limit") || return 1
    if [[ "$LINEAR_LIST_BOUND" != all && "$LINEAR_LIST_BOUND" != first ]]; then
        open=$(jq -r --arg path "$path" 'getpath($path | split(".")).pageInfo.hasNextPage' <<<"$result") || return 1
        if [[ "$open" == true ]]; then
            printf 'linear-list: truncated path=%s limit=%s\nMore rows match than --limit %s returns; pass --max to read them all.\n' \
                "$path" "$limit" "$limit" >&2
        fi
    fi
    printf '%s\n' "$result"
}

# The fields are the existing command contracts, shared by their continuation
# queries. A nested read only runs when Linear leaves that connection open.
linear_connection_fields() {
    case "$1:$2" in
    issue:labels|project:labels|project:teams|user:teams|viewer:teams) printf '%s' 'name' ;;
    issue:relations) printf '%s' "$ISSUE_BLOCKS_NODE_FIELDS" ;;
    issue:inverseRelations) printf '%s' "$ISSUE_BLOCKED_BY_NODE_FIELDS" ;;
    issue:children) linear_children_fields "${LINEAR_CHILD_DEPTH:-1}" ;;
    issue:comments) printf '%s' 'id body createdAt updatedAt user { name }' ;;
    issue:attachments) printf '%s' 'id url title' ;;
    project:relations) printf '%s' 'id type anchorType relatedAnchorType relatedProject { id name state progress }' ;;
    project:inverseRelations) printf '%s' 'id type anchorType relatedAnchorType project { id name state progress }' ;;
    project:projectUpdates) printf '%s' 'id body health createdAt user { name }' ;;
    initiative:projects)
        if [[ "${LINEAR_INITIATIVE_PROJECT_MODE:-list}" == get ]]; then printf '%s' 'id name state progress health'
        else printf '%s' 'id name state'; fi ;;
    team:members) printf '%s' 'name email' ;;
    team:labels) printf '%s' 'name color' ;;
    team:states) printf '%s' 'name type position' ;;
    organization:teams) printf '%s' 'key' ;;
    projectMilestone:issues) printf '%s' 'id identifier title state { name }' ;;
    *) printf 'linear-pages: unknown-connection=%s:%s\n' "$1" "$2" >&2; return 1 ;;
    esac
}

# Match the existing issue read's child fields and its requested depth.
linear_children_fields() {
    local depth="$1" fields descendants
    case "${LINEAR_ISSUE_CHILD_MODE:-brief}" in
    brief) fields='id identifier title state { name }' ;;
    direct) fields='id identifier title state { name type } assignee { name } priority estimate createdAt' ;;
    bundle|recursive)
        fields="id identifier title state { name type } assignee { name } labels(first: 10) { pageInfo { hasNextPage endCursor } nodes { name } } priority estimate parent { identifier } $ISSUE_RELATION_FIELDS"
        if [[ "$LINEAR_ISSUE_CHILD_MODE" == bundle ]]; then fields="description $fields"; fi
        if (( depth > 1 )); then
            descendants=$(linear_children_fields "$((depth - 1))") || return 1
            fields="$fields children(first: 1) { pageInfo { hasNextPage endCursor } nodes { $descendants } }"
        fi
        ;;
    *) printf 'linear-pages: unknown-child-mode=%s\n' "$LINEAR_ISSUE_CHILD_MODE" >&2; return 1 ;;
    esac
    printf '%s' "$fields"
}

# Complete one entity's requested collections; absent fields are not requested.
linear_complete_entity() {
    local type="$1" data="$2" fields field id query variables result connection names rows row children next
    local LINEAR_CHILD_DEPTH="${3:-${LINEAR_CHILD_DEPTH:-1}}"
    if ! jq -e 'type == "object" and all(.. | objects | select(has("nodes") or has("pageInfo"));
        (.nodes | type == "array") and (.pageInfo | type == "object") and
        (.pageInfo.hasNextPage | type == "boolean"))' <<<"$data" >/dev/null; then
        printf 'linear-pages: incomplete=%s\n' "$type" >&2
        return 1
    fi
    next=$(jq -r 'any(.. | objects | select(has("nodes")); .pageInfo.hasNextPage)' <<<"$data") || return 1
    if [[ "$next" == false ]]; then
        printf '%s\n' "$data"
        return 0
    fi
    names=$(jq -r 'to_entries[] | select(.value | type == "object" and has("nodes")) | .key' <<<"$data") || return 1
    while IFS= read -r field; do
        [[ -n "$field" ]] || continue
        next=$(jq -r --arg field "$field" '.[$field].pageInfo.hasNextPage' <<<"$data") || return 1
        if [[ "$next" == true ]]; then
            fields=$(linear_connection_fields "$type" "$field") || return 1
            if [[ "$type" == viewer || "$type" == organization ]]; then
                query="query ContinueConnection(\$after: String) { $type { $field(first: 50, after: \$after) { pageInfo { hasNextPage endCursor } nodes { $fields } } } }"
                variables='{}'
            else
                id=$(jq -ce '(.id // ._linearOwnerId) | strings | select(length > 0)' <<<"$data") || return 1
                query="query ContinueConnection(\$id: String!, \$after: String) { $type(id: \$id) { id $field(first: 50, after: \$after) { pageInfo { hasNextPage endCursor } nodes { $fields } } } }"
                variables=$(jq -c '{id: .}' <<<"$id") || return 1
            fi
            result=$(jq -c --arg type "$type" '{($type): .}' <<<"$data") || return 1
            result=$(graphql_pages "$query" "$variables" "$type.$field" 0 "$result") || return 1
            connection=$(jq -c --arg type "$type" --arg field "$field" '.[$type][$field]' <<<"$result") || return 1
            data=$(jq -cs --arg field "$field" '.[1] as $connection | .[0] | .[$field] = $connection' <<<"$data"$'\n'"$connection") || return 1
        fi
        # Bundle queries request descendants at each level. Complete the levels
        # already present, without expanding a caller's requested depth.
        if [[ "$type:$field" == issue:children ]]; then
            rows=$(jq -c '.children.nodes[]' <<<"$data") || return 1
            children='[]'
            while IFS= read -r row; do
                [[ -n "$row" ]] || continue
                row=$(linear_complete_entity issue "$row" "$((LINEAR_CHILD_DEPTH - 1))") || return 1
                children=$(jq -cs '.[0] + [.[1]]' <<<"$children"$'\n'"$row") || return 1
            done <<<"$rows"
            data=$(jq -cs '.[1] as $children | .[0] | .children.nodes = $children' <<<"$data"$'\n'"$children") || return 1
        fi
    done <<<"$names"
    printf '%s\n' "$data"
}

# Finish nested collections on the existing helper's read and mutation replies.
linear_complete_result() {
    local data="$1" root type rows row all value roots kind open
    jq -e 'type == "object"' <<<"$data" >/dev/null || return 1
    roots=$(jq -r 'keys[]' <<<"$data") || return 1
    while IFS= read -r root; do
        case "$root" in
        issue|project|initiative|team|user|viewer|organization|projectMilestone) type="$root" ;;
        issues) type=issue ;;
        projects) type=project ;;
        initiatives) type=initiative ;;
        teams) type=team ;;
        users) type=user ;;
        projectMilestones) type=projectMilestone ;;
        *Create|*Update)
            value=$(jq -c --arg root "$root" '.[$root]' <<<"$data") || return 1
            if [[ "$value" != null ]]; then
                value=$(linear_complete_result "$value") || return 1
                data=$(jq -cs --arg root "$root" '.[1] as $value | .[0] | .[$root] = $value' <<<"$data"$'\n'"$value") || return 1
            fi
            continue ;;
        *) continue ;;
        esac
        value=$(jq -c --arg root "$root" '.[$root]' <<<"$data") || return 1
        [[ "$value" != null ]] || continue
        value=$(linear_complete_entity "$type" "$value") || return 1
        kind=$(jq -r 'has("nodes")' <<<"$value") || return 1
        if [[ "$kind" == true ]]; then
            # The connection above is validated whole; a page whose rows hold
            # no open collection is complete as read, and walking its rows one
            # by one would cost a jq run per row for nothing.
            open=$(jq -r 'any(.nodes[] | .. | objects | select(has("nodes")); .pageInfo.hasNextPage)' <<<"$value") || return 1
            [[ "$open" == true ]] || continue
            rows=$(jq -c '.nodes[]' <<<"$value") || return 1
            all='[]'
            while IFS= read -r row; do
                [[ -n "$row" ]] || continue
                row=$(linear_complete_entity "$type" "$row") || return 1
                all=$(jq -cs '.[0] + [.[1]]' <<<"$all"$'\n'"$row") || return 1
            done <<<"$rows"
            data=$(jq -cs --arg root "$root" '.[1] as $all | .[0] | .[$root].nodes = $all' <<<"$data"$'\n'"$all") || return 1
        else
            data=$(jq -cs --arg root "$root" '.[1] as $value | .[0] | .[$root] = $value' <<<"$data"$'\n'"$value") || return 1
        fi
    done <<<"$roots"
    printf '%s\n' "$data"
}

# One request and its nested completion. Returns graphql_request's status, so
# a caller can tell Linear's "Entity not found" (2) from a failed read (1).
graphql_query() {
    local result
    result=$(graphql_request "$@") || return
    linear_complete_result "$result"
}
