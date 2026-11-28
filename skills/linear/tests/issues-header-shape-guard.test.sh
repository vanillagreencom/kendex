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

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"
TEAM_ID=7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47
# The issue read answers with the description in DESCRIPTION_FILE; the update
# answers with the description it was sent. Decode and answer each request
# in one jq process so the curl stub does not multiply subprocess launches.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r -d '' config || true
data="${config#*$'\n'data = }"
reply="$(jq -nj --arg data "${data%%$'\n'*}" --rawfile filed "${DESCRIPTION_FILE:?}" --arg team "$TEAM_ID" '
  def connection($nodes): {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $nodes};
  def issue($description): {
    id: "issue-uuid", identifier: "CC-1", title: "t", description: $description,
    state: {name: "Todo", type: "unstarted"}, assignee: null, project: null,
    projectMilestone: null, cycle: null, parent: null, team: {key: "CC", id: $team, name: "Claude"},
    priority: 3, estimate: null, sortOrder: 1.0, url: "https://linear.app/x/issue/CC-1", branchName: "cc-1",
    createdAt: "2026-10-11T00:00:00Z", updatedAt: "2026-10-11T00:00:00Z", archivedAt: null, trashed: null,
    labels: connection([]), children: connection([]), relations: connection([]), inverseRelations: connection([])
  };
  ($data | fromjson | fromjson) as $payload
  | ($payload | tojson), "\n",
    ($payload.query | if contains("workflowStates(filter:") then
        {data: {workflowStates: connection([{id: "state-done"}])}}
      elif contains("issueCreate(input:") then
        {data: {issueCreate: {success: true, issue: issue($filed)}}}
      elif contains("issueUpdate(id:") then
        {data: {issueUpdate: {success: true, issue: issue($payload.variables.input.description // "")}}}
      elif contains("issue(id:") then
        {data: {issue: issue($filed)}}
      else {errors: [{message: "unexpected query"}]} end | tojson), "___HTTP_CODE___200"')"
printf '%s\n' "${reply%%$'\n'*}" >>"${CURL_LOG:?}"
printf '%s' "${reply#*$'\n'}"
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
  # Only create needs a team. The UUID avoids name resolution there, and
  # existing-issue writes leave the cross-team guard to its own suite.
  local team=""
  [[ "$2" != create ]] || team="$TEAM_ID"
  local -a reach=(LINEAR_REQUIRE_REACH="$REACH")
  [ "$REACH" != unset ] || reach=()
  OUT="$(cd "$PROJECT" && env -u LINEAR_AGENT_LABELS -u LINEAR_REQUIRE_REACH ${reach[@]+"${reach[@]}"} \
    PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM="$team" TEAM_ID="$TEAM_ID" \
    CURL_LOG="$CURL_LOG" DESCRIPTION_FILE="$FILED" \
    "$BASH" "$LINEAR" "$@" 2>"$ERR_FILE")" || RC=$?
  ERR="$(sed '/^linear: cross-team-guard=inactive action=[^ ]* cause=no-team$/d' "$ERR_FILE")"
}

sent() { jq -s -e --arg op "$1" 'any(.[]; .query | contains($op))' "$CURL_LOG" >/dev/null; }
assert_written() { # DESC OPERATION
  assert_eq "$1 exits zero" "$RC" 0
  assert "$1 reaches $2" sent "$2"
}
assert_unwritten() { # DESC
  if [ "$LAST_COMMAND" = "issues update" ]; then
    assert_not "$1 refuses before any write" sent issueUpdate
  else
    assert_not "$1 refuses before any API call" test -s "$CURL_LOG"
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

# shellcheck source=../scripts/lib/issue-validation.sh
source "$SKILL_DIR/scripts/lib/issue-validation.sh"
run_header_guard() {
  RC=0
  LINEAR_REQUIRE_REACH=1 require_issue_header_shape "$@" 2>"$ERR_FILE" || RC=$?
  ERR="$(<"$ERR_FILE")"
}

echo "=== post-merge box fields still refuse ==="
# Each operation exercises a refusal and a write. The trigger and deadline
# variants that only change the shared verdict call the guard directly.
# Run the control's refusal assertions first so unrelated CLI work cannot delay them.
while IFS='|' read -r operation trigger deadline rule; do
  description="$(printf '%s\n' "$OUTCOME" "$REACH_LINE" '## Done when' \
    "- [ ] Post-merge: Read health; Where: service; Why after merge: deployment; Trigger: $trigger; Deadline: $deadline" \
    '' "$SUPERSESSION_LINE")"
  if [[ "$operation" == guard ]]; then
    run_header_guard "$description"
    if [[ "$rule" == valid ]]; then
      assert_eq "guard accepts $trigger with $deadline" "$RC" 0
      assert_eq "guard accepts $trigger with $deadline without a diagnostic" "$ERR" ""
    else
      assert_ne "guard refuses $trigger with $deadline" "$RC" 0
      assert_jq "guard names $rule and a fix" "$ERR" ".rule == \"$rule\" and .box == 1 and (.fix | length) > 0"
    fi
    continue
  fi
  case "$operation" in
    create) box_args=(issues create --title "Post-merge check"); mutation=issueCreate ;;
    update) box_args=(issues update CC-1); mutation=issueUpdate ;;
    bulk-update) box_args=(issues bulk-update CC-1 CC-2); mutation=issueUpdate ;;
  esac
  if [[ "$operation" == update ]]; then
    body "$description"
    run_linear "${box_args[@]}" --description-file "$TMP_ROOT/body.md"
  else
    run_linear "${box_args[@]}" --description "$description"
  fi
  if [ "$rule" = valid ]; then
    assert_advised "$operation accepts $trigger with $deadline" "$mutation"
  else
    assert_ne "$operation refuses $trigger with $deadline" "$RC" 0
    assert_unwritten "$operation refusing $trigger with $deadline"
    assert_jq "$operation names $rule and a fix" "$ERR" ".rule == \"$rule\" and .box == 1 and (.fix | length) > 0"
  fi
done <<'ROWS'
update|merge|set at merge|post-merge-deadline
create|that row exists|2026-11-17T08:00:00Z|post-merge-fields
update|that row exists|2026-11-17T08:00:00Z|post-merge-fields
bulk-update|that row exists|2026-11-17T08:00:00Z|post-merge-fields
create|release v*|+72h|post-merge-release-repository
create|release owner/repo v*|+72h|valid
update|merge|+72h|valid
bulk-update|merge|2026-10-02T00:00:00Z|valid
guard|merge|2026-09-31T12:00:00Z|post-merge-deadline
guard|release v*|+72h|post-merge-release-repository
guard|2026-10-01T00:00:00Z|2026-10-02T00:00:00Z|valid
guard|merge|+24h|valid
guard|2026-11-16T08:00:00Z|2026-11-17T08:00:00Z|valid
guard|release owner/repo v*|+24h|valid
ROWS

[[ ${LINEAR_HEADER_FIELDS_ONLY:-0} != 1 ]] || exit 0

echo "=== create: the opening line ==="
# A refused opening must remain one JSON record even beside a long header.
body "$SOURCE_LINE" "$REACH_LINE" '' "$OUTCOME" '' "$(pad '**Symptom**: ' 501)" "$SUPERSESSION_LINE"
run_linear issues create --title "Source first" --description-file "$TMP_ROOT/body.md"
assert_opening_refused "a create opening with a **Source**: line"

body '' '' 'Reached by: kendex apply' '' "$OUTCOME" "$SUPERSESSION_LINE"
run_linear issues create --title "Reach first" --description-file "$TMP_ROOT/body.md"
assert_opening_refused "a create whose first non-empty line is Reached by:" 3

echo "=== create: the header length ==="
LONG="$(pad '**Symptom**: ' 501)"
body "$OUTCOME" '' "$SOURCE_LINE" "$LONG" "$REACH_LINE" "$SUPERSESSION_LINE"
run_linear issues create --title "Long symptom" --description-file "$TMP_ROOT/body.md"
assert_advised "a create with a 501-character **Symptom**: line" issueCreate "issue-header-length 8 501"

# The opening matrix calls the shared guard. Entry-point rows separately
# prove create/update/bulk wiring.
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
  run_header_guard "$candidate"
  if [[ "$expected" == pass ]]; then
    assert_eq "opening $shape files" "$RC" 0
    assert_eq "opening $shape prints no diagnostic" "$ERR" ""
  else
    assert_ne "opening $shape refuses" "$RC" 0
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
  run_header_guard "$candidate"
  assert_eq "a $length-character quoted Why files" "$RC" 0
  if [[ "$length" == 500 ]]; then assert_eq 'a 500-character quoted Why prints no advisory' "$(advisories)" ""
  else
    assert_eq 'quoted Why keeps the header-length category and character count' "$(advisories)" "issue-header-length 3 501"
  fi
done

# detail_advisory — the opening-detail advisory in ERR as "LINE KINDS".
detail_advisory() {
  sed -n 's/^linear: advisory=issue-opening-detail line=\([0-9]*\) kinds=\([^ ]*\) .*$/\1 \2/p' <<<"$ERR"
}
# Machine detail in the opening is advised on and written; the plain rows are
# prose that shares a shape with a pattern.
PLAIN_WHY='The owner can use the updated instructions.'
while IFS='|' read -r shape story why kinds; do
  candidate="> **Story:** $story"$'\n\n'"> **Why this matters:** ${why:-$PLAIN_WHY}"$'\n\n## Context'
  run_header_guard "$candidate"
  assert_eq "opening detail $shape files" "$RC" 0
  if [[ -z "$kinds" ]]; then
    assert_eq "opening detail $shape prints no diagnostic" "$ERR" ""
  else
    assert_eq "opening detail $shape names its kinds" "$(detail_advisory)" "1 $kinds"
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


# The body keeps its paths, ids and times.
run_header_guard "$OUTCOME"$'\n\nRead skills/linear/SKILL.md, Slack 1794379603.893169 at 2026-11-11T06:49:47Z.'
assert_eq "a body with machine detail outside the opening files" "$RC" 0
assert_eq "machine detail outside the opening prints no advisory" "$ERR" ""

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

echo "=== owner action: the next non-empty line opens the body ==="
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/skills/mailbox/scripts/lib/mailbox-append.sh"
# The question IDs the mailbox marks each action with (comments owner-questions --id).
QUESTION=a54c6f77-50d1-4001-8000-000000000001
NEWER=a54c6f77-50d1-4002-8000-000000000002
ACTION_LINE="**Brad, what you do:** Run the check. Comment the result. \`Owner question: $QUESTION\`"
OWNER_BODY="$(jq -nr --arg body "$OUTCOME" --arg question "$QUESTION" "$OWNER_ACTION_JQ"'
  $body | owner_action_line("Brad Owner"; "Run the check. Comment the result."; $question)')"
assert_eq "the owner ask builds the accepted description" "$OWNER_BODY" "$(printf '%s\n\n%s' "$ACTION_LINE" "$OUTCOME")"
run_linear issues update CC-1 --description "$OWNER_BODY"
assert_advised "an owner action before the outcome" issueUpdate
assert "the owner action update writes the exact description" \
  jq -s -e --arg desc "$OWNER_BODY" \
  'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"

run_linear issues update CC-1 --description "$(printf '%s\n\n%s' "$ACTION_LINE" "$SOURCE_LINE")"
assert_opening_refused "an owner-shaped opening $ACTION_LINE followed by a header" 3

for opening in '**Brad, what you do**: Run the check.' '**Brad, what you do:**Run the check.'; do
  run_header_guard "$opening"$'\n\n'"$SOURCE_LINE"
  assert_ne "an owner-shaped opening $opening followed by a header exits nonzero" "$RC" 0
  assert_jq "an owner-shaped opening $opening followed by a header names the opening refusal" "$ERR" \
    '.rule == "issue-header-opening" and .line == 1 and (.fix | length) > 0'
done
body '' "$ACTION_LINE" '' "$OUTCOME"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_advised "an owner action as the first non-empty line" issueUpdate
for length in 500 501; do
  run_header_guard "$(pad '**Brad, what you do:** ' "$length")"$'\n\n'"$OUTCOME"
  assert_eq "a $length-character owner action is accepted" "$RC" 0
  if [ "$length" -eq 500 ]; then assert_eq "a 500-character owner action has no advisory" "$ERR" ""
  else assert_eq "a 501-character owner action names its advisory" "$(advisories)" "issue-header-length 1 501"; fi
done

echo "=== owner action: posting, replacing and removing the mailbox line ==="
# owner_ask_over STORED_FILE ACTION QUESTION — the description the mailbox
# owner ask or repair writes over the stored body, with a trailing sentinel
# the caller strips.
owner_ask_over() {
  jq -nr --rawfile body "$1" --arg action "$2" --arg question "$3" "$OWNER_ACTION_JQ"'
    ($body | owner_action_line("Brad Owner"; $action; $question)) + "."'
}
# write_over STORED ACTION QUESTION — WRITTEN: the mailbox's description over
# STORED, or STORED itself where ACTION is empty, as a rollback or the watch's
# close writes the body back without the line.
write_over() {
  printf '%s' "$1" >"$FILED"
  if [ -z "$2" ]; then WRITTEN="$1"; else WRITTEN="$(owner_ask_over "$FILED" "$2" "$3")"; WRITTEN="${WRITTEN%.}"; fi
}
printf '%s\n' '**Source**: x' "$REACH_LINE" '' "$OUTCOME" >"$FILED"
FILED_FIRST="$(cat "$FILED"; printf .)"; FILED_FIRST="${FILED_FIRST%.}"
# Each body the guard accepts: the quoted opening, and one filed in the older
# header-first form, which a stored body keeps.
for stored_name in quoted header-first; do
  if [ "$stored_name" = quoted ]; then STORED="$OUTCOME"; else STORED="$FILED_FIRST"; fi
  write_over "$STORED" 'Run the check.' "$QUESTION"
  POSTED="$WRITTEN"
  assert_eq "the owner ask puts its marked line over the $stored_name body" "$POSTED" \
    "**Brad, what you do:** Run the check. \`Owner question: $QUESTION\`"$'\n\n'"$STORED"
  write_over "$POSTED" 'Read the new check.' "$NEWER"
  REPLACED="$WRITTEN"
  assert_eq "a newer ask replaces the marked line over the $stored_name body" "$REPLACED" \
    "**Brad, what you do:** Read the new check. \`Owner question: $NEWER\`"$'\n\n'"$STORED"
  while IFS='|' read -r step from action question; do
    case "$from" in body) from="$STORED" ;; posted) from="$POSTED" ;; esac
    write_over "$from" "$action" "$question"
    # The earlier owner action row proves the quoted description is sent
    # unchanged. Only the legacy body relies on preserving the stored text.
    if [ "$stored_name" = quoted ]; then
      run_header_guard "$WRITTEN" "$from"
      assert_eq "the $step over the $stored_name body is accepted" "$RC" 0
      assert_eq "the $step over the $stored_name body has no advisory" "$ERR" ""
      continue
    fi
    run_linear issues update CC-1 --description "$WRITTEN"
    assert_advised "the $step over the $stored_name body" issueUpdate
    assert "the $step over the $stored_name body writes its exact description" \
      jq -s -e --arg desc "$WRITTEN" \
      'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"
  done <<ROWS
