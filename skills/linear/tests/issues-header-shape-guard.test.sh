#!/usr/bin/env bash
# Tests for the header-shape guard. Under the reach guard's key, `issues
# create`, `issues update --description` / `--description-file`, and `issues
# bulk-update --description` refuse,
# before any API call, an opening header other than an owner action, a
# header after the owner action instead of an outcome, and a `**Key**:` or
# `Reached by:` header, and one with a header line over 500 characters; each
# refusal names the line and its length. `issues complete` ticking boxes in an
# already filed body is not new authored text and still writes.

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
assert_refused() { # DESC RULE LINE LENGTH
  assert_ne "$1 is refused" "$RC" 0
  assert_eq "$1 emits no stdout" "$OUT" ""
  assert_eq "$1 refuses before any API call" "$(api_calls)" "0"
  assert_jq "$1 names the rule, the line and its length" "$ERR" \
    ".rule == \"$2\" and .line == $3 and .length == $4"
}
# pad PREFIX N — PREFIX followed by filler to N characters.
pad() { local s="$1"; while [ "${#s}" -lt "$2" ]; do s+="x"; done; printf '%s' "$s"; }

OUTCOME='Refresh keeps the installed render current in a linked worktree.'
REACH_LINE='**Reached by**: running `kendex refresh` in a linked worktree'
SOURCE_LINE='**Source**: review of owner/repo#47'
body() { printf '%s\n' "$@" >"$TMP_ROOT/body.md"; }

echo "=== create: the opening line ==="
body "$SOURCE_LINE" "$REACH_LINE" '' "$OUTCOME"
run_linear issues create --title "Source first" --description-file "$TMP_ROOT/body.md"
assert_refused "a create opening with a **Source**: line" issue-header-opening 1 "${#SOURCE_LINE}"

body '' '' 'Reached by: kendex apply' '' "$OUTCOME"
run_linear issues create --title "Reach first" --description-file "$TMP_ROOT/body.md"
assert_refused "a create whose first non-empty line is Reached by:" issue-header-opening 3 24

echo "=== owner action: the next non-empty line opens the body ==="
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/skills/orch/scripts/lib/mailbox-append.sh"
ACTION_LINE='**Brad, what you do:** Run the check. Comment the result.'
OWNER_BODY="$(jq -nr --arg body "$OUTCOME" "$OWNER_ACTION_JQ"'
  $body | owner_action_line("Brad Owner"; "Run the check. Comment the result.")')"
assert_eq "the owner ask builds the accepted description" "$OWNER_BODY" "$(printf '%s\n\n%s' "$ACTION_LINE" "$OUTCOME")"
run_linear issues update CC-1 --description "$OWNER_BODY"
assert_written "an owner action before the outcome" issueUpdate
assert "the owner action update writes the exact description" \
  jq -s -e --arg desc "$OWNER_BODY" \
  'any(.[]; (.query | contains("issueUpdate")) and .variables.input.description == $desc)' "$CURL_LOG"

for opening in "$ACTION_LINE" '**Brad, what you do**: Run the check.' '**Brad, what you do:**Run the check.'; do
  run_linear issues update CC-1 --description "$(printf '%s\n\n%s' "$opening" "$SOURCE_LINE")"
  if [ "$opening" = "$ACTION_LINE" ]; then line=3; length="${#SOURCE_LINE}"
  else line=1; length="${#opening}"; fi
  assert_refused "an owner-shaped opening $opening followed by a header" issue-header-opening "$line" "$length"
done
body '' "$ACTION_LINE" '' "$OUTCOME"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_written "an owner action as the first non-empty line" issueUpdate
for length in 500 501; do
  body "$(pad '**Brad, what you do:** ' "$length")" '' "$OUTCOME"
  run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
  if [ "$length" -eq 500 ]; then assert_written "a 500-character owner action" issueUpdate
  else assert_refused "a 501-character owner action" issue-header-length 1 501; fi
done

echo "=== create: the header length ==="
LONG="$(pad '**Symptom**: ' 501)"
body "$OUTCOME" '' "$SOURCE_LINE" "$LONG" "$REACH_LINE"
run_linear issues create --title "Long symptom" --description-file "$TMP_ROOT/body.md"
assert_refused "a create with a 501-character **Symptom**: line" issue-header-length 4 501

body "$OUTCOME" '' "$(pad '**Symptom**: ' 500)" "$REACH_LINE"
run_linear issues create --title "Edge symptom" --description-file "$TMP_ROOT/body.md"
assert_written "a create with a 500-character header line" issueCreate

# 450 two-byte characters: over 500 bytes, under 500 characters.
# Counted by repetition, not ${#}, which counts bytes under a C locale.
WIDE='**Symptom**: '
for _ in $(seq 450); do WIDE+="é"; done
body "$OUTCOME" '' "$WIDE" "$REACH_LINE"
run_linear issues create --title "Wide symptom" --description-file "$TMP_ROOT/body.md"
assert_written "a create whose header is under 500 characters and over 500 bytes" issueCreate

body "$OUTCOME" '' 'The work is complete when refresh writes the render.' \
  '' '## Done when' '' '- [ ] Refresh writes the render.' \
  '' '## Filing record' '' "$SOURCE_LINE" '**Symptom**: the render stayed stale' "$REACH_LINE"
