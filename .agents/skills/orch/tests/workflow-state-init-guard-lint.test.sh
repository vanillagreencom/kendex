#!/usr/bin/env bash
# `workflow-state init` overwrites. A workflow that runs it over a restored
# state file drops the item's round history: `cycles`, `fixed_items` and
# `patched_causes`. Every workflow that runs `init` therefore reads
# `workflow-state exists --json` first.
#
# A fenced rule pins the `exists` command in the section holding the `init`;
# dev-start runs `init` in its preamble, which has no heading of its own, so
# its rule reads the whole file. A prose rule reads the whole file too, and
# pins the guard and the `init` on one line. The two workflows that keep an
# existing state also pin both `workflow-state set` commands of that path. The
# file-set check fails when a workflow gains an `init` no rule here reads.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch workflow-state init guard lint ==="

W="$SKILL_DIR/workflows"
GUARDED=()
guard_fenced() { GUARDED+=("$2"); rule_fenced "$1 reads exists in its init section" "$W/$2" "$3" "$4"; }
guard_prose() { GUARDED+=("$2"); rule "$1 reads exists on its init line" "$W/$2" "" "$3" 'workflow-state init'; }
keeps_state() {
  rule_fenced "$1 keeps existing state: sets worktree" "$W/$2" "$3" 'workflow-state set [ISSUE_ID] worktree'
  rule_fenced "$1 keeps existing state: sets branch" "$W/$2" "$3" 'workflow-state set [ISSUE_ID] branch'
}

guard_fenced start-worktree start-worktree.md "## 1. Open The Session" 'workflow-state exists --json [ISSUE_ID]'
keeps_state start-worktree start-worktree.md "## 1. Open The Session"
guard_fenced micro micro.md "## 1. Open The Session" 'workflow-state exists --json [ISSUE_ID]'
keeps_state micro micro.md "## 1. Open The Session"
guard_fenced dev-start dev-start.md "" 'workflow-state exists --json [ISSUE_ID]'
guard_fenced ci-fix ci-fix.md "## 1. Identify Failures" 'workflow-state exists --json [STATE_KEY]'
guard_fenced merge-pr merge-pr.md "## 3. Check Merge Readiness" 'workflow-state exists --json [STATE_KEY]'
guard_fenced oversee oversee.md "### Lane record" 'workflow-state exists --json oversee'
guard_prose post-summary post-summary.md 'workflow-state exists --json [ISSUE_ID]` reports false'
guard_prose review-pr review-pr.md 'workflow-state exists --json [ISSUE_ID]`; when absent'
guard_prose submit-pr submit-pr.md 'workflow-state exists --json [ISSUE_ID]`; when absent'
guard_prose review-pr-comments review-pr-comments.md 'workflow-state exists --json [ISSUE_ID]` reports false'

# init_files DIR — the sorted base names of DIR's workflows that run `init`.
# Returns grep's status when grep failed rather than matched nothing.
init_files() {
  local out rc
  out="$(grep -l -F 'workflow-state init' -- "$1"/*.md)" && rc=0 || rc=$?
  if [ "$rc" -gt 1 ]; then return "$rc"; fi
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's|.*/||' | sort; fi
  return 0
}

expected="$(printf '%s\n' "${GUARDED[@]}" | sort)"
actual="$(init_files "$W")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "init file set — grep exited $rc over ${W#$REPO_ROOT/}"
elif [ -z "$actual" ]; then
  fail "init file set — the grep found no workflow running init, so the extractor is broken"
elif [ "$actual" = "$expected" ]; then
  pass "every workflow running init has a guard rule"
else
  fail "init file set differs from the guarded set"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/          /' || true
fi

# Control: a workflow no rule reads, planted beside a copy of the real ones,
# must be the one name the check adds.
cp -R "$W" "$MD_TMP/workflows"
printf '```bash\n.agents/skills/orch/scripts/workflow-state init [ISSUE_ID]\n```\n' >"$MD_TMP/workflows/planted.md"
planted="$(init_files "$MD_TMP/workflows")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$planted" = "$(printf '%s\n' "${GUARDED[@]}" planted.md | sort)" ]; then
  pass "control: the init file set names a planted unguarded workflow"
else
  fail "control: the init file set missed planted.md (grep exit $rc)"
fi

md_report
