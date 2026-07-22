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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/.agents/skills" "$tmp/.cache/linear"
git -C "$tmp" init -q -b main
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
safe_out="$(run cache issues get CC-803 --format=safe 2>/dev/null)"
if ! jq -e '.id == "CC-803" and .parent_id == "CC-811"' >/dev/null 2>&1 <<<"$safe_out"; then
  echo "FAIL safe cache get dropped parent_id on labels:null record, got: [$safe_out]"
  exit 1
fi
# agent must degrade gracefully to "" (not crash) when labels is null
if ! jq -e '.agent == "" and (.labels == [])' >/dev/null 2>&1 <<<"$safe_out"; then
  echo "FAIL safe output did not degrade labels/agent gracefully, got: $safe_out"
  exit 1
fi

# --- raw: unchanged, still shows the parent --------------------------------------
raw_out="$(run cache issues get CC-803 --format=raw 2>/dev/null)"
if ! jq -e '.issue.parent.identifier == "CC-811"' >/dev/null 2>&1 <<<"$raw_out"; then
  echo "FAIL raw cache get no longer shows parent, got: $raw_out"
  exit 1
fi

# --- well-formed control record is unaffected (agent still resolved) -------------
ctrl_out="$(run cache issues get CC-802 --format=safe 2>/dev/null)"
if ! jq -e '.parent_id == "CC-811" and .agent == "iced" and (.labels | index("agent:iced"))' >/dev/null 2>&1 <<<"$ctrl_out"; then
  echo "FAIL well-formed record output changed, got: $ctrl_out"
  exit 1
fi

# --- --with-bundle safe path also resolves parent on the labels:null child -------
bundle_out="$(run cache issues get CC-803 --with-bundle --format=safe 2>/dev/null)"
if ! jq -e '.parent_id == "CC-811"' >/dev/null 2>&1 <<<"$bundle_out"; then
  echo "FAIL bundle safe path dropped parent_id, got: $bundle_out"
  exit 1
fi

# --- list --format=safe must not crash the WHOLE list on one labels:null record --
list_out="$(run cache issues list --max --format=safe 2>/dev/null)"
if ! jq -e '(map(.id) | index("CC-803")) and (map(.id) | index("CC-802"))' >/dev/null 2>&1 <<<"$list_out"; then
  echo "FAIL safe list crashed / dropped records on labels:null member, got: $list_out"
  exit 1
fi
if ! jq -e '.[] | select(.id == "CC-803") | .parent_id == "CC-811"' >/dev/null 2>&1 <<<"$list_out"; then
  echo "FAIL safe list dropped parent_id for labels:null member, got: $list_out"
  exit 1
fi

echo "all pass"
