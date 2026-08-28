#!/usr/bin/env bash
# The reviewer-guidance template against the copy the enclosing repo's bots
# actually read.
#
# templates/review-bots.md carries the ENGINE's accepted residual classes.
# They are claims about this engine, so the only repo that can keep them true
# is the one that owns the engine — a template asserted nowhere states last
# year's semantics to every consumer that copied it. The copy at the repo root
# is the file Copilot and Codex load, so asserting the template alone would
# prove the contents of a file no bot reads.
#
# The two files are one artifact outside ONE marked block, which is the
# consumer's own half: the strip drops that block from both sides and compares
# the rest byte-for-byte.
#
# WHICH REPO IS RUNNING THIS decides whether a missing root copy is a failure.
# The repo carrying this skill's catalog source ships the template, and its
# root copy is the only thing holding the template to current engine
# semantics — missing there is a FAIL, under either spelling of the skill root.
# A consumer gets the same drift comparison once adoption has placed its root
# copy, and the structural assertions alone before that.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

BEGIN_MARKER='<!-- BEGIN repo-specific accepted residuals -->'
END_MARKER='<!-- END repo-specific accepted residuals -->'

# Everything the markers enclose is repo-owned; both markers go with it, so a
# file that dropped them compares as the whole file and cannot pass silently.
strip_block() { # FILE
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { skip = 1 }
    !skip
    $0 == e { skip = 0 }
  ' "$1"
}

line_of() { grep -nFx -- "$2" "$1" | cut -d: -f1; }
count_of() { grep -cFx -- "$2" "$1" || true; }

# ------------------------------------------------------------- the copies ---

TEMPLATE="$SKILL_ROOT/templates/review-bots.md"

# Walk up to the enclosing repo: this skill sits at skills/review-gate/ in the
# catalog and at .agents/skills/review-gate/ in a consumer, so a fixed ../../
# resolves to two different places.
REPO_ROOT=""
_dir="$SKILL_ROOT"
while [[ "$_dir" != "/" ]]; do
  if [[ -e "$_dir/.git" || -d "$_dir/.github" ]]; then
    REPO_ROOT="$_dir"
    break
  fi
  _dir="$(dirname "$_dir")"
done

ADOPTED=""
[[ -n "$REPO_ROOT" ]] && ADOPTED="$REPO_ROOT/review-bots.md"

# The enclosing repo carries this skill's catalog source, so it is the repo
# that SHIPS the template — true whether this copy is the catalog tree or the
# render beside it, and false in any consumer.
OWNS_ENGINE=0
[[ -n "$REPO_ROOT" && -f "$REPO_ROOT/skills/review-gate/templates/review-bots.md" ]] && OWNS_ENGINE=1

echo "=== structure ==="

FILES=()
LABELS=()
if [[ -f "$TEMPLATE" ]]; then
  FILES+=("$TEMPLATE"); LABELS+=("template")
else
  fail "the shipped template is missing at $TEMPLATE"
fi
if [[ -n "$ADOPTED" && -f "$ADOPTED" ]]; then
  FILES+=("$ADOPTED"); LABELS+=("repo copy")
elif [[ "$OWNS_ENGINE" -eq 1 ]]; then
  fail "no review-bots.md at ${ADOPTED:-<no enclosing repo root>} — the repo shipping this template must carry the copy that holds it to the engine"
else
  printf '  note  %s\n' "no root review-bots.md at ${ADOPTED:-<no enclosing repo root>} — a checkout before adoption; asserting the template only"
fi

for i in "${!FILES[@]}"; do
  f="${FILES[$i]}"; tag="${LABELS[$i]}"
  nb="$(count_of "$f" "$BEGIN_MARKER")"
  ne="$(count_of "$f" "$END_MARKER")"
  if [[ "$nb" == "1" && "$ne" == "1" ]]; then
    pass "[$tag] exactly one repo-specific block"
  else
    fail "[$tag] expected one BEGIN and one END marker, found $nb and $ne"
  fi
  if [[ "$nb" == "1" && "$ne" == "1" ]]; then
    if [[ "$(line_of "$f" "$BEGIN_MARKER")" -lt "$(line_of "$f" "$END_MARKER")" ]]; then
      pass "[$tag] the block opens before it closes"
    else
      fail "[$tag] the END marker precedes the BEGIN marker"
    fi
  fi
done

echo "=== the repo copy is the template outside its own block ==="

if [[ -n "$ADOPTED" && -f "$ADOPTED" && -f "$TEMPLATE" ]]; then
  if diff -u <(strip_block "$TEMPLATE") <(strip_block "$ADOPTED") >"$TMP_ROOT/drift.diff"; then
    pass "the repo copy carries the shipped template verbatim"
  else
    fail "the repo copy has drifted from templates/review-bots.md — bring them back into step by hand, taking the template as the source for everything outside the marked block
$(sed 's/^/        /' "$TMP_ROOT/drift.diff" | head -20)"
  fi

  # MUST-FAIL CONTROLS on the comparison itself. Both read the repo copy as
  # their baseline, so a copy that has already drifted reports that once,
  # above, instead of twice more here under the wrong cause.
  MUTATED="$TMP_ROOT/mutated.md"

  sed "s/^## Review economics$/## Review economics, reworded/" "$ADOPTED" >"$MUTATED"
  if diff -q <(strip_block "$ADOPTED") <(strip_block "$MUTATED") >/dev/null; then
    fail "control: an edit OUTSIDE the block passed the comparison"
  else
    pass "control: an edit outside the block is reported as drift"
  fi

  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { print; print ""; print "- **A residual only this repo has.** Do not re-raise."; skip = 1; next }
    $0 == e { skip = 0 }
    !skip
  ' "$ADOPTED" >"$MUTATED"
  if diff -q <(strip_block "$ADOPTED") <(strip_block "$MUTATED") >/dev/null; then
    pass "control: an edit inside the block is the repo's own and passes"
  else
    fail "control: an edit INSIDE the block was reported as drift"
  fi
fi

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
