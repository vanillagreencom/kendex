#!/usr/bin/env bash
# Regression lint for vstack#687. A focused Linear issue audit's read-only
# post-mutation verification produced `linear.sh issues view` — an action the
# Linear CLI does not have; the supported lookups are `issues get`,
# `issues bulk-get`, and `cache issues get`. No canonical doc carried the bad
# form — the audit workflow stated no post-mutation verification command at
# all, so the auditing agent improvised one (same class as vstack#641).
# audit-issues § 7.5 now names the exact tracker-routed verification commands,
# and the linear SKILL.md states there is no `view`/`show` action.
#
# This lint scans the project-management and linear doc trees (every line —
# prose, inline code, and fenced blocks alike, since guidance text is what
# agents relay; linear is a required project-management dependency, so both
# are present wherever project-management is installed) and FAILS if any line
# invokes a `view`/`show` issue lookup:
#   - `linear.sh issues view ...` (the reported miss) / `linear.sh issue view`
#   - `linear.sh cache issues view ...`
#   - `issues.sh view` / bare `issues view` / `issues show` shapes
# The GitHub route's `gh issue view` is a real command (singular `issue`) and
# must never be flagged. The lint also asserts the docs that state the
# verification obligation still carry the supported commands, so the guidance
# can't silently drop them.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILLS_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_bad_issues_view <file>
# Emits one "file:line: ..." row per line that invokes a view/show issue
# lookup. `gh issue view` never matches — bare-shape matching is plural-only
# (`issues`), and the CLI shapes require a `linear.sh`/`issues.sh` prefix.
scan_bad_issues_view() {
  grep -nE '(linear\.sh[[:space:]]+(cache[[:space:]]+)?issues?|issues\.sh|(^|[^[:alnum:]_./-])issues)[[:space:]]+(view|show)([^[:alnum:]]|$)' "$1" \
    | sed "s|^|$1:|" || true
}

echo "=== linear issues view lookup lint (vstack#687) ==="

# --- Part a: project-management and linear docs must be clean ----------------
offenders=""
for skill in project-management linear; do
  while IFS= read -r -d '' doc; do
    out="$(scan_bad_issues_view "$doc")"
    [[ -n "$out" ]] && offenders+="$out"$'\n'
  done < <(find "$SKILLS_ROOT/$skill" -maxdepth 2 -type f -name '*.md' -not -path '*/tests/*' -print0)
done
if [[ -z "$offenders" ]]; then
  pass "project-management/linear docs never invoke a view/show issue lookup"
else
  fail "docs invoke a view/show issue lookup (use issues get / issues bulk-get / cache issues get):"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: the obligation-stating docs carry the supported commands --------
audit_issues="$SKILL_DIR/workflows/audit-issues.md"
if grep -Fq 'linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2] --format=safe' "$audit_issues"; then
  pass "audit-issues post-mutation verification carries the live bulk-get fetch"
else
  fail "audit-issues post-mutation verification lost the live bulk-get fetch"
fi
if grep -Fq 'linear.sh cache issues get [ISSUE_ID]' "$audit_issues"; then
  pass "audit-issues post-mutation verification carries the cache get lookup"
else
  fail "audit-issues post-mutation verification lost the cache get lookup"
fi
if grep -Fq 'gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels,state,url' "$audit_issues"; then
  pass "audit-issues post-mutation verification carries the GitHub-route fetch"
else
  fail "audit-issues post-mutation verification lost the GitHub-route fetch"
fi
if grep -Eq 'Post-Mutation Verification' "$audit_issues"; then
  pass "audit-issues § 7 states the post-mutation verification obligation"
else
  fail "audit-issues § 7 lost the post-mutation verification section"
fi
if grep -Fq 'issues bulk-get' "$SKILLS_ROOT/linear/SKILL.md"; then
  pass "linear SKILL.md names bulk-get as a supported lookup"
else
  fail "linear SKILL.md lost the bulk-get lookup note"
fi

# --- Part c: the lint has teeth ----------------------------------------------

# inject_line <descriptor> <line> → prints scratch-file path.
# Appends <line> to a scratch copy of the real, now-clean audit workflow doc
# under $TMP_ROOT (removed by the EXIT trap). The base doc has zero offenders
# — including its legitimate GitHub-route `gh issue view` lines — so any
# offender reported comes from the injected line alone.
inject_line() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$audit_issues" "$scratch"
  printf '\n%s\n' "$2" >> "$scratch"
  printf '%s' "$scratch"
}

# c.1 — the reported miss IS flagged.
if [[ -n "$(scan_bad_issues_view "$(inject_line miss 'Verify with `.agents/skills/linear/scripts/linear.sh issues view CC-125 --format=safe`.')")" ]]; then
  pass "lint flags 'linear.sh issues view'"
else
  fail "lint MISSED 'linear.sh issues view' (no teeth)"
fi

# c.2 — near-miss variants ARE flagged.
if [[ -n "$(scan_bad_issues_view "$(inject_line singular 'Run `linear.sh issue view PROJ-42`.')")" ]]; then
  pass "lint flags the singular 'linear.sh issue view' near-miss"
else
  fail "lint MISSED the singular 'linear.sh issue view' near-miss (no teeth)"
fi
if [[ -n "$(scan_bad_issues_view "$(inject_line cache 'Run `linear.sh cache issues view PROJ-42`.')")" ]]; then
  pass "lint flags 'linear.sh cache issues view'"
else
  fail "lint MISSED 'linear.sh cache issues view' (no teeth)"
fi
if [[ -n "$(scan_bad_issues_view "$(inject_line bare 'Verify each mutation with `issues view PROJ-42` afterwards.')")" ]]; then
  pass "lint flags the bare 'issues view' shape"
else
  fail "lint MISSED the bare 'issues view' shape (no teeth)"
fi
if [[ -n "$(scan_bad_issues_view "$(inject_line show 'Run `issues.sh show PROJ-42`.')")" ]]; then
  pass "lint flags the 'issues.sh show' near-miss"
else
  fail "lint MISSED the 'issues.sh show' near-miss (no teeth)"
fi

# c.3 — supported and legitimate forms are NOT flagged.
if [[ -z "$(scan_bad_issues_view "$(inject_line gh 'Fetch with `gh issue view [N] --repo [OWNER/REPO] --json labels`.')")" ]]; then
  pass "lint accepts the GitHub route's 'gh issue view'"
else
  fail "lint false-flagged the GitHub route's 'gh issue view'"
fi
if [[ -z "$(scan_bad_issues_view "$(inject_line bulkget 'Verify with `.agents/skills/linear/scripts/linear.sh issues bulk-get PROJ-42 PROJ-43 --format=safe`.')")" ]]; then
  pass "lint accepts the supported 'issues bulk-get' fetch"
else
  fail "lint false-flagged the supported 'issues bulk-get' fetch"
fi
if [[ -z "$(scan_bad_issues_view "$(inject_line cacheget 'Read `linear.sh cache issues get PROJ-42`.')")" ]]; then
  pass "lint accepts the supported 'cache issues get' lookup"
else
  fail "lint false-flagged the supported 'cache issues get' lookup"
fi
if [[ -z "$(scan_bad_issues_view "$(inject_line prose 'Report the issues shown in the summary.')")" ]]; then
  pass "lint accepts prose like 'issues shown'"
else
  fail "lint false-flagged prose like 'issues shown'"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
