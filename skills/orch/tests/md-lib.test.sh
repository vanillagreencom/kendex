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
_subsuite() {
  local opts="$1" script="$MD_TMP/sub-$2.sh" fixture="$3"
  shift 3
  {
    printf '%s\n' "set -$opts" "source \"$MD_LIB_DIR/md.sh\"" "FIX=\"$fixture\""
    printf '%s\n' "$@" 'md_report'
  } >"$script"
  bash "$script" 2>&1
}
subsuite() { _subsuite uo\ pipefail "$@"; }
# The real lint suites run `set -euo pipefail`, and an arm that only exists to
# survive `set -e` is invisible to a sub-suite without it. `subsuite_e` is the
# variant that can observe those: a command substitution that exits non-zero
# aborts the run there, so a case asserting the tally still prints is asserting
# that nothing aborted.
subsuite_e() { _subsuite euo\ pipefail "$@"; }

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

# The same fixture under `set -e`, which is the shell every real lint suite
# runs. A rule matching nothing must report itself and let the pass continue:
# an unguarded capture aborts _md_controls there, and an unguarded strike on an
# empty line number adds a second spurious failure. The tally is what proves
# neither happened.
out="$(subsuite_e missinge "$RULES" \
  'rule "absentee" "$FIX" "## Rules" "delta"' \
  'rule "alpha" "$FIX" "## Rules" "alpha" "beta"')" || true
check "one rule matching nothing does not abort the control pass" \
  grep -qE '^pass: [0-9]+   fail: [0-9]+$' <<<"$out"
check "the surviving rule still gets its control" \
  grep -q "control: 'alpha' goes red alone" <<<"$out"
check "the broken rule is reported once, not twice" \
  test "$(grep -c 'absentee' <<<"$out")" = 1

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
# rather than resolved by document position. And an absence check has two ways
# to run over nothing, each closed on its own: the heading is missing, or the
# heading is there with nothing under it.
DUP="$MD_TMP/duplicate-heading.md"
printf '## Rules\n\nfirst\n\n## Rules\n\nsecond\n' >"$DUP"
out="$(subsuite ambiguous "$DUP" 'rule "dup" "$FIX" "## Rules" "first"')" || true
check "an ambiguous heading selector is reported" \
  grep -q "the selector is ambiguous" <<<"$out"

out="$(subsuite absentnohead "$RULES" \
  'absent "nothing here" "$FIX" "## Nowhere" "forbidden" "forbidden"')" || true
check "an absence check over a missing heading fails closed" \
  grep -q "carries no heading" <<<"$out"

# The other half: the heading is there and nothing is under it. The automatic
# control cannot cover this arm — it inserts its sample UNDER the heading,
# which makes the body non-empty, so it reports teeth whether the arm is there
# or not.
EMPTYSEC="$MD_TMP/empty-section.md"
printf '## A\n\n## B\n\nreal line\n' >"$EMPTYSEC"
out="$(subsuite absentemptybody "$EMPTYSEC" \
  'absent "nothing under it" "$FIX" "## A" "forbidden" "forbidden"')" || true
check "an absence check over an empty section body fails closed" \
  grep -q "has an empty body" <<<"$out"

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
  grep -q "flags its sample in every file it read (2)" <<<"$out"

UNREADABLE="$MD_TMP/gone.md"
out="$(subsuite forbidunreadable "$SCAN_A" \
  "forbid \"no banned word\" 'banned' 'the banned word' \"\$FIX\" \"$UNREADABLE\"")" || true
check "a forbid over an unreadable target goes red" \
  grep -q "not a readable file" <<<"$out"

# A directory passes `-r`, and the scanner that skips it reports no offender,
# so a readability test alone reads an unscanned target as a clean one.
SCAN_DIR="$MD_TMP/scan-dir"
mkdir -p "$SCAN_DIR"
printf '# D\n\nthe banned word lives here\n' >"$SCAN_DIR/inside.md"
out="$(subsuite forbiddir "$SCAN_A" \
  "forbid \"no banned word\" 'banned' 'the banned word' \"\$FIX\" \"$SCAN_DIR\"")" || true
check "a forbid over a directory goes red rather than reading it clean" \
  grep -q "not a readable file" <<<"$out"

# `permits` is the third form that passes on an empty search result, and the
# only one with no control loop. Its PROBE is the positive half: a base whose
# last line opens an HTML comment that never closes swallows whatever the
# append adds, so without the probe a near-miss verdict is reported over a scan
# that read nothing. Run under `set -e`, which also exercises the cp guard.
OPENC="$MD_TMP/open-comment.md"
printf '# Base\n\nclean\n\n<!-- opened and never closed\n' >"$OPENC"
out="$(subsuite_e permitprobe "$OPENC" \
  "permits \"near-miss\" 'banned' 'the banned word' 'a safe word' \"\$FIX\"")" || true
check "a permits whose probe never reaches the scan goes red" \
  grep -q "the probe line was not flagged" <<<"$out"

out="$(subsuite_e permitdir "$SCAN_A" \
  "permits \"near-miss\" 'banned' 'the banned word' 'a safe word' \"$SCAN_DIR\"")" || true
check "a permits over a directory reports a verdict, not a cp error" \
  grep -q "not a readable file" <<<"$out"

# And a list of no files is an absence check over nothing, the same fail-open
# an empty section is.
out="$(subsuite forbidnone "$SCAN_A" \
  'EMPTY=(); forbid "over nothing" '"'"'banned'"'"' '"'"'the banned word'"'"' ${EMPTY+"${EMPTY[@]}"}')" || true
check "a forbid registering no file at all goes red" \
  grep -q "no scan target was registered" <<<"$out"

md_report
