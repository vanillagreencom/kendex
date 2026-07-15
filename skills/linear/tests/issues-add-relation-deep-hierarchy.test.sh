#!/usr/bin/env bash
# Regression test for #557 (reopened): hierarchies deeper than the per-query
# parent selection cap must not silently truncate ancestor chains. The stub
# emulates the server's depth-capped responses, so the guard only sees the
# full hierarchy if it issues follow-up AncestorChunk queries. Covers: an
# ancestor pair beyond the cap, deep-but-valid siblings, deep cousins whose
# LCA sits beyond the cap, and the fail-closed chunk bound.
#
# Fixture (project "Test"):
#   CC-701 (root) <- CC-702 <- ... <- CC-707 <- CC-708, CC-709   (8 levels)
#   CC-701 <- CC-751 <- CC-752 <- ... <- CC-757                  (second branch)
#   CC-9000 (root) <- CC-9001 <- ... <- CC-9120                  (121 levels)
#   CC-850 <- CC-851 <- ... <- CC-855 <- CC-856 <- CC-857 <- CC-852
#                                                    (cross-chunk parent cycle)
#   CC-860, CC-861 -> P -> A -> B -> C -> D -> A
#                    (same-parent cycle hidden beyond the eager selection)

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

to_identifier() {
  case "$1" in
  uuid-*) printf 'CC-%s' "${1#uuid-}" ;;
  *) printf '%s' "$1" ;;
  esac
}

parent_of() {
  case "$1" in
  CC-702) echo CC-701 ;; CC-703) echo CC-702 ;; CC-704) echo CC-703 ;;
  CC-705) echo CC-704 ;; CC-706) echo CC-705 ;; CC-707) echo CC-706 ;;
  CC-708) echo CC-707 ;; CC-709) echo CC-707 ;;
  CC-751) echo CC-701 ;; CC-752) echo CC-751 ;; CC-753) echo CC-752 ;;
  CC-754) echo CC-753 ;; CC-755) echo CC-754 ;; CC-756) echo CC-755 ;;
  CC-757) echo CC-756 ;;
  CC-850) echo CC-851 ;; CC-851) echo CC-852 ;; CC-852) echo CC-853 ;;
  CC-853) echo CC-854 ;; CC-854) echo CC-855 ;; CC-855) echo CC-856 ;;
  CC-856) echo CC-857 ;; CC-857) echo CC-852 ;;
  CC-860 | CC-861) echo CC-870 ;; CC-870) echo CC-871 ;;
  CC-871) echo CC-872 ;; CC-872) echo CC-873 ;; CC-873) echo CC-874 ;;
  CC-874) echo CC-871 ;;
  CC-9???)
    local n="${1#CC-}"
    if [ "$n" -gt 9000 ]; then printf 'CC-%d' "$((n - 1))"; fi
    ;;
  *) : ;;
  esac
}

# Emulate the server honoring the query's parent selection depth: nest at most
# DEPTH parent levels; beyond that the parent FIELD is absent (truncation),
# while a real root within the depth gets an explicit "parent":null.
# DEPTH must match ANCESTOR_FETCH_DEPTH in issues.sh.
nested_issue() {
  local id="$1" depth="$2" p
  if [ "$depth" -eq 0 ]; then
    printf '{"id":"uuid-%s","identifier":"%s"}' "${id#CC-}" "$id"
    return
  fi
  p="$(parent_of "$id")"
  if [ -z "$p" ]; then
    printf '{"id":"uuid-%s","identifier":"%s","parent":null}' "${id#CC-}" "$id"
  else
    printf '{"id":"uuid-%s","identifier":"%s","parent":%s}' "${id#CC-}" "$id" "$(nested_issue "$p" $((depth - 1)))"
  fi
}

top_issue() {
  nested_issue "$(to_identifier "$1")" 5 | jq -c '. + {project: {id: "proj-1", name: "Test"}}'
}

case "$query" in
*"ValidateBlocking"*)
  id1="$(jq -r '.id1' <<<"$variables")"
  id2="$(jq -r '.id2' <<<"$variables")"
  printf '{"data":{"issue1":%s,"issue2":%s}}___HTTP_CODE___200' "$(top_issue "$id1")" "$(top_issue "$id2")"
  ;;
*"AncestorChunk"*)
  ref="$(to_identifier "$(jq -r '.id' <<<"$variables")")"
  printf '{"data":{"issue":%s}}___HTTP_CODE___200' "$(nested_issue "$ref" 5)"
  ;;
*"GetIssue"*)
  ref="$(jq -r '.id' <<<"$variables")"
  printf '{"data":{"issue":{"id":"uuid-%s"}}}___HTTP_CODE___200' "${ref#CC-}"
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

run_add_relation() {
  local payload_log="$1"
  shift
  : >"$payload_log"
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues add-relation "$@"
}

extract_prescription() {
  sed -n "s/.*[Uu]se '\([A-Z][A-Z]*-[0-9][0-9]*\) --blocks \([A-Z][A-Z]*-[0-9][0-9]*\)'.*/\1 \2/p" "$1"
}

