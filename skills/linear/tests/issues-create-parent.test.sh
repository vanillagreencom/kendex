#!/usr/bin/env bash
# issues create --parent must link the created issue.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes from `issues create` land in
# the real project's `.cache/linear`.
git -C "$TMP_ROOT" init -q -b main

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
  (
    cd "$TMP_ROOT" && \
    PATH="$TMP_ROOT/bin:$PATH" \
      LINEAR_API_KEY_OVERRIDE=test-token \
      CURL_PAYLOAD_LOG="$payload_log" \
      LINEAR_PARENT_TEST_CASE="$scenario" \
      bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues create \
        --title child \
        --team Claude \
        --project X \
        --labels agent:rust \
        --priority 3 \
        --parent CC-557 \
        --description c
  ) >"$stdout_file" 2>"$stderr_file"
}

success_out="$TMP_ROOT/success.out"
success_err="$TMP_ROOT/success.err"
success_payload="$TMP_ROOT/success-payloads.jsonl"
assert "issues create --parent succeeds on the repair scenario" \
  run_create repair "$success_out" "$success_err" "$success_payload"

out="$(cat "$success_out")"
assert "issues create --parent reports the child under its parent" \
  jq -e '.success == true and .identifier == "CC-558" and .data.issue.parent.identifier == "CC-557"' >/dev/null <<<"$out"

assert "the --parent identifier resolves through GetIssue" \
  jq -s -e 'any(.[]; (.query | contains("query GetIssue")) and .variables.id == "CC-557")' "$success_payload" >/dev/null

assert "the issueCreate payload carries the resolved parent, project and label ids" \
  jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.parentId == "parent-uuid" and .variables.input.projectId == "project-uuid" and .variables.input.labelIds == ["label-uuid"])' "$success_payload" >/dev/null

assert "a follow-up issueUpdate repairs the parent link" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.id == "child-uuid" and .variables.input.parentId == "parent-uuid")' "$success_payload" >/dev/null

assert_create_fails() {
  local scenario="$1"
  local expected="$2"
  local stdout_file="$TMP_ROOT/$scenario.out"
  local stderr_file="$TMP_ROOT/$scenario.err"
  local payload_log="$TMP_ROOT/$scenario-payloads.jsonl"
  local rc

  rc=0
  run_create "$scenario" "$stdout_file" "$stderr_file" "$payload_log" || rc=$?

  assert_ne "scenario $scenario fails" \
    "$rc" 0

  assert "scenario $scenario names the expected error" \
    grep -q "$expected" "$stderr_file"

  if [[ -s "$stdout_file" ]]; then
    assert_not "scenario $scenario emits no normalized success" \
      jq -e '.success == true' "$stdout_file"
  fi
}

assert_create_fails missing-issue "omitted issue object"
assert_create_fails missing-child-id "omitted child id"
assert_create_fails update-error "follow-up repair failed"
assert_create_fails repair-unverified "could not be verified after follow-up repair"

