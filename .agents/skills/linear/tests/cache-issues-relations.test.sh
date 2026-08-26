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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
git -C "$TMP_ROOT" init -q -b main
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

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" >&2; }

# stdin is closed so a jq that fell back to reading it cannot succeed by accident.
run_relations() { (cd "$TMP_ROOT" && bash "$LINEAR" cache issues relations "$@" <&-); }

# --- A: every relation bucket comes back from the cache file ------------------
outA="$(run_relations CC-1 2>/dev/null || true)"
if jq -e '.blocks == [{"id":"CC-2","title":"blocked one","state":"Backlog"}]' >/dev/null 2>&1 <<<"$outA"; then
  pass "A: blocks bucket is read from issues.json"
else
  fail "A: blocks bucket wrong" "$outA"
fi
if jq -e '.blocked_by == [{"id":"CC-9","title":"blocker","state":"In Progress"}]' >/dev/null 2>&1 <<<"$outA"; then
  pass "A: blocked_by bucket comes from inverseRelations"
else
  fail "A: blocked_by bucket wrong" "$outA"
fi
if jq -e '[.related[].id] == ["CC-3"] and [.duplicates[].id] == ["CC-4"]' >/dev/null 2>&1 <<<"$outA"; then
  pass "A: related and duplicates buckets are split by relation type"
else
  fail "A: related/duplicates buckets wrong" "$outA"
fi

# --- B: UUID resolves the same record as the identifier ----------------------
outB="$(run_relations uuid-CC-1 2>/dev/null || true)"
if [[ -n "$outB" ]] && [[ "$(jq -Sc . <<<"$outB")" == "$(jq -Sc . <<<"$outA")" ]]; then
  pass "B: a UUID resolves the same relations record as the identifier"
else
  fail "B: UUID lookup disagreed with identifier lookup" "$outB"
fi

# An issue with no relations is a real empty answer, not a miss.
outB2="$(run_relations CC-2 2>/dev/null || true)"
if jq -e '.blocks == [] and .blocked_by == [] and .related == [] and .duplicates == []' >/dev/null 2>&1 <<<"$outB2"; then
  pass "B: an issue with no relations returns empty buckets, not an error"
else
  fail "B: no-relations issue did not return empty buckets" "$outB2"
fi

# --- C: an unknown issue is a named miss -------------------------------------
missing_out="$(run_relations CC-404 2>&1 || true)"
if run_relations CC-404 >/dev/null 2>&1; then
  fail "C: an unknown issue should not exit 0" "$missing_out"
elif jq -e '.error | test("CC-404")' >/dev/null 2>&1 <<<"$missing_out"; then
  pass "C: an unknown issue fails with an error naming the id"
else
  fail "C: unknown issue did not produce the expected error" "$missing_out"
fi

# --- D: stdin cannot influence the answer ------------------------------------
decoy='[{"id":"uuid-CC-1","identifier":"CC-1","relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"DECOY-1","title":"decoy","state":{"name":"Todo"}}}]},"inverseRelations":{"nodes":[]}}]'
outD="$(cd "$TMP_ROOT" && printf '%s' "$decoy" | bash "$LINEAR" cache issues relations CC-1 2>/dev/null || true)"
if [[ -n "$outD" ]] && jq -e '[.blocks[].id] == ["CC-2"]' >/dev/null 2>&1 <<<"$outD"; then
  pass "D: piped stdin is ignored — the cache file is the only input"
else
  fail "D: stdin changed the answer" "$outD"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
