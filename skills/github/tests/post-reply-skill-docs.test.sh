#!/usr/bin/env bash
# Docs regression tests for the post-reply routing-table row in SKILL.md
# (kendex#545).
#
# post-reply.sh requires an explicit --pr <N> for numeric comment IDs
# (kendex#528; behavior covered by post-reply-numeric-requires-pr.test.sh),
# but the top-level command table in SKILL.md drifted and still advertised
# `post-reply <id> [body | --body-file PATH]` with a blanket "auto-detect
# from the current branch" note. These tests pin the SKILL.md synopsis and
# the --help text to that contract so the docs can't drift again.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/github/SKILL.md"
POST_REPLY="$REPO_ROOT/skills/github/scripts/commands/post-reply.sh"

PASS=0
FAIL=0

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# The markdown checks pin the routing row's own tokens — the --pr flag and the
# PRRT_ id prefix — and the auto-detect block naming --pr. The --help assertion
# below holds the script to the same requirement, which is what proves it.

echo "=== post-reply SKILL.md synopsis matches --pr contract (kendex#545) ==="

# 1. Exactly one post-reply row in the command routing table.
row=$(grep '^| `post-reply ' "$SKILL_MD" || true)
assert_eq "$(printf '%s\n' "$row" | grep -c .)" "1" "SKILL.md has exactly one post-reply routing row"

# 2. The row's synopsis exposes --pr and both ID forms.
assert_contains "$row" '--pr' "post-reply row synopsis mentions --pr"
assert_contains "$row" 'PRRT_' "post-reply row distinguishes PRRT_... thread IDs"

# No check that the auto-detect note names --pr. The paragraph has no heading
# or fence to slice on, only its opening sentence, and a prose boundary makes
# the check prose-dependent however structural its needle is. The requirement
# itself is held by the routing row above and by --help below.

# 5. The script's own --help still declares the same requirement, so the
#    SKILL.md wording above stays pinned to a real contract.
help_out=$("$POST_REPLY" --help)
assert_contains "$help_out" 'required for numeric comment ID' "post-reply --help declares --pr required for numeric IDs"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
