#!/usr/bin/env bash
# Regression test for #553: issues complete must parse --summary/--summary-file
# (post the completion comment BEFORE transitioning to Done) and reject unknown
# or trailing arguments before any mutation.

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
# `.cache/linear` (kendex#43).
git -C "$TMP_ROOT" init -q -b main

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
scenario="${LINEAR_COMPLETE_TEST_CASE:-ok}"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"commentCreate(input:"*)
  if [[ "$scenario" == "comment-fail" ]]; then
    printf '%s' '{"errors":[{"message":"comment rejected"}]}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"commentCreate":{"success":true,"comment":{"id":"comment-1","body":"ok","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","user":{"name":"Test"},"issue":{"identifier":"CC-720","updatedAt":"2026-07-14T00:00:00Z"}}}}}___HTTP_CODE___200'
  fi
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-done"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  printf '%s' '{"data":{"issue":{"id":"issue-uuid","identifier":"CC-720","title":"t","description":null,"state":{"name":"In Review","type":"started"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"backend"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-720","branchName":"cc-720","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"parent":null,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-uuid","identifier":"CC-720","title":"t","description":null,"state":{"name":"Done","type":"completed"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"backend"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-720","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_complete() {
  local scenario="$1"
  local payload_log="$2"
  shift 2
  : >"$payload_log"
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    CURL_PAYLOAD_LOG="$payload_log" \
    LINEAR_COMPLETE_TEST_CASE="$scenario" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues complete "$@")
}

# --- --summary-file posts the canonical comment, then transitions
summary_file="$TMP_ROOT/summary.md"
cat >"$summary_file" <<'MD'
## Completion Summary

**Agent**: rust

Implemented the thing.
MD

file_payload="$TMP_ROOT/file-payloads.jsonl"
out="$(run_complete ok "$file_payload" CC-720 --summary-file "$summary_file" 2>"$TMP_ROOT/file.err")"

assert "complete --summary-file reports the summary as posted" \
  jq -e '.success == true and .action == "completed" and .summary_posted == true' >/dev/null <<<"$out"

posted_body="$(jq -s -r '[.[] | select(.query | contains("commentCreate"))][0].variables.input.body' "$file_payload")"
assert_contains "the posted comment carries the summary file's heading" \
  "$posted_body" "## Completion Summary"
assert_contains "the posted comment carries the summary file's body" \
  "$posted_body" "Implemented the thing."
assert_not_contains "a summary already carrying the marker is not double-prefixed" \
  "$posted_body" "Completion Summary
## Completion Summary"

comment_idx="$(jq -s '[to_entries[] | select(.value.query | contains("commentCreate"))][0].key' "$file_payload")"
update_idx="$(jq -s '[to_entries[] | select(.value.query | contains("issueUpdate"))][0].key' "$file_payload")"
assert_ne "the comment post is present in the payload log" "$comment_idx" "null"
assert_ne "the Done transition is present in the payload log" "$update_idx" "null"
assert "the comment post precedes the Done transition" \
  test "$comment_idx" -lt "$update_idx"
assert "the issueUpdate targets the Done state" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.input.stateId == "state-done")' "$file_payload" >/dev/null

# --- inline --summary without a marker gets the canonical heading prefixed
inline_payload="$TMP_ROOT/inline-payloads.jsonl"
out="$(run_complete ok "$inline_payload" CC-720 --summary "Shipped it" 2>"$TMP_ROOT/inline.err")"
assert "complete --summary reports the summary as posted" \
  jq -e '.success == true and .summary_posted == true' >/dev/null <<<"$out"
inline_body="$(jq -s -r '[.[] | select(.query | contains("commentCreate"))][0].variables.input.body' "$inline_payload")"
assert_eq "an inline summary is prefixed with the canonical heading" \
  "$inline_body" "## Completion Summary"$'\n\n'"Shipped it"

# --- a failed comment post leaves the issue state unchanged
fail_payload="$TMP_ROOT/fail-payloads.jsonl"
rc=0
run_complete comment-fail "$fail_payload" CC-720 --summary "Shipped it" >"$TMP_ROOT/fail.out" 2>"$TMP_ROOT/fail.err" || rc=$?
assert_ne "a failing comment post fails the completion" \
  "$rc" 0
assert "missing clear error for failed summary comment" \
  grep -q "Completion summary comment failed" "$TMP_ROOT/fail.err"
assert_not "issue was transitioned despite failed summary comment" \
  jq -s -e 'any(.[]; .query | contains("issueUpdate"))' "$fail_payload" >/dev/null

# --- unknown/trailing arguments are rejected before any mutation
assert_rejected() {
  local expected="$1"
  shift
  local payload_log="$TMP_ROOT/reject-payloads.jsonl"
  set +e
  run_complete ok "$payload_log" "$@" >"$TMP_ROOT/reject.out" 2>"$TMP_ROOT/reject.err"
  local rc=$?
  set -e
  assert_ne "complete $* unexpectedly succeeded" \
    "$rc" 0
  assert "complete $* refuses with the expected error" \
    grep -q "$expected" "$TMP_ROOT/reject.err"
  assert_not "complete $* rejects the arguments before reaching the API" \
    test -s "$payload_log"
}

assert_rejected "Unexpected argument: stray" CC-720 stray
assert_rejected "Unknown option: --sumary-file" CC-720 --sumary-file "$summary_file"
assert_rejected "mutually exclusive" CC-720 --summary "x" --summary-file "$summary_file"
assert_rejected "not readable" CC-720 --summary-file "$TMP_ROOT/does-not-exist.md"

# --- plain complete keeps prior behavior (no comment, straight to Done)
plain_payload="$TMP_ROOT/plain-payloads.jsonl"
out="$(run_complete ok "$plain_payload" CC-720 2>"$TMP_ROOT/plain.err")"
assert "plain complete reports a completion with no summary" \
  jq -e '.success == true and .action == "completed" and (has("summary_posted") | not)' >/dev/null <<<"$out"
assert_not "plain complete posts no comment" \
  jq -s -e 'any(.[]; .query | contains("commentCreate"))' "$plain_payload" >/dev/null
assert "plain complete transitions to Done" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.input.stateId == "state-done")' "$plain_payload" >/dev/null

