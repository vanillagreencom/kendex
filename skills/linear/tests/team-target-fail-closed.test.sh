#!/usr/bin/env bash
# Regression test: the Linear CLI must never substitute a guessed team.
#
# A team name resolves inside whatever workspace LINEAR_API_KEY reaches, so a
# hardcoded default silently targets another project's tracker. With no team
# configured, writes must refuse before any API call, reads must drop the team
# filter, and auth-check must report the target it would use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[]}}}___HTTP_CODE___200'
  ;;
*"cycles(filter:"*)
  printf '%s' '{"data":{"cycles":{"nodes":[]}}}___HTTP_CODE___200'
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

fail() {
  echo "FAIL $*"
  [[ -s "$CURL_LOG" ]] && echo "--- curl payloads ---" && cat "$CURL_LOG"
  exit 1
}

# Run the CLI inside the temp project with LINEAR_TEAM absent from the process
# environment (parent env wins over project files, so it must be cleared).
run_linear() {
  : >"$CURL_LOG"
  set +e
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")"
  RC=$?
  set -e
  ERR="$(cat "$ERR_FILE")"
}

# Same, with LINEAR_TEAM exported by the caller.
run_linear_env_team() {
  local team="$1"
  shift
  : >"$CURL_LOG"
  set +e
  OUT="$(cd "$PROJECT" && env \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    LINEAR_TEAM="$team" \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")"
  RC=$?
  set -e
  ERR="$(cat "$ERR_FILE")"
}

set_settings_team() {
  printf '[env]\nLINEAR_TEAM = "%s"\n' "$1" >"$PROJECT/vstack.settings.toml"
}

