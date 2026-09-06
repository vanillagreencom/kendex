#!/usr/bin/env bash
# resolve_milestone_id resolves a milestone name inside one project, refuses an
# ambiguous match, and tells an API failure from a genuine miss.
#
# A milestone name is unique to its project and nothing more, and the name query
# was unscoped, so `--milestone Alpha` took whichever project's Alpha the API
# listed first and filed the issue under it reporting success. The same function
# left graphql_query's exit status unchecked, so a rate limit or an outage
# reported "Milestone not found" — the wrong cause. The fixture returns the
# foreign milestone first whenever the query arrives unscoped, which is the
# order the old code got wrong.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited the `git init` below re-inits
# the ambient repository instead of the fixture. All four go, which is the house
# rule in the repository's AGENTS.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this throwaway
# root so cache writes stay out of the real project's .cache/linear.
git -C "$PROJECT" init -q -b main
if [[ ! -d "$PROJECT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $PROJECT/.git: a git environment variable redirected git init"
fi

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

# The milestone fixture answers on the SHAPE of the query, not on a variable:
# a lookup that carries no project filter is one Linear answers from every
# project, and it lists the foreign Alpha first.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid","name":"TestTeam"}]}}}___HTTP_CODE___200'
  ;;
*"projects(filter:"*)
  printf '%s' '{"data":{"projects":{"nodes":[{"id":"live-uuid","state":"backlog"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"projectMilestones(filter:"*)
  name="$(jq -r '.variables.name // empty' <<<"$payload")"
  project="$(jq -r '.variables.projectId // empty' <<<"$payload")"
  scoped=no
  case "$query" in *"project: {id:"*) scoped=yes ;; esac
  if [ "$scoped" = no ]; then
    printf '%s' '{"data":{"projectMilestones":{"nodes":[{"id":"alpha-elsewhere"},{"id":"alpha-here"}]}}}___HTTP_CODE___200'
  elif [ "$project" != "live-uuid" ]; then
    printf '%s' '{"data":{"projectMilestones":{"nodes":[]}}}___HTTP_CODE___200'
  else
    case "$name" in
    Alpha) printf '%s' '{"data":{"projectMilestones":{"nodes":[{"id":"alpha-here"}]}}}___HTTP_CODE___200' ;;
    Twin) printf '%s' '{"data":{"projectMilestones":{"nodes":[{"id":"twin-one"},{"id":"twin-two"}]}}}___HTTP_CODE___200' ;;
    Boom) printf '%s' '{"errors":[{"message":"Rate limited"}]}___HTTP_CODE___200' ;;
    *) printf '%s' '{"data":{"projectMilestones":{"nodes":[]}}}___HTTP_CODE___200' ;;
    esac
  fi
  ;;
*"issues(filter:"* | *"issue(id:"*)
  # ISS-1 is in a project; ISS-2 is in none, which is the only issue a
  # milestone name on the update path can still be refused for.
  if [ "$(jq -r '.variables.id // empty' <<<"$payload")" = "ISS-2" ]; then
    printf '%s' '{"data":{"issue":{"id":"iss2-uuid","identifier":"ISS-2","team":{"id":"team-uuid"},"project":null}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"issue":{"id":"iss-uuid","identifier":"ISS-1","team":{"id":"team-uuid"},"project":{"id":"live-uuid","name":"Dup"}}}}___HTTP_CODE___200'
  fi
  ;;
*"fileUpload"*)
  printf '%s' '{"data":{"fileUpload":{"success":false}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-900","title":"t","description":"d","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"live-uuid","name":"Dup"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"TestTeam"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-900","createdAt":"2026-09-02T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*"issueUpdate"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"iss-uuid","identifier":"ISS-1"}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

run_linear() {
  ( cd "$PROJECT" \
    && CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" \
       LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
       "$LINEAR" "$@" ) >"$TMP_ROOT/out.txt" 2>"$ERR_FILE"
}

create_with_milestone() {
  run_linear issues create --title t --team TestTeam --project Dup \
    --labels agent:rust --priority 3 --description d --milestone "$1"
}

