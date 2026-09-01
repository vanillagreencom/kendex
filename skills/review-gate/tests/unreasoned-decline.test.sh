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

# ONE spelling of the page envelope. Every probe below runs a variant of the
# program over the same shape, so the shape is written here and nowhere else.
page_with() { # page_with PROGRAM THREAD_JSON… -> "unresolved untracked unreasoned hasNext cursor"
  jq -r "$1" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$2]}}}}}"
}
page() { page_with "$prog" "$1"; }
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

# One `# --- heading ---` section of a corpus file, replies only. The probes
# below need a NAMED subset of the corpus and must not restate it as literals:
# a fixture written twice is a fixture that drifts in one place.
section() { # section HEADING FILE
  awk -v h="$1" 'index($0, h) { f = 1; next } /^# --- / { f = 0 } f && $0 !~ /^#/ && NF' "$2"
}

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
  rpage() { page_with "$rprog" "$1"; }

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
  npage() { page_with "$nprog" "$1"; }

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
  upage() { page_with "$uprog" "$1"; }

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
  spage() { page_with "$sprog" "$1"; }

  out=$(spage "$(thread true "$(human 'Declined: KEN-881')")")
  not_counted "$out" && ok "removed: the bare tracker id reads as a reason again" || bad "removed: the bare tracker id reads as a reason again" "$out"

  out=$(spage "$(thread true "$(human 'Declined: tracked in KEN-123')")")
  not_counted "$out" && ok "removed: so does the id behind a track-word" || bad "removed: so does the id behind a track-word" "$out"

  out=$(spage "$(thread true "$(human 'Declined: frozen')")")
  counted "$out" && ok "removed: a label still counts" || bad "removed: a label still counts" "$out"
fi

