#!/usr/bin/env bash
# Surface: initiatives/projects create, update, get and list.
# Inputs: scripts/commands/{initiatives,projects}.sh, scripts/lib/{common,formatters,pages}.sh.
# curl models Linear's user filter and entity links; the CLI owns every write.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
assert_tmpdir TMP_ROOT
mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
query=$(jq -r '.query' <<<"$payload")
vars=$(jq -c '.variables' <<<"$payload")
printf '%s\n' "$payload" >>"${CURL_PAYLOAD_LOG:?}"
closed='{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}'
reply='{}'
case "$query" in
*'users(filter: {email:'*)
    hit=$(jq -r '.email | ascii_downcase' <<<"$vars")
    nodes='[]'
    if [[ "$query" == *'eqIgnoreCase:'* && "$hit" == dana@example.com ]]; then
        nodes='[{"id":"11111111-2222-3333-4444-555555555555","name":"Dana","email":"Dana@Example.com"}]'
    fi
    reply=$(jq -cn --argjson c "$closed" --argjson n "$nodes" '{users: ($c + {nodes: $n})}') ;;
*'teams(filter:'*)
    nodes='[]'
    [[ $(jq -r '.name' <<<"$vars") != CC ]] || nodes='[{"id":"team-id","key":"CC","name":"Core"}]'
    reply=$(jq -cn --argjson c "$closed" --argjson n "$nodes" '{teams: ($c + {nodes: $n})}') ;;
*'Labels(filter:'*)
    key=initiativeLabels
    [[ "$query" != *'projectLabels('* ]] || key=projectLabels
    nodes='[]'
    case $(jq -r '.name' <<<"$vars") in
        Roadmap) nodes='[{"id":"roadmap-label"}]' ;;
        "Won't fix") nodes='[{"id":"second-label"}]' ;;
    esac
    reply=$(jq -cn --arg key "$key" --argjson c "$closed" --argjson n "$nodes" '{($key): ($c + {nodes: $n})}') ;;
*'entityExternalLinkCreate(input:'*)
    if [[ "$FIELD_MODE" == fail-link ]]; then
        printf '%s' '{"errors":[{"message":"link denied"}]}___HTTP_CODE___200'
        exit
    fi
    success=true
    [[ "$FIELD_MODE" != false-link ]] || success=false
    link=$(jq -c '.input | {id: "link-id", label, url}' <<<"$vars")
    if [[ "$success" == true ]]; then
        jq -c --argjson link "$link" '. + [$link]' "$LINK_STATE" >"$LINK_STATE.next"
        mv "$LINK_STATE.next" "$LINK_STATE"
    fi
    reply=$(jq -cn --argjson success "$success" --argjson link "$link" '{entityExternalLinkCreate: {success: $success, entityExternalLink: $link}}') ;;
*)
    entity=initiative
    [[ "$query" != *'project('* && "$query" != *'projects('* && "$query" != *'projectCreate('* && "$query" != *'projectUpdate('* ]] || entity=project
    links=$(cat "$LINK_STATE")
    record=$(jq -cn --arg entity "$entity" --argjson c "$closed" --argjson links "$links" '{id: ($entity + "-id"), name: "Roadmap", owner: {name: "Dana", email: "Dana@Example.com"}, lead: {name: "Dana"}, leadTeam: {id: "team-id", key: "CC", name: "Core"}, labels: ($c + {nodes: [{name: "Roadmap"}]}), links: ($c + {nodes: $links}), projects: $c, teams: $c}')
    if [[ "$FIELD_MODE" == paged ]]; then
        if [[ $(jq -r '.after // ""' <<<"$vars") == next ]]; then
            record=$(jq -c --argjson c "$closed" '.links = ($c + {nodes: [{id:"late-link",label:"Late",url:"https://example.com/late"}]}) | .labels = ($c + {nodes: [{name:"More"}]})' <<<"$record")
        else
            record=$(jq -c '.links = {pageInfo: {hasNextPage:true,endCursor:"next"},nodes: []} | .labels.pageInfo = {hasNextPage:true,endCursor:"next"}' <<<"$record")
        fi
    fi
    # A field absent from the real request is absent from the stub's reply.
    for field in owner lead leadTeam labels links; do
        [[ "$query" == *"$field {"* || "$query" == *"$field(first:"* ]] || record=$(jq -c --arg f "$field" 'del(.[$f])' <<<"$record")
    done
    if [[ "$query" == *'nodes { id label }'* ]]; then
        record=$(jq -c 'del(.links.nodes[].url)' <<<"$record")
    fi
    if [[ "$query" == *'mutation '* ]]; then
        action=Create
        [[ "$query" != *'Update('* ]] || action=Update
        success=true
        [[ "$FIELD_MODE" != fail-entity ]] || success=false
        reply=$(jq -cn --arg key "$entity$action" --arg entity "$entity" --argjson r "$record" --argjson success "$success" '{($key): {success: $success, ($entity): $r}}')
    elif [[ "$query" == *'EntityLinks('* && "$FIELD_MODE" == read-fail ]]; then
        printf '%s' '{"errors":[{"message":"links unavailable"}]}___HTTP_CODE___200'
        exit
    elif [[ "$query" == *"${entity}s("* ]]; then
        reply=$(jq -cn --arg key "${entity}s" --argjson c "$closed" --argjson r "$record" '{($key): ($c + {nodes: [$r]})}')
    else
        reply=$(jq -cn --arg key "$entity" --argjson r "$record" '{($key): $r}')
    fi ;;
