#!/usr/bin/env bash
# Regression test (#625, bug 2): the safe formatter must not silently drop
# parent_id (and every other field) when a cached issue record's `labels` is
# null/absent.
#
# Root cause: in the safe/compact/table jq programs the `agent`/`platform`
# fields iterated `.labels.nodes[]` UNGUARDED, while the sibling `labels:` field
# guarded it with `(.labels.nodes // [])`. A cached record with `labels: null`
# therefore aborted the ENTIRE safe jq ("Cannot iterate over null"), so
# `cache issues get <child> --format=safe` produced no usable object — parent_id
# read back as null/empty even though the record genuinely carried its parent —
# while `--format=raw` (which just echoes the record) still showed the parent.
# That is exactly the "safe drops parent_id despite real linkage / raw shows it"
# symptom class from the report. Guarding the iteration restores the documented
# null-safe contract.
#
# NOTE on the reported CC-803 case specifically: with a WELL-FORMED cached record
# (labels present, parent present) the safe formatter already resolves parent_id
# correctly, so the field reported there was most consistent with a stale cache
# (the record predating the parent assignment). This test locks in the general
# safe-format robustness that a null/absent `labels` no longer nukes parent_id.
#
# Fully offline — pure cache read, no curl needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

assert_tmpdir tmp

mkdir -p "$tmp/.agents/skills" "$tmp/.cache/linear"
git -C "$tmp" init -q -b main

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$tmp"
cp -R "$SKILL_DIR" "$tmp/.agents/skills/linear"
LINEAR="$tmp/.agents/skills/linear/scripts/linear.sh"

cat > "$tmp/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-05-30T00:00:00+00:00"}
JSON

# CC-811 = parent (well-formed labels).
# CC-803 = child WITH a genuine parent (CC-811) but a malformed labels:null.
# CC-802 = child WITH a genuine parent and WELL-FORMED labels (control).
cat > "$tmp/.cache/linear/issues.json" <<'JSON'
[
  {
    "id": "parent-uuid", "identifier": "CC-811", "title": "Parent",
    "state": {"name": "In Progress", "type": "started"},
    "labels": {"nodes": []},
    "project": {"id": "p1", "name": "Phase 2"},
    "parent": null, "projectMilestone": null, "cycle": null,
    "relations": {"nodes": []}, "inverseRelations": {"nodes": []},
    "archivedAt": null, "trashed": false
  },
  {
    "id": "child-uuid", "identifier": "CC-803", "title": "Child (labels null)",
    "state": {"name": "Todo", "type": "unstarted"},
    "labels": null,
    "project": {"id": "p1", "name": "Phase 2"},
    "parent": {"id": "parent-uuid", "identifier": "CC-811", "title": "Parent"},
    "projectMilestone": null, "cycle": null,
    "relations": {"nodes": []}, "inverseRelations": {"nodes": []},
    "archivedAt": null, "trashed": false
  },
  {
    "id": "child2-uuid", "identifier": "CC-802", "title": "Child (well-formed)",
    "state": {"name": "Todo", "type": "unstarted"},
    "labels": {"nodes": [{"name": "agent:iced"}]},
    "project": {"id": "p1", "name": "Phase 2"},
    "parent": {"id": "parent-uuid", "identifier": "CC-811", "title": "Parent"},
    "projectMilestone": null, "cycle": null,
    "relations": {"nodes": []}, "inverseRelations": {"nodes": []},
    "archivedAt": null, "trashed": false
  }
]
JSON

run() { cd "$tmp" && PATH="$tmp/bin:$PATH" bash "$LINEAR" "$@"; }

# --- safe: labels:null child still surfaces its real parent_id -------------------
safe_rc=0
safe_out="$(run cache issues get CC-803 --format=safe 2>/dev/null)" || safe_rc=$?
assert_eq "a safe get of a labels:null record exits zero" "$safe_rc" 0
assert_jq "safe cache get keeps parent_id on a labels:null record" \
  "$safe_out" '.id == "CC-803" and .parent_id == "CC-811"'
# agent must degrade gracefully to "" (not crash) when labels is null
assert_jq "safe output degrades labels and agent gracefully" \
  "$safe_out" '.agent == "" and (.labels == [])' 

# --- raw: unchanged, still shows the parent --------------------------------------
raw_rc=0
raw_out="$(run cache issues get CC-803 --format=raw 2>/dev/null)" || raw_rc=$?
assert_eq "a raw get of the same record exits zero" "$raw_rc" 0
assert_jq "raw cache get still shows the parent" \
  "$raw_out" '.issue.parent.identifier == "CC-811"' 

# --- well-formed control record is unaffected (agent still resolved) -------------
ctrl_rc=0
ctrl_out="$(run cache issues get CC-802 --format=safe 2>/dev/null)" || ctrl_rc=$?
assert_eq "a safe get of a well-formed record exits zero" "$ctrl_rc" 0
assert_jq "a well-formed record still resolves parent, agent and labels" \
  "$ctrl_out" '.parent_id == "CC-811" and .agent == "iced" and (.labels | index("agent:iced"))' 

# --- --with-bundle safe path also resolves parent on the labels:null child -------
bundle_rc=0
bundle_out="$(run cache issues get CC-803 --with-bundle --format=safe 2>/dev/null)" || bundle_rc=$?
assert_eq "the --with-bundle safe path exits zero" "$bundle_rc" 0
assert_jq "the --with-bundle safe path keeps parent_id" "$bundle_out" '.parent_id == "CC-811"' 

# --- list --format=safe must not crash the WHOLE list on one labels:null record --
list_rc=0
list_out="$(run cache issues list --max --format=safe 2>/dev/null)" || list_rc=$?
assert_eq "a safe list over a labels:null member exits zero" "$list_rc" 0
assert_jq "a labels:null member does not drop records from the safe list" \
  "$list_out" '(map(.id) | index("CC-803")) and (map(.id) | index("CC-802"))'
assert_jq "the safe list keeps parent_id for a labels:null member" \
  "$list_out" '.[] | select(.id == "CC-803") | .parent_id == "CC-811"' 

