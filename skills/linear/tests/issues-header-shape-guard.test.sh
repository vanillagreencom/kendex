#!/usr/bin/env bash
# bash-runtime: 4
# Surface: the filing bar on authored descriptions. Missing quoted openings
# and invalid post-merge box fields refuse; header length and machine detail
# in the opening remain advisory.
# An owner action placed on a stored legacy body is judged on its own length.
# Inputs: linear scripts, this suite, its assertion library, and the mailbox
# owner-action producer. Real create/update/bulk-description routes must use
# the same guard; completion and metadata keep stored legacy text.

set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
printf '[env]\nLINEAR_TEAM = "CC"\n' >"$PROJECT/kendex.settings.toml"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"
# The issue read answers with the description in DESCRIPTION_FILE; the update
# answers with the description it was sent.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
payload="$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
description="$(jq -Rs . "${DESCRIPTION_FILE:?}")"
issue='{id:"issue-uuid",identifier:"CC-1",title:"t",description:$d,state:{name:"Todo",type:"unstarted"},assignee:null,project:null,projectMilestone:null,cycle:null,parent:null,team:{key:"CC",id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/x/issue/CC-1",branchName:"cc-1",createdAt:"2026-10-11T00:00:00Z",updatedAt:"2026-10-11T00:00:00Z",archivedAt:null,trashed:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}'
case "$(jq -r '.query' <<<"$payload")" in
*"teams(filter:"*) printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid","key":"CC","name":"Claude"}]}}}' ;;
*"workflowStates(filter:"*) printf '%s' '{"data":{"workflowStates":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"state-done"}]}}}' ;;
*"issueCreate(input:"*) jq -cj --argjson d "$description" "{data:{issueCreate:{success:true,issue:$issue}}}" <<<'null' ;;
*"issueUpdate(id:"*) jq -cj "(.variables.input.description // \"\") as \$d | {data:{issueUpdate:{success:true,issue:$issue}}}" <<<"$payload" ;;
*"issue(id:"*) jq -cj --argjson d "$description" "{data:{issue:$issue}}" <<<'null' ;;
*) printf '%s' '{"errors":[{"message":"unexpected query"}]}' ;;
esac
printf '___HTTP_CODE___200'
SH
chmod +x "$PROJECT/bin/curl"
FILED="$TMP_ROOT/filed.md"
: >"$FILED"

