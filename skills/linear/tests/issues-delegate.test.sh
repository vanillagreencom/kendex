#!/usr/bin/env bash
# bash-runtime: 4
# An agent works an issue as Linear's delegate while a person stays its
# assignee. issues create and update set --delegate, issues get reads it back,
# and both refuse, before any write, an identity Linear will not take in that
# role: an app user as another actor's assignee, a person as delegate, and an
# app whose install lacks app:assignable as delegate. users list marks app
# identities so a caller can tell them apart.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited the `git init` below re-inits
# the ambient repository instead of the fixture's. All four go together, which
# is the house rule in the repository's AGENTS.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# The CLI resolves its project from git rev-parse --show-toplevel, so the
# fixture is a repository of its own.
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

# The workspace as the live one reads: a person, an app whose install lacks
# app:assignable (Jarvis), one that has it (Codex), and the API key's own
# user, itself an app without it (VG Agents).
DANA=11111111-1111-4111-8111-111111111111
JARVIS=22222222-2222-4222-8222-222222222222
CODEX=33333333-3333-4333-8333-333333333333
VIEWER=44444444-4444-4444-8444-444444444444
jq -n --arg dana "$DANA" --arg jarvis "$JARVIS" --arg codex "$CODEX" --arg viewer "$VIEWER" '[
  {id: $dana, name: "Dana Doe", email: "dana@example.com", app: false, isAssignable: true},
  {id: $jarvis, name: "Jarvis", email: "jarvis@apps.example", app: true, isAssignable: false},
  {id: $codex, name: "Codex", email: "codex@apps.example", app: true, isAssignable: true},
  {id: $viewer, name: "VG Agents", email: "agents@apps.example", app: true, isAssignable: false}
]' >"$TMP_ROOT/users.json"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"
users="$(cat "${FAKE_USERS:?}")"

# Linear answers only the fields a query selects, so a user carries a fixture
# key only where the query names it as a word: a selection the code drops
# reads as absent here too.
selected='def selected: with_entries(select(.key as $k | $q | test("\\b" + $k + "\\b")));'

# users_page FILTER — the users connection holding the users FILTER selects.
users_page() {
  jq -cj --argjson v "$variables" --arg q "$query" "$selected"' {data: {users: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.[] | select('"$1"') | selected]}}}' <<<"$users"
  printf '%s' '___HTTP_CODE___200'
}

issue='{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"Todo","type":"unstarted"},"assignee":{"name":"Dana Doe","email":"dana@example.com"},"delegate":{"name":"Codex","email":"codex@apps.example"},"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"key":"CC","name":"Claude"},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"children":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"inverseRelations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}'
# The delegate answers only a query that selects it.
[[ "$query" == *"delegate {"* ]] || issue="$(jq -c 'del(.delegate)' <<<"$issue")"

case "$query" in
*"users(filter: {id:"*) users_page '.id == $v.id' ;;
*"users(filter: {email: {eqIgnoreCase:"*) users_page '(.email | ascii_downcase) == ($v.email | ascii_downcase)' ;;
*"users(filter: {name: {containsIgnoreCase:"*) users_page '(.name | ascii_downcase) | contains($v.name | ascii_downcase)' ;;
*"query ListUsers("*) users_page 'true' ;;
*"viewer {"*)
  jq -cj --arg id "${FAKE_VIEWER:?}" --arg q "$query" "$selected"' {data: {viewer: (.[] | select(.id == $id) | selected)}}' <<<"$users"
  printf '%s' '___HTTP_CODE___200'
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid","key":"CC","name":"Claude"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  printf '{"data":{"issue":%s}}___HTTP_CODE___200' "$issue"
  ;;
*"issueCreate(input:"*)
  printf '{"data":{"issueCreate":{"success":true,"issue":%s}}}___HTTP_CODE___200' "$issue"
  ;;
*"issueUpdate(id:"*)
  printf '{"data":{"issueUpdate":{"success":true,"issue":%s}}}___HTTP_CODE___200' "$issue"
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

