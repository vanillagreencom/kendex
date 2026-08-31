#!/usr/bin/env bash
# Suite for templates/vendored-paths.instructions.md — the RENDER VARIANT
# block's recipe against the body it edits.
#
# The variant addresses the body by quoted prose, and a consumer applies it by
# searching for those quotes. Nothing else checks the quotes still occur, so an
# ordinary rewrap of a body paragraph silently strips the recipe of the edit
# meant to replace it, and the consumer's yield keeps text the flat rule
# forbids. That is not hypothetical: it shipped once, on the commit that
# introduced the block.
#
# The anchor rule, which is what makes this checkable: inside a numbered edit,
# a quoted string is an anchor unless the word before it is "with", in which
# case it is replacement text. Anchors wrap freely inside the block and are
# unwrapped before matching, but each must land on ONE line of the body,
# because a literal search is line-oriented and a phrase split across two body
# lines is found by neither half.
#
# The must-fail control is the shipped defect itself: edit 7's original
# unwrapped anchor, put back into a copy, must red.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$(cd "$TEST_DIR/.." && pwd)/templates/vendored-paths.instructions.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

[ -f "$TEMPLATE" ] || { echo "FATAL: no template at $TEMPLATE" >&2; exit 1; }

MARKER='RENDER VARIANT — DELETE THIS BLOCK'

# The body is everything above the block, the block everything from the marker
# down. Both halves come off the one marker, so a renamed block takes the whole
# suite red rather than leaving it to measure an empty half.
split_template() { # FILE — writes $TMP/body and $TMP/block
  awk -v marker="$MARKER" '
    index($0, marker) { inblock = 1 }
    { print > (inblock ? BLOCK : BODY) }
  ' BODY="$TMP/body" BLOCK="$TMP/block" "$1"
}

# One anchor per line. A numbered edit runs from its "N. " line to the next
# blank line, is unwrapped onto one line, and gives up every quoted string
# whose preceding word is not "with".
anchors() { # BLOCK-FILE
  awk '
    /^[0-9]+\. / { buf = $0; collecting = 1; next }
    collecting && /^[[:space:]]*$/ { print buf; collecting = 0; buf = ""; next }
    collecting { sub(/^[[:space:]]+/, ""); buf = buf " " $0 }
    END { if (collecting) print buf }
  ' "$1" | awk '
    {
      line = $0
      while (match(line, /"[^"]*"/)) {
        before = substr(line, 1, RSTART - 1)
        quoted = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (before ~ /with[[:space:]]+$/) continue
        e = index(quoted, "…")
        if (e > 0) quoted = substr(quoted, 1, e - 1)
        sub(/[[:space:]]+$/, "", quoted)
        if (quoted != "") print quoted
      }
    }
  '
}

check_anchors() { # FILE LABEL expect-pass|expect-fail
  local file="$1" label="$2" expect="$3" missing="" n=0 a
  split_template "$file"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    grep -qF -- "$a" "$TMP/body" || missing="$missing
        $a"
  done < <(anchors "$TMP/block")
  if [ "$n" -eq 0 ]; then
    bad "$label" "the extractor found no anchors at all — it is measuring nothing"
  elif [ "$expect" = expect-pass ]; then
    [ -z "$missing" ] && ok "$label ($n anchors)" || bad "$label" "no body line carries:$missing"
  else
    [ -n "$missing" ] && ok "$label" || bad "$label" "$n anchors all matched; the control proved nothing"
  fi
}

echo "=== every RENDER VARIANT anchor occurs on one line of the body it edits ==="
check_anchors "$TEMPLATE" "every REPLACE anchor is found in the body" expect-pass

# The shipped defect: edit 7 quoting the phrase as it reads unwrapped while the
# body wraps it across two lines, so neither half is findable.
awk '
  /^7\. In the last paragraph, replace "and cross-repo"/ {
    print "7. In the last paragraph, replace \"cross-repo sync timing — an upstream fix not"
    print "   yet re-vendored\" with \"refresh timing — an upstream fix not yet rendered\"."
    dropping = 1
    next
  }
  dropping && /^[[:space:]]*$/ { dropping = 0 }
  dropping { next }
  { print }
' "$TEMPLATE" >"$TMP/wrapped.md"
grep -qF -- 'replace "cross-repo sync timing' "$TMP/wrapped.md" ||
  { echo "FATAL: the control did not reproduce edit 7's original anchor" >&2; exit 1; }
check_anchors "$TMP/wrapped.md" "control: an anchor the body wraps across two lines reds" expect-fail

# And the general case the pin exists for: a body paragraph reworded out from
# under an anchor that still names the old wording.
sed 's/^\*\*Do not stay silent instead\.\*\*/**Never stay silent instead.**/' \
  "$TEMPLATE" >"$TMP/reworded.md"
check_anchors "$TMP/reworded.md" "control: a reworded body paragraph reds its anchor" expect-fail

echo "=== the recipe states the number of edits it carries ==="
# A spelled-out count in prose goes stale the next time an edit is added; this
# is the fixture that reds when it does. Both statements of it are covered: the
# fill comment at the head of the file, and the block's own instruction.
split_template "$TEMPLATE"
edits="$(grep -cE '^[0-9]+\. ' "$TMP/block")"
spelled="$(awk -v n="$edits" 'BEGIN {
  split("one two three four five six seven eight nine ten", w, " ")
  print (n >= 1 && n <= 10) ? w[n] : n
}')"
stated="$(grep -cF -- "$spelled edits" "$TEMPLATE")"
if [ "$stated" -eq 2 ]; then
  ok "both counts read \"$spelled edits\" for the $edits numbered edits"
else
  bad "both counts read \"$spelled edits\" for the $edits numbered edits" "matched $stated line(s), wanted 2"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
