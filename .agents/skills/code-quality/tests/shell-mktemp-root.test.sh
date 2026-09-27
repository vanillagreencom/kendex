#!/usr/bin/env bash
# The shell mktemp-root rule is prose: no guard lane judges a suite that
# compares a resolved path against a raw `mktemp -d` root, because whether a
# later comparison reads a path derived from the root is a data-flow question
# a text scan cannot answer (skills/AGENTS.md states the choice). So this suite
# holds the prose to its spelling instead: ../SKILL.md § Language Discipline names
# the resolved-root line, and in the catalog tree the shell-suite rules beside
# it name the same line. The control removes the sentence from a copy of
# SKILL.md and requires the same judge to turn red once.
#
# Run: bash skills/code-quality/tests/shell-mktemp-root.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CATALOG_RULES="$SKILL_DIR/../AGENTS.md"

# The one spelling every document carries. Held as the literal command the
# rule prescribes so a rewording that drops `pwd -P` turns the row red.
RESOLVED_ROOT_LINE='TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}" >&2; }

# names_rule FILE: 0 when FILE carries the resolved-root line and the `pwd -P`
# words that make it the rule, 1 when it does not, 2 when FILE cannot be read.
names_rule() {
  local file="$1" text
  text="$(cat -- "$file")" || return 2
  case "$text" in
    *"$RESOLVED_ROOT_LINE"*) ;;
    *) return 1 ;;
  esac
  case "$text" in
    *"pwd -P"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- rows: each document that must name the rule -----------------------------
# The catalog's shell-suite rules sit beside the skill only in the source tree;
# an installed copy has no sibling AGENTS.md, and the row says so rather than
# passing on nothing.
ROWS="$SKILL_DIR/SKILL.md"
if [ -f "$CATALOG_RULES" ]; then
  ROWS="$ROWS
$CATALOG_RULES"
else
  printf '  note  catalog rules not judged: no AGENTS.md beside %s (installed copy)\n' "$SKILL_DIR"
fi

while IFS= read -r doc; do
  [ -n "$doc" ] || continue
  if names_rule "$doc"; then
    pass "names the resolved-root rule: $doc"
  else
    fail "does not name the resolved-root rule (status $?): $doc" "expected the line $RESOLVED_ROOT_LINE"
  fi
done <<ROWS_EOF
$ROWS
ROWS_EOF

# --- control: the judge turns red on a copy with the sentence removed --------
# The copy lives under a root resolved at creation, the very rule under test.
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)" || exit 2
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mutant="$TMP_ROOT/SKILL.md"
before="$(grep -c -F -- 'pwd -P' "$SKILL_DIR/SKILL.md")" || before=0
grep -v -F -- 'pwd -P' "$SKILL_DIR/SKILL.md" > "$mutant" || true
after="$(grep -c -F -- 'pwd -P' "$mutant")" || after=0
if [ "$before" -lt 1 ]; then
  fail "control could not plant its defect" "SKILL.md holds no 'pwd -P' line to remove"
elif [ "$after" -ne 0 ]; then
  fail "control mutant still carries the rule" "before=$before after=$after"
elif names_rule "$mutant"; then
  fail "control: the judge passed a copy with the rule removed" "$mutant"
else
  pass "control: the judge refuses a copy with the rule removed"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