# The parent environment wins over project files, so the key is unset for the
# run unless REACH names its value; REACH=unset leaves it unset.
REACH=1
run_linear() {
  LAST_COMMAND="$1 $2"
  : >"$CURL_LOG"
  RC=0
  local -a reach=(LINEAR_REQUIRE_REACH="$REACH")
  [ "$REACH" != unset ] || reach=()
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS -u LINEAR_REQUIRE_REACH ${reach[@]+"${reach[@]}"} \
    PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=test-token CURL_LOG="$CURL_LOG" DESCRIPTION_FILE="$FILED" \
    "$BASH" "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

api_calls() { wc -l <"$CURL_LOG" | tr -d ' '; }
sent() { jq -s -e --arg op "$1" 'any(.[]; .query | contains($op))' "$CURL_LOG" >/dev/null; }
assert_written() { # DESC OPERATION
  assert_eq "$1 exits zero" "$RC" 0
  assert "$1 reaches $2" sent "$2"
}
assert_unwritten() { # DESC
  if [ "$LAST_COMMAND" = "issues update" ]; then
    assert_not "$1 refuses before any write" sent issueUpdate
  else
    assert_eq "$1 refuses before any API call" "$(api_calls)" "0"
  fi
}
assert_opening_refused() { # DESC [LINE]
  assert_ne "$1 exits nonzero" "$RC" 0
  assert_unwritten "$1"
  assert_jq "$1 names the opening refusal" "$ERR" \
    ".rule == \"issue-header-opening\" and .line == ${2:-1} and (.fix | length) > 0"
}
# advisories — each `linear: advisory=` line in ERR as "RULE LINE LENGTH".
advisories() {
  sed -n 's/^linear: advisory=\([^ ]*\) line=\([0-9]*\) length=\([0-9]*\)\( .*\)\{0,1\}$/\1 \2 \3/p' <<<"$ERR"
}
# Bulk-update prints each advisory once per issue it writes.
assert_advised() { # DESC OPERATION ["RULE LINE LENGTH" per line]
  assert_eq "$1 is written" "$RC" 0
  assert "$1 reaches $2" sent "$2"
  assert_eq "$1 names its advisory" "$(advisories)" "${3-}"
}
# pad PREFIX N — PREFIX followed by filler to N characters.
pad() { local s="$1"; while [ "${#s}" -lt "$2" ]; do s+="x"; done; printf '%s' "$s"; }

STORY='> **Story:** Refresh keeps the installed render current in a linked worktree.'
WHY='> **Why this matters:** The owner can use the updated instructions.'
OUTCOME="$(printf '%s\n\n%s\n\n%s' "$STORY" "$WHY" '## Context')"
REACH_LINE='**Reached by**: running `kendex refresh` in a linked worktree'
# Create bodies carry the supersession record last, so no line number moves.
SUPERSESSION_LINE='**Supersession**: none found; searched: refresh, linked worktree'
SOURCE_LINE='**Source**: review of owner/repo#47'
body() { printf '%s\n' "$@" >"$TMP_ROOT/body.md"; }

# The opening matrix calls the actual shared owner. Entry-point rows below
# prove create/update/bulk wiring without repeating this whole matrix per verb.
source "$SKILL_DIR/scripts/lib/issue-validation.sh"
while IFS='|' read -r shape expected; do
  case "$shape" in
    quoted) candidate="$OUTCOME" ;;
    opening-only) candidate="$STORY"$'\n\n'"$WHY" ;;
    continued) candidate=$'> **Story:**\n> The owner reads an issue.\n> It explains the change.\n\n> **Why this matters:**\n> It saves reading time.\n\n## Done when' ;;
    crlf) candidate="${OUTCOME//$'\n'/$'\r\n'}" ;;
    ordinary-quote) candidate="$OUTCOME"$'\n\n> Quoted source evidence.' ;;
    missing-story) candidate="$WHY"$'\n\n## Done when' ;;
    missing-why) candidate="$STORY"$'\n\n## Done when' ;;
    empty-story) candidate=$'> **Story:**\n\n'"$WHY"$'\n\n## Done when' ;;
    empty-why) candidate="$STORY"$'\n\n> **Why this matters:**\n\n## Done when' ;;
    whitespace-only) candidate=$'> **Story:** \t\n> \t\n\n'"$WHY"$'\n\n## Done when' ;;
    placeholder) candidate=$'> **Story:** [STORY]\n\n'"$WHY"$'\n\n## Done when' ;;
    template-placeholder) candidate=$'> **Story:** [Who this is about.] [What happens today.]\n\n'"$WHY"$'\n\n## Done when' ;;
    reversed) candidate="$WHY"$'\n\n'"$STORY"$'\n\n## Done when' ;;
    joined) candidate="$STORY"$'\n'"$WHY"$'\n\n## Done when' ;;
    quoted-separator) candidate="$STORY"$'\n>\n'"$WHY"$'\n\n## Done when' ;;
    heading-first) candidate=$'## Done when\n\n'"$OUTCOME" ;;
    heading-joined) candidate="$STORY"$'\n\n'"$WHY"$'\n## Done when' ;;
    unquoted-story) candidate="${STORY#'> '}"$'\n\n'"$WHY"$'\n\n## Done when' ;;
    unquoted-continuation) candidate="$STORY"$'\nUnquoted continuation.\n\n'"$WHY"$'\n\n## Done when' ;;
    empty) candidate='' ;;
  esac
  rc=0
  require_issue_header_shape "$candidate" 2>"$ERR_FILE" || rc=$?
  ERR="$(cat "$ERR_FILE")"
  if [[ "$expected" == pass ]]; then
    assert_eq "opening $shape files" "$rc" 0
    assert_eq "opening $shape prints no diagnostic" "$ERR" ""
  else
    assert_ne "opening $shape refuses" "$rc" 0
    assert_jq "opening $shape names the opening refusal" "$ERR" \
      '.rule == "issue-header-opening" and (.fix | length) > 0'
  fi
