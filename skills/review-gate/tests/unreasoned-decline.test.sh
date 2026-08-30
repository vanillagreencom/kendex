#!/usr/bin/env bash
# Behavioral coverage for the unreasoned-decline term: the predicate's thread
# jq (extracted from the script, not restated) counts a thread whose newest
# non-bot reply is a `Declined:` that names no mechanism — an empty reason, or
# nothing but non-reason tokens and filler.
#
# The declines that shipped KEN-884..KEN-889 are the fixtures at the top. Each
# is paired with the real reason that must NOT be counted, because the test is
# subtraction: a label BESIDE a mechanism is untouched, and a check that
# rejected both would fail every honest decline on every PR.
#
# Both punctuations are exercised. The replies under audit were written
# without the colon, so a term that read only the punctuated form would pass
# every one of them; the section below pins the unpunctuated shape, and the
# second probe at the bottom is what proves that reading is this change's.
#
# The must-fail probe is at the bottom, in the order the Done-when asks for:
# the new verdict fires on a content-free decline first, then the same jq with
# the term reverted lets it through.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
WRITER="$SCRIPT_DIR/../scripts/review-writer.sh"
WATCH="$SCRIPT_DIR/../scripts/pr-watch.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        got: $2"; }

prog="$(sed -n "/^t_threads_page_jq='/,/^  end'/p" "$PRED" | sed "s/^t_threads_page_jq='//; s/^  end'\$/  end/")"
[ -n "$prog" ] || { echo "FAIL: could not extract t_threads_page_jq"; exit 1; }

page() { # page THREAD_JSON… -> "unresolved untracked unreasoned hasNext cursor"
  jq -r "$prog" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$1]}}}}}"
}
thread() { # thread ISRESOLVED COMMENT_JSON… (comma-joined)
  printf '{"isResolved":%s,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[%s]}}' "$1" "$2"
}
human() { printf '{"body":%s,"author":{"__typename":"User"}}' "$(jq -Rn --arg b "$1" '$b')"; }
bot()   { printf '{"body":%s,"author":{"__typename":"Bot"}}'  "$(jq -Rn --arg b "$1" '$b')"; }

# unreasoned is the THIRD field. The helpers assert on it by position so a
# field added or reordered in the page shape reddens here rather than being
# silently read as another term's count.
counted()     { case "$1" in *" "*" 1 "*) return 0 ;; esac; return 1; }
not_counted() { case "$1" in *" "*" 0 "*) return 0 ;; esac; return 1; }

check() { # check WANT LABEL BODY
  local want="$1" label="$2" out
  out=$(page "$(thread true "$(human "$3")")")
  if [ "$want" = counted ]; then
    counted "$out" && ok "$label" || bad "$label" "$out"
  else
    not_counted "$out" && ok "$label" || bad "$label" "$out"
  fi
}

echo "=== the replies that shipped the defects ==="

check counted "a bare Declined: with nothing after it" \
  'Declined:'
check counted "Declined: with only whitespace" \
  'Declined:    '
check counted "Declined: frozen at a1fa74dca; 104/104 pass" \
  'Declined: frozen at a1fa74dca; 104/104 pass'
check counted "a decline that is only a test count" \
  'Declined: tests pass.'
check counted "Declined: out of scope for this PR" \
  'Declined: out of scope for this PR'
check counted "Declined: pre-existing" \
  'Declined: pre-existing.'
check counted "Declined: at the cap" \
  'Declined: at the cap.'
check counted "Declined: round 4" \
  'Declined: round 4.'
check counted "a disposition substituted for a filing" \
  'Declined: flagged separately'
check counted "Declined: by design" \
  'Declined: by design'
check counted "Declined: works as intended" \
  'Declined: works as intended'
check counted "a decline that is only a sha" \
  'Declined: a1fa74dca'

echo "=== the real reasons that must pass ==="

check clean "a decline naming the passing state" \
  'Declined: the caller already guards the empty case, so the branch you name cannot run.'
check clean "a decline naming the false premise" \
  'Declined: the premise is wrong — resolve_base_branch returns the remote name, not the local ref.'
check clean "a label BESIDE a mechanism is untouched" \
  'Declined: pre-existing, and the loader validates the value before this path reads it.'
check clean "out of scope beside a mechanism" \
  'Declined: out of scope, and the guard you name refuses that shape one lane earlier.'
check clean "a test count beside a mechanism" \
  'Declined: the suite passes and the reproduction hits a branch the parser rejects before it.'
check clean "a short but real reason" \
  'Declined: that argument never reaches argv; the wrapper consumes it.'

# The boundary, pinned deliberately. The rule is "the reason is ONLY the
# token", so a token wrapped in prose that still names no mechanism is out of
# its reach. This case is not a bug in the term; it is the term's stated
# scope, and it is here so the next author sees the edge instead of
# rediscovering it. Widening past this needs a rule about what prose counts
# as a mechanism, which word subtraction cannot decide.
check clean "KNOWN LIMIT: a token wrapped in prose and a test count is not reached" \
  'Declined: frozen at a1fa74dca; lifecycle 104/104 and the tools/guard run at this head.'

echo "=== the colon is not what makes it a decline ==="

check counted "a no-colon decline with nothing after the word" \
  'Declined.'
check counted "a no-colon decline that is only a label" \
  'Declined, out of scope.'
check counted "a no-colon decline that is only a test count" \
  'Declined — tests pass'
check clean "a no-colon decline naming the passing state" \
  'Declined — the caller already guards the empty case, so that branch cannot run.'

