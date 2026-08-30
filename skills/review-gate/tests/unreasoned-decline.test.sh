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
# The must-fail probes are at the bottom, each in the order the Done-when asks
# for: the verdict fires on a content-free decline first, then the same jq with
# one piece of the rule removed lets it through, so the catch belongs to that
# piece and not to the fixture.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/pr-watch.sh"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
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

# unreasoned is the THIRD field. The helpers split the line and read that
# field, rather than globbing for the digit anywhere in it: a glob is right
# only while every count is one digit, and it would keep passing if a field
# were added or reordered in the page shape. Read by position, that reddens
# here instead of being silently satisfied by another term's count.
unreasoned() { local _unresolved _untracked f _rest; read -r _unresolved _untracked f _rest <<<"$1"; printf '%s' "$f"; }
counted()     { [ "$(unreasoned "$1")" = 1 ]; }
not_counted() { [ "$(unreasoned "$1")" = 0 ]; }

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
# The reply this issue exists to catch, quoted from #1860, pinned verbatim.
# It shipped KEN-884..KEN-889, and it went uncaught through a first draft of
# this term because the token list carried `frozen` and not `freeze`.
check counted "THE MOTIVATING REPLY: a freeze plus a filing that never happened" \
  "Declined under this PR's freeze, flagged separately"
check counted "the same reply with nothing trailing it" \
  "Declined under this PR's freeze."
# #1847: the freeze restated as procedure. Who ordered the freeze and which
# push was the last says nothing about whether the finding reproduces.
check counted "a freeze attributed to the owner and nothing more" \
  "Declined: frozen at 39db56854, per the owner's instruction."
check counted "the same, spelled out at length" \
  'Declined: frozen at 39db56854 — the owner set the previous push as this PR'"'"'s last.'
# The seam between the two terms, which this reply used to slip through: the
# colon makes it a canonical disposition, so untracked-claim skips it, and
# `tracked` was a word this subtraction did not strip, so it read as a
# reason. Neither term counted it. The tracking words are non-reason tokens
# here for that reason; untracked-claim still owns the unpunctuated form.
check counted "a promise to track that names no issue and no mechanism" \
  'Declined: tracked separately'
check counted "the same promise in the other inflection" \
  'Declined: tracking separately'
check counted "a filing promised and not made" \
  'Declined: filed separately'

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
# From #1860, and the control that keeps the freeze vocabulary honest: the
# same wrapper as the motivating reply, and it concedes a mechanism, so
# widening the vocabulary must not reach it.
check clean "a freeze that does concede the mechanism" \
  "Declined under this PR's freeze. You are right about the mechanism, and it fails in the safe direction."
# The control for the tracking words: a reason that happens to use one is
# still a reason, because the subtraction leaves everything around it.
check clean "a mechanism that uses the word tracked" \
  'Declined: the caller is tracked by the loader before the branch you name can run.'

# The boundary, pinned deliberately. The subtraction is vocabulary, so it
# ends where the residue stops being words and becomes NAMES — the suite,
# lane or test the count belongs to. `lifecycle` and `tools/guard` below are
# identifiers, and no word list reaches an identifier. This case is not a bug
# in the term; it is the term's stated scope, and it is here so the next
# author sees the edge instead of rediscovering it. Widening past it needs a
# rule about what prose counts as a mechanism, which word subtraction cannot
# decide.
check clean "KNOWN LIMIT: a count whose residue is a suite name is not reached" \
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
[ "$(unreasoned "$out")" = 2 ] && ok "every offending thread is counted" || bad "every offending thread is counted" "$out"

out=$(page "$(thread true "$(human 'Declined: frozen'),$(human 'Declined: the caller guards it, so that branch cannot run')")")
not_counted "$out" && ok "a later real reason clears an earlier bare decline" || bad "a later real reason clears an earlier bare decline" "$out"

out=$(page "$(thread true "$(human 'Declined: the caller guards it, so that branch cannot run'),$(human 'Declined: frozen')")")
counted "$out" && ok "a later bare decline is counted over an earlier real one" || bad "a later bare decline is counted over an earlier real one" "$out"

out=$(page "$(thread true "$(human 'Out of scope, tracked.')")")
case "$out" in "0 1 0 "*) ok "an untracked claim is still counted, and is not a decline";; *) bad "an untracked claim is still counted, and is not a decline" "$out";; esac

out=$(page "$(thread false "$(human 'looking')")")
case "$out" in "1 0 0 "*) ok "unresolved counting unchanged";; *) bad "unresolved counting unchanged" "$out";; esac

echo "=== the verdict reaches its consumers ==="
# The writer's mapping is RUN, not grepped: review-writer.test.sh w8/w8b
# drive this verdict through the writer and assert the failure post and the
# remedy text. A presence grep stood here until KEN-890's second review
# round and passed on a branch nothing executed.
#
# pr-watch's arm is the one consumer still checked by presence. Its
# behavioural rows belong in pr-watch.test.sh beside every other verdict,
# but that file sits on a frozen size-ratchet row (class */tests/*, which
# never rises) and the guard's remedy is to split the suite first. The rows
# are written and their breaks proven; they land with that split.
grep -q 'unreasoned-decline)' "$WATCH" \
  && ok "STOPGAP: pr-watch carries the arm (behavioural rows blocked on a suite split)" \
  || bad "STOPGAP: pr-watch carries the arm (behavioural rows blocked on a suite split)" "not referenced"

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
echo "--- must-fail probe: the freeze vocabulary, removed ---"
# Same jq with `freeze` dropped back out of the token list, leaving only
# `frozen`. That is the state a first draft of this term shipped in, and the
# motivating reply cleared the gate in it. The reply must stop being counted
# here while the punctuated freeze fixture keeps counting, so the count is
# this inflection's rather than the term's.
UNFROZEN="$(sed 's/frozen|freezes?|freezing|/frozen|/' <<<"$prog")"
if [ "$UNFROZEN" = "$prog" ]; then
  bad "probe planted nothing" "the freeze vocabulary did not match"
else
  uprog="$UNFROZEN"
  upage() { jq -r "$uprog" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$1]}}}}}"; }

  out=$(upage "$(thread true "$(human "Declined under this PR's freeze, flagged separately")")")
  not_counted "$out" && ok "removed: the motivating reply clears the gate again" || bad "removed: the motivating reply clears the gate again" "$out"

  out=$(upage "$(thread true "$(human 'Declined: frozen at a1fa74dca; 104/104 pass')")")
  counted "$out" && ok "removed: the frozen form still counts" || bad "removed: the frozen form still counts" "$out"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
