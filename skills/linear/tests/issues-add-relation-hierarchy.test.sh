#!/usr/bin/env bash
# The add-relation blocking-level guard: a blocking relation connects peers of
# one bundle (same direct parent, or both top-level). The guard reads one
# level — each issue's own direct parent — in a single query.
#
# Fixture hierarchy:
#   CC-761 (root)
#     ├── CC-763 ── CC-766, CC-768
#     └── CC-764 ── CC-767
#   CC-780 (root)
#   CC-999 (no such issue; the fail-closed fixture)
#   CC-870..CC-873 (top-level pairs spanning two projects, and a project
#                   paired with none)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Project identities for the CC-870..CC-873 fixtures. Exported so the curl
# stub reads the same values the control below asserts on.
export FIXTURE_PROJECT_A="proj-alpha"
export FIXTURE_PROJECT_B="proj-beta"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

# identifier -> uuid used by the resolve query; validate/mutation see uuids
uuid_for() { printf 'uuid-%s' "${1#CC-}"; }

# Issue node with the direct parent ValidateBlocking selects.
issue_node() {
  case "$1" in
  uuid-761) printf '%s' '{"id":"uuid-761","identifier":"CC-761","parent":null}' ;;
  uuid-763) printf '%s' '{"id":"uuid-763","identifier":"CC-763","parent":{"id":"uuid-761","identifier":"CC-761"}}' ;;
  uuid-764) printf '%s' '{"id":"uuid-764","identifier":"CC-764","parent":{"id":"uuid-761","identifier":"CC-761"}}' ;;
  uuid-766) printf '%s' '{"id":"uuid-766","identifier":"CC-766","parent":{"id":"uuid-763","identifier":"CC-763"}}' ;;
  uuid-767) printf '%s' '{"id":"uuid-767","identifier":"CC-767","parent":{"id":"uuid-764","identifier":"CC-764"}}' ;;
  uuid-768) printf '%s' '{"id":"uuid-768","identifier":"CC-768","parent":{"id":"uuid-763","identifier":"CC-763"}}' ;;
  uuid-780) printf '%s' '{"id":"uuid-780","identifier":"CC-780","parent":null}' ;;
  uuid-870) printf '{"id":"uuid-870","identifier":"CC-870","project":{"id":"%s","name":"Alpha"},"parent":null}' "${FIXTURE_PROJECT_A:?}" ;;
  uuid-871) printf '{"id":"uuid-871","identifier":"CC-871","project":{"id":"%s","name":"Beta"},"parent":null}' "${FIXTURE_PROJECT_B:?}" ;;
  uuid-872) printf '{"id":"uuid-872","identifier":"CC-872","project":{"id":"%s","name":"Alpha"},"parent":null}' "${FIXTURE_PROJECT_A:?}" ;;
  uuid-873) printf '%s' '{"id":"uuid-873","identifier":"CC-873","project":null,"parent":null}' ;;
  *) printf 'null' ;;
  esac
}

case "$query" in
*"ValidateBlocking"*)
  id1="$(jq -r '.id1' <<<"$variables")"
  id2="$(jq -r '.id2' <<<"$variables")"
  printf '{"data":{"issue1":%s,"issue2":%s}}___HTTP_CODE___200' "$(issue_node "$id1")" "$(issue_node "$id2")"
  ;;
*"GetIssue"*)
  ref="$(jq -r '.id' <<<"$variables")"
  printf '{"data":{"issue":{"id":"%s"}}}___HTTP_CODE___200' "$(uuid_for "$ref")"
  ;;
*"issueRelationCreate"*)
  printf '%s' '{"data":{"issueRelationCreate":{"success":true,"issueRelation":{"id":"rel-1","type":"blocks","issue":{"identifier":"CC-X","title":"t"},"relatedIssue":{"identifier":"CC-Y","title":"t"}}}}}___HTTP_CODE___200'
  ;;
*"RefreshIssues"*)
  printf '%s' '{"data":{"issues":{"nodes":[]}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

