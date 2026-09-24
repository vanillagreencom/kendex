#!/usr/bin/env bash
# `workflow-state init` overwrites. A workflow that runs it over a restored
# state file drops the item's round history: `cycles`, `fixed_items` and
# `patched_causes`. Every workflow that runs `init` therefore reads
# `workflow-state exists --json` first. Each rule pins that guard in the
# section holding the `init`, and its control strikes the guard. The file-set
# check fails when a workflow adds an `init` that no rule here reads.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch workflow-state init guard lint ==="

W="$SKILL_DIR/workflows"
GUARDED=()
guard_fenced() { GUARDED+=("$2"); rule_fenced "$1 reads exists in its init section" "$W/$2" "$3" "$4"; }
guard_prose() { GUARDED+=("$2"); rule "$1 reads exists in its init section" "$W/$2" "" "$3" 'workflow-state init'; }

guard_fenced start-worktree start-worktree.md "## 1. Open The Session" 'workflow-state exists --json [ISSUE_ID]'
guard_fenced micro micro.md "## 1. Open The Session" 'workflow-state exists --json [ISSUE_ID]'
guard_fenced dev-start dev-start.md "" 'workflow-state exists --json [ISSUE_ID]'
guard_fenced ci-fix ci-fix.md "## 1. Identify Failures" 'workflow-state exists --json [STATE_KEY]'
guard_fenced merge-pr merge-pr.md "## 3. Check Merge Readiness" 'workflow-state exists --json [STATE_KEY]'
guard_fenced oversee oversee.md "### Lane record" 'workflow-state exists --json oversee'
guard_prose post-summary post-summary.md 'workflow-state exists --json [ISSUE_ID]` reports false'
guard_prose review-pr review-pr.md 'workflow-state exists --json [ISSUE_ID]`; when absent'
guard_prose submit-pr submit-pr.md 'workflow-state exists --json [ISSUE_ID]`; when absent'
guard_prose review-pr-comments review-pr-comments.md 'workflow-state exists --json [ISSUE_ID]` reports false'

# The files that run `init` must be exactly the files a rule above reads.
actual="$(cd "$W" && grep -l -F 'workflow-state init' -- *.md | sort)"
expected="$(printf '%s\n' "${GUARDED[@]}" | sort)"
if [ -z "$actual" ]; then
  fail "init file set — the grep found no workflow running init, so the extractor is broken"
elif [ "$actual" = "$expected" ]; then
  pass "every workflow running init has a guard rule"
else
  fail "init file set differs from the guarded set"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/          /' || true
fi

md_report
