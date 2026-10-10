#!/usr/bin/env bash
# The add-relation blocking-level guard reads complete ancestry and leaf
# status in one query. Input: scripts/commands/issues.sh and
# scripts/lib/issue-validation.sh through the shipped linear.sh command.
#
# Fixture hierarchy:
#   CC-761 (root)
#     ├── CC-763 ── CC-766, CC-768
#     └── CC-764 ── CC-767, CC-769 (container) ── CC-770
#   CC-780 (root)
#   CC-790 (incomplete parent chain)
#   CC-791 (missing child status)
#   CC-792 (container with only an archived child)
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

# Linear returns explicit null at the end of each selected parent chain.
issue_node() {
  jq -cn --arg id "$1" --arg pa "$FIXTURE_PROJECT_A" --arg pb "$FIXTURE_PROJECT_B" --arg query "$query" '
    def parents: {"763":"761", "764":"761", "766":"763", "767":"764", "768":"763", "769":"764", "770":"769"};
    def node($n): {id: ("uuid-" + $n), identifier: ("CC-" + $n),
      parent: (if parents[$n] then node(parents[$n]) else null end),
      children: {nodes: (if ["761","763","764","769"] | index($n) then [{id:"child"}] else [] end), pageInfo: {hasNextPage:false}}};
    def frontier($n): {identifier:("CC-frontier-" + ($n | tostring))}
      + if $n > 0 then {parent:frontier($n - 1)} else {} end;
    ($id | ltrimstr("uuid-")) as $n
    | if $n == "999" then null else node($n)
      | if $n == "790" then .parent = frontier(9) else . end
      | if $n == "791" then .children = null else . end
      | if $n == "792" and ($query | contains("includeArchived: true")) then .children.nodes = [{id:"archived-child"}] else . end
      | if ["870","872"] | index($n) then .project = {id:$pa, name:"Alpha"}
        elif $n == "871" then .project = {id:$pb, name:"Beta"}
        elif $n == "873" then .project = null else . end end'
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
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

# Run this complete failure file with the unsupported macOS-era runtime.
# The CLI must reject it before shared config loads or any API request occurs.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  payload_log="$TMP_ROOT/bash3-payloads.jsonl"
  : >"$payload_log"
  rc=0
  output=$(env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    CURL_PAYLOAD_LOG="$payload_log" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" \
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
  env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    FIXTURE_PROJECT_A="$FIXTURE_PROJECT_A" FIXTURE_PROJECT_B="$FIXTURE_PROJECT_B" \
    CURL_PAYLOAD_LOG="$payload_log" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues add-relation "$@"
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

# This suite consumes the CLI JSON error category: only the stable prefix
# is compared, so human explanations may change.
# --- the rule's outcomes ---

# Peers of one bundle: the pair the parent one level up makes valid.
accept "siblings (CC-763 --blocks CC-764)" CC-763 --blocks CC-764
accept "leaf siblings (CC-766 --blocks CC-768)" CC-766 --blocks CC-768
accept "top-level (CC-761 --blocks CC-780)" CC-761 --blocks CC-780
accept "blocked-by siblings (CC-764 --blocked-by CC-763)" CC-764 --blocked-by CC-763

# A parent/child pair: the hierarchy already carries the dependency.
for args in "CC-766 --blocks CC-763" "CC-763 --blocks CC-766" "CC-763 --blocked-by CC-766"; do
  # shellcheck disable=SC2086
  reject "parent pair ($args)" $args
  assert "parent pair ($args): ancestor category" \
    jq -e '.error | startswith("Hierarchy violation:")' "$TMP_ROOT/err" >/dev/null
done

# Ancestors are refused in either direction, including a grandparent.
for args in "CC-766 --blocks CC-761" "CC-761 --blocks CC-766"; do
  # shellcheck disable=SC2086
  reject "grandparent pair ($args)" $args
  assert "grandparent pair ($args): ancestor category" \
    jq -e '.error | startswith("Hierarchy violation:")' "$TMP_ROOT/err" >/dev/null
done

accept "cross-bundle leaf (CC-766 --blocks CC-767)" CC-766 --blocks CC-767
accept "top-level leaf (CC-766 --blocks CC-780)" CC-766 --blocks CC-780
accept "blocked-by cross-bundle leaf" CC-767 --blocked-by CC-766
assert "blocking query reads child status and nested ancestry" \
  jq -s -e '[.[] | select(.query | contains("ValidateBlocking")) | .query] | all(.[]; contains("children(first: 1,") and contains("pageInfo { hasNextPage }") and contains("parent { identifier parent {"))' "$TMP_ROOT/payloads.jsonl" >/dev/null
reject "cross-bundle container (CC-766 --blocks CC-769)" CC-766 --blocks CC-769
assert "cross-bundle container: level category" jq -e '.error | startswith("Blocking-level violation:")' "$TMP_ROOT/err" >/dev/null
reject "archived-child container" CC-766 --blocks CC-792
assert "archived-child container: level category" jq -e '.error | startswith("Blocking-level violation:")' "$TMP_ROOT/err" >/dev/null

for args in "CC-766 --blocks CC-790" "CC-790 --blocks CC-766"; do
  # shellcheck disable=SC2086
  reject "incomplete chain ($args)" $args
  assert "incomplete chain ($args): facts category" jq -e '.error | startswith("Hierarchy validation failed closed:")' "$TMP_ROOT/err" >/dev/null
done

reject "missing child status" CC-766 --blocks CC-791
assert "missing child status: facts category" jq -e '.error | startswith("Hierarchy validation failed closed:")' "$TMP_ROOT/err" >/dev/null

# An issue the validation query does not return would otherwise read as
# top-level and pass; it refuses instead.
reject "issue missing at validation (CC-999)" CC-766 --blocks CC-999
assert "issue missing at validation: facts category" \
  jq -e '.error | startswith("Hierarchy validation failed closed:")' "$TMP_ROOT/err" >/dev/null

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
