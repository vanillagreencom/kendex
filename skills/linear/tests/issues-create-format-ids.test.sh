#!/usr/bin/env bash
# Regression test: `issues create --format=ids` must be accepted by the parser and
# print ONLY the created issue identifier (one line, nothing else). The merge /
# start-new / plan-issues workflows capture that identifier deterministically, so a
# parser rejection (the #615 "Unknown option: --format=ids" bug) silently breaks them.
# Runs fully offline against a mocked curl — the bug is a pre-mutation parse rejection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Mocked curl: routes by GraphQL operation. issueCreate returns a fixed issue.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"

issue_json='{"id":"issue-uuid","identifier":"PROJ-1","title":"t","description":"d","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/PROJ-1","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' "{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":$issue_json}}}___HTTP_CODE___200"
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

run_create() {
  PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$LINEAR" issues create "$@"
}

# --- --format=ids (equals form): accepted, prints ONLY the identifier -----------
ids_out="$(run_create --title "New task" --team Claude --format=ids)"
if [[ "$ids_out" != "PROJ-1" ]]; then
  echo "FAIL create --format=ids expected exactly 'PROJ-1', got: [$ids_out]"
  exit 1
fi

# --- --format ids (space form): same contract -----------------------------------
ids_out_space="$(run_create --title "New task" --team Claude --format ids)"
if [[ "$ids_out_space" != "PROJ-1" ]]; then
  echo "FAIL create --format ids expected exactly 'PROJ-1', got: [$ids_out_space]"
  exit 1
fi

# --- default (no --format): full JSON create response is unchanged ---------------
default_out="$(run_create --title "New task" --team Claude)"
if ! jq -e '.success == true and .identifier == "PROJ-1"' >/dev/null <<<"$default_out"; then
  echo "FAIL default create output changed; expected JSON with success/identifier, got: $default_out"
  exit 1
fi

# --- parser no longer rejects --format=ids (the #615 bug) ------------------------
set +e
err_out="$(run_create --title "New task" --team Claude --format=ids 2>&1 >/dev/null)"
set -e
if grep -q "Unknown option" <<<"$err_out"; then
  echo "FAIL parser still rejects --format=ids: $err_out"
  exit 1
fi

echo "all pass"
