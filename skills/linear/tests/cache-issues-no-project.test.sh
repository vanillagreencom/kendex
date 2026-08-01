#!/usr/bin/env bash
# cache issues list --no-project (vstack #966).
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

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" >&2; }

# --- A: --no-project returns only the unassigned issues ----------------------
outA="$(run_list --no-project --max --format=compact 2>/dev/null)"
if [[ "$(jq -r '[.[].id] | sort | join(",")' <<<"$outA")" == "CC-2,CC-4" ]]; then
  pass "A: --no-project returns exactly the unassigned issues (null and absent project)"
else
  fail "A: --no-project returned the wrong set" "$outA"
fi
# The assigned issues must NOT leak through — the reported symptom.
if jq -e '[.[].id] | (index("CC-1") or index("CC-3")) | not' >/dev/null 2>&1 <<<"$outA"; then
  pass "A: project-assigned issues do not leak past --no-project"
else
  fail "A: an assigned issue leaked past --no-project" "$outA"
fi
# Each returned row's own project field is empty — list agrees with get record.
if jq -e 'all(.[]; .project == "")' >/dev/null 2>&1 <<<"$outA"; then
  pass "A: every --no-project row carries an empty project (agrees with its get record)"
else
  fail "A: a --no-project row carries a non-empty project" "$outA"
fi

# --- B: mutual exclusion -----------------------------------------------------
if run_list --no-project --project "Trading Panels" >/dev/null 2>&1; then
  fail "B: --no-project --project should fail"
else
  pass "B: --no-project + --project fails loudly"
fi
if run_list --no-project --all-projects >/dev/null 2>&1; then
  fail "B: --no-project --all-projects should fail"
else
  pass "B: --no-project + --all-projects fails loudly"
fi

# --- C: an unknown filter flag fails loudly, not silently ---------------------
unk_out="$(run_list --unassigned 2>&1 || true)"
if run_list --unassigned >/dev/null 2>&1; then
  fail "C: an unknown flag should not exit 0" "$unk_out"
elif jq -e '.error | test("Unknown flag")' >/dev/null 2>&1 <<<"$unk_out"; then
  pass "C: an unknown filter flag is rejected instead of returning every issue"
else
  fail "C: unknown flag did not produce the expected error" "$unk_out"
fi

# --- D: --help and an ordinary list are unaffected ---------------------------
if run_list --help 2>&1 | grep -q "Linear Cache Query"; then
  pass "D: --help still prints cache help"
else
  fail "D: --help no longer prints help"
fi
plain="$(run_list --max --format=ids 2>/dev/null)"
if [[ "$(printf '%s\n' "$plain" | sort | tr '\n' ',' )" == "CC-1,CC-2,CC-3,CC-4," ]]; then
  pass "D: an ordinary list still returns every issue"
else
  fail "D: ordinary list changed" "$plain"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