done <<'ROWS'
quoted|pass
opening-only|pass
continued|pass
crlf|pass
ordinary-quote|pass
missing-story|refuse
missing-why|refuse
empty-story|refuse
empty-why|refuse
whitespace-only|refuse
placeholder|refuse
template-placeholder|refuse
reversed|refuse
joined|refuse
quoted-separator|refuse
heading-first|refuse
heading-joined|refuse
unquoted-story|refuse
unquoted-continuation|refuse
empty|refuse
ROWS

# Why keeps the existing header bound after removing its quote marker.
for length in 500 501; do
  candidate="$STORY"$'\n\n> '"$(pad '**Why this matters:** ' "$length")"$'\n\n## Done when'
  rc=0
  require_issue_header_shape "$candidate" 2>"$ERR_FILE" || rc=$?
  ERR="$(cat "$ERR_FILE")"
  assert_eq "a $length-character quoted Why files" "$rc" 0
  if [[ "$length" == 500 ]]; then assert_eq 'a 500-character quoted Why prints no advisory' "$(advisories)" ""
  else
    assert_eq 'quoted Why keeps the header-length category and character count' "$(advisories)" "issue-header-length 3 501"
  fi
done

# detail_advisory — the opening-detail advisory in ERR as "LINE KINDS".
detail_advisory() {
  sed -n 's/^linear: advisory=issue-opening-detail line=\([0-9]*\) kinds=\([^ ]*\) .*$/\1 \2/p' <<<"$ERR"
}
# The filing agent follows the advisory to the two files that hold the rules.
assert_detail_routes() { # DESC
  assert "$1 names the description template" grep -q 'project-management templates/issue-description-template.md' <<<"$ERR"
  assert "$1 names the reader rule" grep -q 'communication references/reports.md' <<<"$ERR"
}

# Machine detail in the opening is advised on and written; the plain rows are
# prose that shares a shape with a pattern.
PLAIN_WHY='The owner can use the updated instructions.'
while IFS='|' read -r shape story why kinds; do
  candidate="> **Story:** $story"$'\n\n'"> **Why this matters:** ${why:-$PLAIN_WHY}"$'\n\n## Context'
  rc=0
  require_issue_header_shape "$candidate" 2>"$ERR_FILE" || rc=$?
  ERR="$(cat "$ERR_FILE")"
  assert_eq "opening detail $shape files" "$rc" 0
  if [[ -z "$kinds" ]]; then
    assert_eq "opening detail $shape prints no diagnostic" "$ERR" ""
  else
    assert_eq "opening detail $shape names its kinds" "$(detail_advisory)" "1 $kinds"
    assert_detail_routes "opening detail $shape"
  fi
done <<'ROWS'
plain|The owner reads the item and knows what changes.||
url|The owner opens https://linear.app/x/issue/a.md to read it.||
fractions|Agents and/or owners work 24/7 on version 1.5/2.0.||
date-only|It ran on 2026-11-11 and again on Nov 10.||
relative-path|The owner sees skills/linear/SKILL.md in the item.||file-path
root-path|It writes /home/dev/x without asking.||file-path
home-path|It writes ~/.cargo/bin/kendex.||file-path
slack-ts|The owner said so in Slack 1794379603.893169.||slack-ts
mailbox-id|Directive 1794379719-3476856-13832 asked for it.||mailbox-id
utc-z|It ran at 2026-11-11T06:49:47.079Z.||utc-time
utc-word|It ran at 2026-11-11 06:49 UTC.||utc-time
why-block|The owner reads the item.|It costs a read of tmp/notes.md.|file-path
several|At 2026-11-11T06:49:47Z it read tmp/a.md.||file-path,utc-time
ROWS