# run_linear CASE RESOURCE ARGS... — one linear.sh call with the child's whole
# environment named here. Leaves CASE.out, CASE.err, CASE.rc and CASE.jsonl
# (every GraphQL payload sent) in TMP_ROOT.
run_linear() {
  local name="$1" rc=0
  shift
  local log="$TMP_ROOT/$name.jsonl"
  : >"$log"
  (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    XDG_CONFIG_HOME="$TMP_ROOT/.config" XDG_DATA_HOME="$TMP_ROOT/.local/share" \
    XDG_STATE_HOME="$TMP_ROOT/.local/state" XDG_CACHE_HOME="$TMP_ROOT/.cache" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC LINEAR_REQUIRE_REACH= \
    FAKE_USERS="$TMP_ROOT/users.json" FAKE_VIEWER="$VIEWER" CURL_PAYLOAD_LOG="$log" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" "$@") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
  printf '%s' "$rc" >"$TMP_ROOT/$name.rc"
}

# The mutation inputs a case sent.
inputs() {
  jq -s -c --arg mutation "$2" '[.[] | select(.query | contains($mutation)) | .variables.input]' "$TMP_ROOT/$1.jsonl"
}

# One row per case: case, action, --assignee value, --delegate value (- for
# no flag), then the assigneeId and delegateId the one mutation carries (- for
# a field the input leaves out), or the refusal code for a case that sends no
# mutation at all.
while IFS='|' read -r name action assignee delegate want_assignee want_delegate; do
  args=()
  [[ "$assignee" == - ]] || args+=(--assignee "$assignee")
  [[ "$delegate" == - ]] || args+=(--delegate "$delegate")
  case "$action" in
  create) run_linear "$name" issues create --title t "${args[@]}"; mutation=issueCreate ;;
  update) run_linear "$name" issues update CC-760 "${args[@]}"; mutation=issueUpdate ;;
  esac
  if [[ "$want_assignee" == refused ]]; then
    assert_ne "$name: the action fails" "$(cat "$TMP_ROOT/$name.rc")" 0
    assert_jq "$name: the refusal is $want_delegate" "$(cat "$TMP_ROOT/$name.err")" ".code == \"$want_delegate\""
    assert_jq "$name: no $mutation is sent" "$(inputs "$name" "$mutation")" 'length == 0'
    continue
  fi
  assert_eq "$name: the action exits zero" "$(cat "$TMP_ROOT/$name.rc")" 0
  for field in assigneeId:"$want_assignee" delegateId:"$want_delegate"; do
    key="${field%%:*}" want="${field#*:}"
    if [[ "$want" == - ]]; then
      assert_jq "$name: the $mutation leaves $key out" "$(inputs "$name" "$mutation")" \
        "length == 1 and (.[0] | has(\"$key\") | not)"
    else
      assert_jq "$name: the $mutation carries $key" "$(inputs "$name" "$mutation")" \
        "length == 1 and .[0].$key == \"$want\""
    fi
  done
done <<ROWS
person-assignee|update|Dana|-|$DANA|-
app-assignee-by-name|update|Jarvis|-|refused|ASSIGNEE_IS_APP
app-assignee-by-id|update|$JARVIS|-|refused|ASSIGNEE_IS_APP
app-assignee-by-email|create|codex@apps.example|-|refused|ASSIGNEE_IS_APP
self-app-assignee-me|update|me|-|$VIEWER|-
self-app-assignee-by-name|update|VG Agents|-|$VIEWER|-
app-delegate|update|-|Codex|-|$CODEX
app-delegate-create|create|-|$CODEX|-|$CODEX
person-with-app-delegate|update|dana@example.com|Codex|$DANA|$CODEX
person-delegate|update|-|dana@example.com|refused|DELEGATE_NOT_APP
unassignable-delegate|update|-|Jarvis|refused|DELEGATE_NOT_ASSIGNABLE
unassignable-delegate-beside-person|create|Dana|$JARVIS|refused|DELEGATE_NOT_ASSIGNABLE
self-unassignable-delegate|update|-|me|refused|DELEGATE_NOT_ASSIGNABLE
unknown-delegate|update|-|Nobody|refused|USER_NOT_FOUND
ROWS

run_linear clear issues update CC-760 --clear-delegate
assert_eq 'clear delegate: succeeds' "$(cat "$TMP_ROOT/clear.rc")" 0
assert_jq 'clear delegate: null in the mutation' "$(inputs clear issueUpdate)" \
  'length == 1 and (.[0] | has("delegateId") and .delegateId == null)'

# The read names the agent and the accountable person apart, in both get forms.
run_linear read issues get CC-760
assert_eq 'read: succeeds' "$(cat "$TMP_ROOT/read.rc")" 0
assert_jq 'read: names the delegate beside the assignee' "$(cat "$TMP_ROOT/read.out")" \
  '.delegate == "Codex" and .assignee == "Dana Doe"'
run_linear updated issues update CC-760 --delegate Codex --format=safe
assert_jq 'update --format=safe: names the delegate beside the assignee' "$(cat "$TMP_ROOT/updated.out")" \
  '.delegate == "Codex" and .assignee == "Dana Doe"'

run_linear users users list
assert_eq 'users list: succeeds' "$(cat "$TMP_ROOT/users.rc")" 0
assert_jq 'users list: marks each app identity and whether it can be a delegate' "$(cat "$TMP_ROOT/users.out")" \
  'map({key: .name, value: [.app, .assignable]}) | from_entries
   | .["Dana Doe"] == [false, true] and .Jarvis == [true, false] and .Codex == [true, true]'
