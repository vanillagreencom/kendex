#!/usr/bin/env bash
# `issues create --format=ids` must be accepted by the parser and
# print ONLY the created issue identifier (one line, nothing else). The merge /
# Creation workflows capture that identifier deterministically, so a
# parser rejection silently breaks them.
# Runs fully offline against a mocked curl — the bug is a pre-mutation parse rejection.

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
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token \
    bash "$LINEAR" issues create "$@")
}

# --- --format=ids (equals form): accepted, prints ONLY the identifier -----------
ids_rc=0
ids_out="$(run_create --title "New task" --team Claude --format=ids 2>&1)" || ids_rc=$?
assert_eq "create --format=ids exits zero" "$ids_rc" 0
assert_eq "create --format=ids prints exactly the identifier" "$ids_out" "PROJ-1"

# --- --format ids (space form): same contract -----------------------------------
space_rc=0
ids_out_space="$(run_create --title "New task" --team Claude --format ids 2>&1)" || space_rc=$?
assert_eq "create --format ids exits zero" "$space_rc" 0
assert_eq "create --format ids prints exactly the identifier" "$ids_out_space" "PROJ-1"

# --- default (no --format): full JSON create response is unchanged ---------------
default_rc=0
default_out="$(run_create --title "New task" --team Claude 2>&1)" || default_rc=$?
assert_eq "a create with no --format exits zero" "$default_rc" 0
assert_jq "the default create output is still the full JSON response" \
  "$default_out" '.success == true and .identifier == "PROJ-1"'

# --- parser accepts --format=ids ---------------------------------------------
parser_rc=0
err_out="$(run_create --title "New task" --team Claude --format=ids 2>&1 >/dev/null)" || parser_rc=$?
assert_eq "the parser accepts --format=ids and the create exits zero" "$parser_rc" 0
assert_not_contains "the parser does not reject --format=ids" "$err_out" "Unknown option"