clear_settings() {
  rm -f "$PROJECT/vstack.settings.toml"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

assert_no_guessed_team() {
  local label="$1"
  jq -s -e 'all(.[]; (.variables | tostring | contains("team")) | not)' "$CURL_LOG" >/dev/null ||
    fail "$label sent a team filter with no configured team: $(cat "$CURL_LOG")"
  if grep -riq "claude" "$CURL_LOG"; then
    fail "$label carried a guessed team name: $(cat "$CURL_LOG")"
  fi
}

assert_refused() {
  local label="$1"
  [[ "$RC" -ne 0 ]] || fail "$label exited 0; expected a refusal. stdout: $OUT"
  grep -q "No Linear team configured" <<<"$ERR" || fail "$label missing refusal message: $ERR"
  grep -q "LINEAR_TEAM" <<<"$ERR" || fail "$label refusal does not name LINEAR_TEAM: $ERR"
  grep -q "vstack.settings.toml" <<<"$ERR" || fail "$label refusal does not name vstack.settings.toml: $ERR"
  grep -q -- "--team" <<<"$ERR" || fail "$label refusal does not mention --team: $ERR"
  [[ "$(api_calls)" == "0" ]] || fail "$label attempted $(api_calls) API call(s) before refusing"
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

echo "=== a blank configured value stays unset (seeded template is inert) ==="

set_settings_team ""
run_linear issues create --title "Blank team"
assert_refused "issues create with blank LINEAR_TEAM"

echo "=== help never needs a team target ==="

run_linear issues create --help
[[ "$RC" -eq 0 ]] || fail "issues create --help exited $RC: $ERR"
grep -q "Create Options:" <<<"$OUT" || fail "issues create --help did not print help: $OUT"

echo "=== explicit --team satisfies the requirement ==="

clear_settings
run_linear issues create --title "Explicit target" --team Explicit
[[ "$RC" -eq 0 ]] || fail "issues create --team exited $RC: $ERR"
jq -s -e 'any(.[]; (.query | contains("teams(filter:")) and .variables.name == "Explicit")' "$CURL_LOG" >/dev/null ||
  fail "explicit --team was not used to resolve the team"
jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.teamId == "team-uuid")' "$CURL_LOG" >/dev/null ||
  fail "issueCreate did not carry the resolved team id"

echo "=== configured LINEAR_TEAM proceeds ==="

set_settings_team "Configured"
run_linear issues create --title "Configured target"
[[ "$RC" -eq 0 ]] || fail "issues create with configured team exited $RC: $ERR"
jq -s -e 'any(.[]; (.query | contains("teams(filter:")) and .variables.name == "Configured")' "$CURL_LOG" >/dev/null ||
  fail "configured LINEAR_TEAM was not used"

run_linear comments create TEAM-1 --body "hello"
[[ "$RC" -eq 0 ]] || fail "comments create with configured team exited $RC: $ERR"
jq -s -e 'any(.[]; .query | contains("commentCreate"))' "$CURL_LOG" >/dev/null ||
  fail "comments create did not reach the API with a configured team"

echo "=== reads never send a guessed team ==="

clear_settings

run_linear statuses list
[[ "$RC" -eq 0 ]] || fail "statuses list exited $RC: $ERR"
assert_no_guessed_team "statuses list"

run_linear cycles list --type current
[[ "$RC" -eq 0 ]] || fail "cycles list exited $RC: $ERR"
jq -s -e 'all(.[]; (.query | contains("teams(filter:")) | not)' "$CURL_LOG" >/dev/null ||
  fail "cycles list resolved a team with no configured team"
assert_no_guessed_team "cycles list"

run_linear statuses get --name "In Progress"
[[ "$RC" -eq 0 ]] || fail "statuses get exited $RC: $ERR"
assert_no_guessed_team "statuses get"

run_linear issues list --limit 5
[[ "$RC" -eq 0 ]] || fail "issues list exited $RC: $ERR"
assert_no_guessed_team "issues list"

# The team filter is still applied when one is configured.
set_settings_team "Configured"
run_linear cycles list --type current
[[ "$RC" -eq 0 ]] || fail "cycles list with configured team exited $RC: $ERR"
jq -s -e 'any(.[]; (.query | contains("teams(filter:")) and .variables.name == "Configured")' "$CURL_LOG" >/dev/null ||
  fail "cycles list did not resolve the configured team"
jq -s -e 'any(.[]; .variables.filter.team.id.eq == "team-uuid")' "$CURL_LOG" >/dev/null ||
  fail "cycles list did not scope to the configured team: $(cat "$CURL_LOG")"

run_linear statuses list
jq -s -e 'any(.[]; .variables.filter.team.name.eq == "Configured")' "$CURL_LOG" >/dev/null ||
  fail "statuses list did not scope to the configured team: $(cat "$CURL_LOG")"
clear_settings

run_linear sync --full --no-attachments
[[ "$(api_calls)" != "0" ]] || fail "sync issued no requests; the assertion below would be vacuous"
assert_no_guessed_team "sync"
jq -s -e 'any(.[]; .query | contains("SyncCycles"))' "$CURL_LOG" >/dev/null ||
  fail "sync did not query cycles"

set_settings_team "Configured"
run_linear sync --full --no-attachments
jq -s -e 'any(.[]; (.query | contains("SyncCycles")) and .variables.teamName == "Configured")' "$CURL_LOG" >/dev/null ||
  fail "sync did not scope cycles to the configured team: $(cat "$CURL_LOG")"
clear_settings

echo "=== graphql_query refuses any mutation without a target ==="

: >"$CURL_LOG"
set +e
backstop_err="$(cd "$PROJECT" && env -u LINEAR_TEAM \
  PATH="$PROJECT/bin:$PATH" \
  LINEAR_API_KEY=test-token \
  CURL_LOG="$CURL_LOG" \
  bash -c 'source .agents/skills/linear/scripts/lib/common.sh
graphql_query "
    mutation UnregisteredWrite(\$input: IssueCreateInput!) { issueCreate(input: \$input) { success } }" "{}"' 2>&1)"
backstop_rc=$?
set -e
[[ "$backstop_rc" -ne 0 ]] || fail "graphql_query allowed a mutation with no team target"
grep -q "No Linear team configured" <<<"$backstop_err" || fail "graphql_query refusal message missing: $backstop_err"
[[ "$(api_calls)" == "0" ]] || fail "graphql_query issued a request before refusing"

: >"$CURL_LOG"
set +e
(cd "$PROJECT" && env -u LINEAR_TEAM \
  PATH="$PROJECT/bin:$PATH" \
  LINEAR_API_KEY=test-token \
  CURL_LOG="$CURL_LOG" \
  bash -c 'source .agents/skills/linear/scripts/lib/common.sh
graphql_query "query Ping { viewer { id } }" "{}"' >/dev/null 2>&1)
read_rc=$?
set -e
[[ "$read_rc" -eq 0 ]] || fail "graphql_query blocked a read with no team target"
[[ "$(api_calls)" == "1" ]] || fail "read query did not reach the API: $(api_calls) call(s)"

echo "=== auth-check reports the target ==="

clear_settings
run_linear auth-check
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with a valid key: $ERR"
jq -e '.ok == true and .team == null and .team_source == "unset" and .writes_enabled == false' <<<"$OUT" >/dev/null ||
  fail "auth-check did not report an unresolved team: $OUT"
jq -e '.api_key_source == "environment"' <<<"$OUT" >/dev/null ||
  fail "auth-check did not attribute the API key to the environment: $OUT"
jq -e '[.warnings[] | select(contains("LINEAR_TEAM"))] | length > 0' <<<"$OUT" >/dev/null ||
  fail "auth-check did not warn about the missing team: $OUT"
jq -e '[.warnings[] | select(contains("process environment"))] | length > 0' <<<"$OUT" >/dev/null ||
  fail "auth-check did not flag the global key with no project team: $OUT"

run_linear auth-check --strict
[[ "$RC" -ne 0 ]] || fail "auth-check --strict exited 0 with no team configured: $OUT"

set_settings_team "Configured"
run_linear auth-check --strict
[[ "$RC" -eq 0 ]] || fail "auth-check --strict exited $RC with a configured team: $OUT $ERR"
jq -e '.team == "Configured" and .team_source == "project-config" and .writes_enabled == true and (.warnings | length) == 0' <<<"$OUT" >/dev/null ||
  fail "auth-check did not report the configured team: $OUT"
jq -e '.team_source_file == "vstack.settings.toml"' <<<"$OUT" >/dev/null ||
  fail "auth-check did not name the file that set the team: $OUT"

run_linear_env_team "EnvTeam" auth-check
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with an exported team: $ERR"
jq -e '.team == "EnvTeam" and .team_source == "environment" and .writes_enabled == true' <<<"$OUT" >/dev/null ||
  fail "auth-check did not report the exported team: $OUT"
jq -e '[.warnings[] | select(contains("overrides the project value"))] | length > 0' <<<"$OUT" >/dev/null ||
  fail "auth-check did not warn that the environment shadows project config: $OUT"

echo "all pass"