update_with_milestone() {
  run_linear issues update ISS-1 --project Dup --milestone "$1"
}

# Surface: create resolves the milestone inside the project it just resolved.
: >"$CURL_LOG"
run_status create_rc create_with_milestone Alpha
assert_eq "issues create succeeds with a project-scoped milestone name" "$create_rc" 0
assert "issues create files the issue under the project's own milestone" \
  jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.projectMilestoneId == "alpha-here")' \
  "$CURL_LOG" >/dev/null

# Surface: update resolves the milestone inside the project it just resolved.
: >"$CURL_LOG"
run_status update_rc update_with_milestone Alpha
assert_eq "issues update succeeds with a project-scoped milestone name" "$update_rc" 0
assert "issues update sets the project's own milestone" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.input.projectMilestoneId == "alpha-here")' \
  "$CURL_LOG" >/dev/null

# Surface: two milestones of that name in the project is a refusal, not a pick.
: >"$CURL_LOG"
run_status twin_rc create_with_milestone Twin
assert_ne "an ambiguous milestone name refuses the create" "$twin_rc" 0
assert_file_contains "the ambiguity refusal names the first candidate UUID" "$ERR_FILE" "twin-one"
assert_file_contains "the ambiguity refusal names the second candidate UUID" "$ERR_FILE" "twin-two"
assert_file_lacks "no issue is created for an ambiguous milestone" "$CURL_LOG" "issueCreate"

# Surface: a failed lookup is an API failure, a successful empty one is a miss.
: >"$CURL_LOG"
run_status boom_rc create_with_milestone Boom
assert_ne "a failed milestone lookup refuses the create" "$boom_rc" 0
assert_file_contains "a failed lookup reports the API failure" "$ERR_FILE" "Could not resolve milestone"

: >"$CURL_LOG"
run_status ghost_rc create_with_milestone Ghost
assert_ne "an unmatched milestone name refuses the create" "$ghost_rc" 0
assert_file_contains "an unmatched name reports a miss, not an API failure" "$ERR_FILE" "Milestone not found"

# Surface: a milestone name with no project to scope it is refused.
: >"$CURL_LOG"
run_status unscoped_rc run_linear issues create --title t --team TestTeam \
  --labels agent:rust --priority 3 --description d --milestone Alpha
assert_ne "a milestone name without a project refuses the create" "$unscoped_rc" 0
assert_file_contains "the refusal names the missing project" "$ERR_FILE" "without a project"
assert_file_lacks "no milestone lookup is sent without a project to scope it" \
  "$CURL_LOG" "projectMilestones"

# Surface: on update, the issue's own project scopes the name. Asking for
# --project to name the project the issue is already in would move it to
# satisfy a lookup.
: >"$CURL_LOG"
run_status own_project_rc run_linear issues update ISS-1 --milestone Alpha
assert_eq "issues update succeeds without --project on an issue that has one" "$own_project_rc" 0
assert "issues update scopes the name to the issue's own project" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.input.projectMilestoneId == "alpha-here")' \
  "$CURL_LOG" >/dev/null

# Surface: the refusal is decided from the arguments, so it lands before
# --attach uploads. A refusal after an upload strands the asset in Linear
# storage with no issue referencing it.
printf 'x' >"$TMP_ROOT/asset.bin"

: >"$CURL_LOG"
run_status create_attach_rc run_linear issues create --title t --team TestTeam \
  --labels agent:rust --priority 3 --description d --milestone Alpha \
  --attach "$TMP_ROOT/asset.bin"
assert_ne "a project-less milestone name refuses the create that carries --attach" \
  "$create_attach_rc" 0
assert_file_lacks "no upload is sent before the create refusal" "$CURL_LOG" "fileUpload"

: >"$CURL_LOG"
run_status update_attach_rc run_linear issues update ISS-2 --milestone Alpha \
  --attach "$TMP_ROOT/asset.bin"
assert_ne "a milestone name refuses the update of an issue in no project" \
  "$update_attach_rc" 0
assert_file_lacks "no upload is sent before the update refusal" "$CURL_LOG" "fileUpload"