# The body keeps its paths, ids and times.
rc=0
require_issue_header_shape "$OUTCOME"$'\n\nRead skills/linear/SKILL.md, Slack 1794379603.893169 at 2026-11-11T06:49:47Z.' 2>"$ERR_FILE" || rc=$?
assert_eq "a body with machine detail outside the opening files" "$rc" 0
assert_eq "machine detail outside the opening prints no advisory" "$(cat "$ERR_FILE")" ""

# Material invalid openings reach the real command routes with valid reach.
for operation in create update bulk-update; do
  case "$operation" in
    create) opening_args=(issues create --title 'Opening shape') ;;
    update) opening_args=(issues update CC-1) ;;
    bulk-update) opening_args=(issues bulk-update CC-1 CC-2) ;;
  esac
  candidate="$STORY"$'\n\n## Done when\n\n'"$REACH_LINE"$'\n'"$SUPERSESSION_LINE"
  run_linear "${opening_args[@]}" --description "$candidate"
  assert_opening_refused "$operation with a missing quoted Why through its entry point"
done

# The shape rule leaves the reach and review-born symptom rule independent.
rc=0
require_issue_reach "$OUTCOME" 3 2>"$ERR_FILE" || rc=$?
assert_ne 'the reach rule still refuses absent reach' "$rc" 0
rc=0
require_issue_reach "$OUTCOME"$'\n'"$REACH_LINE" 2 1 2>"$ERR_FILE" || rc=$?
assert_ne 'the symptom rule still refuses review-born priority-2 without symptom' "$rc" 0

echo "=== create: the opening line ==="
# A refused opening must remain one JSON record even beside a long header.
body "$SOURCE_LINE" "$REACH_LINE" '' "$OUTCOME" '' "$(pad '**Symptom**: ' 501)" "$SUPERSESSION_LINE"
run_linear issues create --title "Source first" --description-file "$TMP_ROOT/body.md"
assert_opening_refused "a create opening with a **Source**: line"

body '' '' 'Reached by: kendex apply' '' "$OUTCOME" "$SUPERSESSION_LINE"
run_linear issues create --title "Reach first" --description-file "$TMP_ROOT/body.md"
assert_opening_refused "a create whose first non-empty line is Reached by:" 3

echo "=== owner action: the next non-empty line opens the body ==="
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/skills/mailbox/scripts/lib/mailbox-append.sh"
ACTION_LINE='**Brad, what you do:** Run the check. Comment the result.'
OWNER_BODY="$(jq -nr --arg body "$OUTCOME" "$OWNER_ACTION_JQ"'
  $body | owner_action_line("Brad Owner"; "Run the check. Comment the result.")')"
assert_eq "the owner ask builds the accepted description" "$OWNER_BODY" "$(printf '%s\n\n%s' "$ACTION_LINE" "$OUTCOME")"
run_linear issues update CC-1 --description "$OWNER_BODY"
assert_advised "an owner action before the outcome" issueUpdate
assert "the owner action update writes the exact description" \
  jq -s -e --arg desc "$OWNER_BODY" \
  'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"

for opening in "$ACTION_LINE" '**Brad, what you do**: Run the check.' '**Brad, what you do:**Run the check.'; do
  run_linear issues update CC-1 --description "$(printf '%s\n\n%s' "$opening" "$SOURCE_LINE")"
  if [ "$opening" = "$ACTION_LINE" ]; then line=3; else line=1; fi
  assert_opening_refused "an owner-shaped opening $opening followed by a header" "$line"
done
body '' "$ACTION_LINE" '' "$OUTCOME"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_advised "an owner action as the first non-empty line" issueUpdate
for length in 500 501; do
  body "$(pad '**Brad, what you do:** ' "$length")" '' "$OUTCOME"
  run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
  if [ "$length" -eq 500 ]; then assert_advised "a 500-character owner action" issueUpdate
  else assert_advised "a 501-character owner action" issueUpdate "issue-header-length 1 501"; fi
done

