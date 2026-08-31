#!/usr/bin/env bash
# The suite for `lib/md.sh`, the one markdown reader the orch doc lints share.
#
# Each lint proves its own rules through `md_report`'s planted controls. What
# no lint can prove is the reader beneath them, or the control machinery
# itself. A false positive there reddens a suite for an intact contract; a
# false negative lets a deleted rule pass in every lint at once. So both are
# exercised here against fixtures whose every case is known: the reader
# directly, and `md_report` as a sub-suite whose verdicts are asserted.
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

## Three

```markdown
## Embedded Heading

heading-shaped line above, inside a fence
```

```bash
# Shell comment that looks like an H1
printf '<!--'
```

after the fences, still section three
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

# The orch workflows embed summary templates and shell comments whose lines
# start `## ` or `# ` at column zero. Read as headings they close the section
# around them, and everything past the template drops out of the lint's input.
s3="$(section "$FIX" "## Three")"
check "a heading-shaped line inside a fence does not close the section" \
  line_has "$s3" 'after the fences, still section three'
check "a shell comment inside a fence does not close the section" \
  line_has "$s3" 'printf'
check "a fenced heading-shaped line is not a section of its own" \
  test -z "$(section "$FIX" "## Embedded Heading")"
# A literal `<!--` inside a fence used to blank every line to the next `-->`
# or to EOF, taking later violations out of the scan with it.
check "an unmatched comment marker inside a fence is literal text" \
  line_has "$s3" 'after the fences, still section three'

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

# --- the planted-control machinery ----------------------------------------
# `md_report` is what every lint trusts to prove its rules can go red. Run it
# as a sub-suite against fixtures whose verdicts are known.
# Every capture below is `|| true`-guarded: the sub-suite's exit status is the
# case's subject, and an unguarded one aborts this file under `set -e` before
# md_report prints which checks failed.
subsuite() {
  local script="$MD_TMP/sub-$1.sh"
  local fixture="$2"
  shift 2
  {
    printf '%s\n' 'set -uo pipefail' "source \"$MD_LIB_DIR/md.sh\"" "FIX=\"$fixture\""
    printf '%s\n' "$@" 'md_report'
  } >"$script"
  bash "$script" 2>&1
}

RULES="$MD_TMP/rules.md"
cat >"$RULES" <<'MD'
## Rules

alpha carries beta once
gamma sits here
gamma sits here too

```bash
run --with-a-flag
```

the same run --with-a-flag named in prose

## Rules Extra

decoy section, not the one a selector naming Rules should reach
MD

# A rule whose token the fixture states once passes with its control; one a
# SECOND line of the section repeats is toothless, since striking the matched
# line leaves the other standing; and a rule holding another rule's first
# token overlaps with it.
out="$(subsuite good "$RULES" 'rule "alpha" "$FIX" "## Rules" "alpha" "beta"')" || true
check "a sound rule passes with its control" \
  grep -q "goes red alone when its token is dropped" <<<"$out"

out="$(subsuite toothless "$RULES" 'rule "gamma" "$FIX" "## Rules" "gamma"')" || true
check "a rule a second line of its section repeats is reported toothless" \
  grep -q "reddened nothing" <<<"$out"

out="$(subsuite overlap "$RULES" \
  'rule "alpha" "$FIX" "## Rules" "alpha" "beta"' \
  'rule "beta" "$FIX" "## Rules" "beta" "alpha"')" || true
check "two rules pinning one line through each other are reported overlapping" \
  grep -q "the rules overlap" <<<"$out"

out="$(subsuite missing "$RULES" 'rule "absentee" "$FIX" "## Rules" "delta"')" || true
check "a rule whose token is gone fails outright" grep -q "FAIL  absentee" <<<"$out"

# One physical file spelled two ways must still compare equal, or each rule is
# evaluated against the unmutated file during the other's control and the
# overlap goes unreported.
out="$(subsuite twospellings "$RULES" \
  'rule "alpha" "$FIX" "## Rules" "alpha" "beta"' \
  'rule "beta" "${FIX%/*}/./${FIX##*/}" "## Rules" "beta" "alpha"')" || true
check "one file under two spellings still reports the overlap" \
  grep -q "the rules overlap" <<<"$out"

