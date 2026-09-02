#!/usr/bin/env bash
# cache issues list --no-project (kendex #966).
#
# `cache issues list --no-project` used to be an UNIMPLEMENTED flag: the arg loop
# silently swallowed any unknown flag, so the requested "only unassigned" filter
# never ran and the command returned every issue up to the limit — project-
# assigned rows included. Consumers reading it as unassigned triage debt (TPM
# audits, audit-issues) inflated their worklists with false positives.
#
# The rows themselves were never wrong: each carries the same .project.name that
# `cache issues get` reports, from the same issues.json. The bug was purely the
# missing filter plus the silent-swallow. This locks in:
#   A. --no-project returns ONLY issues with no project, and each returned row's
#      own project field is empty — the list cannot disagree with a get record.
#   B. --no-project is mutually exclusive with --project / --all-projects.
#   C. An unknown/unimplemented filter flag fails loudly instead of degenerating
#      to a full unfiltered listing.
#   D. --help and an ordinary list are unaffected.
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
{"synced_at":"2026-07-17T00:00:00+00:00"}
JSON

# Args: identifier state_name state_type project_name (empty = no project).
# A project_name of "-null-" emits a record with the project key entirely absent
# (not just null), the shape an unsynced-project issue can take.
issue_record() {
  local id="$1" sname="$2" stype="$3" pname="$4"
  if [[ "$pname" == "-null-" ]]; then
    printf '{"id":"uuid-%s","identifier":"%s","title":"%s title","state":{"name":"%s","type":"%s"},"labels":{"nodes":[]},"archivedAt":null,"trashed":false}\n' \
      "$id" "$id" "$id" "$sname" "$stype"
    return
  fi
  local project_json="null"
  [[ -n "$pname" ]] && project_json="{\"id\":\"proj-$pname\",\"name\":\"$pname\"}"
  printf '{"id":"uuid-%s","identifier":"%s","title":"%s title","state":{"name":"%s","type":"%s"},"labels":{"nodes":[]},"project":%s,"archivedAt":null,"trashed":false}\n' \
    "$id" "$id" "$id" "$sname" "$stype" "$project_json"
}

{
  issue_record CC-1 Todo unstarted "Trading Panels"
  issue_record CC-2 Todo unstarted ""        # project: null
  issue_record CC-3 Backlog backlog "Execution Engine"
  issue_record CC-4 Backlog backlog "-null-" # project key absent
} | jq -s '.' >"$TMP_ROOT/.cache/linear/issues.json"

run_list() { cd "$TMP_ROOT" && bash "$LINEAR" cache issues list "$@"; }

# --- A: --no-project returns only the unassigned issues ----------------------
outA="$(run_list --no-project --max --format=compact 2>/dev/null)"
assert_eq "A: --no-project returns exactly the unassigned issues (null and absent project)" \
  "$(jq -r '[.[].id] | sort | join(",")' <<<"$outA")" "CC-2,CC-4"
# The assigned issues must NOT leak through — the reported symptom.
assert_jq "A: project-assigned issues do not leak past --no-project" \
  "$outA" '[.[].id] | (index("CC-1") or index("CC-3")) | not'
# Each returned row's own project field is empty — list agrees with get record.
assert_jq "A: every --no-project row carries an empty project (agrees with its get record)" \
  "$outA" 'all(.[]; .project == "")'

# --- B: mutual exclusion -----------------------------------------------------
run_status rc_project run_list --no-project --project "Trading Panels" >/dev/null 2>&1
assert_ne "B: --no-project + --project fails loudly" "$rc_project" 0
run_status rc_all run_list --no-project --all-projects >/dev/null 2>&1
assert_ne "B: --no-project + --all-projects fails loudly" "$rc_all" 0

# --- C: an unknown filter flag fails loudly, not silently ---------------------
unk_rc=0
unk_out="$(run_list --unassigned 2>&1)" || unk_rc=$?
assert_ne "C: an unknown flag does not exit 0" "$unk_rc" 0
assert_jq "C: an unknown filter flag is rejected instead of returning every issue" \
  "$unk_out" '.error | test("Unknown flag")'

# --- D: --help and an ordinary list are unaffected ---------------------------
help_rc=0
help_out="$(run_list --help 2>&1)" || help_rc=$?
assert_eq "D: --help exits zero" "$help_rc" 0
assert_contains "D: --help still prints cache help" "$help_out" "Linear Cache Query"
plain="$(run_list --max --format=ids 2>/dev/null)"
assert_eq "D: an ordinary list still returns every issue" \
  "$(printf '%s\n' "$plain" | sort | tr '\n' ',')" "CC-1,CC-2,CC-3,CC-4,"
