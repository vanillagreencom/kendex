#!/usr/bin/env bash
# Regression test for #557: the add-relation blocking-level guard must emit
# self-consistent remediation. Any command it prescribes must itself pass the
# guard, and ancestor/descendant pairs get a single explanation instead of a
# prescription (there is no valid replacement pair for them).
#
# Fixture hierarchy (all in project "Test"):
#   CC-761 (root)
#     ├── CC-763 ── CC-766, CC-768
#     └── CC-764 ── CC-767
#   CC-780 (root)
#   CC-799 (missing parent key; fail-closed fixture)
#   CC-800 (non-object parent; fail-closed fixture)
#   CC-801 (non-object issue; fail-closed fixture)
#   CC-802 (empty parent ID; fail-closed fixture)
#   CC-830, CC-831 (same-parent P-A-P-A-P cycle; fail-closed fixture)
#   CC-840..CC-845 (malformed project shapes; fail-closed fixtures)
#   CC-846, CC-847 (explicit null projects; supported fixture)

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

# identifier -> uuid used by the resolve query; validate/mutation see uuids
uuid_for() { printf 'uuid-%s' "${1#CC-}"; }

# Issue node with project + 5-level parent chain, as ValidateBlocking selects
issue_node() {
  local prj='"project":{"id":"proj-1","name":"Test"}'
  local cycle_parent='{"id":"uuid-p","identifier":"CC-P","parent":{"id":"uuid-a","identifier":"CC-A","parent":{"id":"uuid-p","identifier":"CC-P","parent":{"id":"uuid-a","identifier":"CC-A","parent":{"id":"uuid-p","identifier":"CC-P"}}}}}'
  case "$1" in
  uuid-761) printf '{"id":"uuid-761","identifier":"CC-761",%s,"parent":null}' "$prj" ;;
  uuid-763) printf '{"id":"uuid-763","identifier":"CC-763",%s,"parent":{"id":"uuid-761","identifier":"CC-761","parent":null}}' "$prj" ;;
  uuid-764) printf '{"id":"uuid-764","identifier":"CC-764",%s,"parent":{"id":"uuid-761","identifier":"CC-761","parent":null}}' "$prj" ;;
  uuid-766) printf '{"id":"uuid-766","identifier":"CC-766",%s,"parent":{"id":"uuid-763","identifier":"CC-763","parent":{"id":"uuid-761","identifier":"CC-761","parent":null}}}' "$prj" ;;
  uuid-767) printf '{"id":"uuid-767","identifier":"CC-767",%s,"parent":{"id":"uuid-764","identifier":"CC-764","parent":{"id":"uuid-761","identifier":"CC-761","parent":null}}}' "$prj" ;;
  uuid-768) printf '{"id":"uuid-768","identifier":"CC-768",%s,"parent":{"id":"uuid-763","identifier":"CC-763","parent":{"id":"uuid-761","identifier":"CC-761","parent":null}}}' "$prj" ;;
  uuid-780) printf '{"id":"uuid-780","identifier":"CC-780",%s,"parent":null}' "$prj" ;;
  uuid-799) printf '{"id":"uuid-799","identifier":"CC-799",%s}' "$prj" ;;
  uuid-800) printf '{"id":"uuid-800","identifier":"CC-800",%s,"parent":"uuid-761"}' "$prj" ;;
  uuid-801) printf '[]' ;;
  uuid-802) printf '{"id":"uuid-802","identifier":"CC-802",%s,"parent":{"id":"","identifier":"CC-761","parent":null}}' "$prj" ;;
  uuid-830 | uuid-831) printf '{"id":"%s","identifier":"CC-%s",%s,"parent":%s}' "$1" "${1#uuid-}" "$prj" "$cycle_parent" ;;
  uuid-840 | uuid-841) printf '{"id":"%s","identifier":"CC-%s","parent":null}' "$1" "${1#uuid-}" ;;
  uuid-842 | uuid-843) printf '{"id":"%s","identifier":"CC-%s","project":"proj-1","parent":null}' "$1" "${1#uuid-}" ;;
  uuid-844 | uuid-845) printf '{"id":"%s","identifier":"CC-%s","project":{"id":"","name":"Test"},"parent":null}' "$1" "${1#uuid-}" ;;
  uuid-846 | uuid-847) printf '{"id":"%s","identifier":"CC-%s","project":null,"parent":null}' "$1" "${1#uuid-}" ;;
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
  set +e
  output=$(PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" \
      issues add-relation CC-763 --blocks CC-764 2>&1)
  rc=$?
  set -e
  expected="Error: Linear CLI requires Bash 4.0 or newer; found Bash $BASH_VERSION. Install Bash 4+ and invoke linear.sh with that executable."
  if [ "$rc" -eq 0 ] || [ "$output" != "$expected" ]; then
    echo "FAIL Bash 3 runtime contract: expected a clear Bash 4+ diagnostic"
    printf 'exit=%s\noutput=%s\n' "$rc" "$output"
    exit 1
  fi
  if [ -s "$payload_log" ]; then
    echo "FAIL Bash 3 runtime contract: CLI attempted an API request"
    cat "$payload_log"
    exit 1
  fi
  echo "all pass (unsupported Bash 3 runtime rejected before hierarchy validation)"
  exit 0
fi

run_add_relation() {
  local payload_log="$1"
  shift
  : >"$payload_log"
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues add-relation "$@"
}

# Extract a prescribed replacement command ("use 'A --blocks B'") from stderr.
# Prints "A B" or nothing.
extract_prescription() {
  sed -n "s/.*[Uu]se '\([A-Z][A-Z]*-[0-9][0-9]*\) --blocks \([A-Z][A-Z]*-[0-9][0-9]*\)'.*/\1 \2/p" "$1"
}

# A rejection must not have created the relation.
assert_no_mutation() {
  local payload_log="$1" label="$2"
  if jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$payload_log" >/dev/null; then
    echo "FAIL $label: rejected relation still sent issueRelationCreate"
    cat "$payload_log"
    exit 1
  fi
}

# Rejected commands may only prescribe replacements the guard accepts: drive
# every prescription back through the guard (issue #557 regression).
assert_prescription_satisfiable() {
  local err_file="$1" label="$2"
  local prescription
  prescription="$(extract_prescription "$err_file")"
  [ -n "$prescription" ] || return 0
  local from to
  read -r from to <<<"$prescription"
  if ! run_add_relation "$TMP_ROOT/prescription-payloads.jsonl" "$from" --blocks "$to" \
    >"$TMP_ROOT/prescription.out" 2>"$TMP_ROOT/prescription.err"; then
    echo "FAIL $label: prescribed command '$from --blocks $to' is itself rejected:"
    cat "$TMP_ROOT/prescription.err"
    exit 1
  fi
}

reject() {
  local label="$1"
  shift
  set +e
  run_add_relation "$TMP_ROOT/payloads.jsonl" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL $label: expected rejection, got success"
    cat "$TMP_ROOT/out"
    exit 1
  fi
  assert_no_mutation "$TMP_ROOT/payloads.jsonl" "$label"
  assert_prescription_satisfiable "$TMP_ROOT/err" "$label"
}

accept() {
  local label="$1"
  shift
  if ! run_add_relation "$TMP_ROOT/payloads.jsonl" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    echo "FAIL $label: expected acceptance, got rejection:"
    cat "$TMP_ROOT/err"
    exit 1
  fi
  if ! jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
    echo "FAIL $label: accepted relation never sent issueRelationCreate"
    cat "$TMP_ROOT/payloads.jsonl"
    exit 1
  fi
}

# --- (b) ancestor/descendant pairs: one clear explanation, no prescription ---
for args in "CC-766 --blocks CC-763" "CC-766 --blocks CC-761" "CC-761 --blocks CC-766" "CC-763 --blocked-by CC-766"; do
  # shellcheck disable=SC2086
  reject "ancestor case ($args)" $args
  if ! grep -q "cannot carry a blocking relation against its own ancestor" "$TMP_ROOT/err"; then
    echo "FAIL ancestor case ($args): missing ancestor explanation:"
    cat "$TMP_ROOT/err"
    exit 1
  fi
  if grep -q -- "--blocks" "$TMP_ROOT/err"; then
    echo "FAIL ancestor case ($args): explanation must not prescribe a --blocks command:"
    cat "$TMP_ROOT/err"
    exit 1
  fi
  if [ "$(wc -l <"$TMP_ROOT/err")" -ne 1 ] || ! jq -e '.error' "$TMP_ROOT/err" >/dev/null; then
    echo "FAIL ancestor case ($args): expected exactly one JSON error line:"
    cat "$TMP_ROOT/err"
    exit 1
  fi
done

# --- (a)+(c) hoistable cases: the correct accepted pair is prescribed ---
reject "cousins (CC-766 --blocks CC-767)" CC-766 --blocks CC-767
if [ "$(extract_prescription "$TMP_ROOT/err")" != "CC-763 CC-764" ]; then
  echo "FAIL cousins: expected prescription 'CC-763 --blocks CC-764', stderr:"
  cat "$TMP_ROOT/err"
  exit 1
fi

reject "depth mismatch (CC-766 --blocks CC-764)" CC-766 --blocks CC-764
if [ "$(extract_prescription "$TMP_ROOT/err")" != "CC-763 CC-764" ]; then
  echo "FAIL depth mismatch: expected prescription 'CC-763 --blocks CC-764', stderr:"
  cat "$TMP_ROOT/err"
  exit 1
fi

reject "different roots (CC-766 --blocks CC-780)" CC-766 --blocks CC-780
if [ "$(extract_prescription "$TMP_ROOT/err")" != "CC-761 CC-780" ]; then
  echo "FAIL different roots: expected prescription 'CC-761 --blocks CC-780', stderr:"
  cat "$TMP_ROOT/err"
  exit 1
fi

# Missing/wrong-typed hierarchy shapes must fail before issueRelationCreate.
reject "missing parent key" CC-799 --blocks CC-780
grep -q "Hierarchy validation failed closed" "$TMP_ROOT/err" || {
  echo "FAIL missing parent key: missing fail-closed diagnostic"
  exit 1
}

reject "non-object parent" CC-800 --blocks CC-780
grep -q "Hierarchy validation failed closed" "$TMP_ROOT/err" || {
  echo "FAIL non-object parent: missing fail-closed diagnostic"
  exit 1
}

reject "non-object issue" CC-801 --blocks CC-780
grep -q "Hierarchy validation failed closed" "$TMP_ROOT/err" || {
  echo "FAIL non-object issue: missing fail-closed diagnostic"
  exit 1
}

reject "empty parent ID" CC-802 --blocks CC-780
grep -q "Hierarchy validation failed closed" "$TMP_ROOT/err" || {
  echo "FAIL empty parent ID: missing fail-closed diagnostic"
  exit 1
}

reject "same-parent repeated ancestor cycle" CC-830 --blocks CC-831
grep -q "parent cycle detected" "$TMP_ROOT/err" || {
  echo "FAIL same-parent repeated ancestor cycle: missing cycle diagnostic"
  exit 1
}

reject "missing project" CC-840 --blocks CC-841
grep -q "missing or malformed project data" "$TMP_ROOT/err" || {
  echo "FAIL missing project: missing fail-closed diagnostic"
  exit 1
}

reject "wrong-typed project" CC-842 --blocks CC-843
grep -q "missing or malformed project data" "$TMP_ROOT/err" || {
  echo "FAIL wrong-typed project: missing fail-closed diagnostic"
  exit 1
}

reject "empty project ID" CC-844 --blocks CC-845
grep -q "missing or malformed project data" "$TMP_ROOT/err" || {
  echo "FAIL empty project ID: missing fail-closed diagnostic"
  exit 1
}

# --- (d) relations the rule blesses still pass ---
accept "siblings (CC-763 --blocks CC-764)" CC-763 --blocks CC-764
accept "leaf siblings (CC-766 --blocks CC-768)" CC-766 --blocks CC-768
accept "top-level (CC-761 --blocks CC-780)" CC-761 --blocks CC-780
accept "blocked-by siblings (CC-764 --blocked-by CC-763)" CC-764 --blocked-by CC-763
accept "explicit null projects" CC-846 --blocks CC-847

echo "all pass"
