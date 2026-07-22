#!/usr/bin/env bash
# Batch all-project cache enumeration (vstack #676).
#
# Audit workflows load a cross-project comparison set from the cache. The
# natural per-project shell loop is rejected by restricted harness approval
# classifiers (loop shape, not access), so `cache issues list` grew an explicit
# `--all-projects` flag: ONE command that enumerates every project, each row
# carrying its `project` name, composable with the existing filters and
# mutually exclusive with `--project`. This test locks in:
#   A. --all-projects returns rows from multiple seeded projects, each tagged
#      with its project name (rows without a project carry "").
#   B. --state composes with --all-projects.
#   C. --all-projects + --project fails loudly (nonzero exit, clear error).
#   D. Per-project call output is unchanged, and the all-projects row shape is
#      identical to the per-project row shape (superset-compatible consumers).
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
{"synced_at":"2026-07-17T00:00:00+00:00"}
JSON

# One cached issue record with an explicit project assignment.
# Args: identifier state_name state_type project_name (empty = no project)
issue_record() {
  local id="$1" sname="$2" stype="$3" pname="$4" project_json="null"
  if [[ -n "$pname" ]]; then
    project_json="{\"id\":\"proj-$pname\",\"name\":\"$pname\"}"
  fi
  printf '{"id":"uuid-%s","identifier":"%s","title":"%s title","description":null,"state":{"name":"%s","type":"%s"},"assignee":null,"labels":{"nodes":[]},"project":%s,"projectMilestone":null,"cycle":null,"priority":3,"estimate":null,"parent":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]},"archivedAt":null,"trashed":false}\n' \
    "$id" "$id" "$id" "$sname" "$stype" "$project_json"
}

{
  issue_record CC-1 Backlog backlog Alpha
  issue_record CC-2 Done completed Alpha
  issue_record CC-3 Todo unstarted Beta
  issue_record CC-4 Backlog backlog ""
} | jq -s '.' >"$TMP_ROOT/.cache/linear/issues.json"

run_list() {
  cd "$TMP_ROOT" && bash "$LINEAR" cache issues list "$@"
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

# --- A: rows from every seeded project, each tagged with its project --------
outA="$(run_list --all-projects --max --format=compact 2>/dev/null)"
check "A: all four cached issues enumerated" "$outA" 'length == 4'
check "A: Alpha rows carry project Alpha" "$outA" \
  '[.[] | select(.project == "Alpha") | .id] | sort == ["CC-1", "CC-2"]'
check "A: Beta row carries project Beta" "$outA" \
  '[.[] | select(.project == "Beta") | .id] == ["CC-3"]'
check "A: project-less row carries empty project" "$outA" \
  '[.[] | select(.project == "") | .id] == ["CC-4"]'

# Safe (default) format carries project per row too.
outAsafe="$(run_list --all-projects --max 2>/dev/null)"
check "A: safe format enumerates all projects with project field" "$outAsafe" \
  '(length == 4) and ([.[] | select(.id == "CC-3") | .project] == ["Beta"])'

# --- B: --state composes with --all-projects --------------------------------
outB="$(run_list --all-projects --state "Backlog,Todo" --max --format=compact 2>/dev/null)"
check "B: Done row excluded by composed state filter" "$outB" \
  '[.[].id] | sort == ["CC-1", "CC-3", "CC-4"]'

# --- C: mutual exclusion with --project fails loudly -------------------------
rcC=0
errC="$(run_list --all-projects --project "Alpha" --max 2>&1 >/dev/null)" || rcC=$?
if [[ "$rcC" -eq 0 ]]; then
  echo "FAIL: C: --all-projects with --project must exit nonzero"
  fail=1
fi
if [[ "$errC" != *"--all-projects cannot be combined with --project"* ]]; then
  echo "FAIL: C: conflict error message missing"
  echo "  stderr: $errC"
  fail=1
fi

# --- D: per-project call unchanged; row shape matches --all-projects ---------
outD="$(run_list --project "Alpha" --max --format=compact 2>/dev/null)"
check "D: per-project call returns only that project's issues" "$outD" \
  '[.[].id] | sort == ["CC-1", "CC-2"]'
check "D: per-project rows keep the compact field set" "$outD" \
  '.[0] | keys | sort == ["agent", "blocked_by", "blocks", "estimate", "id", "labels", "parent_id", "priority", "project", "sort_order", "state", "state_type", "title"]'

per_project_keys="$(jq -c '[.[] | select(.id == "CC-1")][0] | keys | sort' <<<"$outD")"
all_projects_keys="$(jq -c '[.[] | select(.id == "CC-1")][0] | keys | sort' <<<"$outA")"
if [[ "$per_project_keys" != "$all_projects_keys" ]]; then
  echo "FAIL: D: --all-projects row shape diverges from per-project row shape"
  echo "  per-project:  $per_project_keys"
  echo "  all-projects: $all_projects_keys"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "cache-issues-all-projects: FAIL"
  exit 1
fi

echo "all pass"
