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
#
# One table. A row is one command line and what it left behind, rendered as
# one line: the exit status, every logged operation with the milestone
# reference it carried (a lookup's name and project scope, a mutation's
# projectMilestoneId), then stderr whole, so a refusal is pinned on its entire
# line and a proceed on the milestone it filed under and the lookups it made.

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
  else
    case "$project/$name" in
    # The project --project names.
    live-uuid/Alpha) printf '%s' '{"data":{"projectMilestones":{"nodes":[{"id":"alpha-here"}]}}}___HTTP_CODE___200' ;;
    # The project ISS-1 is already in. Its Alpha is a different milestone, so
    # a case that passes --project proves which of the two won.
    old-uuid/Alpha) printf '%s' '{"data":{"projectMilestones":{"nodes":[{"id":"alpha-old"}]}}}___HTTP_CODE___200' ;;
    live-uuid/Twin) printf '%s' '{"data":{"projectMilestones":{"nodes":[{"id":"twin-one"},{"id":"twin-two"}]}}}___HTTP_CODE___200' ;;
    live-uuid/Boom) printf '%s' '{"errors":[{"message":"Rate limited"}]}___HTTP_CODE___200' ;;
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
    printf '%s' '{"data":{"issue":{"id":"iss-uuid","identifier":"ISS-1","team":{"id":"team-uuid"},"project":{"id":"old-uuid","name":"Old"}}}}___HTTP_CODE___200'
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

# --- the renderer -------------------------------------------------------------
# Every payload the fake curl logged, as `Operation(key=value,...)`: the named
# operation, with the lookup's name and projectId and the mutation's
# projectMilestoneId; a file upload is its bare `FileUpload()`, so the order
# of a refusal against an upload is on the line.
wire() {
  jq -r '
    def op: (.query | capture("^[[:space:]]*(query|mutation)[[:space:]]+(?<n>[A-Za-z_]+)").n)
      // (.query | capture("\\{[[:space:]]*(?<n>[A-Za-z_]+)").n);
    def shown: [(.variables // {}) as $v | $v | paths(scalars) as $p
      | select($p == ["name"] or $p == ["projectId"] or $p == ["input", "projectMilestoneId"])
      | "\($p | join("."))=\($v | getpath($p))"];
    "\(op)(\(shown | join(",")))"' "$CURL_LOG" | paste -sd, -
}

# run ARGS... — one command in the project, rendered.
run() {
  local rc=0 err
  : >"$CURL_LOG"
  (cd "$PROJECT" && CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam "$LINEAR" "$@") >"$TMP_ROOT/out.txt" 2>"$TMP_ROOT/err" || rc=$?
  err="$(sed "s#$TMP_ROOT#<root>#g" "$TMP_ROOT/err" | paste -sd';' -)"
  printf 'rc=%s wire=%s%s' "$rc" "$(wire)" "${err:+ $err}"
}

# --- the expected lines --------------------------------------------------------
# expected RC WIRE MESSAGE — the line a row expects. MESSAGE is `-` (nothing
# on stderr), or one of ambiguous:NAME, unscoped:NAME, failed:NAME,
# notfound:NAME, unreadable:FILE, each the resolver's or the preflight's line.
expected() {
  local msg
  case "$3" in
  -) msg="" ;;
  ambiguous:*) msg="$(printf ' {"error":"Milestone name is ambiguous within the project: \\"%s\\" matches twin-one, twin-two; pass a milestone UUID to target one)"}' "${3#*:}")" ;;
  unscoped:*) msg="$(printf ' {"error":"Cannot resolve milestone \\"%s\\" without a project: the same milestone name exists in other projects. Pass --project, or pass the milestone UUID."}' "${3#*:}")" ;;
  failed:*) msg="$(printf ' {"error":"Rate limited"};{"error":"Could not resolve milestone \\"%s\\": Linear API request failed (see previous error)"}' "${3#*:}")" ;;
  notfound:*) msg="$(printf ' {"error":"Milestone not found: %s"}' "${3#*:}")" ;;
  unreadable:*) msg="$(printf ' {"error":"--attach path not readable: <root>/%s"}' "${3#*:}")" ;;
  esac
  printf 'rc=%s wire=%s%s' "$1" "$2" "$msg"
}

