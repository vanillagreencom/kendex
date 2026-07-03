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
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-558","title":"child","description":"c","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-uuid","name":"X"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-558","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  if [[ "$(jq -r '.id' <<<"$variables")" != "child-uuid" || "$(jq -r '.input.parentId // empty' <<<"$variables")" != "parent-uuid" ]]; then
    printf '%s' '{"errors":[{"message":"unexpected parent repair"}]}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-558","title":"child","description":"c","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"project-uuid","name":"X"},"projectMilestone":null,"cycle":null,"parent":{"id":"parent-uuid","identifier":"CC-557","title":"parent"},"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-558","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

export CURL_PAYLOAD_LOG="$TMP_ROOT/payloads.jsonl"
out="$(
  PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues create \
      --title child \
      --team Claude \
      --project X \
      --labels agent:rust \
      --priority 3 \
      --parent CC-557 \
      --description c
)"

if ! jq -e '.success == true and .identifier == "CC-558" and .data.issue.parent.identifier == "CC-557"' >/dev/null <<<"$out"; then
  echo "FAIL issues create --parent returned unexpected output: $out"
  exit 1
fi

if ! jq -s -e 'any(.[]; (.query | contains("query GetIssue")) and .variables.id == "CC-557")' "$CURL_PAYLOAD_LOG" >/dev/null; then
  echo "FAIL --parent identifier was not resolved through GetIssue"
  cat "$CURL_PAYLOAD_LOG"
  exit 1
fi

if ! jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.parentId == "parent-uuid" and .variables.input.projectId == "project-uuid" and .variables.input.labelIds == ["label-uuid"])' "$CURL_PAYLOAD_LOG" >/dev/null; then
  echo "FAIL issueCreate payload did not include resolved parent/project/label ids"
  cat "$CURL_PAYLOAD_LOG"
  exit 1
fi

if ! jq -s -e 'any(.[]; (.query | contains("issueUpdate")) and .variables.id == "child-uuid" and .variables.input.parentId == "parent-uuid")' "$CURL_PAYLOAD_LOG" >/dev/null; then
  echo "FAIL missing follow-up issueUpdate parent repair"
  cat "$CURL_PAYLOAD_LOG"
  exit 1
fi

echo "all pass"
