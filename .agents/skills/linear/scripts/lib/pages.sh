#!/bin/bash
# Cursor traversal for Linear's Relay connections. Requires common.sh.
set -euo pipefail

# Read the requested connection to its end, or to a caller's total row limit.
# Every page must carry pageInfo. A row limit can leave the chain open.
# Output follows successful traversal to the end or limit. Failures leave stdout empty.
graphql_pages() {
    local query="$1" variables="$2" path="$3" limit="${4:-0}" initial="${5:-}"
    local result nodes all='[]' seen='[]' cursor='null' next count=0 key
    key=$(jq -cn --arg path "$path" '$path | split(".")') || return 1
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
        all=$(jq -cs '.[0] + .[1]' <<<"$all"$'\n'"$nodes") || return 1
        count=$((count + 1))
        next=$(jq -r --argjson key "$key" 'getpath($key).pageInfo.hasNextPage' <<<"$result") || return 1
        if [[ "$next" == false ]]; then break; fi
        local collected
        collected=$(jq 'length' <<<"$all") || return 1
        if (( limit > 0 && collected >= limit )); then break; fi
        cursor=$(jq -ce --argjson key "$key" 'getpath($key).pageInfo.endCursor | strings | select(length > 0)' <<<"$result") || {
            printf 'linear-pages: missing-cursor=%s\n' "$path" >&2
            return 1
        }
        next=$(jq -rs '.[1] as $cursor | .[0] | index($cursor) != null' <<<"$seen"$'\n'"$cursor") || return 1
        if [[ "$next" == true ]]; then
            printf 'linear-pages: repeated-cursor=%s\n' "$path" >&2
            return 1
        fi
        seen=$(jq -cs '.[0] + [.[1]]' <<<"$seen"$'\n'"$cursor") || return 1
        # Linear can keep a connection open under concurrent edits. Bound that
        # work without treating a partial result as a complete inventory.
        if (( count >= 400 )); then
            printf 'linear-pages: page-cap=%s\n' "$path" >&2
            return 1
        fi
    done
    if (( limit > 0 )); then all=$(jq -c --argjson n "$limit" '.[:$n]' <<<"$all") || return 1; fi
    result=$(jq -cs --argjson key "$key" '
        .[1] as $nodes | .[0] | setpath($key + ["nodes"]; $nodes)' <<<"$result"$'\n'"$all") || return 1
    linear_complete_result "$result"
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
        fields="id identifier title state { name type } assignee { name } labels(first: 10) { pageInfo { hasNextPage endCursor } nodes { name } } priority estimate parent { identifier } $ISSUE_RELATION_PAGE_FIELDS"
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
    local data="$1" root type rows row all value roots kind
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

graphql_query() {
    local result
    result=$(graphql_request "$@") || return 1
    linear_complete_result "$result"
}
