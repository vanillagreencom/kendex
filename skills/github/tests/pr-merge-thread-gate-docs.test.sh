#!/usr/bin/env bash
# Docs regression tests for pr-merge's review-thread gate (vstack#825).
#
# pr-merge counts only threads that are unresolved AND not outdated, which is
# deliberately narrower than GitHub's required_conversation_resolution. That
# divergence, the fact that the gate binds only merges routed through the
# skill, and the recovery path for outdated threads that block a merge while
# being unreachable in the UI all live in prose only. These tests pin that
# prose to the real script behavior so neither side can drift silently.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/github/SKILL.md"
README_MD="$REPO_ROOT/skills/github/README.md"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"

PASS=0
FAIL=0

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n' "$name" "$needle"
  fi
}

assert_matches() {
  local got="$1" pattern="$2" name="$3"
  if grep -qE "$pattern" <<<"$got"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to match: %s\n' "$name" "$pattern"
  fi
}

echo "=== pr-merge thread-gate docs match the script (vstack#825) ==="

# 0. The behavior the docs describe is still what the script does. If this
#    filter changes, the prose below is wrong and must be revisited.
script_src=$(cat "$PR_MERGE")
assert_contains "$script_src" \
  'select(.is_resolved == false and .is_outdated == false)' \
  "pr-merge.sh still counts unresolved AND non-outdated threads only"
assert_matches "$script_src" 'unresolved_threads\|review_threads_fetch_failed' \
  "pr-merge.sh still fails closed on unreadable thread state"

skill_src=$(cat "$SKILL_MD")
readme_src=$(cat "$README_MD")

# 1. Actionable-only semantics, named against the platform setting it diverges
#    from, so an operator can tell the two guarantees apart.
assert_contains "$skill_src" 'required_conversation_resolution' \
  "SKILL.md names required_conversation_resolution"
assert_matches "$skill_src" 'narrower guarantee|Narrower than branch protection' \
  "SKILL.md states the gate is narrower than branch protection"
assert_matches "$skill_src" 'not outdated|non-outdated' \
  "SKILL.md states outdated threads are excluded from the gate"

# 2. Policy, not mechanism: the gate binds only merges routed through pr-merge.
assert_matches "$skill_src" 'Policy, not mechanism' \
  "SKILL.md frames the gate as policy rather than mechanism"
assert_matches "$skill_src" 'UI Merge button|Merge button' \
  "SKILL.md names the UI Merge button as a bypass"
assert_matches "$skill_src" 'raw .gh pr merge' \
  "SKILL.md names raw gh pr merge as a bypass"

# 3. The unreachable-thread escape path. Match on the searchable heading an
#    operator would land on, then on both commands the recovery needs.
assert_contains "$skill_src" '### PR blocked with no visible conversations' \
  "SKILL.md has a findable heading for the unreachable-thread case"
escape_block=$(sed -n '/^### PR blocked with no visible conversations$/,/^### /p' "$SKILL_MD")
assert_contains "$escape_block" 'resolveReviewThread' \
  "escape path names the GraphQL mutation the UI cannot reach"
assert_contains "$escape_block" 'pr-threads' \
  "escape path tells the operator to list threads with pr-threads"
assert_contains "$escape_block" 'resolve-thread' \
  "escape path tells the operator to resolve by id with resolve-thread"
assert_matches "$escape_block" 'force-push|rebase' \
  "escape path explains how a thread becomes unreachable"

# 4. The command table rows stay index entries pointing at that prose.
threads_row=$(grep '^| `pr-threads ' "$SKILL_MD" || true)
resolve_row=$(grep '^| `resolve-thread ' "$SKILL_MD" || true)
assert_contains "$threads_row" 'PR blocked with no visible conversations' \
  "pr-threads row points at the escape-path section"
assert_contains "$resolve_row" 'PR blocked with no visible conversations' \
  "resolve-thread row points at the escape-path section"

# 5. README carries the same three points for the non-agent surface.
assert_contains "$readme_src" 'required_conversation_resolution' \
  "README.md names required_conversation_resolution"
assert_matches "$readme_src" 'policy, not mechanism' \
  "README.md states the policy-not-mechanism bound"
assert_matches "$readme_src" 'unreachable in the UI' \
  "README.md states the unreachable-thread hazard"
assert_contains "$readme_src" 'resolve-thread' \
  "README.md points at resolve-thread for recovery"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
