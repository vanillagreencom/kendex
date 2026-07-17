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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

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
  PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$LINEAR" issues update "$@"
}

# --- --format=safe (equals form): accepted, emits safe issue with parent_id ------
safe_out="$(run_update PROJ-42 --priority 2 --format=safe)"
if ! jq -e '.id == "PROJ-42" and .parent_id == "PROJ-10" and .agent == "iced"' >/dev/null <<<"$safe_out"; then
  echo "FAIL update --format=safe did not emit safe issue with parent_id/agent, got: $safe_out"
  exit 1
fi

# --- --format safe (space form): same contract ----------------------------------
safe_space="$(run_update PROJ-42 --priority 2 --format safe)"
if ! jq -e '.id == "PROJ-42" and .parent_id == "PROJ-10"' >/dev/null <<<"$safe_space"; then
  echo "FAIL update --format safe (space form) mismatch, got: $safe_space"
  exit 1
fi

# --- reported repro path: --state ... --format=safe -----------------------------
state_safe="$(run_update PROJ-42 --state "Todo" --format=safe)"
if ! jq -e '.id == "PROJ-42" and .parent_id == "PROJ-10"' >/dev/null <<<"$state_safe"; then
  echo "FAIL update --state Todo --format=safe mismatch, got: $state_safe"
  exit 1
fi

# --- --format=ids: prints ONLY the updated identifier ---------------------------
ids_out="$(run_update PROJ-42 --priority 2 --format=ids)"
if [[ "$ids_out" != "PROJ-42" ]]; then
  echo "FAIL update --format=ids expected exactly 'PROJ-42', got: [$ids_out]"
  exit 1
fi

# --- --format=raw: raw mutation response ----------------------------------------
raw_out="$(run_update PROJ-42 --priority 2 --format=raw)"
if ! jq -e '.issueUpdate.success == true and .issueUpdate.issue.identifier == "PROJ-42"' >/dev/null <<<"$raw_out"; then
  echo "FAIL update --format=raw did not emit raw mutation response, got: $raw_out"
  exit 1
fi

# --- default (no --format): mutation summary is UNCHANGED (backward compat) ------
default_out="$(run_update PROJ-42 --priority 2)"
if ! jq -e '.success == true and .identifier == "PROJ-42" and (.data != null)' >/dev/null <<<"$default_out"; then
  echo "FAIL default update output changed; expected {success, identifier, data}, got: $default_out"
  exit 1
fi

# --- parser no longer rejects --format (the #625 bug) ---------------------------
set +e
err_out="$(run_update PROJ-42 --priority 2 --format=safe 2>&1 >/dev/null)"
set -e
if grep -q "Unknown option" <<<"$err_out"; then
  echo "FAIL parser still rejects --format: $err_out"
  exit 1
fi

# --- unknown flags are STILL rejected (no over-broad parsing) --------------------
set +e
bogus_out="$(run_update PROJ-42 --bogus x 2>&1)"
set -e
if ! grep -q "Unknown option" <<<"$bogus_out"; then
  echo "FAIL update no longer rejects a genuinely unknown flag: $bogus_out"
  exit 1
fi

echo "all pass"