esac
printf '{"data":%s}___HTTP_CODE___200' "$reply"
STUB
chmod +x "$TMP_ROOT/bin/curl"
run_linear() {
    local name="$1" mode="$2" rc=0
    shift 2
    : >"$TMP_ROOT/$name.jsonl"
    (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
        LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC FIELD_MODE="$mode" \
        CURL_PAYLOAD_LOG="$TMP_ROOT/$name.jsonl" LINK_STATE="$TMP_ROOT/links.json" \
        "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" "$@") \
        >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
    printf '%s' "$rc" >"$TMP_ROOT/$name.rc"
}
inputs() {
    jq -sc --arg op "$2" '[.[] | select(.query | contains($op + "(")) | .variables.input]' "$TMP_ROOT/$1.jsonl"
}
printf '[]\n' >"$TMP_ROOT/links.json"
while IFS='|' read -r resource action flag value field want; do
    name="$resource-$action-$field-$want"
    args=("$resource" "$action")
    if [[ "$action" == create ]]; then args+=(--name Roadmap); else args+=(entity-id); fi
    run_linear "$name" normal "${args[@]}" "$flag" "$value"
    entity=${resource%s}
    case "$action" in
        create) op="${entity}Create" ;;
        update) op="${entity}Update" ;;
    esac
    if [[ "$want" == refused ]]; then
        assert_ne "$name: refuses" "$(cat "$TMP_ROOT/$name.rc")" 0
        assert_eq "$name: no write" "$(jq -s '[.[] | select(.query | contains("mutation "))] | length' "$TMP_ROOT/$name.jsonl")" 0
        if [[ "$field" == labelIds ]]; then
            assert_jq "$name: names unknown label" "$(cat "$TMP_ROOT/$name.err")" '.code == "LABEL_NOT_FOUND" and .reference == "Unknown"'
        elif [[ "$field" != leadTeamId ]]; then
            assert_jq "$name: names unknown user" "$(cat "$TMP_ROOT/$name.err")" '.code == "USER_NOT_FOUND" and .reference == "nobody@example.com"'
        fi
    else
        assert_eq "$name: succeeds" "$(cat "$TMP_ROOT/$name.rc")" 0
        if [[ "$field" == labelIds ]]; then
            assert_jq "$name: native field" "$(inputs "$name" "$op")" 'length == 1 and .[0].labelIds == ["roadmap-label", "second-label"]'
        else
            assert_jq "$name: native field" "$(inputs "$name" "$op")" ". | length == 1 and .[0].$field == \"$want\""
        fi
    fi
done <<'ROWS'
initiatives|create|--owner|dana@EXAMPLE.com|ownerId|11111111-2222-3333-4444-555555555555
initiatives|update|--owner|dana@EXAMPLE.com|ownerId|11111111-2222-3333-4444-555555555555
initiatives|create|--owner|nobody@example.com|ownerId|refused
initiatives|update|--owner|nobody@example.com|ownerId|refused
initiatives|create|--lead-team|CC|leadTeamId|team-id
initiatives|update|--lead-team|CC|leadTeamId|team-id
initiatives|create|--lead-team|Unknown|leadTeamId|refused
initiatives|update|--lead-team|Unknown|leadTeamId|refused
initiatives|create|--labels|Roadmap, Won't fix|labelIds|labels
initiatives|update|--labels|Roadmap, Won't fix|labelIds|labels
initiatives|create|--labels|Unknown|labelIds|refused
initiatives|update|--labels|Unknown|labelIds|refused
projects|create|--lead|dana@EXAMPLE.com|leadId|11111111-2222-3333-4444-555555555555
projects|update|--lead|dana@EXAMPLE.com|leadId|11111111-2222-3333-4444-555555555555
projects|create|--lead|nobody@example.com|leadId|refused
projects|update|--lead|nobody@example.com|leadId|refused
projects|create|--labels|Roadmap, Won't fix|labelIds|labels
projects|update|--labels|Roadmap, Won't fix|labelIds|labels
ROWS