# `rule` matches any body line; `rule_fenced` requires a command line inside a
# bash fence, so a prose mention of an invocation cannot stand in for running
# it.
out="$(subsuite fencedok "$RULES" \
  'rule_fenced "runs it" "$FIX" "## Rules" "run --with-a-flag"')" || true
check "rule_fenced matches a fenced command" grep -q "  ok    runs it" <<<"$out"

PROSE="$MD_TMP/prose-only.md"
sed '/^```bash$/,/^```$/d' "$RULES" >"$PROSE"
out="$(subsuite fencedprose "$PROSE" \
  'rule_fenced "runs it" "$FIX" "## Rules" "run --with-a-flag"')" || true
check "rule_fenced is not satisfied by a prose mention" \
  grep -q "no fenced command under" <<<"$out"

# A selector naming a heading that two lines answer to, or none, is reported
# rather than resolved by document position — and an absence check over a
# section that is not there passes for the wrong reason.
DUP="$MD_TMP/duplicate-heading.md"
printf '## Rules\n\nfirst\n\n## Rules\n\nsecond\n' >"$DUP"
out="$(subsuite ambiguous "$DUP" 'rule "dup" "$FIX" "## Rules" "first"')" || true
check "an ambiguous heading selector is reported" \
  grep -q "the selector is ambiguous" <<<"$out"

out="$(subsuite absentnohead "$RULES" \
  'absent "nothing here" "$FIX" "## Nowhere" "forbidden" "forbidden"')" || true
check "an absence check over a missing heading fails closed" \
  grep -q "carries no heading" <<<"$out"

# A decoy heading whose text merely CONTAINS the selector, sitting ahead of the
# real one, used to capture the read: the section inspected was the decoy's and
# it ended where the real heading began, so a violation in the real section was
# never scanned.
DECOY="$MD_TMP/decoy-heading.md"
printf '## Present And Fix Notes\n\ndecoy body\n\n## Present And Fix\n\nreal body\n' >"$DECOY"
check "a selector reaches the heading it names, not a longer one above it" \
  line_has "$(section "$DECOY" '## Present And Fix')" 'real body'
check "a selector does not read the decoy's body" \
  test -z "$(line_has "$(section "$DECOY" '## Present And Fix')" 'decoy body' && echo hit)"
check "the longer heading is still reachable by its own full text" \
  line_has "$(section "$DECOY" '## Present And Fix Notes')" 'decoy body'

# `order` earns its control by MOVING A's line below B's: swapping the two is
# true by construction and can never go red.
ORDER="$MD_TMP/order.md"
printf 'alpha here\nmiddle\nbeta here\n' >"$ORDER"
out="$(subsuite ordergood "$ORDER" 'order "sound" "$FIX" "alpha" "beta"')" || true
check "a sound order rule passes with its control" \
  grep -q "goes red when" <<<"$out"

TOOTHLESS="$MD_TMP/order-toothless.md"
printf 'alpha here\nalpha second\nbeta here\n' >"$TOOTHLESS"
out="$(subsuite orderbad "$TOOTHLESS" 'order "toothless" "$FIX" "alpha" "beta"')" || true
check "an order rule whose regex matches a second line ahead of B is reported" \
  grep -q "did not reverse the order" <<<"$out"

# A scan target nobody can read must be an offender, not an empty result, and
# the control must prove the sample flagged in EVERY registered file.
SCAN_A="$MD_TMP/scan-a.md"
SCAN_B="$MD_TMP/scan-b.md"
printf '# A\n\nclean\n' >"$SCAN_A"
printf '# B\n\nclean\n' >"$SCAN_B"
out="$(subsuite forbidall "$SCAN_A" \
  "forbid \"no banned word\" 'banned' 'the banned word' \"\$FIX\" \"$SCAN_B\"")" || true
check "a forbid control flags its sample in every registered file" \
  grep -q "flags its sample in all 2 file(s)" <<<"$out"

UNREADABLE="$MD_TMP/gone.md"
out="$(subsuite forbidunreadable "$SCAN_A" \
  "forbid \"no banned word\" 'banned' 'the banned word' \"\$FIX\" \"$UNREADABLE\"")" || true
check "a forbid over an unreadable target goes red" \
  grep -q "unreadable scan target" <<<"$out"

md_report
