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

# One record per line, `EDIT<TAB>ANCHOR`. A numbered edit runs from its "N. "
# line to the next blank line, is unwrapped onto one line, and gives up every
# quoted string whose preceding word is not "with". Each edit also emits one
# record with an empty anchor, so an edit that yields nothing is still counted:
# the anchor rule is a heuristic over English and several ordinary phrasings
# read a real anchor as replacement text ("beginning with", "starting with"),
# put it in quotes this pattern cannot match (typographic ones), or elide it to
# nothing (a leading ellipsis). Which of those it is does not matter downstream
# — an edit contributing no anchor is the failure, whatever emptied it.
anchors() { # BLOCK-FILE
  awk '
    /^[0-9]+\. / {
      if (collecting) print num "\t" buf
      num = $0; sub(/\..*/, "", num); buf = $0; collecting = 1; next
    }
    collecting && /^[[:space:]]*$/ { print num "\t" buf; collecting = 0; buf = ""; next }
    collecting { sub(/^[[:space:]]+/, ""); buf = buf " " $0 }
    END { if (collecting) print num "\t" buf }
  ' "$1" | awk -F'\t' '
    {
      num = $1
      line = $2
      print num "\t"
      while (match(line, /"[^"]*"/)) {
        before = substr(line, 1, RSTART - 1)
        quoted = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (before ~ /with[[:space:]]+$/) continue
        e = index(quoted, "…")
        if (e > 0) quoted = substr(quoted, 1, e - 1)
        sub(/[[:space:]]+$/, "", quoted)
        if (quoted != "") print num "\t" quoted
      }
    }
  '
}

# expect-dark:N asserts the per-edit floor itself: edit N is present in the
# block and contributes no anchor. Without it a phrasing that empties one edit
# subtracts silently from the global count and the suite still reports green.
check_anchors() { # FILE LABEL expect-pass|expect-fail|expect-dark:N
  local file="$1" label="$2" expect="$3" missing="" dark="" seen="" armed="" n=0 num a want=""
  case "$expect" in expect-dark:*) want="${expect#expect-dark:}" ;; esac
  split_template "$file"
  while IFS=$'\t' read -r num a; do
    case " $seen " in *" $num "*) ;; *) seen="$seen $num" ;; esac
    [ -n "$a" ] || continue
    n=$((n + 1))
    case " $armed " in *" $num "*) ;; *) armed="$armed $num" ;; esac
    grep -qF -- "$a" "$TMP/body" || missing="$missing
        $a"
  done < <(anchors "$TMP/block")
  for num in $seen; do
    case " $armed " in *" $num "*) ;; *) dark="$dark $num" ;; esac
  done
  if [ -z "$seen" ]; then
    bad "$label" "the extractor found no numbered edits at all — it is measuring nothing"
  elif [ -n "$want" ]; then
    case " $dark " in
      *" $want "*) ok "$label" ;;
      *) bad "$label" "edit $want still yielded an anchor; dark:${dark:- none}" ;;
    esac
  elif [ "$expect" = expect-pass ]; then
    [ -z "$dark" ] && [ -z "$missing" ] && ok "$label ($n anchors)" \
      || bad "$label" "no anchor from edit(s):${dark:- none}; no body line carries:${missing:- none}"
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

# And the phrasing that empties one edit rather than mismatching it: the
# anchor moved behind the word "with", where the extraction rule reads it as
# replacement text. The global count falls by one and every remaining anchor
# still matches, so only the per-edit floor sees this.
awk '
  /^3\. REPLACE the second routing bullet \("The fix lands in these vendored bytes":$/ {
    print "3. REPLACE the second routing bullet, the one beginning with \"The fix lands"
    print "   in these vendored bytes\", with:"
    dropping = 1
    next
  }
  dropping && /^   REVIEW SUMMARY BODY\) with:$/ { dropping = 0; next }
  { print }
' "$TEMPLATE" >"$TMP/beginning-with.md"
grep -qF -- 'the one beginning with "The fix lands' "$TMP/beginning-with.md" ||
  { echo "FATAL: the control did not rephrase edit 3" >&2; exit 1; }
check_anchors "$TMP/beginning-with.md" "control: an edit whose only quote follows the word with goes dark, and reds" expect-dark:3

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