while IFS='|' read -r resource action; do
    entity=${resource%s}
    name="$resource-$action-link"
    args=("$resource" "$action")
    if [[ "$action" == create ]]; then args+=(--name Roadmap); else args+=(entity-id); fi
    printf '[]\n' >"$TMP_ROOT/links.json"
    run_linear "$name" normal "${args[@]}" --link 'Plan=https://example.com/plan?q=a=b' --link 'Other=https://example.com/other' --link 'Again=https://example.com/plan?q=a=b'
    assert_eq "$name: succeeds" "$(cat "$TMP_ROOT/$name.rc")" 0
    assert_jq "$name: parent and URL" "$(inputs "$name" entityExternalLinkCreate)" "length == 2 and .[0].${entity}Id == \"$entity-id\" and .[0].label == \"Plan\" and .[0].url == \"https://example.com/plan?q=a=b\""
    run_linear "$name-repeat" normal "$resource" update entity-id --link 'Renamed=https://example.com/plan?q=a=b'
    assert_eq "$name: repeat succeeds" "$(cat "$TMP_ROOT/$name-repeat.rc")" 0
    assert_jq "$name: repeat skips URL" "$(inputs "$name-repeat" entityExternalLinkCreate)" 'length == 0'
    for mode in fail-link false-link read-fail; do
        printf '[]\n' >"$TMP_ROOT/links.json"
        run_linear "$name-$mode" "$mode" "${args[@]}" --link 'Plan=https://example.com/plan'
        assert_ne "$name-$mode: fails" "$(cat "$TMP_ROOT/$name-$mode.rc")" 0
        assert_jq "$name-$mode: partial write" "$(cat "$TMP_ROOT/$name-$mode.out")" '.partial == true and .success == true'
    done
    run_linear "$name-malformed" normal "${args[@]}" --link 'missing separator'
    assert_jq "$name: malformed link" "$(cat "$TMP_ROOT/$name-malformed.err")" '.code == "INVALID_LINK"'
    assert_eq "$name: malformed link makes no write" "$(jq -s '[.[] | select(.query | contains("mutation "))] | length' "$TMP_ROOT/$name-malformed.jsonl")" 0
    run_linear "$name-fail-entity" fail-entity "${args[@]}" --link 'Plan=https://example.com/plan'
    assert_ne "$name: failed entity fails" "$(cat "$TMP_ROOT/$name-fail-entity.rc")" 0
    assert_jq "$name: failed entity makes no link" "$(inputs "$name-fail-entity" entityExternalLinkCreate)" 'length == 0'
done <<'ROWS'
initiatives|create
initiatives|update
projects|create
projects|update
ROWS

printf '[{"id":"link-id","label":"Plan","url":"https://example.com/plan"}]\n' >"$TMP_ROOT/links.json"
for resource in initiatives projects; do
    for action in get list; do
        name="$resource-$action"
        args=("$resource" "$action")
        [[ "$action" != get ]] || args+=(11111111-2222-3333-4444-555555555555)
        run_linear "$name" normal "${args[@]}"
        assert_eq "$name: succeeds" "$(cat "$TMP_ROOT/$name.rc")" 0
        data=$(cat "$TMP_ROOT/$name.out")
        [[ "$action" != list ]] || data=$(jq -c '.[0]' <<<"$data")
        assert_jq "$name: labels and links" "$data" '.labels == ["Roadmap"] and .links == [{id:"link-id",label:"Plan",url:"https://example.com/plan"}]'
        if [[ "$resource" == initiatives ]]; then
            assert_jq "$name: owner and team" "$data" '.owner == "Dana" and .lead_team == "Core"'
        else
            assert_jq "$name: lead" "$data" '.lead == "Dana"'
        fi
        run_linear "$name-raw" normal "${args[@]}" --format raw
        assert_jq "$name: raw nesting" "$(cat "$TMP_ROOT/$name-raw.out")" '(.initiative // .project // .initiatives.nodes[0] // .projects.nodes[0]).links.nodes[0].label == "Plan"'
    done
done

for resource in initiatives projects; do
    run_linear "$resource-paged" paged "$resource" get 11111111-2222-3333-4444-555555555555
    assert_eq "$resource: paged read succeeds" "$(cat "$TMP_ROOT/$resource-paged.rc")" 0
    assert_jq "$resource: paged labels and links" "$(cat "$TMP_ROOT/$resource-paged.out")" '.labels == ["Roadmap", "More"] and .links[0].url == "https://example.com/late"'
    run_linear "$resource-late-link" paged "$resource" update entity-id --link 'Plan=https://example.com/late'
    assert_eq "$resource: later-page duplicate succeeds" "$(cat "$TMP_ROOT/$resource-late-link.rc")" 0
    assert_jq "$resource: later-page duplicate skips" "$(inputs "$resource-late-link" entityExternalLinkCreate)" 'length == 0'
done
