#!/usr/bin/env bash
# --assignee on issues create and issues update takes an email address: a
# value containing `@` is matched against a user's whole address,
# case-insensitively, and a miss refuses before any mutation. A user id is
# sent as given, and the name form keeps matching as a substring.

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

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes land in the real project's
# `.cache/linear`.
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

# The one user answers only a lookup filtered on the address itself, compared
# as Linear compares under eqIgnoreCase (case folded), eq (exact) or
# containsIgnoreCase (a substring): a listing scanned page by page is an
# unexpected query here.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

issue='{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'

case "$query" in
*"users(filter: {email: {"*)
  asked="$(jq -r '.email' <<<"$variables")"
  stored="Dana@Example.com"
  folded_asked="$(tr '[:upper:]' '[:lower:]' <<<"$asked")"
  folded_stored="$(tr '[:upper:]' '[:lower:]' <<<"$stored")"
  case "$query" in
  *"eqIgnoreCase:"*) [[ "$folded_asked" == "$folded_stored" ]] ;;
  *"containsIgnoreCase:"*) [[ "$folded_stored" == *"$folded_asked"* ]] ;;
  *"eq:"*) [[ "$asked" == "$stored" ]] ;;
  *) false ;;
  esac && hit=1 || hit=0
  if [[ "$hit" == 1 ]]; then
    printf '%s' '{"data":{"users":{"nodes":[{"id":"11111111-2222-3333-4444-555555555555","name":"Dana Doe","email":"Dana@Example.com"}]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"users":{"nodes":[]}}}___HTTP_CODE___200'
  fi
  ;;
*"users(filter: {name:"*)
  if [[ "$(jq -r '.name' <<<"$variables")" == "Dana" ]]; then
    printf '%s' '{"data":{"users":{"nodes":[{"id":"11111111-2222-3333-4444-555555555555"}]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"users":{"nodes":[]}}}___HTTP_CODE___200'
  fi
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
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

# run_issues CASE ARGS... — one issues action with the child's whole
# environment named here. Leaves CASE.out, CASE.err, CASE.rc and CASE.jsonl
# (every GraphQL payload sent) in TMP_ROOT.
run_issues() {
  local name="$1" rc=0
  shift
  local log="$TMP_ROOT/$name.jsonl"
  : >"$log"
  (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    CURL_PAYLOAD_LOG="$log" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues "$@") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
  printf '%s' "$rc" >"$TMP_ROOT/$name.rc"
}

# The mutation inputs a case sent, for the one mutation its action makes.
inputs() {
  jq -s -c --arg mutation "$2" \
    '[.[] | select(.query | contains($mutation)) | .variables.input]' "$TMP_ROOT/$1.jsonl"
}

# One row per case: case, action, --assignee value, the assigneeId the
# mutation carries, or `refused` for a miss that sends no mutation at all, and
# whether the action also carries --attach. A refusal comes before any upload,
# so a miss leaves no asset behind.
DANA_ID=11111111-2222-3333-4444-555555555555
OTHER_ID=99999999-8888-7777-6666-555555555555
printf 'notes\n' >"$TMP_ROOT/notes.txt"
while IFS='|' read -r name action ref want attach; do
  # Guarded at each expansion: Bash before 4.4 reads an empty array under
  # set -u as unbound.
  extra=()
  [[ "$attach" != attach ]] || extra=(--attach "$TMP_ROOT/notes.txt")
  case "$action" in
  create) run_issues "$name" create --title t --assignee "$ref" ${extra[@]+"${extra[@]}"}; mutation=issueCreate ;;
  update) run_issues "$name" update CC-760 --assignee "$ref" ${extra[@]+"${extra[@]}"}; mutation=issueUpdate ;;
  esac
  if [[ "$want" == refused ]]; then
    assert_ne "$name: the action fails" "$(cat "$TMP_ROOT/$name.rc")" 0
    assert_jq "$name: the refusal names the value" "$(cat "$TMP_ROOT/$name.err")" \
      ".error == \"Assignee not found: $ref\""
    assert_jq "$name: no $mutation is sent" "$(inputs "$name" "$mutation")" 'length == 0'
    assert_eq "$name: no file is uploaded" \
      "$(jq -s '[.[] | select(.query | contains("fileUpload"))] | length' "$TMP_ROOT/$name.jsonl")" 0
  else
    assert_eq "$name: the action exits zero" "$(cat "$TMP_ROOT/$name.rc")" 0
    assert_jq "$name: the $mutation carries the user's id" \
      "$(inputs "$name" "$mutation")" "length == 1 and .[0].assigneeId == \"$want\""
  fi
done <<ROWS
create-email|create|dana@EXAMPLE.com|$DANA_ID|-
create-email-miss|create|nobody@example.com|refused|-
create-attach-miss|create|nobody@example.com|refused|attach
update-email|update|dana@example.com|$DANA_ID|-
update-email-miss|update|nobody@example.com|refused|-
update-attach-miss|update|nobody@example.com|refused|attach
update-email-partial|update|ana@example.com|refused|-
update-name|update|Dana|$DANA_ID|-
update-id|update|$OTHER_ID|$OTHER_ID|-
ROWS
