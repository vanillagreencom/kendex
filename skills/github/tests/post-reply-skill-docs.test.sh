#!/usr/bin/env bash
# Docs regression tests for the post-reply routing-table row in SKILL.md
# (vstack#545).
#
# post-reply.sh requires an explicit --pr <N> for numeric comment IDs
# (vstack#528; behavior covered by post-reply-numeric-requires-pr.test.sh),
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

echo "=== post-reply SKILL.md synopsis matches --pr contract (vstack#545) ==="

# 1. Exactly one post-reply row in the command routing table.
row=$(grep '^| `post-reply ' "$SKILL_MD" || true)
assert_eq "$(printf '%s\n' "$row" | grep -c .)" "1" "SKILL.md has exactly one post-reply routing row"

# 2. The row's synopsis exposes --pr and both ID forms.
assert_contains "$row" '--pr' "post-reply row synopsis mentions --pr"
assert_contains "$row" 'PRRT_' "post-reply row distinguishes PRRT_... thread IDs"
assert_contains "$row" 'numeric' "post-reply row distinguishes numeric comment IDs"

# 3. The row states that --pr is required for numeric comment IDs.
assert_contains "$row" 'REQUIRED for numeric' "post-reply row marks --pr REQUIRED for numeric IDs"

# 4. The blanket auto-detect note carries the post-reply exception. Match the
# exception sentence itself rather than a fixed line window after the blanket
# note, so reflowing either paragraph cannot silently break the assertion.
exception=$(grep -E 'Exception.*post-reply|post-reply.*never auto-detects' "$SKILL_MD" || true)
assert_contains "$exception" 'Exception' "auto-detect note frames post-reply as an explicit exception"
autodetect_block=$(sed -n '/auto-detect from the current branch/,/^$/p' "$SKILL_MD")
assert_contains "$autodetect_block" '--pr' "auto-detect exception mentions --pr"

# 5. The script's own --help still declares the same requirement, so the
#    SKILL.md wording above stays pinned to a real contract.
help_out=$("$POST_REPLY" --help)
assert_contains "$help_out" 'required for numeric comment ID' "post-reply --help declares --pr required for numeric IDs"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
