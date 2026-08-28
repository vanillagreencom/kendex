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
# the rest byte-for-byte. A consumer checkout has no root copy and gets the
# template's own structural assertions only.
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
ADOPTED=""
_dir="$SKILL_ROOT"
while [[ "$_dir" != "/" ]]; do
  if [[ -e "$_dir/.git" || -d "$_dir/.github" ]]; then
    ADOPTED="$_dir/review-bots.md"
    break
  fi
  _dir="$(dirname "$_dir")"
done

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
else
  printf '  note  %s\n' "no root review-bots.md at ${ADOPTED:-<no enclosing repo root>} — asserting the template only"
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
    fail "the repo copy has drifted from templates/review-bots.md — re-copy it, or move the change into the template
$(sed 's/^/        /' "$TMP_ROOT/drift.diff" | head -20)"
  fi

  # MUST-FAIL CONTROLS. The comparison is only worth its verdict if it
  # rejects the drift it exists for and admits the edit it exists to allow.
  MUTATED="$TMP_ROOT/mutated.md"

  sed "s/^## Review economics$/## Review economics, reworded/" "$ADOPTED" >"$MUTATED"
  if diff -q <(strip_block "$TEMPLATE") <(strip_block "$MUTATED") >/dev/null; then
    fail "control: an edit OUTSIDE the block passed the comparison"
  else
    pass "control: an edit outside the block is reported as drift"
  fi

  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { print; print ""; print "- **A residual only this repo has.** Do not re-raise."; skip = 1; next }
    $0 == e { skip = 0 }
    !skip
  ' "$ADOPTED" >"$MUTATED"
  if diff -q <(strip_block "$TEMPLATE") <(strip_block "$MUTATED") >/dev/null; then
    pass "control: an edit inside the block is the repo's own and passes"
  else
    fail "control: an edit INSIDE the block was reported as drift"
  fi
fi

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
