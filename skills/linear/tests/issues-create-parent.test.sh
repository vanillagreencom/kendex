#!/usr/bin/env bash
# Regression test: issues create --parent must link the created issue.

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
variables="$(jq -c '.variables' <<<"$payload")"
scenario="${LINEAR_PARENT_TEST_CASE:-repair}"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"projects(filter:"*)
  printf '%s' '{"data":{"projects":{"nodes":[{"id":"project-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  if [[ "$(jq -r '.id' <<<"$variables")" != "CC-557" ]]; then
    printf '%s' '{"errors":[{"message":"unexpected parent lookup"}]}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' '{"data":{"issue":{"id":"parent-uuid"}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  if [[ "$(jq -r '.input.parentId // empty' <<<"$variables")" != "parent-uuid" ]]; then
    printf '%s' '{"errors":[{"message":"issueCreate missing parentId"}]}___HTTP_CODE___200'
    exit 0
  fi
  case "$scenario" in
  missing-issue)
    printf '%s' '{"data":{"issueCreate":{"success":true,"issue":null}}}___HTTP_CODE___200'
    ;;
  missing-child-id)
    printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"identifier":"CC-558","title":"child","description":"c","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-uuid","name":"X"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-558","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
    ;;
  *)
    printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-558","title":"child","description":"c","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-uuid","name":"X"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-558","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
    ;;
  esac
  ;;
*"issueUpdate(id:"*)
  if [[ "$(jq -r '.id' <<<"$variables")" != "child-uuid" || "$(jq -r '.input.parentId // empty' <<<"$variables")" != "parent-uuid" ]]; then
    printf '%s' '{"errors":[{"message":"unexpected parent repair"}]}___HTTP_CODE___200'
    exit 0
  fi
  case "$scenario" in
  update-error)
    printf '%s' '{"errors":[{"message":"update failed"}]}___HTTP_CODE___200'
    ;;
  repair-unverified)
    printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-558","title":"child","description":"c","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-uuid","name":"X"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-558","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
    ;;
  *)
    printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-558","title":"child","description":"c","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-uuid","name":"X"},"projectMilestone":null,"cycle":null,"parent":{"id":"parent-uuid","identifier":"CC-557","title":"parent"},"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-558","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
    ;;
  esac
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_create() {
  local scenario="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local payload_log="$4"

  : >"$payload_log"
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_PAYLOAD_LOG="$payload_log" \
    LINEAR_PARENT_TEST_CASE="$scenario" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues create \
      --title child \
      --team Claude \
      --project X \
      --labels agent:rust \
      --priority 3 \
      --parent CC-557 \
      --description c \
      >"$stdout_file" 2>"$stderr_file"
}

success_out="$TMP_ROOT/success.out"
success_err="$TMP_ROOT/success.err"
success_payload="$TMP_ROOT/success-payloads.jsonl"
if ! run_create repair "$success_out" "$success_err" "$success_payload"; then
  echo "FAIL issues create --parent repair scenario failed"
  cat "$success_err"
  exit 1
fi

out="$(cat "$success_out")"
if ! jq -e '.success == true and .identifier == "CC-558" and .data.issue.parent.identifier == "CC-557"' >/dev/null <<<"$out"; then
  echo "FAIL issues create --parent returned unexpected output: $out"
  exit 1
fi

if ! jq -s -e 'any(.[]; (.query | contains("query GetIssue")) and .variables.id == "CC-557")' "$success_payload" >/dev/null; then
  echo "FAIL --parent identifier was not resolved through GetIssue"
  cat "$success_payload"
  exit 1
fi

if ! jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.parentId == "parent-uuid" and .variables.input.projectId == "project-uuid" and .variables.input.labelIds == ["label-uuid"])' "$success_payload" >/dev/null; then
  echo "FAIL issueCreate payload did not include resolved parent/project/label ids"
  cat "$success_payload"
  exit 1
fi

if ! jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.id == "child-uuid" and .variables.input.parentId == "parent-uuid")' "$success_payload" >/dev/null; then
  echo "FAIL missing follow-up issueUpdate parent repair"
  cat "$success_payload"
  exit 1
fi

assert_create_fails() {
  local scenario="$1"
  local expected="$2"
  local stdout_file="$TMP_ROOT/$scenario.out"
  local stderr_file="$TMP_ROOT/$scenario.err"
  local payload_log="$TMP_ROOT/$scenario-payloads.jsonl"
  local rc

  set +e
  run_create "$scenario" "$stdout_file" "$stderr_file" "$payload_log"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL scenario $scenario unexpectedly succeeded"
    cat "$stdout_file"
    exit 1
  fi

  if ! grep -q "$expected" "$stderr_file"; then
    echo "FAIL scenario $scenario missing expected error: $expected"
    cat "$stderr_file"
    exit 1
  fi

  if [[ -s "$stdout_file" ]] && jq -e '.success == true' "$stdout_file" >/dev/null 2>&1; then
    echo "FAIL scenario $scenario emitted normalized success"
    cat "$stdout_file"
    exit 1
  fi
}

assert_create_fails missing-issue "omitted issue object"
assert_create_fails missing-child-id "omitted child id"
assert_create_fails update-error "follow-up repair failed"
assert_create_fails repair-unverified "could not be verified after follow-up repair"

echo "all pass"
