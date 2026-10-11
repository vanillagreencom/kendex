#!/usr/bin/env bash
# Tests for the header-shape guard. Under the reach guard's key, `issues
# create` and `issues update --description` / `--description-file` refuse,
# before any API call, a body whose first non-empty line is a `**Key**:` or
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
issue='{id:"issue-uuid",identifier:"CC-1",title:"t",description:$d,state:{name:"Todo",type:"unstarted"},assignee:null,project:null,projectMilestone:null,cycle:null,parent:null,team:{id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/x/issue/CC-1",branchName:"cc-1",createdAt:"2026-10-11T00:00:00Z",updatedAt:"2026-10-11T00:00:00Z",archivedAt:null,trashed:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}'
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

echo "=== complete: ticking a body filed before the guard ==="
printf '%s\n' "$SOURCE_LINE" "$LONG" '' '## Done when' '' '- [ ] first' >"$FILED"
run_linear issues complete CC-1 --done-when-met 1
assert_written "a complete ticking a body that opens with a long header" issueUpdate
assert "the complete writes the ticked box" \
  jq -s -e 'any(.[]; .variables.input.description // "" | contains("- [x] first"))' "$CURL_LOG"
: >"$FILED"

echo "=== the reach guard's key holds this guard too ==="
body "$SOURCE_LINE" "$REACH_LINE"
REACH=unset
run_linear issues create --title "Default key" --description-file "$TMP_ROOT/body.md"
assert_refused "with no LINEAR_REQUIRE_REACH key a create opening with a header" issue-header-opening 1 "${#SOURCE_LINE}"

REACH=""
run_linear issues create --title "Key off" --description-file "$TMP_ROOT/body.md"
assert_written "with an empty LINEAR_REQUIRE_REACH a create opening with a header" issueCreate
