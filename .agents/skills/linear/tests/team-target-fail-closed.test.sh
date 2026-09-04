#!/usr/bin/env bash
# the Linear CLI must never substitute a guessed team.
#
# A team name resolves inside whatever workspace LINEAR_API_KEY reaches, so a
# hardcoded default silently targets another project's tracker. With no team
# configured, writes must refuse before any API call, reads must drop the team
# filter, and auth-check must report the target it would use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"viewer"*)
  printf '%s' '{"data":{"viewer":{"id":"viewer-uuid"}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  printf '%s' '{"data":{"issue":{"id":"issue-uuid"}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Explicit"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-07-30T00:00:00Z","updatedAt":"2026-07-30T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*"commentCreate(input:"*)
  printf '%s' '{"data":{"commentCreate":{"success":true,"comment":{"id":"comment-uuid","body":"b","createdAt":"2026-07-30T00:00:00Z","user":{"name":"tester"}}}}}___HTTP_CODE___200'
  ;;
*"projectCreate(input:"*)
  printf '%s' '{"data":{"projectCreate":{"success":true,"project":{"id":"project-uuid","name":"P","url":"https://linear.app/x/project/P","state":"planned"}}}}___HTTP_CODE___200'
  ;;
*"cycleCreate(input:"*)
  printf '%s' '{"data":{"cycleCreate":{"success":true,"cycle":{"id":"cycle-uuid","number":1,"name":"C","startsAt":"2026-08-01T00:00:00Z","endsAt":"2026-08-15T00:00:00Z","team":{"name":"Explicit"}}}}}___HTTP_CODE___200'
  ;;
*"issueLabelCreate(input:"*)
  printf '%s' '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"label-uuid","name":"backend","color":"#fff","description":null,"isGroup":false,"team":null,"parent":null,"createdAt":"2026-07-30T00:00:00Z"}}}}___HTTP_CODE___200'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[]}}}___HTTP_CODE___200'
  ;;
*"cycles(filter:"*)
  printf '%s' '{"data":{"cycles":{"nodes":[]}}}___HTTP_CODE___200'
  ;;
*"comments(filter:"*)
  printf '%s' '{"data":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200'
  ;;
*"issues(filter:"*)
  printf '%s' '{"data":{"issues":{"nodes":[]}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

OUT=""
ERR=""
RC=0

# assert_log DESC FILTER — FILTER must select a true value over the logged
# curl payloads, read as a stream.
assert_log() {
  assert "$1" jq -s -e "$2" "$CURL_LOG"
}

