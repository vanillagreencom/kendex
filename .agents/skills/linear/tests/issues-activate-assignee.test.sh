#!/usr/bin/env bash
# issues activate assigns an issue nobody is assigned to the person
# KENDEX_USER_EMAIL names, in the same issueUpdate as the state change. Every
# outcome but a failed users lookup still lands the state change, and each
# says what happened in one keyed stderr line and the JSON `assignee` field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes land in the real project's
# `.cache/linear`.
git -C "$TMP_ROOT" init -q -b main

# FAKE_ASSIGNEE is the issue's current assignee as JSON (null for nobody);
# FAKE_USERS_FAIL=1 makes the users listing answer with a GraphQL error.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"users(first:"*)
  if [[ "${FAKE_USERS_FAIL:-}" == 1 ]]; then
    printf '%s' '{"errors":[{"message":"users listing unavailable"}]}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"users":{"nodes":[{"id":"user-other","name":"Other Person","email":"other@example.com","displayName":"other","active":true,"admin":false,"createdAt":"2026-01-01T00:00:00Z"},{"id":"user-dana","name":"Dana Doe","email":"Dana@Example.com","displayName":"dana","active":true,"admin":false,"createdAt":"2026-01-01T00:00:00Z"}]}}}___HTTP_CODE___200'
  fi
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-in-progress"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  jq -cj --argjson assignee "${FAKE_ASSIGNEE:-null}" '.data.issue.assignee = $assignee' <<'JSON'
{"data":{"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","branchName":"cc-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"parent":null,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}
JSON
  printf '%s' '___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"In Progress","type":"started"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

# run_activate CASE EMAIL ASSIGNEE_JSON USERS_FAIL — activate CC-760 with the
# child's whole environment named here, so a KENDEX_USER_EMAIL the developer
# exports never reaches the case. Leaves CASE.out, CASE.err, CASE.rc and
# CASE.jsonl (every GraphQL payload sent) in TMP_ROOT.
run_activate() {
  local name="$1" email="$2" assignee="$3" users_fail="$4" rc=0
  local log="$TMP_ROOT/$name.jsonl"
  : >"$log"
  (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    KENDEX_USER_EMAIL="$email" FAKE_ASSIGNEE="$assignee" FAKE_USERS_FAIL="$users_fail" \
    CURL_PAYLOAD_LOG="$log" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues activate CC-760) \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
  printf '%s' "$rc" >"$TMP_ROOT/$name.rc"
}

updates() {
  jq -s -c '[.[] | select(.query | contains("issueUpdate")) | .variables.input]' "$TMP_ROOT/$1.jsonl"
}

# One row per outcome: case, KENDEX_USER_EMAIL, current assignee, the keyed
# stderr line, the JSON assignee field, and the assigneeId the one
# issueUpdate carries (none: the input has no assigneeId at all).
OTHER='{"name":"Other Person","email":"other@example.com"}'
while IFS='|' read -r name email assignee line field sent; do
  run_activate "$name" "$email" "$assignee" ""
  assert_eq "$name: activation exits zero" "$(cat "$TMP_ROOT/$name.rc")" 0
  assert "$name: stderr carries the keyed line" grep -qxF -- "$line" "$TMP_ROOT/$name.err"
  assert_jq "$name: the result reports assignee $field" \
    "$(cat "$TMP_ROOT/$name.out")" ".success == true and .assignee == \"$field\""
  assert_jq "$name: one issueUpdate lands the state change" \
    "$(updates "$name")" 'length == 1 and .[0].stateId == "state-in-progress"'
  if [[ "$sent" == none ]]; then
    assert_jq "$name: the issueUpdate leaves the assignee alone" \
      "$(updates "$name")" '.[0] | has("assigneeId") | not'
  else
    assert_jq "$name: the issueUpdate carries the assignee" \
      "$(updates "$name")" ".[0].assigneeId == \"$sent\""
  fi
done <<ROWS
set|dana@example.com|null|assignee-set assignee=Dana Doe|set|user-dana
kept|dana@example.com|$OTHER|assignee-kept assignee=Other Person|kept|none
unset||null|assignee-skipped cause=unset|skipped|none
unknown|nobody@example.com|null|assignee-skipped cause=unknown-email email=nobody@example.com|skipped|none
ROWS

assert_not "unset: no users lookup is made" \
  jq -s -e 'any(.[]; .query | contains("users(first:"))' "$TMP_ROOT/unset.jsonl"

# A lookup that failed is not an unknown address: activation fails with the
# listing's error and changes nothing.
run_activate lookup-failed dana@example.com null 1
assert_ne "lookup-failed: activation fails" "$(cat "$TMP_ROOT/lookup-failed.rc")" 0
assert_file_contains "lookup-failed: the listing's error is reported" \
  "$TMP_ROOT/lookup-failed.err" "users listing unavailable"
assert_file_lacks "lookup-failed: no skip is reported" \
  "$TMP_ROOT/lookup-failed.err" "assignee-skipped"
assert_jq "lookup-failed: no issueUpdate is sent" "$(updates lookup-failed)" 'length == 0'