echo "=== owner action: placed on and removed from a stored header-first body ==="
# owner_ask_over STORED_FILE ACTION — the description the mailbox owner ask
# writes over the stored body, with a trailing sentinel the caller strips.
owner_ask_over() {
  jq -nr --rawfile body "$1" --arg action "$2" "$OWNER_ACTION_JQ"'
    ($body | owner_action_line("Brad Owner"; $action)) + "."'
}
printf '%s\n' '**Source**: x' "$REACH_LINE" '' "$OUTCOME" >"$FILED"
STORED="$(cat "$FILED"; printf .)"; STORED="${STORED%.}"
ASK="$(owner_ask_over "$FILED" 'Run the check.')"; ASK="${ASK%.}"
assert_eq "the owner ask puts its action line over the stored body" "$ASK" "**Brad, what you do:** Run the check."$'\n\n'"$STORED"
run_linear issues update CC-1 --description "$ASK"
assert_advised "an owner ask over a stored body opening with **Source**:" issueUpdate
assert "the owner ask writes its exact description" \
  jq -s -e --arg desc "$ASK" \
  'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"
printf '%s' "$ASK" >"$FILED"
REPLACED="$(owner_ask_over "$FILED" 'Read the new check.')"; REPLACED="${REPLACED%.}"
run_linear issues update CC-1 --description "$REPLACED"
assert_advised "replacing only the stored legacy owner action" issueUpdate
run_linear issues update CC-1 --description "$STORED"
assert_advised "the rollback or close writing the stored body back without the action line" issueUpdate
assert "the rollback writes the stored body exactly" \
  jq -s -e --arg desc "$STORED" \
  'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"

printf '%s' "$STORED" >"$FILED"
OTHER_SOURCE='**Source**: y'
run_linear issues update CC-1 --description "$(printf '%s\n\n%s\n%s' "$ACTION_LINE" "$OTHER_SOURCE" "$OUTCOME")"
assert_opening_refused "an owner action over a header-first body other than the stored one" 3
run_linear issues update CC-1 --description "$(printf '%s\n%s' "$OTHER_SOURCE" "$OUTCOME")"
assert_opening_refused "a header-first body other than the stored one"
LONG_ACTION_LINE="$(pad '**Brad, what you do:** ' 501)"
LONG_ASK="$(owner_ask_over "$FILED" "${LONG_ACTION_LINE#'**Brad, what you do:** '}")"
LONG_ASK="${LONG_ASK%.}"
run_linear issues update CC-1 --description "$LONG_ASK"
assert_advised "a 501-character owner action over the unchanged stored body" issueUpdate "issue-header-length 1 501"
: >"$FILED"

echo "=== create: the header length ==="
LONG="$(pad '**Symptom**: ' 501)"
body "$OUTCOME" '' "$SOURCE_LINE" "$LONG" "$REACH_LINE" "$SUPERSESSION_LINE"
run_linear issues create --title "Long symptom" --description-file "$TMP_ROOT/body.md"
assert_advised "a create with a 501-character **Symptom**: line" issueCreate "issue-header-length 8 501"

body "$OUTCOME" '' "$(pad '**Symptom**: ' 500)" "$REACH_LINE" "$SUPERSESSION_LINE"
run_linear issues create --title "Edge symptom" --description-file "$TMP_ROOT/body.md"
assert_advised "a create with a 500-character header line" issueCreate

# 450 two-byte characters: over 500 bytes, under 500 characters.
# Counted by repetition, not ${#}, which counts bytes under a C locale.
WIDE='**Symptom**: '
for _ in $(seq 450); do WIDE+="é"; done
body "$OUTCOME" '' "$WIDE" "$REACH_LINE" "$SUPERSESSION_LINE"
run_linear issues create --title "Wide symptom" --description-file "$TMP_ROOT/body.md"
assert_advised "a create whose header is under 500 characters and over 500 bytes" issueCreate

body "$OUTCOME" '' 'The work is complete when refresh writes the render.' \
  '' '## Done when' '' '- [ ] Refresh writes the render.' \
  '' '## Filing record' '' "$SOURCE_LINE" '**Symptom**: the render stayed stale' "$REACH_LINE" "$SUPERSESSION_LINE"
run_linear issues create --title "Template body" --description-file "$TMP_ROOT/body.md"
assert_advised "a template-shaped create" issueCreate

echo "=== opening detail: each authored-description route writes and advises ==="
DETAIL_OPENING="$(printf '%s\n\n%s\n\n%s' '> **Story:** The owner sees skills/linear/SKILL.md in the item.' "$WHY" '## Context')"
while IFS='|' read -r operation expected; do
  case "$operation" in
    create) detail_args=(issues create --title 'Opening detail'); mutation=issueCreate ;;
    update) detail_args=(issues update CC-1); mutation=issueUpdate ;;
    bulk-update) detail_args=(issues bulk-update CC-1 CC-2); mutation=issueUpdate ;;
  esac
  run_linear "${detail_args[@]}" --description "$DETAIL_OPENING"$'\n\n'"$REACH_LINE"$'\n'"$SUPERSESSION_LINE"
  assert_written "$operation with machine detail in the opening" "$mutation"
  assert_eq "$operation advises once per written issue" "$(detail_advisory)" "$(printf "$expected")"