# --- the table ------------------------------------------------------------------
# label|args|rc|wire|message
# CREATE is the create up to its milestone; the fixture answers the project
# lookup first because the resolvers are hoisted ahead of the team and label
# ones. --attach rows put an asset behind the resolution: a refusal that lands
# after the upload strands the asset in Linear storage with no issue
# referencing it. The ambiguity rows need the lookup, not just the arguments,
# so they are the ones proving the whole resolution runs ahead of the upload.
CREATE='issues create --title t --team TestTeam --labels agent:rust --priority 3 --description d'
printf 'x' >"$TMP_ROOT/asset.bin"
ROWS='
issues create files the issue under the project own milestone|$CREATE --project Dup --milestone Alpha|0|GetProject(name=Dup),GetMilestone(name=Alpha,projectId=live-uuid),GetTeam(name=TestTeam),GetLabel(name=agent:rust),CreateIssue(input.projectMilestoneId=alpha-here)|-
--project wins over the project the issue is already in|issues update ISS-1 --project Dup --milestone Alpha|0|GetIssue(),GetProject(name=Dup),GetMilestone(name=Alpha,projectId=live-uuid),UpdateIssue(input.projectMilestoneId=alpha-here)|-
two milestones of that name in the project is a refusal, not a pick|$CREATE --project Dup --milestone Twin|1|GetProject(name=Dup),GetMilestone(name=Twin,projectId=live-uuid)|ambiguous:Twin
a failed lookup reports the API failure, not a miss|$CREATE --project Dup --milestone Boom|1|GetProject(name=Dup),GetMilestone(name=Boom,projectId=live-uuid)|failed:Boom
an unmatched name reports a miss, not an API failure|$CREATE --project Dup --milestone Ghost|1|GetProject(name=Dup),GetMilestone(name=Ghost,projectId=live-uuid)|notfound:Ghost
a milestone name with no project to scope it is refused before any lookup|$CREATE --milestone Alpha|1||unscoped:Alpha
issues update scopes the name to the issue own project|issues update ISS-1 --milestone Alpha|0|GetIssue(),GetMilestone(name=Alpha,projectId=old-uuid),UpdateIssue(input.projectMilestoneId=alpha-old)|-
a milestone UUID needs no project and no lookup|issues update ISS-2 --milestone 11111111-2222-3333-4444-555555555555|0|GetIssue(),UpdateIssue(input.projectMilestoneId=11111111-2222-3333-4444-555555555555)|-
an uppercase UUID is a UUID too|issues update ISS-2 --milestone 11111111-2222-3333-4444-5555555555AA|0|GetIssue(),UpdateIssue(input.projectMilestoneId=11111111-2222-3333-4444-5555555555AA)|-
a project-less name refuses the create before its upload|$CREATE --milestone Alpha --attach $TMP_ROOT/asset.bin|1||unscoped:Alpha
a name refuses the update of an issue in no project before its upload|issues update ISS-2 --milestone Alpha --attach $TMP_ROOT/asset.bin|1|GetIssue()|unscoped:Alpha
an unreadable --attach path refuses before any lookup|$CREATE --project Dup --milestone Alpha --attach $TMP_ROOT/nope.bin|1||unreadable:nope.bin
an ambiguous name refuses the create before its upload|$CREATE --project Dup --milestone Twin --attach $TMP_ROOT/asset.bin|1|GetProject(name=Dup),GetMilestone(name=Twin,projectId=live-uuid)|ambiguous:Twin
an ambiguous name refuses the update before its upload|issues update ISS-1 --project Dup --milestone Twin --attach $TMP_ROOT/asset.bin|1|GetIssue(),GetProject(name=Dup),GetMilestone(name=Twin,projectId=live-uuid)|ambiguous:Twin
'

while IFS='|' read -r label args rc wire msg; do
  [ -n "$label" ] || continue
  eval "set -- $args"
  assert_eq "$label" "$(run "$@")" "$(expected "$rc" "$wire" "$msg")"
done <<<"$ROWS"
