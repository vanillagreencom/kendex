#!/usr/bin/env bash
# The Linear CLI never substitutes a guessed team.
#
# A team name resolves inside whatever workspace LINEAR_API_KEY reaches, so a
# hardcoded default silently targets another project's tracker. With no team
# configured, a write refuses before any API call, a read drops the team
# filter, and auth-check reports the target it would use.
#
# One table. A row names the project's settings file, the exported LINEAR_TEAM,
# the command, and everything the command left behind, rendered as one line:
# the exit status, the count of API calls, every call's operation with the
# team it scoped to (`SyncCycles(teamName="Configured")`; `ListIssues()` is a
# call that named no team anywhere in its variables or its document), then
# stderr whole, or for an auth-check row its report's fields and warnings whole.

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

# --- the fixture vocabulary --------------------------------------------------
# settings: what kendex.settings.toml holds when the command runs.
settings() {
  case "$1" in
  none) rm -f "$PROJECT/kendex.settings.toml" ;;
  blank) printf '[env]\nLINEAR_TEAM = ""\n' >"$PROJECT/kendex.settings.toml" ;;
  dup) printf '[env]\nLINEAR_TEAM = "Partial"\nDUP = "a"\nDUP = "b"\n' >"$PROJECT/kendex.settings.toml" ;;
  *) printf '[env]\nLINEAR_TEAM = "%s"\n' "$1" >"$PROJECT/kendex.settings.toml" ;;
  esac
}

# --- the renderer -------------------------------------------------------------
# Every payload the fake curl logged, as `Operation(path=value,...)`: the
# operation is the document's named operation, or its first field for an
# anonymous one; the values are every variable whose path mentions a team, the
# top-level name a lookup resolves, the body or title a write carries, and
# `inline-team` when the document itself carries a team filter, which is where
# sync puts its scoping. `ListIssues()` is a call that named no team anywhere.
wire() {
  jq -r '
    def op: (.query | capture("^[[:space:]]*(query|mutation)[[:space:]]+(?<n>[A-Za-z_]+)").n)
      // (.query | capture("\\{[[:space:]]*(?<n>[A-Za-z_]+)").n);
    def shown: [(.variables // {}) as $v | $v | paths(scalars) as $p
      | select(($p | map(tostring) | any(test("team"; "i")))
          or $p == ["name"] or $p == ["input", "body"] or $p == ["input", "title"])
      | "\($p | map(tostring) | join("."))=\($v | getpath($p) | tojson)"]
      + (if (.query | test("team[A-Za-z]*[[:space:]]*:"; "i")) then ["inline-team"] else [] end)
      + (if (tostring | test("claude"; "i")) then ["guessed-name"] else [] end);
    "\(op)(\(shown | join(",")))"' "$CURL_LOG" | paste -sd, -
}

# An auth-check report as its fields, then its warnings whole.
auth_view() {
  jq -r '"ok=\(.ok) team=\(.team) source=\(.team_source) file=\(.team_source_file) key=\(.api_key_source) writes=\(.writes_enabled)",
    .warnings[]' <<<"$1" | paste -sd';' -
}

# run SETTINGS ENV VIEW ARGS... — one command in the project, rendered as one
# line: the status, the call count, then the view. ENV is `-` (LINEAR_TEAM
# absent from the process) or the exported value, the empty string included.
# VIEW: `err` is the wire and stderr whole; `wire` is the wire alone (sync's
# progress line carries an elapsed time); `out` is the first stdout line (help
# prints one document); `auth` is the report's fields and warnings.
run() {
  local fixture="$1" envteam="$2" view="$3" rc=0 out err calls
  shift 3
  settings "$fixture"
  : >"$CURL_LOG"
  if [ "$envteam" = "-" ]; then
    out="$(cd "$PROJECT" && env -u LINEAR_TEAM PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=test-token \
      CURL_LOG="$CURL_LOG" bash "$LINEAR" "$@" 2>"$TMP_ROOT/err")" || rc=$?
  else
    out="$(cd "$PROJECT" && env LINEAR_TEAM="$envteam" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=test-token \
      CURL_LOG="$CURL_LOG" bash "$LINEAR" "$@" 2>"$TMP_ROOT/err")" || rc=$?
  fi
  err="$(sed "s#$PROJECT#<project>#g" "$TMP_ROOT/err" | paste -sd';' -)"
  calls="$(wc -l <"$CURL_LOG" | tr -d ' ')"
  case "$view" in
  auth) printf 'rc=%s calls=%s %s' "$rc" "$calls" "$(auth_view "$out")" ;;
  out) printf 'rc=%s calls=%s %s' "$rc" "$calls" "$(printf '%s\n' "$out" | head -1)" ;;
  wire) printf 'rc=%s calls=%s wire=%s' "$rc" "$calls" "$(wire)" ;;
  err) printf 'rc=%s calls=%s wire=%s%s' "$rc" "$calls" "$(wire)" "${err:+ $err}" ;;
  *) printf 'UNKNOWN-VIEW:%s' "$view" ;;
  esac
}