post or repair|body|Run the check.|$QUESTION
replace|posted|Read the new check.|$NEWER
ROWS
  # The rollback and the watch's close write the stored body back.
  for marked in "$POSTED" "$REPLACED"; do
    if [ "$stored_name" = quoted ]; then
      run_header_guard "$STORED" "$marked"
      assert_eq "the marked line's removal from the $stored_name body is accepted" "$RC" 0
      assert_eq "the marked line's removal from the $stored_name body has no advisory" "$ERR" ""
      continue
    fi
    printf '%s' "$marked" >"$FILED"
    run_linear issues update CC-1 --description "$STORED"
    assert_advised "the marked line's removal from the $stored_name body" issueUpdate
    assert "the removal from the $stored_name body writes the stored body exactly" \
      jq -s -e --arg desc "$STORED" \
      'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"
  done
done

STORED="$FILED_FIRST"
printf '%s' "$STORED" >"$FILED"
OTHER_SOURCE='**Source**: y'
run_linear issues update CC-1 --description "$(printf '%s\n\n%s\n%s' "$ACTION_LINE" "$OTHER_SOURCE" "$OUTCOME")"
assert_opening_refused "an owner action over a header-first body other than the stored one" 3
run_linear issues update CC-1 --description "$(printf '%s\n%s' "$OTHER_SOURCE" "$OUTCOME")"
assert_opening_refused "a header-first body other than the stored one"
LONG_ACTION_LINE="$(pad '**Brad, what you do:** ' 501)"
LONG_ASK="$(owner_ask_over "$FILED" "${LONG_ACTION_LINE#'**Brad, what you do:** '}" "")"
LONG_ASK="${LONG_ASK%.}"
run_linear issues update CC-1 --description "$LONG_ASK"
assert_advised "a 501-character owner action over the unchanged stored body" issueUpdate "issue-header-length 1 501"
: >"$FILED"

echo "=== header length boundaries and template-shaped create ==="
run_header_guard "$OUTCOME"$'\n\n'"$(pad '**Symptom**: ' 500)"
assert_eq "a 500-character header line is accepted" "$RC" 0
assert_eq "a 500-character header line has no advisory" "$ERR" ""

# 450 two-byte characters: over 500 bytes, under 500 characters.
# Counted by repetition, not ${#}, which counts bytes under a C locale.
WIDE='**Symptom**: '
for _ in $(seq 450); do WIDE+="é"; done
run_header_guard "$OUTCOME"$'\n\n'"$WIDE"
assert_eq "a header under 500 characters and over 500 bytes is accepted" "$RC" 0
assert_eq "a header under 500 characters and over 500 bytes has no advisory" "$ERR" ""

body "$OUTCOME" '' 'The work is complete when refresh writes the render.' \
  '' '## Done when' '' '- [ ] Refresh writes the render.' \
  '' '## Filing record' '' "$SOURCE_LINE" '**Symptom**: the render stayed stale' "$REACH_LINE" "$SUPERSESSION_LINE"
run_linear issues create --title "Template body" --description-file "$TMP_ROOT/body.md"
assert_advised "a template-shaped create" issueCreate

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
