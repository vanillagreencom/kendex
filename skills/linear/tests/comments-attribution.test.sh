#!/usr/bin/env bash
# bash-runtime: 4
# The attribution line every new comment opens with: `comments create` reads
# who posts it once, through orch's `orch-runtime session` beside the
# package, and writes `> Posted by Agent: A, Model: M, Effort: E` over the
# body its caller supplied. A safe read gives that body back, so a reader that
# finds its own comment by its opening text or bytes (orch's summary, Jarvis's
# next action) still finds it.
#
# The reader rows replay the lines `orch-runtime session` prints
# (agent-runtime context.rs `Now::lines`, orch turnend/admission.rs
# `session`): the Claude Code row as a lane's own reading printed it, the Codex
# row as agent-runtime's own fixture names a turn_context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
printf '[env]\nLINEAR_TEAM = "KEN"\n' >"$PROJECT/kendex.settings.toml"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
READER="$PROJECT/.agents/skills/orch/scripts/orch-runtime"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
COMMENTS="$TMP_ROOT/comments.jsonl"

# Linear's side: one team, KEN, whose issues answer every read block and
# unblock make; a created comment is stored with the body it was sent, and
# `comments list` answers the stored comments.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
if jq -e '.query | test("^\\s*mutation CreateComment")' >/dev/null <<<"$payload"; then
  jq -c --arg id "c$(($(wc -l <"${COMMENTS:?}") + 1))" '{id: $id, body: .variables.input.body}' <<<"$payload" >>"$COMMENTS"
fi
touch "${COMMENTS:?}"
jq -cj --slurpfile stored "$COMMENTS" '
  def page($nodes): {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $nodes};
  def team: {id: "1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d", key: "KEN", name: "kendex"};
  def issue($ref):
    {id: "9c8d7e6f-5a4b-4c3d-9e2f-1a0b9c8d7e6f", identifier: ($ref | ascii_upcase), title: "t", description: "",
     url: "https://linear.app/x/issue/KEN-1", branchName: "b", state: {name: "Todo", type: "unstarted"},
     assignee: null, project: null, projectMilestone: null, cycle: null, parent: null, team: team,
     priority: 3, estimate: null, sortOrder: 1.0, createdAt: "2026-11-22T00:00:00Z",
     updatedAt: "2026-11-22T00:00:00Z", archivedAt: null, trashed: null, labels: page([]),
     children: page([]), comments: page([]), relations: page([]), inverseRelations: page([])};
  def comment($c): {id: $c.id, body: $c.body, createdAt: "2026-11-22T00:00:00Z",
    updatedAt: "2026-11-22T00:00:00Z", user: {id: "u1", name: "VG Agents", email: "app@example.org"},
    parent: null, url: ("https://linear.app/x/issue/KEN-1#comment-" + $c.id)};
  .query as $q | (.variables // {}) as $v
  | if ($q | test("^\\s*mutation")) then
      ($q | capture("\\{\\s*(?<f>[A-Za-z]+)").f) as $f
      | {data: {($f): ({success: true}
          + if $f == "issueUpdate" then {issue: issue("KEN-1")}
            elif $f == "commentCreate" then {comment: (comment($stored[-1])
              + {issue: {identifier: "KEN-1", updatedAt: "2026-11-22T00:00:00Z"}})}
            elif $f == "issueRelationCreate" then {issueRelation: {id: "r1", type: "blocks"}}
            else {} end)}}
    elif ($q | contains("ListComments")) then
      {data: {issue: {id: "9c8d7e6f-5a4b-4c3d-9e2f-1a0b9c8d7e6f", comments: page([$stored[] | comment(.)])}}}
    elif ($q | contains("ValidateBlocking")) then {data: {issue1: issue($v.id1), issue2: issue($v.id2)}}
    elif ($q | contains("teams(filter:")) then {data: {teams: page([team])}}
    elif ($q | contains("issue(id:")) then {data: {issue: issue($v.id)}}
    elif ($q | contains("issueLabels(filter:")) then {data: {issueLabels: page([{id: "label-uuid"}])}}
    else {errors: [{message: "unexpected fixture query"}]} end' <<<"$payload"
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$PROJECT/bin/curl"

# plant KIND EXIT LINES: orch beside the package as KIND says. `stub` answers
# `session` with LINES (`;` between lines) at exit EXIT; `unbuilt` is the
# wrapper with no binary, which says so on stderr at exit 69; `absent`
# plants none.
plant() {
  rm -rf "$PROJECT/.agents/skills/orch"
  [[ "$1" != absent ]] || return 0
  mkdir -p "${READER%/*}"
  case "$1" in
  stub) printf '#!/usr/bin/env bash\n[ "$*" = session ] || exit 64\nprintf %%s %q\nexit %s\n' \
    "${3//;/$'\n'}" "$2" >"$READER" ;;
  unbuilt) printf '#!/usr/bin/env bash\necho "orch-runtime: setup-required key=k run=setup" >&2\nexit 69\n' >"$READER" ;;
  esac
  chmod +x "$READER"
}

# run ARGS...: one linear.sh command in the project, its exit in RC.
run() {
  RC=0
  : >"$CURL_LOG"
  (cd -- "$PROJECT" && env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=stub \
    KENDEX_USER_EMAIL= LINEAR_REQUIRE_REACH= CURL_LOG="$CURL_LOG" COMMENTS="$COMMENTS" \
    "$BASH" "$LINEAR" "$@") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
}