echo "=== the term does not disturb the others ==="

check clean "a Fixed in reply is not a decline" \
  'Fixed in abc1234'
check clean "a Tracked reply is not a decline" \
  'Tracked: KEN-885'
# The untracked-claim term keeps the narrow `Declined:` form, and this is
# the reply that is why: it names no issue, and reading it as a disposition
# there would clear the claim instead of failing it. Field 2 is that term.
out=$(page "$(thread true "$(human 'Declined under the cap, tracked separately')")")
case "$out" in "0 1 "*) ok "a no-colon decline still trips the untracked-claim term";; *) bad "a no-colon decline still trips the untracked-claim term" "$out";; esac

out=$(page "$(thread true "$(bot 'Declined: frozen')")")
not_counted "$out" && ok "a bot decline never moves the disposition" || bad "a bot decline never moves the disposition" "$out"

out=$(page "$(thread true "$(human 'Declined: frozen')"),$(thread true "$(human 'Declined: pre-existing')")")
case "$out" in *" "*" 2 "*) ok "every offending thread is counted";; *) bad "every offending thread is counted" "$out";; esac

out=$(page "$(thread true "$(human 'Declined: frozen'),$(human 'Declined: the caller guards it, so that branch cannot run')")")
not_counted "$out" && ok "a later real reason clears an earlier bare decline" || bad "a later real reason clears an earlier bare decline" "$out"

out=$(page "$(thread true "$(human 'Declined: the caller guards it, so that branch cannot run'),$(human 'Declined: frozen')")")
counted "$out" && ok "a later bare decline is counted over an earlier real one" || bad "a later bare decline is counted over an earlier real one" "$out"

out=$(page "$(thread true "$(human 'Out of scope, tracked.')")")
case "$out" in "0 1 0 "*) ok "an untracked claim is still counted, and is not a decline";; *) bad "an untracked claim is still counted, and is not a decline" "$out";; esac

out=$(page "$(thread false "$(human 'looking')")")
case "$out" in "1 0 0 "*) ok "unresolved counting unchanged";; *) bad "unresolved counting unchanged" "$out";; esac

echo "=== the verdict reaches its consumers ==="

grep -q 'unreasoned-decline)    desired="failure"' "$WRITER" \
  && ok "writer maps unreasoned-decline to failure" \
  || bad "writer maps unreasoned-decline to failure" "mapping line missing"
grep -q 'unreasoned-decline' "$WATCH" \
  && ok "pr-watch accepts and surfaces the verdict" \
  || bad "pr-watch accepts and surfaces the verdict" "not referenced"
grep -q 'verdict=unreasoned-decline detail=' "$PRED" \
  && ok "the predicate emits the verdict with a detail line" \
  || bad "the predicate emits the verdict with a detail line" "no verdict line"

echo
echo "--- must-fail probe: the term, reverted ---"
# Same jq, with reason_left made to look non-empty for every reply, which is
# the term switched off. The content-free decline must stop being counted and
# the real reason must stay uncounted: a probe where both fixtures moved would
# prove the fixtures, not the term.
REVERTED="$(sed 's/^    | gsub("\^ +| +\$"; "");$/    | gsub("^ +| +$"; "") | "x";/' <<<"$prog")"
if [ "$REVERTED" = "$prog" ]; then
  bad "probe planted nothing" "the reason_left tail did not match"
else
  rprog="$REVERTED"
  rpage() { jq -r "$rprog" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$1]}}}}}"; }

  out=$(page "$(thread true "$(human 'Declined: frozen at a1fa74dca; 104/104 pass')")")
  counted "$out" && ok "live: the content-free decline is counted" || bad "live: the content-free decline is counted" "$out"

  out=$(rpage "$(thread true "$(human 'Declined: frozen at a1fa74dca; 104/104 pass')")")
  not_counted "$out" && ok "reverted: it is not — the count is this term's" || bad "reverted: it is not — the count is this term's" "$out"

  out=$(rpage "$(thread true "$(human 'Declined: the caller already guards the empty case, so the branch cannot run.')")")
  not_counted "$out" && ok "reverted: the real reason stays uncounted in both states" || bad "reverted: the real reason stays uncounted in both states" "$out"
fi

echo
echo "--- must-fail probe: the shape reading, narrowed to the colon ---"
# Same jq with both decline forms put back to `declined:`, which is the shape
# reading switched off. The unpunctuated fixture must stop being counted while
# the punctuated one keeps counting: a probe where both moved would prove the
# term, not the widening.
NARROW="$(sed 's/declined\\\\b/declined:/g' <<<"$prog")"
if [ "$NARROW" = "$prog" ]; then
  bad "probe planted nothing" "the wide decline form did not match"
else
  nprog="$NARROW"
  npage() { jq -r "$nprog" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$1]}}}}}"; }

  out=$(page "$(thread true "$(human 'Declined, out of scope.')")")
  counted "$out" && ok "live: the no-colon decline is counted" || bad "live: the no-colon decline is counted" "$out"

  out=$(npage "$(thread true "$(human 'Declined, out of scope.')")")
  not_counted "$out" && ok "narrowed: it is not — the count is this widening's" || bad "narrowed: it is not — the count is this widening's" "$out"

  out=$(npage "$(thread true "$(human 'Declined: out of scope.')")")
  counted "$out" && ok "narrowed: the punctuated form still counts" || bad "narrowed: the punctuated form still counts" "$out"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
