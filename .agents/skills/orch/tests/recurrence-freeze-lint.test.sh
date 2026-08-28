#!/usr/bin/env bash
# Regression lint: a root cause that recurs at a new site ends the patch
# sequence, and the check runs before the round cap.
#
# PR #1617 ran eight fix rounds on one request-ordering race. Each round met a
# new site of the same cause, each was treated as a fresh finding, and the diff
# reached ten times the reported symptom. The round cap could not stop it: it
# counts rounds, and one cause fits several recurrences inside the budget.
#
# The rule has one home, `references/finding-disposition.md` § Recurrence, and
# one router, `workflows/review-pr-comments.md` § 5. This lint pins the tokens
# both depend on, and the order that makes the router matter: the recurrence
# check must be readable ahead of the `iterations` cap, not after it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DISPOSITION="$SKILL_DIR/references/finding-disposition.md"
COMMENTS_WF="$SKILL_DIR/workflows/review-pr-comments.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch recurrence/freeze lint ==="

# Every assertion pins a token — a heading, a disposition literal, a reply
# form, a link anchor — so the rule can be reworded without breaking CI.
recurrence_section() { awk '/^## Recurrence$/{on=1;next} /^## /{on=0} on' "$1"; }

check_token() {
  # $1 = file, $2 = literal token, $3 = label
  if grep -qF "$2" "$1"; then
    pass "$3"
  else
    fail "$3"
  fi
}

check_section_token() {
  # $1 = file, $2 = literal token, $3 = label. Herestring, never a pipe:
  # `grep -q` exits at the first match and a pipe would hand awk a SIGPIPE
  # that `pipefail` promotes into a failure for a contract that is present.
  if grep -qF "$2" <<<"$(recurrence_section "$1")"; then
    pass "$3"
  else
    fail "$3"
  fi
}

check_token "$DISPOSITION" '## Recurrence' \
  "finding-disposition.md carries the Recurrence section"
check_section_token "$DISPOSITION" '`structural-close`' \
  "Recurrence names the structural-close disposition"
check_section_token "$DISPOSITION" '`freeze`' \
  "Recurrence names the freeze disposition"
check_section_token "$DISPOSITION" '`Tracked: <ID>`' \
  "Recurrence binds freeze to a Tracked reply"
check_section_token "$DISPOSITION" '`decline`' \
  "Recurrence declines a later finding on a frozen cause"

# The signals table must route recurrence to the section rather than answer it
# with another `fix` round, which is the shape that let #1617 keep patching.
recurrence_row() { grep -F 'sharing a root cause' "$1" | grep -F '|' || true; }

ROW="$(recurrence_row "$DISPOSITION")"
if [[ -n "$ROW" ]] && grep -qF '§ Recurrence' <<<"$ROW"; then
  pass "the signals table routes a recurring root cause to § Recurrence"
else
  fail "the signals table lost its route to § Recurrence"
fi

# The router, and the order that gives it force.
check_token "$COMMENTS_WF" '../references/finding-disposition.md#recurrence' \
  "review-pr-comments.md § 5 links the Recurrence section"

router_line() { grep -nF 'finding-disposition.md#recurrence' "$1" | head -1 | cut -d: -f1; }
cap_line() { grep -nF 'iterations >= 5' "$1" | head -1 | cut -d: -f1; }

check_order() {
  # $1 = file, $2 = label, $3 = expectation (`before` or `after`)
  local router cap
  router="$(router_line "$1")"
  cap="$(cap_line "$1")"
  if [[ -z "$router" || -z "$cap" ]]; then
    printf 'missing\n'
    return
  fi
  if [[ "$router" -lt "$cap" ]]; then printf 'before\n'; else printf 'after\n'; fi
}

case "$(check_order "$COMMENTS_WF")" in
  before) pass "the recurrence check is routed ahead of the iterations cap" ;;
  after)  fail "the recurrence check now sits behind the iterations cap" ;;
  *)      fail "review-pr-comments.md lost the recurrence router or the iterations cap" ;;
