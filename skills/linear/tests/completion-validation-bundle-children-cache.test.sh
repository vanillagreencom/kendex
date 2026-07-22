#!/usr/bin/env bash
# Cache-path companion to completion-validation-bundle-children.test.sh
# (vstack #634, coverage follow-up #640).
#
# #634 fixed the --include-children-of expansion in BOTH paths: the live
# issues.sh path (covered by the sibling test) and cache_validate_completion in
# commands/cache-query.sh, which expands the bundle from the local cache with
#   [.children[] | select(.state_type != "canceled") | .id]
# Pre-fix that filter was `select(.state_type | IN("completed", "canceled") | not)`,
# which DROPPED completed children — the exact children that validate as Done
# under the "bundle-child" role — so a fully-Done bundle expanded to an EMPTY
# child list. This test locks in the cache-path behavior independently.
#
# Fully offline — pure cache read via `linear.sh cache issues
# validate-completion`, no curl needed. Same three scenarios as the live test:
#   A. All children completed  -> children present + passing, all_ok true.
#   B. One child still pending -> child present + failing, all_ok false.
#   C. A canceled child        -> excluded from the expansion entirely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear/comments"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-07-14T00:00:00+00:00"}
JSON

# One cached issue record. Children are linked to their bundle purely through
# parent.identifier — cache_get_children_recursive derives the bundle's
# children from that field, so no children array is seeded on the parent.
# Args: identifier state_name state_type parent_identifier
issue_record() {
  local id="$1" sname="$2" stype="$3" parent="$4" parent_json="null"
  if [[ -n "$parent" ]]; then
    parent_json="{\"id\":\"uuid-$parent\",\"identifier\":\"$parent\",\"title\":\"parent\"}"
  fi
  printf '{"id":"uuid-%s","identifier":"%s","title":"%s","description":null,"state":{"name":"%s","type":"%s"},"assignee":null,"labels":{"nodes":[]},"project":null,"projectMilestone":null,"cycle":null,"priority":3,"estimate":null,"parent":%s,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]},"archivedAt":null,"trashed":false}\n' \
    "$id" "$id" "$id" "$sname" "$stype" "$parent_json"
}

{
  issue_record CC-900 'In Review' started ""
  issue_record CC-901 Done completed CC-900
  issue_record CC-902 Done completed CC-900
  issue_record CC-910 'In Review' started ""
  issue_record CC-911 Done completed CC-910
  issue_record CC-912 'In Progress' started CC-910
  issue_record CC-920 'In Review' started ""
  issue_record CC-921 Done completed CC-920
  issue_record CC-922 Canceled canceled CC-920
} | jq -s '.' >"$TMP_ROOT/.cache/linear/issues.json"

# Every issue except the canceled one carries a Completion Summary comment, so
# scenario B's pending child fails on state alone (mirrors the live test).
seed_summary_comment() {
  cat >"$TMP_ROOT/.cache/linear/comments/$1.json" <<'JSON'
[{"id":"c1","body":"## Completion Summary\n\nShipped.","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","user":{"name":"Test"}}]
JSON
}
for id in CC-900 CC-901 CC-902 CC-910 CC-911 CC-912 CC-920 CC-921; do
  seed_summary_comment "$id"
done

run_validate() {
  cd "$TMP_ROOT" && bash "$LINEAR" cache issues validate-completion "$@"
}

fail=0

check() {
  local label="$1" out="$2" filter="$3"
  if ! jq -e "$filter" >/dev/null 2>&1 <<<"$out"; then
    echo "FAIL: $label"
    echo "  filter: $filter"
    echo "  output: $out"
    fail=1
  fi
}

# --- Scenario A: all children completed (the #634 regression) --------------
outA="$(run_validate CC-900 --include-children-of CC-900 2>/dev/null)"
check "A: three results (root + 2 completed children)" "$outA" \
  '(.results | length) == 3'
check "A: completed child CC-901 is PRESENT and passes as Done" "$outA" \
  '.results[] | select(.id == "CC-901") | .state == "Done" and .state_ok == true and .ok == true'
check "A: completed child CC-902 is PRESENT and passes as Done" "$outA" \
  '.results[] | select(.id == "CC-902") | .state == "Done" and .state_ok == true and .ok == true'
check "A: session-root CC-900 passes in its pre-merge In Review state" "$outA" \
  '.results[] | select(.id == "CC-900") | .state == "In Review" and .state_ok == true and .ok == true'
check "A: all_ok true when every child is Done" "$outA" '.all_ok == true'

# --- Scenario B: a still-pending child must still fail ----------------------
outB="$(run_validate CC-910 --include-children-of CC-910 2>/dev/null)"
check "B: three results (root + Done child + pending child)" "$outB" \
  '(.results | length) == 3'
check "B: Done child CC-911 passes" "$outB" \
  '.results[] | select(.id == "CC-911") | .ok == true'
check "B: pending child CC-912 is PRESENT and fails state_ok/ok" "$outB" \
  '.results[] | select(.id == "CC-912") | .state == "In Progress" and .state_ok == false and .ok == false'
check "B: all_ok false when a child is still pending" "$outB" '.all_ok == false'

# --- Scenario C: canceled children are excluded from the expansion ---------
outC="$(run_validate CC-920 --include-children-of CC-920 2>/dev/null)"
check "C: two results (root + only the Done child; canceled excluded)" "$outC" \
  '(.results | length) == 2'
check "C: Done child CC-921 passes" "$outC" \
  '.results[] | select(.id == "CC-921") | .ok == true'
check "C: canceled child CC-922 is NOT in results" "$outC" \
  '([.results[] | select(.id == "CC-922")] | length) == 0'
check "C: all_ok true (canceled child does not block)" "$outC" '.all_ok == true'

# --- Preserve single-issue behavior (no --include-children-of) -------------
outS="$(run_validate CC-901 2>/dev/null)"
check "S: single-issue validate has exactly one result" "$outS" \
  '(.results | length) == 1 and .results[0].id == "CC-901"'

if [[ "$fail" -ne 0 ]]; then
  echo "completion-validation-bundle-children-cache: FAIL"
  exit 1
fi

echo "all pass"
