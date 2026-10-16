#!/usr/bin/env bash
# The `issues list` filter options an audit reads the whole backlog with:
# --all-projects sends no project filter, --no-project asks for issues with no
# project, every --label and --labels name must be on the issue, and two
# project-scope options together refuse before any request.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -c 'fromjson')
printf '%s\n' "$payload" >>"$CALLS"
if [[ -n "${SELECTION_CASE:-}" ]]; then
    after=$(jq -r '.variables.after // ""' <<<"$payload")
    if [[ "$SELECTION_CASE" == page-fail && "$after" == next || "$SELECTION_CASE" == blocker-fail && "$after" == blocker ]]; then
        printf '%s' '{"errors":[{"message":"fixture later page failed"}]}___HTTP_CODE___200'
        exit 0
    fi
    jq -cj '
      def conn($nodes; $more; $cursor): {nodes:$nodes,pageInfo:{hasNextPage:$more,endCursor:$cursor}};
      def blocker($id; $type): {id:$id,type:"blocks",issue:{id:$id,identifier:$id,title:$id,state:{name:$type,type:$type}}};
      if (.query | contains("ContinueConnection")) then
        {data:{issue:{id:"uuid-1",inverseRelations:conn([blocker("KEN-open";"started"),blocker("KEN-done";"completed")];false;null)}}}
      elif .variables.after == "next" then
        {data:{issues:conn([{identifier:"KEN-2",createdAt:"2026-08-15T09:01:00Z"}];false;null)}}
      else
        {data:{issues:conn([({id:"uuid-1",identifier:"KEN-1",title:"container",description:"outcome",priority:2,
          state:{name:"Verifying",type:"started"},parent:{identifier:"KEN-parent"},createdAt:"2026-08-15T09:00:00Z"}
          + if (.query | contains("inverseRelations")) then {inverseRelations:conn([];true;"blocker")} else {} end)];true;"next")}}
      end' <<<"$payload"
    printf '___HTTP_CODE___200'
    exit 0
fi
printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

# label|args|expected rc|jq over the request's filter, or `none` for no request
while IFS='|' read -r label args want check; do
    : >"$TMP_ROOT/calls"
    rc=0
    # shellcheck disable=SC2086  # args is one command line of plain words
    (cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh issues list $args --max \
        >/dev/null 2>"$TMP_ROOT/err") || rc=$?
    assert_eq "$label: exit status" "$rc" "$want"
    if [[ "$check" == none ]]; then
        assert_not "$label: sends no request" test -s "$TMP_ROOT/calls"
    else
        assert_jq "$label: filter" "$(cat "$TMP_ROOT/calls")" ".variables.filter | $check"
    fi
done <<'ROWS'
email assignee|--assignee Owner@Example.com|0|.assignee == {email: {eqIgnoreCase: "Owner@Example.com"}}
UTC scan floor|--created-since 2026-08-15T09:00:00Z|0|.createdAt == {gte: "2026-08-15T09:00:00Z"}
day scan floor|--created-since 1d|0|.createdAt.gte | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")
invalid UTC floor|--created-since 2026-02-30T09:00:00Z|1|none
offset scan floor|--created-since 2026-08-15T09:00:00+00:00|1|none
all projects|--all-projects --state Todo|0|has("project") | not
no project|--no-project|0|.project == {null: true}
one label|--label bug|0|.labels == {name: {eq: "bug"}}
two labels by --labels|--labels bug,skills|0|.and == [{labels: {name: {eq: "bug"}}}, {labels: {name: {eq: "skills"}}}]
two labels by --label|--label bug --label skills|0|.and == [{labels: {name: {eq: "bug"}}}, {labels: {name: {eq: "skills"}}}]
--project with --all-projects|--project P --all-projects|1|none
--no-project with --project|--no-project --project P|1|none
--all-projects with --no-project|--all-projects --no-project|1|none
ROWS

for selection in triage owed; do
    for mode in complete page-fail blocker-fail; do
        [[ "$selection:$mode" != triage:blocker-fail ]] || continue
        : >"$TMP_ROOT/calls"
        rc=0
        out=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
            SELECTION_CASE="$mode" LINEAR_API_KEY_OVERRIDE=test-key "$BASH" .agents/skills/linear/scripts/linear.sh \
            issues list --select "$selection" --max 2>"$TMP_ROOT/err") || rc=$?
        if [[ "$mode" == complete ]]; then
            [[ "$rc" == 0 ]] || cat "$TMP_ROOT/err" >&2
            assert_eq "$selection: complete read" "$rc" 0
            assert_jq "$selection: every issue page" "$out" 'map(.id) == ["KEN-1","KEN-2"]'
            assert_jq "$selection: pages of 250" "$(cat "$TMP_ROOT/calls")" 'select(.query | contains("ListIssues")) | .variables.first == 250'
            if [[ "$selection" == triage ]]; then
                assert_jq 'triage: only identity and creation selected upstream' "$(cat "$TMP_ROOT/calls")" \
                    '.query | capture("nodes \\{(?<fields>[^}]+)\\}").fields | split("\n") | join(" ") | split(" ") | map(select(length > 0)) | sort == ["createdAt","identifier"]'
                assert_jq 'triage: required output fields' "$out" '.[0] == {id:"KEN-1",created_at:"2026-08-15T09:00:00Z"}'
            else
                # The fixture supplies values without projecting the request.
                # Check the wire fields owed_read needs, including their scope.
                assert_jq 'owed: required fields selected upstream' "$(jq -sc '[.[] | select(.query | contains("ListIssues")) | .query]' "$TMP_ROOT/calls")" '
                    length > 0 and all(.[];
                        (capture("nodes\\s*\\{(?<fields>.*)\\}\\s*\\}\\s*\\}\\s*$"; "s")
                          // error("owed-selection-unread")).fields
                        | [scan("[_A-Za-z][_0-9A-Za-z]*|[{}]")]
                        | reduce .[] as $token ({scope: [], prior: null, paths: []};
                            if $token == "{" then .scope += [.prior]
                            elif $token == "}" then .scope = .scope[:-1]
                            else .prior = $token | .paths += [(.scope + [$token] | join("."))] end)
                        | .paths as $selected
                        | ["id", "identifier", "title", "description", "priority", "createdAt",
                           "state.name", "state.type", "parent.identifier",
                           "inverseRelations.pageInfo.hasNextPage", "inverseRelations.pageInfo.endCursor",
                           "inverseRelations.nodes.id", "inverseRelations.nodes.type",
                           "inverseRelations.nodes.issue.identifier", "inverseRelations.nodes.issue.state.type"]
                          - $selected | length == 0)'
                assert_jq 'owed: unused fields omitted upstream' "$(cat "$TMP_ROOT/calls")" \
                    'select(.query | contains("ListIssues")) | .query | test("assignee|labels|project|estimate|sortOrder|updatedAt|archivedAt|trashed|url|relatedIssue") | not'
                assert_jq 'owed: verification and container facts survive every blocker page' "$out" \
                    '.[0] == {id:"KEN-1",title:"container",description:"outcome",priority:2,state:"Verifying",state_type:"started",parent_id:"KEN-parent",created_at:"2026-08-15T09:00:00Z",blocked_by_open:["KEN-open"]}'
            fi
        else
            assert_ne "$selection $mode: refuses incomplete discovery" "$rc" 0
            assert_eq "$selection $mode: no partial output" "$out" ''
        fi
    done
done
