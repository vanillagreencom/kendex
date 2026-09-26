#!/usr/bin/env bash
# issues activate assigns an issue nobody is assigned to the person
# KENDEX_USER_EMAIL names, in the same issueUpdate as the state change. Every
# outcome but a failed read or update still lands the state change, and each
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

# FAKE_ASSIGNEE is the issue's current assignee as JSON (null for nobody).
# FAKE_FAIL names the one call that fails: `users` and `issue` answer a
# GraphQL error, `update` an issueUpdate with success false.
#
# The one user answers only a lookup filtered on the address itself, as
# Linear's eqIgnoreCase (case folded) or eq (exact) compares it: a listing
# scanned page by page is an unexpected query here.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"
dana='{"id":"11111111-2222-3333-4444-555555555555","name":"Dana Doe","email":"Dana@Example.com"}'

case "$query" in
*"users(filter: {email: {"*)
  if [[ "${FAKE_FAIL:-}" == users ]]; then
    printf '%s' '{"errors":[{"message":"users lookup unavailable"}]}___HTTP_CODE___200'
    exit 0
  fi
  asked="$(jq -r '.email' <<<"$variables")"
  stored="$(jq -r '.email' <<<"$dana")"
  if [[ "$query" == *"eqIgnoreCase:"* ]]; then
    asked="$(tr '[:upper:]' '[:lower:]' <<<"$asked")"
    stored="$(tr '[:upper:]' '[:lower:]' <<<"$stored")"
  fi
  if [[ "$asked" == "$stored" ]]; then
    printf '{"data":{"users":{"nodes":[%s]}}}___HTTP_CODE___200' "$dana"
  else
    printf '%s' '{"data":{"users":{"nodes":[]}}}___HTTP_CODE___200'
  fi
  ;;
*"issueLabels(filter:"*)
  case "$(jq -r '.name' <<<"$variables")" in
  "agent:rust") printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-agent-rust"}]}}}___HTTP_CODE___200' ;;
  "backend") printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-backend"}]}}}___HTTP_CODE___200' ;;
  *) printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}___HTTP_CODE___200' ;;
  esac
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-in-progress"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  if [[ "${FAKE_FAIL:-}" == issue ]]; then
    printf '%s' '{"errors":[{"message":"issue read unavailable"}]}___HTTP_CODE___200'
    exit 0
  fi
  jq -cj --argjson assignee "${FAKE_ASSIGNEE:-null}" '.data.issue.assignee = $assignee' <<'JSON'
{"data":{"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:old"},{"name":"backend"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","branchName":"cc-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"parent":null,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}
JSON
  printf '%s' '___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  if [[ "${FAKE_FAIL:-}" == update ]]; then
    printf '%s' '{"data":{"issueUpdate":{"success":false,"issue":null}}}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"In Progress","type":"started"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

# run_activate CASE AGENT EMAIL ASSIGNEE_JSON FAIL — activate CC-760, with
# --agent AGENT where AGENT is not empty, and the child's whole environment
# named here, so a KENDEX_USER_EMAIL the developer exports never reaches the
# case. Leaves CASE.out, CASE.err, CASE.rc and CASE.jsonl (every GraphQL
# payload sent) in TMP_ROOT.
run_activate() {
  local name="$1" agent="$2" email="$3" assignee="$4" fail="$5" rc=0
  local log="$TMP_ROOT/$name.jsonl" args=(CC-760)
  [[ -z "$agent" ]] || args+=(--agent "$agent")
  : >"$log"
  (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    KENDEX_USER_EMAIL="$email" FAKE_ASSIGNEE="$assignee" FAKE_FAIL="$fail" \
    CURL_PAYLOAD_LOG="$log" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues activate "${args[@]}") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
  printf '%s' "$rc" >"$TMP_ROOT/$name.rc"
}

updates() {
  jq -s -c '[.[] | select(.query | contains("issueUpdate")) | .variables.input]' "$TMP_ROOT/$1.jsonl"
}

users_calls() {
  jq -s '[.[] | select(.query | contains("users("))] | length' "$TMP_ROOT/$1.jsonl"
}

# One row per outcome: case, --agent, KENDEX_USER_EMAIL, current assignee,
# the keyed stderr line, the JSON assignee field, the assigneeId the one
# issueUpdate carries (none: the input has no assigneeId at all), and the
# labelIds it carries (none: no labelIds at all).
DANA_ID=11111111-2222-3333-4444-555555555555
OTHER='{"name":"Other Person","email":"other@example.com"}'
while IFS='|' read -r name agent email assignee line field sent labels; do
  run_activate "$name" "$agent" "$email" "$assignee" ""
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
  if [[ "$labels" == none ]]; then
    assert_jq "$name: the issueUpdate leaves the labels alone" \
      "$(updates "$name")" '.[0] | has("labelIds") | not'
  else
    assert_jq "$name: the issueUpdate carries the replaced label set" \
      "$(updates "$name")" ".[0].labelIds == $labels"
  fi
done <<ROWS
set||dana@example.com|null|assignee-set assignee=Dana Doe|set|$DANA_ID|none
set-agent|rust|dana@example.com|null|assignee-set assignee=Dana Doe|set|$DANA_ID|["label-backend","label-agent-rust"]
kept||dana@example.com|$OTHER|assignee-kept assignee=Other Person|kept|none|none
unset||||assignee-skipped cause=unset|skipped|none|none
unknown||nobody@example.com|null|assignee-skipped cause=unknown-email email=nobody@example.com|skipped|none|none
ROWS

assert_eq "set: the person is looked up once" "$(users_calls set)" 1
assert_eq "unset: no users lookup is made" "$(users_calls unset)" 0

# One row per failure: case, the call that fails, the issueUpdates sent, and
# the error stderr must carry (- for none beyond the refusal itself). None is
# a skip or a kept assignee, and none reports an assignee at all.
while IFS='|' read -r name fail sent needle; do
  run_activate "$name" "" dana@example.com null "$fail"
  assert_ne "$name: activation fails" "$(cat "$TMP_ROOT/$name.rc")" 0
  assert_eq "$name: issueUpdates sent" "$(jq 'length' <<<"$(updates "$name")")" "$sent"
  assert_not "$name: no assignee line is reported" grep -q '^assignee-' "$TMP_ROOT/$name.err"
  if [[ "$needle" != - ]]; then
    assert_file_contains "$name: the failed call's error is reported" "$TMP_ROOT/$name.err" "$needle"
  fi
done <<'ROWS'
lookup-failed|users|0|users lookup unavailable
issue-read-failed|issue|0|issue read unavailable
update-failed|update|1|-
ROWS