run_linear issues create --title "Template body" --description-file "$TMP_ROOT/body.md"
assert_written "a template-shaped create" issueCreate

echo "=== update: --description and --description-file ==="
run_linear issues update CC-1 --description "$(printf '%s\n\n%s\n' "$SOURCE_LINE" "$OUTCOME")"
assert_refused "an update --description opening with a **Source**: line" issue-header-opening 1 "${#SOURCE_LINE}"

body "$OUTCOME" '' "$LONG"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_refused "an update --description-file with a 501-character header" issue-header-length 3 501

body "$OUTCOME" '' "$SOURCE_LINE"
run_linear issues update CC-1 --description-file "$TMP_ROOT/body.md"
assert_written "a template-shaped update --description-file" issueUpdate

run_linear issues update CC-1 --description ""
assert_written "an update clearing the description" issueUpdate

echo "=== bulk-update: the shared authored description ==="
for form in split equals; do
  for shape in opening long template boundary empty; do
    rule=""
    case "$shape" in
      opening) description="$SOURCE_LINE"; rule=issue-header-opening; line=1; length="${#SOURCE_LINE}" ;;
      long) description="$(printf '%s\n\n%s' "$OUTCOME" "$LONG")"; rule=issue-header-length; line=3; length=501 ;;
      template) description="$(printf '%s\n\n%s' "$OUTCOME" "$SOURCE_LINE")" ;;
      boundary) description="$(printf '%s\n\n%s' "$OUTCOME" "$(pad '**Symptom**: ' 500)")" ;;
      empty) description="" ;;
    esac
    case "$form" in
      split) description_args=(--description "$description") ;;
      equals) description_args=(--description="$description") ;;
    esac
    run_linear issues bulk-update CC-1 CC-2 "${description_args[@]}"
    if [ -n "$rule" ]; then
      assert_refused "a bulk-update $form $shape description" "$rule" "$line" "$length"
    else
      assert_written "a bulk-update $form $shape description" issueUpdate
      assert_jq "a bulk-update $form $shape description updates every issue" "$OUT" \
        '.success == true and .updated == 2 and .failed == 0'
      assert "a bulk-update $form $shape description writes the authored text" \
        jq -s -e --arg desc "$description" \
        '[.[] | select(.query | contains("issueUpdate")) | .variables.input.description] == [$desc, $desc]' "$CURL_LOG"
    fi
  done
done

run_linear issues bulk-update CC-1 --description "$SOURCE_LINE" --description="$OUTCOME"
assert_written "a bulk-update replacing an invalid description option with a valid one" issueUpdate
run_linear issues bulk-update CC-1 --description="$OUTCOME" --description "$SOURCE_LINE"
assert_refused "a bulk-update replacing a valid description option with an invalid one" issue-header-opening 1 "${#SOURCE_LINE}"

printf '%s\n' "$SOURCE_LINE" "$LONG" >"$FILED"
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

echo "=== the reach guard's key holds this guard too ==="
for operation in create update bulk-update; do
  case "$operation" in
    create) box_args=(issues create --title "Post-merge check"); mutation=issueCreate ;;
    update) box_args=(issues update CC-1); mutation=issueUpdate ;;
    bulk-update) box_args=(issues bulk-update CC-1 CC-2); mutation=issueUpdate ;;
  esac
  while IFS='|' read -r trigger deadline rule; do
    description="$(printf '%s\n' "$OUTCOME" "$REACH_LINE" '## Done when' \
      "- [ ] Post-merge: Read health; Where: service; Why after merge: deployment; Trigger: $trigger; Deadline: $deadline")"
    run_linear "${box_args[@]}" --description "$description"
    if [ "$rule" = valid ]; then
      assert_written "$operation accepts $trigger with $deadline" "$mutation"
    else
      assert_ne "$operation refuses $trigger with $deadline" "$RC" 0
      assert_eq "$operation refuses $trigger with $deadline before any API call" "$(api_calls)" 0
      assert_jq "$operation names $rule and a fix" "$ERR" ".rule == \"$rule\" and .box == 1 and (.fix | length) > 0"
    fi
  done <<'ROWS'
release v*|+72h|post-merge-release-repository
merge|set at merge|post-merge-deadline
merge|2026-09-31T12:00:00Z|post-merge-deadline
release owner/repo v*|+72h|valid
merge|+72h|valid
merge|2026-10-02T00:00:00Z|valid
2026-10-01T00:00:00Z|2026-10-02T00:00:00Z|valid
ROWS
done

body "$SOURCE_LINE" "$REACH_LINE"
REACH=unset
run_linear issues create --title "Default key" --description-file "$TMP_ROOT/body.md"
assert_refused "with no LINEAR_REQUIRE_REACH key a create opening with a header" issue-header-opening 1 "${#SOURCE_LINE}"
run_linear issues bulk-update CC-1 --description "$SOURCE_LINE"
assert_refused "with no LINEAR_REQUIRE_REACH key a bulk-update opening with a header" issue-header-opening 1 "${#SOURCE_LINE}"

REACH=""
run_linear issues create --title "Key off" --description-file "$TMP_ROOT/body.md"
assert_written "with an empty LINEAR_REQUIRE_REACH a create opening with a header" issueCreate
run_linear issues bulk-update CC-1 --description="$SOURCE_LINE"
assert_written "with an empty LINEAR_REQUIRE_REACH a bulk-update opening with a header" issueUpdate