done <<'ROWS'
create|1 file-path
update|1 file-path
bulk-update|1 file-path\n1 file-path
ROWS


echo "=== update: --description and --description-file ==="
run_linear issues update CC-1 --description "$(printf '%s\n\n%s\n' "$SOURCE_LINE" "$OUTCOME")"
assert_opening_refused "an update --description opening with a **Source**: line"

body "$OUTCOME" '' "$LONG"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_advised "an update --description-file with a 501-character header" issueUpdate "issue-header-length 7 501"

body "$OUTCOME" '' "$SOURCE_LINE"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_advised "a template-shaped update --description-file" issueUpdate

printf '%s' "$OUTCOME" >"$FILED"
run_linear issues update CC-1 --description ""
assert_opening_refused "an update clearing a nonempty description"
: >"$FILED"

echo "=== bulk-update: the shared authored description ==="
# These rows prove the authored-description option forms share the guard.
while IFS='|' read -r form shape; do
  case "$shape" in
    opening) description="$SOURCE_LINE" ;;
    template) description="$(printf '%s\n\n%s' "$OUTCOME" "$SOURCE_LINE")" ;;
    empty) description="" ;;
  esac
  case "$form" in
    split) description_args=(--description "$description") ;;
    equals) description_args=(--description="$description") ;;
  esac
  run_linear issues bulk-update CC-1 CC-2 "${description_args[@]}"
  if [ "$shape" = template ]; then
    assert_advised "a bulk-update $form $shape description" issueUpdate
    assert_jq "a bulk-update $form $shape description updates every issue" "$OUT" \
      '.success == true and .updated == 2 and .failed == 0'
    assert "a bulk-update $form $shape description writes the authored text" \
      jq -s -e --arg desc "$description" \
      '[.[] | select(.query | contains("issueUpdate")) | .variables.input.description] == [$desc, $desc]' "$CURL_LOG"
  else
    assert_opening_refused "a bulk-update $form $shape description"
  fi
done <<'ROWS'
split|opening
split|template
split|empty
equals|opening
ROWS

run_linear issues bulk-update CC-1 --description "$SOURCE_LINE" --description="$OUTCOME"
assert_advised "a bulk-update replacing an invalid description option with a valid one" issueUpdate
run_linear issues bulk-update CC-1 --description="$OUTCOME" --description "$SOURCE_LINE"
assert_opening_refused "a bulk-update replacing a valid description option with an invalid one"

printf '%s\n' "$SOURCE_LINE" "$LONG" >"$FILED"
run_linear issues update CC-1 --title "Keep the filed description"
assert_written "an update with no authored description keeps a filed legacy body" issueUpdate
run_linear issues bulk-update CC-1 --title "Keep the filed description"
assert_written "a bulk-update with no authored description keeps a filed header-first body" issueUpdate

