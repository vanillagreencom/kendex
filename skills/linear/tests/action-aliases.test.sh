#!/usr/bin/env bash
# Regression test: documented legacy action aliases should route to the
# canonical relation/dependency list commands.

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

case "$query" in
*"GetRelations"*)
  printf '%s' '{"data":{"issue":{"identifier":"PROJ-42","title":"Current","relations":{"nodes":[{"id":"rel-1","type":"blocks","relatedIssue":{"id":"issue-43","identifier":"PROJ-43","title":"Downstream","state":{"name":"Todo"}}}]},"inverseRelations":{"nodes":[{"id":"rel-2","type":"blocks","issue":{"id":"issue-41","identifier":"PROJ-41","title":"Upstream","state":{"name":"In Progress"}}}]}}}}___HTTP_CODE___200'
  ;;
*"projects(filter: {name: {eq: \$name}}"*)
  if [[ "$(jq -r '.name' <<<"$variables")" != 'Project "Quoted"' ]]; then
    printf '%s' '{"errors":[{"message":"unexpected project name"}]}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' '{"data":{"projects":{"nodes":[{"id":"project-1"}]}}}___HTTP_CODE___200'
  ;;
*"GetProjectDependencies"*)
  if [[ "$(jq -r '.id' <<<"$variables")" != "project-1" ]]; then
    printf '%s' '{"errors":[{"message":"dependencies query did not use resolved project id"}]}___HTTP_CODE___200'
    exit 0
  fi
  printf '%s' '{"data":{"project":{"id":"project-1","name":"Project \"Quoted\"","relations":{"nodes":[{"id":"dep-1","type":"dependency","anchorType":"project","relatedAnchorType":"project","relatedProject":{"id":"project-0","name":"Foundation","state":"started","progress":0.5}}]},"inverseRelations":{"nodes":[{"id":"dep-2","type":"dependency","anchorType":"project","relatedAnchorType":"project","project":{"id":"project-2","name":"Followup","state":"planned","progress":0}}]}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

issues_out="$(
  PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues relations PROJ-42 --format=safe
)"

if ! jq -e '.blocks[0].id == "PROJ-43" and .blocked_by[0].id == "PROJ-41"' >/dev/null <<<"$issues_out"; then
  echo "FAIL issues relations alias returned unexpected output: $issues_out"
  exit 1
fi

projects_out="$(
  PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" projects dependencies 'Project "Quoted"' --format=safe
)"

if ! jq -e '.name == "Project \"Quoted\"" and .blocked_by[0].name == "Foundation" and .blocks[0].name == "Followup"' >/dev/null <<<"$projects_out"; then
  echo "FAIL projects dependencies alias returned unexpected output: $projects_out"
  exit 1
fi

echo "all pass"