# graphql MODE — the wire backstop: graphql_query sourced with no dispatcher
# guard in front of it, no team configured.
graphql() {
  local doc rc=0 err
  case "$1" in
  mutation) doc='mutation UnregisteredWrite($input: IssueCreateInput!) { issueCreate(input: $input) { success } }' ;;
  read) doc='query Ping { viewer { id } }' ;;
  esac
  settings none
  : >"$CURL_LOG"
  (cd "$PROJECT" && env -u LINEAR_TEAM PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=test-token CURL_LOG="$CURL_LOG" \
    bash -c 'source .agents/skills/linear/scripts/lib/common.sh; graphql_query "$1" "{}"' _ "$doc" >/dev/null 2>"$TMP_ROOT/err") || rc=$?
  err="$(paste -sd';' "$TMP_ROOT/err")"
  printf 'rc=%s calls=%s wire=%s%s' "$rc" "$(wc -l <"$CURL_LOG" | tr -d ' ')" "$(wire)" "${err:+ $err}"
}

# --- the expected lines --------------------------------------------------------
REFUSAL='{"error": "No Linear team configured for this project - refusing to write. A team name resolves inside whatever workspace LINEAR_API_KEY reaches, so writing without one can land in another project tracker. Fix: set LINEAR_TEAM in this project kendex.settings.toml [env] (committed, non-secret) or .env.local. The create actions that take a team (issues, projects, cycles, labels) also accept --team <name> for one call. Verify with: linear.sh auth-check --strict"}'
REDIRECT='Error: Comments are a separate resource. Use:;  linear.sh comments create [ISSUE_ID] --body "Your comment";  linear.sh cache comments list [ISSUE_ID]'
W_NOTEAM='No LINEAR_TEAM configured: Linear writes are refused. Set LINEAR_TEAM in kendex.settings.toml [env] (committed, non-secret) or .env.local.'
W_ENVKEY='LINEAR_API_KEY comes from the process environment (a machine-wide key reaches every workspace it owns) while this project names no team. Until LINEAR_TEAM is set, this project has no Linear target of its own.'
w_shadow() { printf 'LINEAR_TEAM from the process environment ("%s") overrides the project value ("%s"). Writes go to the environment value.' "$1" "$2"; }
w_empty() { printf 'LINEAR_TEAM is exported as an empty value, which overrides the project value ("%s"). Unset it in the environment to use project configuration.' "$1"; }

