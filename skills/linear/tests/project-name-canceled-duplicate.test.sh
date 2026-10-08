#!/usr/bin/env bash
# Surface: issue project-name selection, including canceled twins and team scope.
# Inputs: scripts/linear.sh, scripts/commands/issues.sh, scripts/lib/*.sh.
# Linear permits reused project names in different teams and within one team.
# The fixture applies the query's team filter, so removing it returns the foreign
# project first. Every row checks the write or refusal, not the query spelling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >>"${CURL_PAYLOAD_LOG:?}"
case "$query" in
*"teams(filter:"*)
  ref="$(jq -r '.variables.name' <<<"$payload")"
  jq -cn --arg ref "$ref" '{data:{teams:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:(if $ref == "HT" then "ht-team" else "cc-team" end),key:$ref,name:$ref}]}}}'
  ;;
*"projects(filter:"*)
  name="$(jq -r '.variables.name' <<<"$payload")"
  if [[ "$name" == Boom ]]; then
    printf '%s' '{"errors":[{"message":"lookup unavailable"}]}'
  else
    team="$(jq -r '.variables.teamId // empty' <<<"$payload")"
    case "$query" in *'accessibleTeams: {some: {id: {eq: $teamId}}}'*) ;; *) team="" ;; esac
    jq -cn --arg name "$name" --arg team "$team" '
      def project($id; $state; $team): {id:$id,state:$state,teams:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{name:$team}]}};
      [project("dead-uuid"; "canceled"; "CC") + {name:"Dup",team:"cc-team"},
       project("foreign-uuid"; "backlog"; "HT") + {name:"Dup",team:"ht-team"},
       project("live-uuid"; "backlog"; "CC") + {name:"Dup",team:"cc-team"},
       project("twin-one"; "started"; "CC") + {name:"Twin",team:"cc-team"},
       project("twin-two"; "backlog"; "CC") + {name:"Twin",team:"cc-team"},
       project("foreign-only"; "backlog"; "HT") + {name:"Foreign",team:"ht-team"},
       project("dead-only"; "canceled"; "CC") + {name:"Canceled",team:"cc-team"}]
      | [.[] | select(.name == $name and ($team == "" or .team == $team))]
      | {data:{projects:{pageInfo:{hasNextPage:false,endCursor:null},nodes:.}}}'
  fi
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"label-uuid"}]}}}'
  ;;
*"issue(id:"*)
  ref="$(jq -r '.variables.id' <<<"$payload")"
  jq -cn --arg ref "$ref" '{data:{issue:{id:($ref + "-uuid"),identifier:$ref,team:(if $ref == "CC-2" then null else {id:(if ($ref | startswith("HT-")) or $ref == "CC-3" then "ht-team" else "cc-team" end)} end),project:null}}}'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-900","title":"t","description":"d","team":{"name":"CC"},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"inverseRelations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  ;;
*"issueUpdate"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"iss-uuid","identifier":"CC-1"}}}}'
  ;;
*) printf '%s' '{"errors":[{"message":"unexpected query"}]}' ;;
esac
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

PAYLOAD_LOG="$TMP_ROOT/payloads.jsonl"
CREATE='issues create --title t --labels agent:rust --priority 3 --description d'
# label|configured team|command|status|project IDs written|structured refusal
ROWS='
canceled twins lose to the live project in the configured team|CC|$CREATE --project Dup|0|live-uuid|-
same-name projects in two teams resolve under the explicit create team||$CREATE --team HT --project Dup|0|foreign-uuid|-
update uses the issue team when the configured team is absent||issues update HT-1 --project Dup|0|foreign-uuid|-
update uses the live issue team rather than an old identifier prefix|CC|issues update CC-3 --project Dup|0|foreign-uuid|-
bulk-update resolves the same project name separately for each issue team||issues bulk-update CC-1 HT-1 --project Dup|0|live-uuid,foreign-uuid|-
ambiguous live names refuse with every candidate and its team|CC|$CREATE --project Twin|1||AMBIGUOUS_PROJECT
update refuses ambiguous live names before writing||issues update CC-1 --project Twin|1||AMBIGUOUS_PROJECT
foreign-only project names cannot assign an issue to another team|CC|$CREATE --project Foreign|1||-
a name with only canceled matches refuses|CC|$CREATE --project Canceled|1||-
a project UUID passes through without a project lookup|CC|$CREATE --project 11111111-2222-3333-4444-555555555555|0|11111111-2222-3333-4444-555555555555|uuid
an existing issue without a team refuses name resolution||issues update CC-2 --project Dup|1||ISSUE_TEAM_MISSING
a failed project lookup refuses before writing|CC|$CREATE --project Boom|1||-
'

while IFS='|' read -r label team args want_rc want_projects refusal; do
  [[ -n "$label" ]] || continue
  : >"$PAYLOAD_LOG"
  eval "set -- $args"
  rc=0
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_TEAM="$team" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_REQUIRE_REACH= CURL_PAYLOAD_LOG="$PAYLOAD_LOG" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" "$@") \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  projects="$(jq -rs '[.[] | select(.query | test("issue(Create|Update)")) | .variables.input.projectId] | join(",")' "$PAYLOAD_LOG")"
  assert_eq "$label" "$rc:$projects" "$want_rc:$want_projects"
  sed -n '/^{/p' "$TMP_ROOT/err" >"$TMP_ROOT/errors.jsonl"
  case "$refusal" in
  AMBIGUOUS_PROJECT)
    assert "$label lists both project IDs with team names" \
      jq -se 'any(.[]; .code == "AMBIGUOUS_PROJECT" and .project == "Twin" and .team_id == "cc-team"
        and (.candidates | sort_by(.id)) == [{id:"twin-one",teams:["CC"]},{id:"twin-two",teams:["CC"]}])' "$TMP_ROOT/errors.jsonl" >/dev/null
    ;;
  ISSUE_TEAM_MISSING)
    assert "$label names the missing issue team" jq -se 'any(.[]; .code == "ISSUE_TEAM_MISSING" and .issue == "CC-2")' \
      "$TMP_ROOT/errors.jsonl" >/dev/null
    ;;
  uuid)
    assert "$label sends no project query" jq -se 'all(.[]; (.query | contains("projects(filter:")) | not)' "$PAYLOAD_LOG" >/dev/null
    ;;
  esac
done <<<"$ROWS"