# --- deep ancestor pair (root is beyond the per-query parent cap) ---
for args in "CC-708 --blocks CC-701" "CC-701 --blocks CC-708"; do
  set +e
  # shellcheck disable=SC2086
  run_add_relation "$TMP_ROOT/payloads.jsonl" $args >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL deep ancestor ($args): expected rejection, got success"
    exit 1
  fi
  if ! grep -q "cannot carry a blocking relation against its own ancestor" "$TMP_ROOT/err"; then
    echo "FAIL deep ancestor ($args): missing ancestor explanation:"
    cat "$TMP_ROOT/err"
    exit 1
  fi
  if grep -q -- "--blocks" "$TMP_ROOT/err"; then
    echo "FAIL deep ancestor ($args): truncated chain produced a bogus prescription:"
    cat "$TMP_ROOT/err"
    exit 1
  fi
  if ! jq -s -e 'any(.[]; .query | contains("AncestorChunk"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
    echo "FAIL deep ancestor ($args): expected follow-up AncestorChunk queries"
    cat "$TMP_ROOT/payloads.jsonl"
    exit 1
  fi
done

# --- deep-but-valid siblings: accepted after their root is proven ---
if ! run_add_relation "$TMP_ROOT/payloads.jsonl" CC-708 --blocks CC-709 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  echo "FAIL deep siblings: expected acceptance, got rejection:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if ! jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
  echo "FAIL deep siblings: accepted relation never sent issueRelationCreate"
  exit 1
fi
if ! jq -s -e 'any(.[]; .query | contains("AncestorChunk"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
  echo "FAIL deep siblings: full-depth accept path did not prove its root"
  cat "$TMP_ROOT/payloads.jsonl"
  exit 1
fi

# --- deep cousins: LCA beyond the cap; prescription must be the pair under it ---
set +e
run_add_relation "$TMP_ROOT/payloads.jsonl" CC-708 --blocks CC-757 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL deep cousins: expected rejection, got success"
  exit 1
fi
if [ "$(extract_prescription "$TMP_ROOT/err")" != "CC-702 CC-751" ]; then
  echo "FAIL deep cousins: expected prescription 'CC-702 --blocks CC-751', stderr:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if ! run_add_relation "$TMP_ROOT/payloads.jsonl" CC-702 --blocks CC-751 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  echo "FAIL deep cousins: prescribed command 'CC-702 --blocks CC-751' is itself rejected:"
  cat "$TMP_ROOT/err"
  exit 1
fi

# --- chunk bound exceeded: fail closed, no remediation from a truncated chain ---
set +e
run_add_relation "$TMP_ROOT/payloads.jsonl" CC-9120 --blocks CC-9000 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL chunk bound: expected rejection, got success"
  exit 1
fi
if ! grep -q "Hierarchy too deep to validate" "$TMP_ROOT/err"; then
  echo "FAIL chunk bound: missing fail-closed error:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if grep -q "[Uu]se '" "$TMP_ROOT/err"; then
  echo "FAIL chunk bound: fail-closed rejection must not carry a prescription:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if [ "$(wc -l <"$TMP_ROOT/err")" -ne 1 ] || ! jq -e '.error' "$TMP_ROOT/err" >/dev/null; then
  echo "FAIL chunk bound: expected exactly one JSON error line:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
  echo "FAIL chunk bound: rejected relation still sent issueRelationCreate"
  exit 1
fi

# --- cycle crossing a chunk boundary: reject before relation mutation ---
set +e
run_add_relation "$TMP_ROOT/payloads.jsonl" CC-850 --blocks CC-701 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL cross-chunk cycle: expected rejection, got success"
  exit 1
fi
if ! grep -q "parent cycle detected" "$TMP_ROOT/err"; then
  echo "FAIL cross-chunk cycle: missing cycle diagnostic:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
  echo "FAIL cross-chunk cycle: rejected relation still sent issueRelationCreate"
  exit 1
fi

# --- same-parent cycle hidden beyond eager selection: fail before shortcut ---
set +e
run_add_relation "$TMP_ROOT/payloads.jsonl" CC-860 --blocks CC-861 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL hidden same-parent cycle: expected rejection, got success"
  exit 1
fi
if ! grep -q "parent cycle detected" "$TMP_ROOT/err"; then
  echo "FAIL hidden same-parent cycle: missing cycle diagnostic:"
  cat "$TMP_ROOT/err"
  exit 1
fi
if ! jq -s -e 'any(.[]; .query | contains("AncestorChunk"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
  echo "FAIL hidden same-parent cycle: no root-proof query was sent"
  exit 1
fi
if jq -s -e 'any(.[]; .query | contains("issueRelationCreate"))' "$TMP_ROOT/payloads.jsonl" >/dev/null; then
  echo "FAIL hidden same-parent cycle: rejected relation still sent issueRelationCreate"
  exit 1
fi

echo "all pass"