# The body the last commentCreate sent, or `none`, closed by `|` so its
# trailing newline survives the command substitution.
sent_body() {
  jq -jrs '[.[] | select(.query | test("^\\s*mutation CreateComment"))]
    | (if length == 0 then "none" else last.variables.input.body end) + "|"' "$CURL_LOG"
}

CODEX='model=gpt-6.1-sol source=session;effort=high source=session;agent=KEN-7 source=launch'
CODEX_LINE='> Posted by Agent: KEN-7, Model: gpt-6.1-sol, Effort: high'
UNREAD='> Posted by Agent: unknown, Model: unknown, Effort: unknown'

echo "=== each member is the reading's, or unknown ==="

# label|kind|exit|lines|attribution
READS='
a Codex lane names its model and effort from the session|stub|0|'"$CODEX"'|'"$CODEX_LINE"'
a Claude Code lane records no effort|stub|1|model=claude-opus-5-5 source=session;session-effort-unrecorded harness=claude session=2082e1ce-d02d-4cd4-aa90-5b2a9180706c;agent=KEN-4554 source=launch|> Posted by Agent: KEN-4554, Model: claude-opus-5-5, Effort: unknown
a model only the launch requested is unknown|stub|1|model=opus source=launch;session-effort-unrecorded harness=claude session=s1;agent=KEN-7 source=launch|> Posted by Agent: KEN-7, Model: unknown, Effort: unknown
a session record that cannot be read leaves model and effort unknown|stub|2|session-file-unreadable harness=codex session=s1 cause=denied;session-file-unreadable harness=codex session=s1 cause=denied;agent=KEN-7 source=launch|> Posted by Agent: KEN-7, Model: unknown, Effort: unknown
a session no launch named leaves the agent unknown|stub|1|model=gpt-6.1-sol source=session;effort=high source=session;session-agent-unrecorded harness=codex session=s1|> Posted by Agent: unknown, Model: gpt-6.1-sol, Effort: high
a caller with no lane session bound reads nothing|stub|2|session-unnamed dir=/home/u/dev/kendex cause=no lane|'"$UNREAD"'
an orch runtime not yet built reads nothing|unbuilt|69||'"$UNREAD"'
a package with no orch beside it reads nothing|absent|0||'"$UNREAD"'
'

while IFS='|' read -r label kind code lines attribution; do
  [ -n "$label" ] || continue
  : >"$COMMENTS"
  plant "$kind" "$code" "$lines"
  run comments create KEN-1 --body "Shipped it"
  assert_eq "$label" "rc=$RC $(sent_body)" "rc=0 $attribution"$'\n\n'"Shipped it"$'\n|'
done <<<"$READS"

echo "=== the caller's body stays as it was supplied, under the one line ==="

plant stub 0 "$CODEX"
# label|body|sent after the line
BODIES='
a caller written attribution is replaced by the reading|> Posted by Agent: overseer, Model: standard, Effort: high\n\nFiling verification: kept.|Filing verification: kept.
a line like it inside the body stays where it is|Intro\n> Posted by Agent: a, Model: b, Effort: c\n\nrest|Intro\n> Posted by Agent: a, Model: b, Effort: c\n\nrest
the completion heading follows the line|## Completion Summary\n\nShipped it|## Completion Summary\n\nShipped it
'
while IFS='|' read -r label body rest; do
  [ -n "$label" ] || continue
  : >"$COMMENTS"
  run comments create KEN-1 --body "$(printf '%b' "$body")"
  assert_eq "$label" "rc=$RC $(sent_body)" "rc=0 $CODEX_LINE"$'\n\n'"$(printf '%b' "$rest")"$'\n|'
done <<<"$BODIES"

: >"$COMMENTS"
run comments create KEN-1 --parent 5f1e2d3c-4b5a-4968-8776-655443322110 --body "A reply"
assert_eq "a reply keeps its parent under the line" \
  "rc=$RC $(jq -rs 'last.variables.input.parentId' "$CURL_LOG") $(sent_body)" \
  "rc=0 5f1e2d3c-4b5a-4968-8776-655443322110 $CODEX_LINE"$'\n\n'"A reply"$'\n|'

echo "=== a safe read gives back the body its caller posted ==="

: >"$COMMENTS"
run comments create KEN-1 --body "$(printf '## Completion Summary\n\nShipped it')"
run comments list KEN-1
assert_eq "a safe read gives back the body its caller posted" \
  "rc=$RC $(jq -jr '"\(length) \(.[0].body)|"' "$TMP_ROOT/out")" "rc=0 1 ## Completion Summary"$'\n\n'"Shipped it"$'\n|'
run comments list KEN-1 --format raw
assert_eq "a raw read keeps the stored body with its line" \
  "rc=$RC $(jq -jr '.issue.comments.nodes[0].body + "|"' "$TMP_ROOT/out")" \
  "rc=0 $CODEX_LINE"$'\n\n'"## Completion Summary"$'\n\n'"Shipped it"$'\n|'

echo "=== block and unblock post through the same writer ==="

: >"$COMMENTS"
run issues block KEN-1 --by KEN-2 --reason "Needs the parser."
assert_eq "block posts its comment under the line" "rc=$RC $(sent_body)" \
  "rc=0 $CODEX_LINE"$'\n\n'"BLOCKED: Waiting for KEN-2. Needs the parser."$'\n|'
: >"$COMMENTS"
run issues unblock KEN-1
assert_eq "unblock posts its comment under the line" "rc=$RC $(sent_body)" \
  "rc=0 $CODEX_LINE"$'\n\n'"Unblocked. Resuming work."$'\n|'
