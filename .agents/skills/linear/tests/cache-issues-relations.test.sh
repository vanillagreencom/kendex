#!/usr/bin/env bash
# `cache issues relations <ID>` reads the cache file, not stdin.
#
# The jq invocation behind this action was never given its input file, so it
# inherited the caller's stdin: an interactive run hung, and a scripted run read
# whatever the caller happened to pipe in. No test exercised the action, so the
# suite stayed green either way. This pins the contract:
#   A. A known issue's relations come back from issues.json, all four buckets.
#   B. Both an identifier and a UUID resolve the same record.
#   C. An unknown issue is a named miss, not an empty success.
#   D. Nothing on stdin can change the answer.
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
git -C "$TMP_ROOT" init -q -b main

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-08-12T00:00:00+00:00"}
JSON

cat >"$TMP_ROOT/.cache/linear/issues.json" <<'JSON'
[
  {
    "id": "uuid-CC-1",
    "identifier": "CC-1",
    "title": "root",
    "state": {"name": "Todo", "type": "unstarted"},
    "labels": {"nodes": []},
    "relations": {"nodes": [
      {"type": "blocks",    "relatedIssue": {"identifier": "CC-2", "title": "blocked one", "state": {"name": "Backlog"}}},
      {"type": "related",   "relatedIssue": {"identifier": "CC-3", "title": "related one", "state": {"name": "Todo"}}},
      {"type": "duplicate", "relatedIssue": {"identifier": "CC-4", "title": "dupe one",    "state": {"name": "Done"}}}
    ]},
    "inverseRelations": {"nodes": [
      {"type": "blocks", "issue": {"identifier": "CC-9", "title": "blocker", "state": {"name": "In Progress"}}}
    ]}
  },
  {
    "id": "uuid-CC-2",
    "identifier": "CC-2",
    "title": "leaf",
    "state": {"name": "Backlog", "type": "backlog"},
    "labels": {"nodes": []},
    "relations": {"nodes": []},
    "inverseRelations": {"nodes": []}
  }
]
JSON

# stdin is closed so a jq that fell back to reading it cannot succeed by accident.
run_relations() { (cd "$TMP_ROOT" && bash "$LINEAR" cache issues relations "$@" <&-); }

# --- A: every relation bucket comes back from the cache file ------------------
outA_rc=0
outA="$(run_relations CC-1 2>/dev/null)" || outA_rc=$?
assert_eq "A: reading a known issue's relations exits zero" "$outA_rc" 0
assert_jq "A: blocks bucket is read from issues.json" \
  "$outA" '.blocks == [{"id":"CC-2","title":"blocked one","state":"Backlog"}]'
assert_jq "A: blocked_by bucket comes from inverseRelations" \
  "$outA" '.blocked_by == [{"id":"CC-9","title":"blocker","state":"In Progress"}]'
assert_jq "A: related and duplicates buckets are split by relation type" \
  "$outA" '[.related[].id] == ["CC-3"] and [.duplicates[].id] == ["CC-4"]'

# --- B: UUID resolves the same record as the identifier ----------------------
outB_rc=0
outB="$(run_relations uuid-CC-1 2>/dev/null)" || outB_rc=$?
assert_eq "B: a UUID lookup exits zero" "$outB_rc" 0
assert_ne "B: a UUID lookup returns a record" "$outB" ""
assert_eq "B: a UUID resolves the same relations record as the identifier" \
  "$(jq -Sc . <<<"${outB:-null}")" "$(jq -Sc . <<<"${outA:-null}")"

# An issue with no relations is a real empty answer, not a miss.
outB2_rc=0
outB2="$(run_relations CC-2 2>/dev/null)" || outB2_rc=$?
assert_eq "B: an issue with no relations exits zero" "$outB2_rc" 0
assert_jq "B: an issue with no relations returns empty buckets, not an error" \
  "$outB2" '.blocks == [] and .blocked_by == [] and .related == [] and .duplicates == []'

# --- C: an unknown issue is a named miss -------------------------------------
missing_rc=0
missing_out="$(run_relations CC-404 2>&1)" || missing_rc=$?
assert_ne "C: an unknown issue does not exit 0" "$missing_rc" 0
assert_jq "C: an unknown issue fails with an error naming the id" \
  "$missing_out" '.error | test("CC-404")'

# --- D: stdin cannot influence the answer ------------------------------------
decoy='[{"id":"uuid-CC-1","identifier":"CC-1","relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"DECOY-1","title":"decoy","state":{"name":"Todo"}}}]},"inverseRelations":{"nodes":[]}}]'
outD_rc=0
outD="$(cd "$TMP_ROOT" && printf '%s' "$decoy" | bash "$LINEAR" cache issues relations CC-1 2>/dev/null)" || outD_rc=$?
assert_eq "D: a read with stdin piped in exits zero" "$outD_rc" 0
assert_jq "D: piped stdin is ignored — the cache file is the only input" \
  "$outD" '[.blocks[].id] == ["CC-2"]'