# expected SPEC — the line a row expects, from its spec:
#   refused            the gate's line, before any call
#   redirect           the issues-comment redirect, before any call
#   help               one help document, no call
#   ok-parse           the action's own unknown-option line for --help, no call
#   ok WIRE            exit 0, one call per operation in WIRE
#   auth RC TEAM SOURCE FILE WRITES [WARNING...]   the report (one call);
#                      a warning is noteam, envkey, shadow:ENV:PROJECT or
#                      empty:PROJECT
#   settings-refused   the loader's refusal of the settings file
expected() {
  local spec="$1" wire w
  case "$spec" in
  refused) printf 'rc=1 calls=0 wire= %s' "$REFUSAL" ;;
  redirect) printf 'rc=1 calls=0 wire= %s' "$REDIRECT" ;;
  help) printf 'rc=0 calls=0 Issue Operations' ;;
  ok-parse) printf 'rc=1 calls=0 wire= {"error": "Unknown option: --help. Run --help for valid options."}' ;;
  ok\ *)
    wire="${spec#ok }"
    printf 'rc=0 calls=%s wire=%s' "$(printf '%s' "$wire" | tr -cd ')' | wc -c | tr -d ' ')" "$wire"
    ;;
  auth\ *)
    # shellcheck disable=SC2086  # the spec's fields are its words
    set -- ${spec#auth }
    printf 'rc=%s calls=1 ok=true team=%s source=%s file=%s key=environment writes=%s' "$1" "$2" "$3" "$4" "$5"
    shift 5
    for w in "$@"; do
      case "$w" in
      noteam) printf ';%s' "$W_NOTEAM" ;;
      envkey) printf ';%s' "$W_ENVKEY" ;;
      shadow:*) printf ';%s' "$(w_shadow "$(cut -d: -f2 <<<"$w")" "$(cut -d: -f3 <<<"$w")")" ;;
      empty:*) printf ';%s' "$(w_empty "${w#empty:}")" ;;
      esac
    done
    ;;
  settings-refused)
    printf 'rc=1 calls=0 wire= ::error::<project>/kendex.settings.toml: DUP is assigned more than once in [env] (each key must be unique in the table)'
    ;;
  *) printf 'UNKNOWN-SPEC:%s' "$spec" ;;
  esac
}

