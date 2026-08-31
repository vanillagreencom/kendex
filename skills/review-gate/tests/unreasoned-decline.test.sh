#!/usr/bin/env bash
# Behavioral coverage for the unreasoned-decline term: the predicate's thread
# jq (extracted from the script, not restated) counts a thread whose newest
# non-bot reply is a `Declined:` that names no mechanism — an empty reason, or
# nothing but non-reason tokens and filler.
#
# The fixtures are tests/corpus/, not literals in here, and adding a label
# starts there — see the sweep below. The declines that shipped KEN-884..
# KEN-889 head that file. Each label is paired with the real reason that must
# NOT be counted, because the test is subtraction: a label BESIDE a mechanism
# is untouched, and a check rejecting both would fail every honest decline.
#
# Both punctuations are exercised. The replies under audit were written
# without the colon, so a term that read only the punctuated form would pass
# every one of them; the probes at the bottom prove that reading is a choice
# this change made rather than something the fixtures happen to satisfy.
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

CORPUS="$SCRIPT_DIR/corpus"

# THE CORPUS IS THE CONTRACT. Every fixture below is a line in one of three
# files, not a literal in this script, because the subtraction is a word list
# and a word list maintained by review rounds is always one label behind.
# Three rounds of this issue each landed one missing label. Adding the next
# one starts by writing the reply in tests/corpus/declines-unreasoned.txt the
# way a person types it; this suite goes red until the list in
# review-predicate.sh covers it.
#
# Both directions run, and the must-pass half is what stops the must-catch
# half being satisfied by a rule that fails every decline.
sweep() { # sweep FILE counted|clean|limit
  local file="$1" want="$2" line n=0 caught
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    caught=$(caught_by_either "$line")
    case "$want" in
      counted)
        [ "$caught" = yes ] && ok "counted: $line" || bad "counted: $line" "$(page_of "$line")" ;;
      clean)
        [ "$caught" = no ] && ok "passes: $line" || bad "passes: $line" "$(page_of "$line")" ;;
      limit)
        # Pinned as NOT caught. If one ever is, that is a real change: move
        # the line and say what reached it. Never widen past this boundary.
        [ "$caught" = no ] && ok "known limit, still out of reach: $line" \
          || bad "known limit is now caught — move the line and explain what reached it" "$line" ;;
    esac
  done < "$file"
  [ "$n" -gt 0 ] || bad "corpus file read nothing" "$file"
  echo "  ($n replies from ${file##*/})"
}

page_of() { page "$(thread true "$(human "$1")")"; }

# A reply is caught when EITHER thread term counts it. Read both, because the
# two terms divide this space between them and a reply can fall in the seam:
# "Declined: tracked separately" was a canonical disposition to one and a
# stated reason to the other, so neither counted it.
caught_by_either() {
  local r _u untracked unreasoned _rest
  r=$(page_of "$1")
  read -r _u untracked unreasoned _rest <<<"$r"
  if [ "$untracked" != 0 ] || [ "$unreasoned" != 0 ]; then echo yes; else echo no; fi
}

echo "=== the corpus: declines that name no mechanism must be caught ==="
sweep "$CORPUS/declines-unreasoned.txt" counted

echo "=== the corpus: declines that name one must pass ==="
sweep "$CORPUS/declines-reasoned.txt" clean

echo "=== the corpus: the boundary, pinned ==="
sweep "$CORPUS/declines-known-limit.txt" limit

echo "=== the colon is not what makes it a decline ==="

check counted "a no-colon decline with nothing after the word" \
  'Declined.'
check counted "a no-colon decline that is only a label" \
  'Declined, out of scope.'
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
echo "--- must-fail probe: the tracker-id strip, removed ---"
# Same jq with the tracker-id strip dropped. Without it the punctuation pass
# splits KEN-881 and the number pass takes only the digits, so "ken" survives
# as a stated reason. The bare reference must stop being counted here while a
# label keeps counting, so the count is this strip's rather than the term's.
UNSTRIPPED="$(sed '/gsub("\[A-Z\]\[A-Z0-9\]+-\[0-9\]+|#\[0-9\]+"; " ")/d' <<<"$prog")"
if [ "$UNSTRIPPED" = "$prog" ]; then
  bad "probe planted nothing" "the tracker-id strip did not match"
else
  sprog="$UNSTRIPPED"
  spage() { jq -r "$sprog" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$1]}}}}}"; }

  out=$(spage "$(thread true "$(human 'Declined: KEN-881')")")
  not_counted "$out" && ok "removed: the bare tracker id reads as a reason again" || bad "removed: the bare tracker id reads as a reason again" "$out"

  out=$(spage "$(thread true "$(human 'Declined: tracked in KEN-123')")")
  not_counted "$out" && ok "removed: so does the id behind a track-word" || bad "removed: so does the id behind a track-word" "$out"

  out=$(spage "$(thread true "$(human 'Declined: frozen')")")
  counted "$out" && ok "removed: a label still counts" || bad "removed: a label still counts" "$out"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