echo
echo "--- must-fail probe: both name strips, removed ---"
# Same jq with the count phrase and the path left standing, which is the
# state the term shipped in. Every #1851 reply must stop being counted here —
# "lifecycle", "merge", "tools guard" survive again — while every counted
# reply that names a mechanism stays uncounted in both states. A probe where
# both halves moved would prove the fixtures, not the strips.
NONAME="$(sed '/^    | gsub("..S+..s+\[0-9\]+..s\*\/..s\*\[0-9\]+"/d; /^    | gsub("\[a-z0-9\]+(\//d' <<<"$prog")"
if [ "$NONAME" = "$prog" ]; then
  bad "probe planted nothing" "the name strips did not match"
else
  cprog="$NONAME"
  cpage() { page_with "$cprog" "$1"; }

  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    out=$(page "$(thread true "$(human "$line")")")
    counted "$out" && ok "live: counted — $line" || bad "live: counted — $line" "$out"
    out=$(cpage "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "removed: clears the gate again — $line" || bad "removed: clears the gate again — $line" "$out"
  done < <(section 'a count and the name in front of it' "$CORPUS/declines-unreasoned.txt")
  [ "$n" -gt 0 ] || bad "the #1851 section read nothing" "declines-unreasoned.txt"

  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    out=$(page "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "live: a count beside a mechanism passes — $line" || bad "live: a count beside a mechanism passes — $line" "$out"
    out=$(cpage "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "removed: it passes in both states — $line" || bad "removed: it passes in both states — $line" "$out"
  done < <(section 'a count BESIDE a mechanism' "$CORPUS/declines-reasoned.txt")
  [ "$n" -gt 0 ] || bad "the paired-mechanism section read nothing" "declines-reasoned.txt"
fi

echo
echo "--- must-fail probe: each name strip alone ---"
# The two strips divide the #1851 replies between them, so each is proven on
# the reply only it reaches. "pr-merge 103/103" needs the count strip: nothing
# else takes a name the vocabulary has never heard of. "workflow 16/16" does
# not — the word list already carries `workflows?` — so that one is the path
# strip's, and it is what proves `tools/guard` goes whole.
probe_alone() { # probe_alone LABEL SED_EXPR REPLY
  local label="$1" expr="$2" reply="$3" variant out
  variant="$(sed "$expr" <<<"$prog")"
  if [ "$variant" = "$prog" ]; then
    bad "probe planted nothing" "$label"
    return
  fi
  out=$(page "$(thread true "$(human "$reply")")")
  counted "$out" && ok "live: counted — $label" || bad "live: counted — $label" "$out"
  out=$(page_with "$variant" "$(thread true "$(human "$reply")")")
  not_counted "$out" && ok "removed: clears the gate again — $label" || bad "removed: clears the gate again — $label" "$out"
}

probe_alone "the count strip" '/^    | gsub("..S+..s+\[0-9\]+..s\*\/..s\*\[0-9\]+"/d' \
  'Declined: frozen at a1fa74dca; pr-merge 103/103 and the full tools/guard pass at this head.'
probe_alone "the path strip" '/^    | gsub("\[a-z0-9\]+(\//d' \
  'Declined: frozen at a1fa74dca; workflow 16/16 and the full tools/guard pass at this head.'

echo
echo "--- must-fail probe: the strips moved back in front of the label pass ---"
# The order is the rule. A strip eats a whole token, so in front of the label
# pass it eats the TAIL of a multi-word entry and strands the head: "out of
# scope 3/3" leaves "out", and the reply clears a gate it used to red. That
# shipped once. Every line of the label-phrase section must flip here, and
# the counted mechanisms must stay uncounted, or the probe is proving the
# fixtures rather than the order.
# The label line is moved DOWN past both strips, which is the same
# misordering as moving the strips up and is one pass. Matched by literal
# text rather than a regex over a regex.
MISORDERED="$(awk '
  index($0, "gsub(\"\\\\b(frozen") { lbl = $0; next }
  index($0, "(/[a-z0-9]+)+")           { print; print lbl; next }
  { print }' <<<"$prog")"
if [ "$MISORDERED" = "$prog" ]; then
  bad "probe planted nothing" "the label pass and the strips did not match"
else
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    out=$(page "$(thread true "$(human "$line")")")
    counted "$out" && ok "live: counted — $line" || bad "live: counted — $line" "$out"
    out=$(page_with "$MISORDERED" "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "misordered: clears the gate again — $line" || bad "misordered: clears the gate again — $line" "$out"
  done < <(section 'a label phrase, then a count' "$CORPUS/declines-unreasoned.txt")
  [ "$n" -gt 0 ] || bad "the label-phrase section read nothing" "declines-unreasoned.txt"

  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    out=$(page_with "$MISORDERED" "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "misordered: the mechanism still passes — $line" || bad "misordered: the mechanism still passes — $line" "$out"
  done < <(section 'a count BESIDE a mechanism' "$CORPUS/declines-reasoned.txt")
  [ "$n" -gt 0 ] || bad "the paired-mechanism section read nothing" "declines-reasoned.txt"
fi

echo
echo "--- must-fail probe: the whitespace around the count's slash ---"
# `\s*` on either side of the slash is the only thing that reads "104 / 104"
# as a count. Tightened to a bare slash the name in front of it survives, so
# the fixture that spells the count with spaces flips: a character-level edit
# has to change a VERDICT here, not just stop matching the probe's own text.
SPACED="$(sed 's/..s\*\/..s\*/\//' <<<"$prog")"
if [ "$SPACED" = "$prog" ]; then
  bad "probe planted nothing" "the count slash did not match"
else
  t='Declined: frozen at a1fa74dca; lifecycle 104 / 104 and the full tools/guard pass at this head.'
  out=$(page "$(thread true "$(human "$t")")")
  counted "$out" && ok "live: a count spelled with spaces is a count" || bad "live: a count spelled with spaces is a count" "$out"
  out=$(page_with "$SPACED" "$(thread true "$(human "$t")")")
  not_counted "$out" && ok "tightened: the name survives — the spaces are this regex's" || bad "tightened: the name survives — the spaces are this regex's" "$out"
fi

# A path INSIDE a mechanism is untouched by the path strip: it takes the name
# and leaves the sentence, the same way the count strip takes one token.
check clean "a path inside a mechanism still passes" \
  'Declined: crates/core/src/lock.rs refuses that shape before the branch you name runs.'
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