echo "=== complete: ticking a body filed before the guard ==="
printf '%s\n' "$SOURCE_LINE" "$LONG" '' '## Done when' '' '- [ ] first' >"$FILED"
printf '%s\n' '1: branch test read passed' >"$TMP_ROOT/evidence.txt"
run_linear issues complete CC-1 --done-when-met 1 --evidence-file "$TMP_ROOT/evidence.txt"
assert_written "a complete ticking a body that opens with a long header" issueUpdate
assert "the complete writes the ticked box" \
  jq -s -e 'any(.[]; .variables.input.description // "" | contains("- [x] first"))' "$CURL_LOG"
: >"$FILED"

echo "=== post-merge box fields still refuse ==="
# Each rule refuses and each operation is wired for a refusal and a write; the
# Deadline rule's own table is issues-complete-done-when's filing rows.
while IFS='|' read -r operation trigger deadline rule; do
  case "$operation" in
    create) box_args=(issues create --title "Post-merge check"); mutation=issueCreate ;;
    update) box_args=(issues update CC-1); mutation=issueUpdate ;;
    bulk-update) box_args=(issues bulk-update CC-1 CC-2); mutation=issueUpdate ;;
  esac
  description="$(printf '%s\n' "$OUTCOME" "$REACH_LINE" '## Done when' \
    "- [ ] Post-merge: Read health; Where: service; Why after merge: deployment; Trigger: $trigger; Deadline: $deadline" \
    '' "$SUPERSESSION_LINE")"
  run_linear "${box_args[@]}" --description "$description"
  if [ "$rule" = valid ]; then
    assert_advised "$operation accepts $trigger with $deadline" "$mutation"
  else
    assert_ne "$operation refuses $trigger with $deadline" "$RC" 0
    assert_unwritten "$operation refusing $trigger with $deadline"
    assert_jq "$operation names $rule and a fix" "$ERR" ".rule == \"$rule\" and .box == 1 and (.fix | length) > 0"
  fi
done <<'ROWS'
create|release v*|+72h|post-merge-release-repository
update|merge|set at merge|post-merge-deadline
bulk-update|merge|2026-09-31T12:00:00Z|post-merge-deadline
bulk-update|release v*|+72h|post-merge-release-repository
create|release owner/repo v*|+72h|valid
update|merge|+72h|valid
bulk-update|merge|2026-10-02T00:00:00Z|valid
create|2026-10-01T00:00:00Z|2026-10-02T00:00:00Z|valid
ROWS

# A missing opening beside a refused box leaves the box refusal alone on stderr.
run_linear issues create --title "Post-merge check" --description "$(printf '%s\n' "$SOURCE_LINE" "$REACH_LINE" '## Done when' \
  "- [ ] Post-merge: Read health; Where: service; Why after merge: deployment; Trigger: merge; Deadline: set at merge" \
  '' "$SUPERSESSION_LINE")"
assert_ne "a missing opening beside an invalid deadline is refused" "$RC" 0
assert_unwritten "a missing opening beside an invalid deadline"
assert_jq "the refusal is the one stderr record" "$ERR" '.rule == "post-merge-deadline" and .box == 1'

echo "=== the reach guard's key holds this guard too ==="
body "$SOURCE_LINE" "$REACH_LINE" "$SUPERSESSION_LINE"
REACH=unset
run_linear issues create --title "Default key" --description-file "$TMP_ROOT/body.md"
assert_opening_refused "with no LINEAR_REQUIRE_REACH key a create opening with a header"
run_linear issues bulk-update CC-1 --description "$SOURCE_LINE"
assert_opening_refused "with no LINEAR_REQUIRE_REACH key a bulk-update opening with a header"

REACH=""
run_linear issues create --title "Key off" --description-file "$TMP_ROOT/body.md"
assert_advised "with an empty LINEAR_REQUIRE_REACH a create opening with a header" issueCreate
run_linear issues bulk-update CC-1 --description="$SOURCE_LINE"
assert_advised "with an empty LINEAR_REQUIRE_REACH a bulk-update opening with a header" issueUpdate