# Run this complete regression file with the unsupported macOS-era runtime.
# The CLI must reject it before shared config loads or any API request occurs.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  payload_log="$TMP_ROOT/bash3-payloads.jsonl"
  : >"$payload_log"
  rc=0
  output=$(PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" \
      issues add-relation CC-763 --blocks CC-764 2>&1) || rc=$?
  expected="Error: Linear CLI requires Bash 4.0 or newer; found Bash $BASH_VERSION. Install Bash 4+ and invoke linear.sh with that executable."

  assert_ne "Bash 3 runtime contract: the CLI refuses" "$rc" 0
  assert_eq "Bash 3 runtime contract: the diagnostic names the Bash 4+ requirement" \
    "$output" "$expected"
  assert_not "Bash 3 runtime contract: no API request is attempted" test -s "$payload_log"
  exit 0
fi

run_add_relation() {
  local payload_log="$1"
  shift
  : >"$payload_log"
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues add-relation "$@"
}

# A rejection must not have created the relation.
assert_no_mutation() {
  local payload_log="$1" label="$2"
  assert_not "$label: the rejected relation sent no issueRelationCreate" \
    jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$payload_log" >/dev/null
}

reject() {
  local label="$1"
  shift
  local rc=0
  run_add_relation "$TMP_ROOT/payloads.jsonl" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?

  assert_ne "$label: the relation is rejected" "$rc" 0
  assert_no_mutation "$TMP_ROOT/payloads.jsonl" "$label"
  assert "$label: the rejection is exactly one line" \
    test "$(wc -l <"$TMP_ROOT/err")" -eq 1
  assert "$label: the rejection line is a JSON error" \
    jq -e '.error' "$TMP_ROOT/err"
}

accept() {
  local label="$1"
  shift
  assert "$label: the relation is accepted" \
    run_add_relation "$TMP_ROOT/payloads.jsonl" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  assert "$label: the accepted relation sent issueRelationCreate" \
    jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$TMP_ROOT/payloads.jsonl" >/dev/null
}

# --- the rule's outcomes, read one level up ---

# Peers of one bundle: the pair the parent one level up makes valid.
accept "siblings (CC-763 --blocks CC-764)" CC-763 --blocks CC-764
accept "leaf siblings (CC-766 --blocks CC-768)" CC-766 --blocks CC-768
accept "top-level (CC-761 --blocks CC-780)" CC-761 --blocks CC-780
accept "blocked-by siblings (CC-764 --blocked-by CC-763)" CC-764 --blocked-by CC-763

# A parent/child pair: the hierarchy already carries the dependency.
for args in "CC-766 --blocks CC-763" "CC-763 --blocks CC-766" "CC-763 --blocked-by CC-766"; do
  # shellcheck disable=SC2086
  reject "parent pair ($args)" $args
  assert "parent pair ($args): missing ancestor explanation" \
    grep -q "cannot carry a blocking relation against its own ancestor" "$TMP_ROOT/err"
  assert_not "parent pair ($args): the explanation must not prescribe a --blocks command" \
    grep -q -- "--blocks" "$TMP_ROOT/err"
done

# Different parents: a child of a child, a cousin, and two different roots.
for args in "CC-766 --blocks CC-761" "CC-766 --blocks CC-767" "CC-766 --blocks CC-780"; do
  # shellcheck disable=SC2086
  reject "different parents ($args)" $args
  assert "different parents ($args): the rejection states the rule" \
    grep -q "must connect peers of one bundle (same direct parent, or both top-level)" "$TMP_ROOT/err"
done

# An issue the validation query does not return would otherwise read as
# top-level and pass; it refuses instead.
reject "issue missing at validation (CC-999)" CC-766 --blocks CC-999
assert "issue missing at validation: missing fail-closed diagnostic" \
  grep -q "Hierarchy validation failed closed" "$TMP_ROOT/err"

# --- a bundle peer pair may span projects ---
# Control first: the cases below only exercise a project boundary if the
# fixtures sit on opposite sides of one. Assert that before trusting them —
# if the fixtures ever collapse onto one project, fail here rather than
# reporting a vacuous pass.
assert_ne "project-spanning control: CC-870 carries a project" "${FIXTURE_PROJECT_A:-}" ""
assert_ne "project-spanning control: CC-870 and CC-871 carry distinct projects" \
  "${FIXTURE_PROJECT_A:-}" "${FIXTURE_PROJECT_B:-}"

accept "top-level across two projects" CC-870 --blocks CC-871
accept "top-level across two projects (blocked-by)" CC-871 --blocked-by CC-870
accept "top-level, one project and one without" CC-872 --blocks CC-873
accept "top-level, one project and one without (blocked-by)" CC-873 --blocked-by CC-872
