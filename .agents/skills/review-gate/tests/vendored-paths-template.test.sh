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
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

. "$TEST_DIR/../scripts/lib/diagnostics.sh"
[ -f "$TEMPLATE" ] || { rg_message error template-file "$TEMPLATE" "Template is absent." >&2; exit 1; }

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

# The recipe's English anchors are a consumer search protocol. The checker
# returns stable result fields; each row still checks the exact anchor text.
check_anchors() { # FILE -> stable diagnostic, exit 0 valid / 1 broken / 2 unreadable
  local file="$1" missing="" dark="" seen="" armed="" n=0 num a records
  : >"$TMP/body"
  : >"$TMP/block"
  split_template "$file" || return 2
  records="$(anchors "$TMP/block")" || return 2
  while IFS=$'\t' read -r num a; do
    [ -n "$num" ] || continue
    case " $seen " in *" $num "*) ;; *) seen="$seen $num" ;; esac
    [ -n "$a" ] || continue
    n=$((n + 1))
    case " $armed " in *" $num "*) ;; *) armed="$armed $num" ;; esac
    if ! grep -qF -- "$a" "$TMP/body"; then missing="${missing:+$missing;}$a"; fi
  done <<<"$records"
  for num in $seen; do
    case " $armed " in *" $num "*) ;; *) dark="${dark:+$dark;}$num" ;; esac
  done
  if [ -z "$seen" ]; then
    rg_message error template-edits empty 'The extractor found no numbered edits.'
    return 2
  elif [ -n "$dark" ]; then
    rg_message error template-unarmed-edit "$dark" 'An edit yielded no searchable anchor.'
    return 1
  elif [ -n "$missing" ]; then
    rg_message error template-anchor-missing "$missing" 'No body line contains the anchor.'
    return 1
  fi
  rg_message notice template-anchors valid "$n anchors match the body."
}

# The named mutations alter real template input, not the checker. Every edit
# asserts its unique anchor and changed bytes before any row can pass.
while IFS='|' read -r shape expected_exit kind code value; do
  candidate="$TMP/$shape.md"
  python3 - "$TEMPLATE" "$candidate" "$shape" "$MARKER" <<'PY_EDIT'
from pathlib import Path
import sys
source, target, shape, marker = sys.argv[1:]
path = Path(source)
assert not path.is_symlink(), source
text = path.read_text()
body, separator, block = text.partition(marker)
assert separator and marker not in block

def replace_once(text, before, after):
    assert text.count(before) == 1, (shape, before, text.count(before))
    changed = text.replace(before, after)
    assert changed != text
    return changed

if shape == 'wrapped-anchor':
    block = replace_once(block,
        '7. In the last paragraph, replace "and cross-repo" with "and", and replace\n'
        '   "sync timing — an upstream fix not yet re-vendored" with "refresh timing —\n'
        '   an upstream fix not yet rendered". The phrase wraps in the body, so it is\n'
        '   two edits on two lines rather than one search for the joined sentence.',
        '7. In the last paragraph, replace "cross-repo sync timing — an upstream fix not\n'
        '   yet re-vendored" with "refresh timing — an upstream fix not yet rendered".')
    body = replace_once(body, 'an upstream fix not yet re-vendored',
                        'an upstream fix not\nyet re-vendored')
elif shape == 'reworded-body':
    body = replace_once(body, '**Do not stay silent instead.**', '**Never stay silent instead.**')
elif shape == 'unarmed-edit':
    block = replace_once(block,
        '3. REPLACE the second routing bullet ("The fix lands in these vendored bytes":\n'
        '   REVIEW SUMMARY BODY) with:',
        '3. REPLACE the second routing bullet, the one beginning with "The fix lands\n'
        '   in these vendored bytes", with:')
else:
    assert shape == 'unchanged', shape
result = body + separator + block
assert (result == text) == (shape == 'unchanged')
Path(target).write_text(result)
PY_EDIT
  rc=0
  result="$(check_anchors "$candidate")" || rc=$?
  printf -v quoted '%q' "$value"
  if [ "$rc" = "$expected_exit" ] && [ "${result%%$'\n'*}" = "review-gate-$kind=$code value=$quoted" ]; then
    ok "$shape"
  else
    bad "$shape" "exit=$rc result=$result"
  fi
done <<'CASES'
unchanged|0|notice|template-anchors|valid
wrapped-anchor|1|error|template-anchor-missing|cross-repo sync timing — an upstream fix not yet re-vendored
reworded-body|1|error|template-anchor-missing|**Do not stay silent instead.**
unarmed-edit|1|error|template-unarmed-edit|3
CASES

echo "=== the recipe states the number of edits it carries ==="
# A spelled-out count in prose goes stale the next time an edit is included; this
# is the fixture that reds when it does. Both statements of it are covered: the
# fill comment at the head of the file, and the block's own instruction.
split_template "$TEMPLATE"
edits="$(grep -cE '^[0-9]+\. ' "$TMP/block")"
spelled="$(awk -v n="$edits" 'BEGIN {
  split("one two three four five six seven eight nine ten", w, " ")
  print (n >= 1 && n <= 10) ? w[n] : n
}')"
stated_rc=0
stated="$(grep -cF -- "$spelled edits" "$TEMPLATE")" || stated_rc=$?
[ "$stated_rc" -le 1 ] || exit 1
if [ "$stated" -eq 2 ]; then
  ok "both counts read \"$spelled edits\" for the $edits numbered edits"
else
  bad "both counts read \"$spelled edits\" for the $edits numbered edits" "matched $stated line(s), wanted 2"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
