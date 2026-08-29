#!/usr/bin/env bash
# Regression test (#625, bug 1): `issues update <ID> ... --format=safe` must be
# accepted by the parser and emit the documented safe output for the updated
# issue. The README documents `safe` as the default/global output format, yet
# `update` used to reject any `--format` flag via its `-*` "Unknown option"
# catch-all (mirroring the #615 `create --format=ids` rejection). Workflows that
# uniformly append `--format=safe` to every call failed on the update path.
#
# Runs fully offline against a mocked curl — the bug is a pre-mutation parse
# rejection, so no live Linear is needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes from `issues update` land in
# the real project's `.cache/linear` (kendex#43).
git -C "$TMP_ROOT" init -q -b main

# Mocked curl: routes by GraphQL operation. The updated issue carries a real
# parent (PROJ-10) and a label so the safe formatter must surface parent_id and
# agent from a well-formed record.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"

issue_json='{"id":"issue-uuid","identifier":"PROJ-42","title":"t","description":"d","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"p1","name":"Phase 2"},"projectMilestone":null,"cycle":null,"parent":{"id":"par-uuid","identifier":"PROJ-10","title":"Parent"},"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:iced"}]},"priority":2,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/PROJ-42","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-03T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}'

case "$query" in
*"issueUpdate(id:"*)
  printf '%s' "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":$issue_json}}}___HTTP_CODE___200" ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200' ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-todo","name":"Todo"}]}}}___HTTP_CODE___200' ;;
*"issue(id:"*)
  printf '%s' "{\"data\":{\"issue\":$issue_json}}___HTTP_CODE___200" ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

run_update() {
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    bash "$LINEAR" issues update "$@")
}

# --- --format=safe (equals form): accepted, emits safe issue with parent_id ------
safe_out="$(run_update PROJ-42 --priority 2 --format=safe)"
assert "update --format=safe emits the safe issue with parent_id and agent" \
  jq -e '.id == "PROJ-42" and .parent_id == "PROJ-10" and .agent == "iced"' >/dev/null <<<"$safe_out"

# --- --format safe (space form): same contract ----------------------------------
safe_space="$(run_update PROJ-42 --priority 2 --format safe)"
assert "the space form --format safe honours the same contract" \
  jq -e '.id == "PROJ-42" and .parent_id == "PROJ-10"' >/dev/null <<<"$safe_space"

# --- reported repro path: --state ... --format=safe -----------------------------
state_safe="$(run_update PROJ-42 --state "Todo" --format=safe)"
assert "--state with --format=safe emits the safe issue" \
  jq -e '.id == "PROJ-42" and .parent_id == "PROJ-10"' >/dev/null <<<"$state_safe"

# --- --format=ids: prints ONLY the updated identifier ---------------------------
ids_out="$(run_update PROJ-42 --priority 2 --format=ids)"
assert_eq "update --format=ids prints exactly the identifier" \
  "$ids_out" "PROJ-42"

# --- --format=raw: raw mutation response ----------------------------------------
raw_out="$(run_update PROJ-42 --priority 2 --format=raw)"
assert "update --format=raw emits the raw mutation response" \
  jq -e '.issueUpdate.success == true and .issueUpdate.issue.identifier == "PROJ-42"' >/dev/null <<<"$raw_out"

# --- default (no --format): mutation summary is UNCHANGED (backward compat) ------
default_out="$(run_update PROJ-42 --priority 2)"
assert "the default update output is still the mutation summary" \
  jq -e '.success == true and .identifier == "PROJ-42" and (.data != null)' >/dev/null <<<"$default_out"

# --- parser no longer rejects --format (the #625 bug) ---------------------------
err_out="$(run_update PROJ-42 --priority 2 --format=safe 2>&1 >/dev/null)" || true
assert_not "the parser accepts --format" \
  grep -q "Unknown option" <<<"$err_out"

# --- unknown flags are STILL rejected (no over-broad parsing) --------------------
bogus_out="$(run_update PROJ-42 --bogus x 2>&1)" || true
assert "update still rejects a genuinely unknown flag" \
  grep -q "Unknown option" <<<"$bogus_out"

