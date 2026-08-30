#!/usr/bin/env bash
# Docs regression tests for pr-merge's review-thread gate (kendex#825).
#
# pr-merge counts only threads that are unresolved and not outdated. Its help
# records that bound; SKILL.md keeps routing and recovery instructions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/github/SKILL.md"
README_MD="$REPO_ROOT/skills/github/README.md"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"
GITHUB_SH="$REPO_ROOT/skills/github/scripts/github.sh"

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

# Documentation assertions pin headings, commands, flags, and field names.
# Script assertions prove the filter itself.

echo "=== pr-merge thread-gate docs match the script (kendex#825) ==="

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
merge_help=$($GITHUB_SH pr-merge --help)

# 1. Actionable-only semantics, named against the platform setting it diverges
#    from, so an operator can tell the two guarantees apart.
assert_contains "$merge_help" 'required_conversation_resolution' \
  "pr-merge help names required_conversation_resolution"
assert_contains "$merge_help" 'Review-thread gate:' \
  "pr-merge help carries the review-thread gate"

# 2. Policy, not mechanism: the gate binds only merges routed through pr-merge.
assert_matches "$skill_src" 'Policy, not mechanism' \
  "SKILL.md frames the gate as policy rather than mechanism"
assert_contains "$merge_help" 'UI Merge button' \
  "pr-merge help names the UI Merge button"
assert_contains "$merge_help" 'gh pr merge' \
  "pr-merge help names gh pr merge"

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
assert_contains "$readme_src" 'resolve-thread' \
  "README.md points at resolve-thread for recovery"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
