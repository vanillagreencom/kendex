#!/usr/bin/env bash
# Regression test for #553: issues complete must parse --summary/--summary-file
# (post the completion comment BEFORE transitioning to Done) and reject unknown
# or trailing arguments before any mutation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

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
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_PAYLOAD_LOG="$payload_log" \
    LINEAR_COMPLETE_TEST_CASE="$scenario" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues complete "$@"
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

if ! jq -e '.success == true and .action == "completed" and .summary_posted == true' >/dev/null <<<"$out"; then
  echo "FAIL complete --summary-file returned unexpected output: $out"
  exit 1
fi

posted_body="$(jq -s -r '[.[] | select(.query | contains("commentCreate"))][0].variables.input.body' "$file_payload")"
if [[ "$posted_body" != *"## Completion Summary"* || "$posted_body" != *"Implemented the thing."* ]]; then
  echo "FAIL posted comment did not carry the summary file content: $posted_body"
  exit 1
fi
if [[ "$posted_body" == *"Completion Summary"*"## Completion Summary"* ]]; then
  echo "FAIL summary already carrying the marker was double-prefixed: $posted_body"
  exit 1
fi

comment_idx="$(jq -s '[to_entries[] | select(.value.query | contains("commentCreate"))][0].key' "$file_payload")"
update_idx="$(jq -s '[to_entries[] | select(.value.query | contains("issueUpdate"))][0].key' "$file_payload")"
if [[ "$comment_idx" == "null" || "$update_idx" == "null" || "$comment_idx" -ge "$update_idx" ]]; then
  echo "FAIL comment post must precede the Done transition (comment=$comment_idx update=$update_idx)"
  cat "$file_payload"
  exit 1
fi
if ! jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.input.stateId == "state-done")' "$file_payload" >/dev/null; then
  echo "FAIL issueUpdate did not target the Done state"
  cat "$file_payload"
  exit 1
fi

# --- inline --summary without a marker gets the canonical heading prefixed
inline_payload="$TMP_ROOT/inline-payloads.jsonl"
out="$(run_complete ok "$inline_payload" CC-720 --summary "Shipped it" 2>"$TMP_ROOT/inline.err")"
if ! jq -e '.success == true and .summary_posted == true' >/dev/null <<<"$out"; then
  echo "FAIL complete --summary returned unexpected output: $out"
  exit 1
fi
inline_body="$(jq -s -r '[.[] | select(.query | contains("commentCreate"))][0].variables.input.body' "$inline_payload")"
if [[ "$inline_body" != "## Completion Summary"$'\n\n'"Shipped it" ]]; then
  echo "FAIL inline summary was not prefixed with the canonical heading: $inline_body"
  exit 1
fi

# --- a failed comment post leaves the issue state unchanged
fail_payload="$TMP_ROOT/fail-payloads.jsonl"
set +e
run_complete comment-fail "$fail_payload" CC-720 --summary "Shipped it" >"$TMP_ROOT/fail.out" 2>"$TMP_ROOT/fail.err"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL complete with failing comment post unexpectedly succeeded"
  cat "$TMP_ROOT/fail.out"
  exit 1
fi
if ! grep -q "Completion summary comment failed" "$TMP_ROOT/fail.err"; then
  echo "FAIL missing clear error for failed summary comment"
  cat "$TMP_ROOT/fail.err"
  exit 1
fi
if jq -s -e 'any(.[]; .query | contains("issueUpdate"))' "$fail_payload" >/dev/null; then
  echo "FAIL issue was transitioned despite failed summary comment"
  cat "$fail_payload"
  exit 1
fi

# --- unknown/trailing arguments are rejected before any mutation
assert_rejected() {
  local expected="$1"
  shift
  local payload_log="$TMP_ROOT/reject-payloads.jsonl"
  set +e
  run_complete ok "$payload_log" "$@" >"$TMP_ROOT/reject.out" 2>"$TMP_ROOT/reject.err"
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL complete $* unexpectedly succeeded"
    cat "$TMP_ROOT/reject.out"
    exit 1
  fi
  if ! grep -q "$expected" "$TMP_ROOT/reject.err"; then
    echo "FAIL complete $* missing expected error: $expected"
    cat "$TMP_ROOT/reject.err"
    exit 1
  fi
  if [[ -s "$payload_log" ]]; then
    echo "FAIL complete $* reached the API before argument rejection"
    cat "$payload_log"
    exit 1
  fi
}

assert_rejected "Unexpected argument: stray" CC-720 stray
assert_rejected "Unknown option: --sumary-file" CC-720 --sumary-file "$summary_file"
assert_rejected "mutually exclusive" CC-720 --summary "x" --summary-file "$summary_file"
assert_rejected "not readable" CC-720 --summary-file "$TMP_ROOT/does-not-exist.md"

# --- plain complete keeps prior behavior (no comment, straight to Done)
plain_payload="$TMP_ROOT/plain-payloads.jsonl"
out="$(run_complete ok "$plain_payload" CC-720 2>"$TMP_ROOT/plain.err")"
if ! jq -e '.success == true and .action == "completed" and (has("summary_posted") | not)' >/dev/null <<<"$out"; then
  echo "FAIL plain complete returned unexpected output: $out"
  exit 1
fi
if jq -s -e 'any(.[]; .query | contains("commentCreate"))' "$plain_payload" >/dev/null; then
  echo "FAIL plain complete posted an unexpected comment"
  cat "$plain_payload"
  exit 1
fi
if ! jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.input.stateId == "state-done")' "$plain_payload" >/dev/null; then
  echo "FAIL plain complete did not transition to Done"
  cat "$plain_payload"
  exit 1
fi

echo "all pass"