# --- the table ------------------------------------------------------------------
# label|settings|env|view|args|expect
# settings: none, blank (the seeded template's empty value), dup (a file the
# loader refuses), or the team name the file declares. env: `-` for no
# LINEAR_TEAM in the process, else the exported value. args is one command
# line, quoted as a shell would. expect is a spec for `expected`.
ROWS='
issues create is refused|none|-|err|issues create --title "Cross-workspace write"|refused
issues update is refused|none|-|err|issues update TEAM-1 --state Done|refused
issues complete is refused|none|-|err|issues complete TEAM-1|refused
issues archive is refused|none|-|err|issues archive TEAM-1|refused
issues add-relation is refused|none|-|err|issues add-relation TEAM-1 --blocks TEAM-2|refused
comments create is refused|none|-|err|comments create TEAM-1 --body hello|refused
projects create is refused|none|-|err|projects create --name "New project"|refused
cycles create is refused|none|-|err|cycles create --start 2026-08-01 --end 2026-08-15|refused
labels create is refused|none|-|err|labels create --name backend|refused
milestones create is refused|none|-|err|milestones create --project P --name Alpha|refused
initiatives create is refused|none|-|err|initiatives create --name "Phase 1"|refused
a --team=CC comment body is free text, not a target|none|-|err|comments create TEAM-1 --body "--team=CC"|refused
a bare --team comment body is free text|none|-|err|comments create TEAM-1 --body "--team"|refused
--team inside comment prose is free text|none|-|err|comments create TEAM-1 --body "see --team CC for context"|refused
a bare --team title on update is free text|none|-|err|issues update TEAM-1 --title "--team" --state Done|refused
a --team=CC title on update is free text|none|-|err|issues update TEAM-1 --title "--team=CC" --state Done|refused
a --team=CC title on create is free text|none|-|err|issues create --title "--team=CC"|refused
the issues comment redirect makes no call|none|-|err|issues comment TEAM-1 --body "--team=CC"|redirect
a blank configured value stays unset|blank|-|err|issues create --title "Blank team"|refused
an exported empty LINEAR_TEAM shadows the project file and refuses|Configured||err|issues create --title "Empty export"|refused
issues --help needs no team, whatever the action (issues answers it before the gate)|none|-|out|issues update --help|help
the --help of a guarded action passes the dispatcher gate to its own parser|none|-|err|cycles update --help|ok-parse
an explicit --team resolves that team and creates under it|none|-|err|issues create --title "Explicit target" --team Explicit|ok GetTeam(name="Explicit"),CreateIssue(input.title="Explicit target",input.teamId="team-uuid")
a configured LINEAR_TEAM is the team resolved|Configured|-|err|issues create --title "Configured target"|ok GetTeam(name="Configured"),CreateIssue(input.title="Configured target",input.teamId="team-uuid")
comments create reaches the API with a configured team|Configured|-|err|comments create TEAM-1 --body hello|ok CreateComment(input.body="hello\n")
a --team-shaped body is written verbatim under a configured team|Configured|-|err|comments create TEAM-1 --body "--team=CC"|ok CreateComment(input.body="--team=CC\n")
projects create --team resolves its target after parsing|none|-|err|projects create --name P --team Explicit|ok GetTeam(name="Explicit"),CreateProject(input.teamIds.0="team-uuid")
cycles create --team resolves its target after parsing|none|-|err|cycles create --start 2026-08-01 --end 2026-08-15 --team Explicit|ok GetTeam(name="Explicit"),CreateCycle(input.teamId="team-uuid")
labels create --team resolves its target after parsing|none|-|err|labels create --name backend --team Explicit|ok GetTeam(name="Explicit"),CreateLabel(input.teamId="team-uuid")
labels create with no --team scopes the label to no team it was not asked for|Configured|-|err|labels create --name backend|ok CreateLabel()
statuses list sends no guessed team|none|-|err|statuses list|ok ListStates()
cycles list resolves no team and filters on none|none|-|err|cycles list --type current|ok ListCycles()
statuses get sends no guessed team|none|-|err|statuses get --name "In Progress"|ok GetState()
issues list sends no guessed team|none|-|err|issues list --limit 5|ok ListIssues()
cycles list scopes to the configured team|Configured|-|err|cycles list --type current|ok GetTeam(name="Configured"),ListCycles(filter.team.id.eq="team-uuid")
statuses list scopes to the configured team|Configured|-|err|statuses list|ok ListStates(filter.team.name.eq="Configured")
sync inlines no team into any document with no team configured|none|-|wire|sync --full --no-attachments|ok SyncIssues(),SyncComments(),SyncProjects(),SyncCycles(),SyncInitiatives(),SyncLabels()
sync scopes cycles to the configured team, in the document and its variables|Configured|-|wire|sync --full --no-attachments|ok SyncIssues(),SyncComments(),SyncProjects(),SyncCycles(teamName="Configured",inline-team),SyncInitiatives(),SyncLabels()
auth-check reports an unresolved team and the global key|none|-|auth|auth-check|auth 0 null unset null false noteam envkey
auth-check --strict fails on an unresolved team|none|-|auth|auth-check --strict|auth 1 null unset null false noteam envkey
auth-check --strict names the configured team and its file|Configured|-|auth|auth-check --strict|auth 0 Configured project-config kendex.settings.toml true
an exported team is reported from the environment, shadowing the file|Configured|EnvTeam|auth|auth-check|auth 0 EnvTeam environment null true shadow:EnvTeam:Configured
an exported empty team is unset, names no file, and says what it shadows|Configured||auth|auth-check|auth 0 null unset null false noteam empty:Configured envkey
a refused settings file runs no command|dup|-|err|auth-check|settings-refused
'

while IFS='|' read -r label fixture envteam view args spec; do
  [ -n "$label" ] || continue
  eval "set -- $args"
  assert_eq "$label" "$(run "$fixture" "$envteam" "$view" "$@")" "$(expected "$spec")"
done <<<"$ROWS"

# The backstop sits under every dispatcher: a mutation reaching graphql_query
# with no target is refused at the wire, a read is not.
assert_eq "graphql_query refuses a mutation with no team target" \
  "$(graphql mutation)" "$(expected refused)"
assert_eq "graphql_query lets a read through with no team target" \
  "$(graphql read)" "rc=0 calls=1 wire=Ping()"