# Run the CLI inside the temp project with LINEAR_TEAM absent from the process
# environment (parent env wins over project files, so it must be cleared).
run_linear() {
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

# Same, with LINEAR_TEAM exported by the caller.
run_linear_env_team() {
  local team="$1"
  shift
  : >"$CURL_LOG"
  RC=0
  OUT="$(cd "$PROJECT" && env \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    LINEAR_TEAM="$team" \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

set_settings_team() {
  printf '[env]\nLINEAR_TEAM = "%s"\n' "$1" >"$PROJECT/kendex.settings.toml"
}

clear_settings() {
  rm -f "$PROJECT/kendex.settings.toml"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

assert_no_guessed_team() {
  local label="$1"
  assert_log "$label sends no team filter with no configured team" \
    'all(.[]; (.variables | tostring | contains("team")) | not)'
  # sync builds team scoping into the query document itself, where a variables-
  # only check cannot see it.
  assert_log "$label inlines no team filter into the query document" \
    'all(.[]; (.query | test("team[[:space:]]*:")) | not)'
  assert_not "$label carries no guessed team name" grep -riq "claude" "$CURL_LOG"
}

assert_refused() {
  local label="$1"
  assert_ne "$label is refused" "$RC" 0
  assert_contains "$label carries the refusal message" "$ERR" "No Linear team configured"
  assert_contains "$label refusal names LINEAR_TEAM" "$ERR" "LINEAR_TEAM"
  assert_contains "$label refusal names kendex.settings.toml" "$ERR" "kendex.settings.toml"
  assert_contains "$label refusal names the per-call override" "$ERR" "--team"
  # The message may only offer --team where a parser actually accepts it.
  assert_contains "$label refusal names the actions that take --team" \
    "$ERR" "issues, projects, cycles, labels"
  assert_eq "$label refuses before any API call" "$(api_calls)" "0"
}

echo "=== writes refuse when no team is configured ==="

clear_settings

run_linear issues create --title "Cross-workspace write"
assert_refused "issues create"

run_linear issues update TEAM-1 --state Done
assert_refused "issues update"

run_linear issues complete TEAM-1
assert_refused "issues complete"

run_linear issues archive TEAM-1
assert_refused "issues archive"

run_linear issues add-relation TEAM-1 --blocks TEAM-2
assert_refused "issues add-relation"

run_linear comments create TEAM-1 --body "hello"
assert_refused "comments create"

run_linear projects create --name "New project"
assert_refused "projects create"

run_linear cycles create --start 2026-08-01 --end 2026-08-15
assert_refused "cycles create"

run_linear labels create --name backend
assert_refused "labels create"

run_linear milestones create --project P --name Alpha
assert_refused "milestones create"

run_linear initiatives create --name "Phase 1"
assert_refused "initiatives create"

echo "=== free text is not a team target ==="

# The guard must not read a team out of unparsed argv: a `--team` token in a
# comment body or an issue title is ordinary user text, and honoring it would
# let any write open its own gate.
clear_settings

run_linear comments create TEAM-1 --body "--team=CC"
assert_refused "comments create with --team=CC as the body"

run_linear comments create TEAM-1 --body "--team"
assert_refused "comments create with a bare --team body"

run_linear comments create TEAM-1 --body "see --team CC for context"
assert_refused "comments create with --team inside prose"

run_linear issues update TEAM-1 --title "--team" --state Done
assert_refused "issues update with a bare --team title"

run_linear issues update TEAM-1 --title "--team=CC" --state Done
assert_refused "issues update with --team=CC as the title"

run_linear issues create --title "--team=CC"
assert_refused "issues create with --team=CC as the title"

run_linear issues comment TEAM-1 --body "--team=CC"
assert_ne "issues comment redirect fails" "$RC" 0
assert_eq "the issues comment redirect" "$(api_calls)" "0"

echo "=== a blank configured value stays unset (seeded template is inert) ==="

set_settings_team ""
run_linear issues create --title "Blank team"
assert_refused "issues create with blank LINEAR_TEAM"

echo "=== help never needs a team target ==="

clear_settings
run_linear issues create --help
assert_eq "issues create --help exits zero" "$RC" 0
assert_contains "issues create --help prints its help" "$OUT" "Create Options:"

# `update` is guarded at the dispatcher, so its help path is the one that needs
# the exemption.
run_linear issues update --help
assert_eq "issues update --help exits zero" "$RC" 0
assert_contains "issues update --help prints its help" "$OUT" "Update Options:"
assert_eq "issues update --help" "$(api_calls)" "0"

echo "=== explicit --team satisfies the requirement ==="

clear_settings
run_linear issues create --title "Explicit target" --team Explicit
assert_eq "issues create --team exits zero" "$RC" 0
assert_log "an explicit --team resolves the team" \
  'any(.[]; (.query | contains("teams(filter:")) and .variables.name == "Explicit")'
assert_log "issueCreate carries the resolved team id" \
  'any(.[]; (.query | contains("issueCreate")) and .variables.input.teamId == "team-uuid")'

echo "=== configured LINEAR_TEAM proceeds ==="

set_settings_team "Configured"
run_linear issues create --title "Configured target"
assert_eq "issues create with configured team exits zero" "$RC" 0
assert_log "a configured LINEAR_TEAM is used" \
  'any(.[]; (.query | contains("teams(filter:")) and .variables.name == "Configured")'

run_linear comments create TEAM-1 --body "hello"
assert_eq "comments create with configured team exits zero" "$RC" 0
assert_log "comments create reaches the API with a configured team" \
  'any(.[]; .query | contains("commentCreate"))'

# Free text stays free text: a configured project still writes the body as-is.
run_linear comments create TEAM-1 --body "--team=CC"
assert_eq "comments create with a --team-shaped body exits zero" "$RC" 0
assert_log "the comment body is preserved verbatim" \
  'any(.[]; (.query | contains("commentCreate")) and (.variables.input.body | startswith("--team=CC")))'

# Every create action that parses --team resolves its target after parsing.
clear_settings
for create_case in "projects create --name P --team Explicit:projectCreate" \
  "cycles create --start 2026-08-01 --end 2026-08-15 --team Explicit:cycleCreate" \
  "labels create --name backend --team Explicit:issueLabelCreate"; do
  args="${create_case%:*}"
  op="${create_case##*:}"
  # shellcheck disable=SC2086
  run_linear $args
  assert_eq "$args exits zero" "$RC" 0
  assert "$args reaches $op" \
    jq -s -e --arg op "$op" 'any(.[]; .query | contains($op))' "$CURL_LOG"
done

# labels create takes an optional --team; with none passed it still needs a
# configured target, and it must not invent a team scope for the label.
set_settings_team "Configured"
run_linear labels create --name backend
assert_eq "labels create with configured team exits zero" "$RC" 0
assert_log "labels create scopes the label to no team it was not asked for" \
  'any(.[]; (.query | contains("issueLabelCreate")) and (.variables.input | has("teamId") | not))'

echo "=== reads never send a guessed team ==="

clear_settings

run_linear statuses list
assert_eq "statuses list exits zero" "$RC" 0
assert_no_guessed_team "statuses list"

run_linear cycles list --type current
assert_eq "cycles list exits zero" "$RC" 0
assert_log "cycles list resolves no team when none is configured" \
  'all(.[]; (.query | contains("teams(filter:")) | not)'
assert_no_guessed_team "cycles list"

run_linear statuses get --name "In Progress"
assert_eq "statuses get exits zero" "$RC" 0
assert_no_guessed_team "statuses get"

run_linear issues list --limit 5
assert_eq "issues list exits zero" "$RC" 0
assert_no_guessed_team "issues list"

# The team filter is still applied when one is configured.
set_settings_team "Configured"
run_linear cycles list --type current
assert_eq "cycles list with configured team exits zero" "$RC" 0
assert_log "cycles list did not resolve the configured team" \
  'any(.[]; (.query | contains("teams(filter:")) and .variables.name == "Configured")'
assert_log "cycles list scopes to the configured team" \
  'any(.[]; .variables.filter.team.id.eq == "team-uuid")'

run_linear statuses list
assert_log "statuses list scopes to the configured team" \
  'any(.[]; .variables.filter.team.name.eq == "Configured")'
clear_settings

run_linear sync --full --no-attachments
assert_ne "sync issues requests, so the check below is not vacuous" "$(api_calls)" "0"
assert_no_guessed_team "sync"
assert_log "sync queries cycles" \
  'any(.[]; .query | contains("SyncCycles"))'

set_settings_team "Configured"
run_linear sync --full --no-attachments
assert_log "sync scopes cycles to the configured team" \
  'any(.[]; (.query | contains("SyncCycles")) and .variables.teamName == "Configured")'
clear_settings

echo "=== graphql_query refuses any mutation without a target ==="

: >"$CURL_LOG"
backstop_rc=0
backstop_err="$(cd "$PROJECT" && env -u LINEAR_TEAM \
  PATH="$PROJECT/bin:$PATH" \
  LINEAR_API_KEY=test-token \
  CURL_LOG="$CURL_LOG" \
  bash -c 'source .agents/skills/linear/scripts/lib/common.sh
graphql_query "
    mutation UnregisteredWrite(\$input: IssueCreateInput!) { issueCreate(input: \$input) { success } }" "{}"' 2>&1)" || backstop_rc=$?
assert_ne "graphql_query refuses a mutation with no team target" "$backstop_rc" 0
assert_contains "the graphql_query refusal names the missing team" "$backstop_err" "No Linear team configured"
assert_eq "graphql_query" "$(api_calls)" "0"

: >"$CURL_LOG"
read_rc=0
(cd "$PROJECT" && env -u LINEAR_TEAM \
  PATH="$PROJECT/bin:$PATH" \
  LINEAR_API_KEY=test-token \
  CURL_LOG="$CURL_LOG" \
  bash -c 'source .agents/skills/linear/scripts/lib/common.sh
graphql_query "query Ping { viewer { id } }" "{}"' >/dev/null 2>&1) || read_rc=$?
assert_eq "graphql_query allows a read with no team target" "$read_rc" 0
assert_eq "the read query reaches the API" "$(api_calls)" "1"

echo "=== auth-check reports the target ==="

clear_settings
run_linear auth-check
assert_eq "auth-check exits zero" "$RC" 0
assert_jq "auth-check reports an unresolved team" "$OUT" '.ok == true and .team == null and .team_source == "unset" and .writes_enabled == false'
assert_jq "auth-check attributes the API key to the environment" "$OUT" '.api_key_source == "environment"'
assert_jq "auth-check warns about the missing team" "$OUT" '[.warnings[] | select(contains("LINEAR_TEAM"))] | length > 0'
assert_jq "auth-check flags a global key with no project team" "$OUT" '[.warnings[] | select(contains("process environment"))] | length > 0'

run_linear auth-check --strict
assert_ne "auth-check --strict fails" "$RC" 0

set_settings_team "Configured"
run_linear auth-check --strict
assert_eq "auth-check --strict exits zero" "$RC" 0
assert_jq "auth-check reports the configured team" "$OUT" '.team == "Configured" and .team_source == "project-config" and .writes_enabled == true and (.warnings | length) == 0'
assert_jq "auth-check names the file that set the team" "$OUT" '.team_source_file == "kendex.settings.toml"'

run_linear_env_team "EnvTeam" auth-check
assert_eq "auth-check exits zero" "$RC" 0
assert_jq "auth-check reports the exported team" "$OUT" '.team == "EnvTeam" and .team_source == "environment" and .writes_enabled == true'
assert_jq "auth-check names no project file for an environment-sourced team" "$OUT" '.team_source_file == null'
assert_jq "auth-check warns that the environment shadows project config" "$OUT" '[.warnings[] | select(contains("overrides the project value"))] | length > 0'

# An exported-but-empty LINEAR_TEAM wins over the project file (parent env
# beats project config) and resolves to nothing. Attribution must say so
# instead of naming a file that supplied nothing.
run_linear_env_team "" auth-check
assert_eq "auth-check exits zero" "$RC" 0
assert_jq "auth-check attribution is consistent for an exported empty team" "$OUT" '.team == null and .team_source == "unset" and .team_source_file == null and .writes_enabled == false'
assert_jq "auth-check warns that an empty export shadows project config" "$OUT" '[.warnings[] | select(contains("exported as an empty value"))] | length > 0'

run_linear_env_team "" issues create --title "Empty export"
assert_refused "issues create with an exported empty LINEAR_TEAM"
clear_settings

# A malformed settings file refuses the whole CLI at startup: no command
# runs on a partial read, so team provenance can never quote a value from a
# file the loader rejected.
printf '[env]\nLINEAR_TEAM = "Partial"\nDUP = "a"\nDUP = "b"\n' >"$PROJECT/kendex.settings.toml"
run_linear auth-check
assert_ne "auth-check does not run on a refused settings load" "$RC" 0
assert_file_contains "the refusal names the settings defect" "$ERR_FILE" "assigned more than once"
clear_settings

