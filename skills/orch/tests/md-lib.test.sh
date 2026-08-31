#!/usr/bin/env bash
# The suite for `lib/md.sh`, the one markdown reader the orch doc lints share.
#
# Each lint proves its own rules through `md_report`'s planted controls. What
# no lint can prove is the reader beneath them: that a commented-out rule reads
# as absent, that a section stops where the next heading of its level starts,
# and that a fence scanner sees command lines and nothing else. A false
# positive there reddens a suite for an intact contract; a false negative lets
# a deleted rule pass in three lints at once. So the reader is exercised
# against a fixture whose every case is known.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

FIX="$MD_TMP/fixture.md"
cat >"$FIX" <<'MD'
# Title

## One

live token in section one
<!-- commented token in section one -->
<!--
multi token spanning lines
-->
trailing <!-- inline token --> tail

### One Point One

nested token

## Two

token in section two

```bash
# a comment inside a bash fence with a token
run --flag one
```

```json
{"token": "inside a json fence"}
```

prose with a `token` in inline code
MD

echo "=== md.sh reader ==="

s1="$(section "$FIX" "## One")"
check "a section carries its own live line" line_has "$s1" 'live token in section one'
check "a section stops at the next heading of its level" \
  test -z "$(line_has "$s1" 'token in section two' && echo hit)"
check "a section keeps its nested subsection" line_has "$s1" 'nested token'
check "a nested heading opens its own section" \
  line_has "$(section "$FIX" "### One Point One")" 'nested token'

check "a one-line HTML comment reads as absent" \
  test -z "$(line_has "$s1" 'commented token' && echo hit)"
check "a multi-line HTML comment reads as absent" \
  test -z "$(line_has "$s1" 'multi token' && echo hit)"
check "an inline HTML comment blanks only its own span" \
  test -z "$(line_has "$s1" 'inline token' && echo hit)"
check "text outside an inline comment survives it" line_has "$s1" 'trailing' 'tail'

f="$(fenced "$FIX" | cut -f3-)"
check "a bash fence yields its command lines" line_has "$f" 'run --flag one'
check "a comment line inside a fence is not a command" \
  test -z "$(line_has "$f" 'a comment inside a bash fence' && echo hit)"
check "a json fence is not a command block" \
  test -z "$(line_has "$f" 'inside a json fence' && echo hit)"
check "inline code outside a fence is not a command" \
  test -z "$(line_has "$f" 'prose with a' && echo hit)"

check "line_has requires every token on ONE line" \
  test -z "$(line_has "$s1" 'live token in section one' 'nested token' && echo hit)"

# --- the planted-control machinery itself ---------------------------------
# `md_report` is what every lint trusts to prove its rules can go red. Run it
# as a sub-suite against a fixture whose verdicts are known: a rule whose token
# the fixture states once must pass with its control; a rule whose token a
# SECOND line of the section repeats must be reported as toothless, since
# striking the matched line leaves the other standing; and a rule holding
# another rule's first token must be reported as overlapping.
subsuite() {
  local script="$MD_TMP/sub-$1.sh"
  shift
  {
    printf '%s\n' 'set -uo pipefail' "source \"$MD_LIB_DIR/md.sh\"" \
      "FIX=\"$MD_TMP/rules.md\""
    printf '%s\n' "$@" 'md_report'
  } >"$script"
  bash "$script" 2>&1
}

cat >"$MD_TMP/rules.md" <<'MD'
## Rules

alpha carries beta once
gamma sits here
gamma sits here too
MD

out="$(subsuite good 'rule "alpha" "$FIX" "## Rules" "alpha" "beta"')"
check "a sound rule passes with its control" \
  grep -q "goes red alone when its token is dropped" <<<"$out"

out="$(subsuite toothless 'rule "gamma" "$FIX" "## Rules" "gamma"')" || true
check "a rule a second line of its section repeats is reported toothless" \
  grep -q "reddened nothing" <<<"$out"

out="$(subsuite overlap \
  'rule "alpha" "$FIX" "## Rules" "alpha" "beta"' \
  'rule "beta" "$FIX" "## Rules" "beta" "alpha"')" || true
check "two rules pinning one line through each other are reported overlapping" \
  grep -q "the rules overlap" <<<"$out"

out="$(subsuite missing 'rule "absentee" "$FIX" "## Rules" "delta"')" || true
check "a rule whose token is gone fails outright" grep -q "FAIL  absentee" <<<"$out"

md_report
