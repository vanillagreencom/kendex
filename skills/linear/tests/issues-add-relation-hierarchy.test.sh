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
#   CC-790 ── CC-791 ── CC-792 ── CC-793 ── CC-794 ── CC-795 ── CC-796
#                                                                  ├── CC-797
#                                                                  └── CC-798
#   CC-799 (incomplete parent edge; fail-closed fixture)
#   CC-810 <-> CC-811 (parent cycle; fail-closed fixture)

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

# Issue node with one parent edge. ValidateBlockingIssue must follow these
# edges iteratively until it observes an explicit null root.
issue_node() {
  local prj='"project":{"id":"proj-1","name":"Test"}'
  local suffix="${1#uuid-}" parent_id
  case "$1" in
  uuid-761 | uuid-780 | uuid-790) parent_id="null" ;;
  uuid-763 | uuid-764) parent_id="uuid-761" ;;
  uuid-766 | uuid-768) parent_id="uuid-763" ;;
  uuid-767) parent_id="uuid-764" ;;
  uuid-791) parent_id="uuid-790" ;;
  uuid-792) parent_id="uuid-791" ;;
  uuid-793) parent_id="uuid-792" ;;
  uuid-794) parent_id="uuid-793" ;;
  uuid-795) parent_id="uuid-794" ;;
  uuid-796) parent_id="uuid-795" ;;
  uuid-797 | uuid-798) parent_id="uuid-796" ;;
  uuid-799) parent_id="missing" ;;
  uuid-810) parent_id="uuid-811" ;;
  uuid-811) parent_id="uuid-810" ;;
  *) printf 'null'; return ;;
  esac
  case "$parent_id" in
  null) printf '{"id":"%s","identifier":"CC-%s",%s,"parent":null}' "$1" "$suffix" "$prj" ;;
  missing) printf '{"id":"%s","identifier":"CC-%s",%s,"parent":{}}' "$1" "$suffix" "$prj" ;;
  *) printf '{"id":"%s","identifier":"CC-%s",%s,"parent":{"id":"%s"}}' "$1" "$suffix" "$prj" "$parent_id" ;;
  esac
}

case "$query" in
*"ValidateBlockingIssue"*)
  id="$(jq -r '.id' <<<"$variables")"
  printf '{"data":{"issue":%s}}___HTTP_CODE___200' "$(issue_node "$id")"
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

# `mapfile`/`readarray` are Bash 4 additions. Keep the hierarchy path runnable
# under macOS system Bash 3.2 by preventing either command from reappearing.
if grep -Eq '^[[:space:]]*(mapfile|readarray)([[:space:]]|$)' "$SKILL_DIR/scripts/lib/issue-validation.sh"; then
  echo "FAIL hierarchy validation uses a Bash 4-only line-reader"
  exit 1
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

# The ancestor is seven parent edges above the leaf. A fixed five-parent
# GraphQL selection used to misclassify this as a cross-root relation.
reject "deep ancestor (CC-797 --blocks CC-790)" CC-797 --blocks CC-790
if ! grep -q "cannot carry a blocking relation against its own ancestor" "$TMP_ROOT/err"; then
  echo "FAIL deep ancestor: complete chain was not recognized:"
  cat "$TMP_ROOT/err"
  exit 1
fi

# An incomplete parent object is neither a root nor a usable edge. Reject it
# before relation mutation instead of silently treating the chain as complete.
reject "incomplete ancestor response (CC-799 --blocks CC-780)" CC-799 --blocks CC-780
if ! grep -q "Hierarchy validation failed closed" "$TMP_ROOT/err"; then
  echo "FAIL incomplete ancestor response: missing fail-closed diagnostic:"
  cat "$TMP_ROOT/err"
  exit 1
fi

reject "cyclic ancestor response (CC-810 --blocks CC-780)" CC-810 --blocks CC-780
if ! grep -q "parent cycle detected" "$TMP_ROOT/err"; then
  echo "FAIL cyclic ancestor response: missing fail-closed diagnostic:"
  cat "$TMP_ROOT/err"
  exit 1
fi

# --- (d) relations the rule blesses still pass ---
accept "siblings (CC-763 --blocks CC-764)" CC-763 --blocks CC-764
accept "leaf siblings (CC-766 --blocks CC-768)" CC-766 --blocks CC-768
accept "deep leaf siblings (CC-797 --blocks CC-798)" CC-797 --blocks CC-798
accept "top-level (CC-761 --blocks CC-780)" CC-761 --blocks CC-780
accept "blocked-by siblings (CC-764 --blocked-by CC-763)" CC-764 --blocked-by CC-763

echo "all pass"