esac

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# A sed program that matches nothing leaves the fixture identical to its
# source, and the control then reports a lint miss for a guard that works.
# These run inside a command substitution, where an increment to FAIL would
# die with the subshell, so the note goes to a file the parent reads back.
UNPLANTED="$TMP_ROOT/unplanted"
: > "$UNPLANTED"
note_unplanted() { printf 'control %s planted nothing — its sed program matched no text\n' "$1" >> "$UNPLANTED"; }

plant() {
  # $1 = control name, $2 = source file, $3 = sed program
  local scratch="$TMP_ROOT/$1.md"
  sed "$3" "$2" > "$scratch"
  cmp -s "$scratch" "$2" && note_unplanted "$1"
  printf '%s' "$scratch"
}

CTRL="$(plant heading "$DISPOSITION" 's/^## Recurrence$/## Repeat findings/')"
if grep -qF '## Recurrence' "$CTRL"; then
  fail "lint MISSED a renamed Recurrence section"
else
  pass "lint flags a renamed Recurrence section"
fi

CTRL="$(plant freeze "$DISPOSITION" 's/`freeze`/another fix round/g')"
if grep -qF '`freeze`' <<<"$(recurrence_section "$CTRL")"; then
  fail "lint MISSED a dropped freeze disposition"
else
  pass "lint flags a dropped freeze disposition"
fi

CTRL="$(plant tracked "$DISPOSITION" 's/`Tracked: <ID>`/a note on the thread/')"
if grep -qF '`Tracked: <ID>`' <<<"$(recurrence_section "$CTRL")"; then
  fail "lint MISSED a dropped Tracked reply form"
else
  pass "lint flags a dropped Tracked reply form"
fi

CTRL="$(plant declined "$DISPOSITION" 's/`decline`d with its reason, never a second filing/filed as its own issue/')"
if grep -qF '`decline`' <<<"$(recurrence_section "$CTRL")"; then
  fail "lint MISSED a frozen cause that files again instead of declining"
else
  pass "lint flags a frozen cause that files again instead of declining"
fi

# Scoping control: the tokens must be pinned INSIDE § Recurrence. A `freeze`
# elsewhere in the file must not stand in for the rule.
CTRL="$(plant scope "$DISPOSITION" 's/^## Recurrence$/## Recurrence\n\nSee below.\n\n## Elsewhere\n\nUse `freeze` and `structural-close` when it suits./')"
if grep -qF '`freeze`' <<<"$(recurrence_section "$CTRL")"; then
  fail "lint false-passed on a freeze token outside § Recurrence"
else
  pass "lint scopes its disposition tokens to § Recurrence"
fi

CTRL="$(plant row "$DISPOSITION" 's/| § Recurrence, which allows `structural-close` or `freeze` and no further patch |/| `fix` as a structural close |/')"
ROW="$(recurrence_row "$CTRL")"
if [[ -n "$ROW" ]] && grep -qF '§ Recurrence' <<<"$ROW"; then
  fail "lint MISSED a signals row that answers recurrence with another fix"
else
  pass "lint flags a signals row that answers recurrence with another fix"
fi

CTRL="$(plant router "$COMMENTS_WF" 's#\.\./references/finding-disposition\.md\#recurrence#../references/finding-disposition.md#')"
if grep -qF '../references/finding-disposition.md#recurrence' "$CTRL"; then
  fail "lint MISSED a dropped Recurrence router link"
else
  pass "lint flags a dropped Recurrence router link"
fi

# Order control: the same router text, moved behind the cap, must fail.
CTRL="$(plant order "$COMMENTS_WF" '/^\*\*Recurrence before the cap\.\*\*/d')"
MOVED="$TMP_ROOT/order-moved.md"
awk '{print} /^`iterations >= 5` /{print ""; print "**Recurrence before the cap.** See [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence)."}' "$CTRL" > "$MOVED"
cmp -s "$MOVED" "$CTRL" && note_unplanted "order"
case "$(check_order "$MOVED")" in
  after) pass "lint flags a recurrence check moved behind the iterations cap" ;;
  *)     fail "lint MISSED a recurrence check moved behind the iterations cap" ;;
esac

while IFS= read -r unplanted_note; do
  [[ -n "$unplanted_note" ]] && fail "$unplanted_note"
done < "$UNPLANTED"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
