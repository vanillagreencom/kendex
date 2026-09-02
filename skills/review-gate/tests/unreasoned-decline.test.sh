#!/usr/bin/env bash
# Behavioral coverage for BOTH thread terms the predicate's thread jq decides,
# because one program decides them and the fixtures that separate them are the
# same fixtures. The jq is extracted from the script, not restated.
#
# unreasoned-decline counts a thread whose newest non-bot reply is a
# `Declined:` that names no mechanism — an empty reason, or nothing but
# non-reason tokens and filler.
#
# untracked-claim counts a thread whose newest non-bot reply THAT IS A
# DISPOSITION OR CARRIES A TRACK-WORD claims tracking and names no issue.
# Replies of any other kind never move it, so a thread ending in ordinary
# conversation still counts — `a reply that is neither claim nor disposition
# does not move it` is that case. A comments page the program cannot finish
# fails closed. The two terms divide the disposition space between them and a
# reply can fall in the seam, which is why `caught_by_either` below reads both
# counts rather than one.
#
# Neither verdict's mapping to a failure status is here: review-writer.test.sh
# runs both through the writer, w8/w8b for unreasoned-decline and w9/w9b for
# untracked-claim.
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

# A probe plants a mutant by rewriting the program's text, and "the text
# changed" is a contract that a WRONG change satisfies: an anchor that has
# drifted can delete the pass a probe claims to move, and every assertion
# under it then runs against a program nobody described. Each probe therefore
# declares the SHAPE its mutation should have and this checks it — a move
# preserves the line count, a substitution changes lines without changing the
# count, a deletion removes exactly as many lines as it names.
#
# Prints nothing on success. On failure it reds and the caller skips its
# assertions, because assertions under an unplanted mutant are not evidence.
planted() { # planted LABEL SHAPE VARIANT   SHAPE: move | sub | del:N
  local label="$1" shape="$2" variant="$3" want lines
  if [ "$variant" = "$prog" ]; then
    bad "probe planted nothing — $label" "the anchor matched no line"
    return 1
  fi
  lines=$(( $(wc -l <<<"$prog") - $(wc -l <<<"$variant") ))
  case "$shape" in
    move|sub) want=0 ;;
    del:*)    want="${shape#del:}" ;;
    *)        bad "probe declared no shape — $label" "$shape"; return 1 ;;
  esac
  if [ "$lines" != "$want" ]; then
    bad "probe planted the wrong shape — $label" \
        "declared $shape, but the program lost $lines line(s)"
    return 1
  fi
  return 0
}
thread() { # thread ISRESOLVED COMMENT_JSON… (comma-joined) [HASNEXTPAGE]
  printf '{"isResolved":%s,"comments":{"pageInfo":{"hasNextPage":%s},"nodes":[%s]}}' "$1" "${3:-false}" "$2"
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

echo "=== the untracked-claim term: a claim naming no issue, judged on the standing reply ==="
# Field 2 throughout. Each thread is judged by its newest non-bot comment that
# is a `Fixed in <sha>`/`Declined:` reply or carries a track-word: a claim with
# no issue id counts, such a reply never does, and later replies of any other
# kind, bot replies and resolving the thread do not move it.

out=$(page "$(thread true "$(human 'Out of scope for this PR, tracked.')")")
case "$out" in "0 1 "*) ok "issue-less tracking claim counts";; *) bad "issue-less tracking claim counts" "$out";; esac

out=$(page "$(thread true "$(human 'Tracked: KEN-12oops')"),$(thread true "$(human 'tracked in #34abc')")")
case "$out" in "0 2 "*) ok "a malformed id does not anchor a claim";; *) bad "a malformed id does not anchor a claim" "$out";; esac

out=$(page "$(thread true "$(human 'Tracked: KEN-536')"),$(thread true "$(human 'Tracked: DRV-12')"),$(thread true "$(human 'Fixed in abc123, tracked as #77')")")
case "$out" in "0 0 "*) ok "claims naming KEN-/other-prefix/#id pass";; *) bad "claims naming KEN-/other-prefix/#id pass" "$out";; esac

out=$(page "$(thread true "$(bot 'this should be tracked somewhere')")")
case "$out" in "0 0 "*) ok "bot comments are exempt";; *) bad "bot comments are exempt" "$out";; esac

out=$(page "$(thread true "$(human 'Declined: probe is intentional')")")
case "$out" in "0 0 "*) ok "a decline is not a claim";; *) bad "a decline is not a claim" "$out";; esac

out=$(page "$(thread true "$(human 'Out of scope, tracked.'),$(human 'Declined: probe is intentional')")")
case "$out" in "0 0 "*) ok "a later Declined: reply clears a naked claim";; *) bad "a later Declined: reply clears a naked claim" "$out";; esac

out=$(page "$(thread true "$(human 'Out of scope, tracked.'),$(human 'Fixed in abc1234')")")
case "$out" in "0 0 "*) ok "a later Fixed in <sha> reply clears a naked claim";; *) bad "a later Fixed in <sha> reply clears a naked claim" "$out";; esac

out=$(page "$(thread true "$(human 'Out of scope, tracked.'),$(human 'Tracked: KEN-637')")")
case "$out" in "0 0 "*) ok "a later Tracked: <id> reply clears a naked claim";; *) bad "a later Tracked: <id> reply clears a naked claim" "$out";; esac

out=$(page "$(thread true "$(human 'Fixed in abc1234, every tracked caller now runs')")")
case "$out" in "0 0 "*) ok "a Fixed in reply is never a claim, whatever its prose";; *) bad "a Fixed in reply is never a claim, whatever its prose" "$out";; esac

out=$(page "$(thread true "$(human 'Out of scope, tracked.'),$(bot 'Thanks, noted')")")
case "$out" in "0 1 "*) ok "a bot reply does not move the disposition";; *) bad "a bot reply does not move the disposition" "$out";; esac

out=$(page "$(thread true "$(human 'Fixed in abc1234'),$(human 'the rest is tracked for later')")")
case "$out" in "0 1 "*) ok "a resolved thread with a naked last reply still counts";; *) bad "a resolved thread with a naked last reply still counts" "$out";; esac

out=$(page "$(thread true "$(human 'Out of scope, tracked.'),$(human 'ok')"),$(thread true "$(human 'Out of scope, tracked.'),$(human 'Which issue?')")")
case "$out" in "0 2 "*) ok "a reply that is neither claim nor disposition does not move it";; *) bad "a reply that is neither claim nor disposition does not move it" "$out";; esac

out=$(page "$(thread true "$(human 'Fixed in a follow-up, tracked separately')")")
case "$out" in "0 1 "*) ok "Fixed in without a sha is not a disposition";; *) bad "Fixed in without a sha is not a disposition" "$out";; esac

out=$(page "$(thread true "$(human 'Declined: the caller is tracked by the loader already')")")
case "$out" in "0 0 "*) ok "a Declined: reply with a naked track-word is never a claim";; *) bad "a Declined: reply with a naked track-word is never a claim" "$out";; esac

out=$(page "$(thread true "$(human 'Tracked: KEN-1')" true)")
case "$out" in malformed) ok "a 50+-comment thread fails closed as malformed";; *) bad "a 50+-comment thread fails closed as malformed" "$out";; esac

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
if ! planted "the term, reverted" sub "$REVERTED"; then :
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
if ! planted "the shape reading, narrowed" sub "$NARROW"; then :
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
if ! planted "the freeze vocabulary, removed" sub "$UNFROZEN"; then :
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
if ! planted "the tracker-id strip, removed" del:1 "$UNSTRIPPED"; then :
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
NONAME="$(sed '/^    | gsub("..S+..s+\[0-9\]+..s\*\/..s\*\[0-9\]+"/d; /^    | gsub("\[a-z0-9\]\[*a-z0-9._-\]*\**(\//d' <<<"$prog")"
if ! planted "both name strips, removed" del:2 "$NONAME"; then :
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
  # `|| return 0`, not `|| return`: probe_alone is called as a bare command
  # under `set -e`, so a non-zero return would abort the suite before it
  # printed its own count. The failure is already recorded by `bad`.
  planted "$label" del:1 "$variant" || return 0
  out=$(page "$(thread true "$(human "$reply")")")
  counted "$out" && ok "live: counted — $label" || bad "live: counted — $label" "$out"
  out=$(page_with "$variant" "$(thread true "$(human "$reply")")")
  not_counted "$out" && ok "removed: clears the gate again — $label" || bad "removed: clears the gate again — $label" "$out"
}

probe_alone "the count strip" '/^    | gsub("..S+..s+\[0-9\]+..s\*\/..s\*\[0-9\]+"/d' \
  'Declined: frozen at a1fa74dca; pr-merge 103/103 and the full tools/guard pass at this head.'
probe_alone "the path strip" '/^    | gsub("\[a-z0-9\]\[*a-z0-9._-\]*\**(\//d' \
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
  index($0, "\"frozen|") { lbl = $0; next }
  index($0, "(/[a-z0-9]")           { print; print lbl; next }
  { print }' <<<"$prog")"
if ! planted "the label pass, moved" move "$MISORDERED"; then :
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
echo "--- must-fail probe: the filler pass moved back behind the strips ---"
# The other half of the same contract. BOTH word lists run ahead of the
# strips, for one reason: a word the term deletes must not shield the name
# behind it. The label half is proven above; this is the filler half, and it
# is a separate probe rather than a second line in that one so a stranding is
# attributable to the list it belongs to.
MISFILLER="$(awk '
  index($0, "\"a|an|the|") { fil = $0; next }
  index($0, "(/[a-z0-9]")                { print; print fil; next }
  { print }' <<<"$prog")"
if ! planted "the filler pass, moved" move "$MISFILLER"; then :
else
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    out=$(page "$(thread true "$(human "$line")")")
    counted "$out" && ok "live: counted — $line" || bad "live: counted — $line" "$out"
    out=$(page_with "$MISFILLER" "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "misordered: clears the gate again — $line" || bad "misordered: clears the gate again — $line" "$out"
  done < <(section 'a filler word, then a count' "$CORPUS/declines-unreasoned.txt")
  [ "$n" -gt 0 ] || bad "the filler-phrase section read nothing" "declines-unreasoned.txt"

  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    out=$(page_with "$MISFILLER" "$(thread true "$(human "$line")")")
    not_counted "$out" && ok "misordered: the mechanism still passes — $line" || bad "misordered: the mechanism still passes — $line" "$out"
  done < <(section 'a count BESIDE a mechanism' "$CORPUS/declines-reasoned.txt")
  [ "$n" -gt 0 ] || bad "the paired-mechanism section read nothing" "declines-reasoned.txt"
fi

echo
echo "--- the ordering section covers every entry the derivation names ---"
# The two probes above iterate a hand-written corpus section, so they prove
# the entries someone already wrote down. What they cannot see is a label
# entry ADDED to reason_left with no fixture beside it — the lists are the
# half of this term that changes most, and a new multi-word entry is exactly
# the shape the ordering fix exists to hold. So the set is derived HERE from
# the program, the same way the pass sweep derives its lines, and the section
# must cover it.
#
# The rule, and it is the file's rule rather than this script's: a multi-word
# entry strands when its FIRST word is in neither list — nothing else deletes
# the head — and at least one word after the first is missing from the OTHER
# list, the one still running ahead of the strips in that probe. When that
# pass deletes EVERY word after the head, the strip's reach walks leftward
# until it consumes the head itself and nothing is stranded, which is why
# `nothing to do` is excluded: both `to` and `do` are filler, so the strip
# lands on `nothing`. Reading the last word alone would miss a three-word
# entry with a mixed tail and demand no fixture for one that needs it.
#
# Nothing in that rule is about WHICH list an entry lives in. Both probes
# exist because both lists must run ahead of the strips, so the derivation
# runs over both alternations, each against its own ordering section. The
# filler list carries only single words today and derives nothing; that is a
# fact about its contents, not a property of it, and the day someone adds a
# phrase there this reds instead of the suite staying green.
alt_of() { # alt_of FIRST_ALTERNATIVE -> the alternation that opens with it
  # Located by the jq string quote the list opens with, then read to the
  # closing quote: the alternation IS the whole `word_strip` argument, and the
  # boundary that argument is wrapped in lives in `word_strip` itself, so
  # nothing here transcribes a term this suite is measuring. A nested group
  # like `instruction(s|ed)?` is read through, quotes being the only
  # delimiter the list cannot contain.
  awk -v k="$1" '{ p = index($0, "\"" k "|"); if (!p) next
                   out = ""
                   for (i = p + 1; i <= length($0); i++) { ch = substr($0, i, 1)
                     if (ch == "\"") { print out; exit }
                     out = out ch } }' <<<"$prog"
}
LABEL_ALT="$(alt_of frozen)"
FILLER_ALT="$(alt_of "a|an|the")"
if [ -z "$LABEL_ALT" ] || [ -z "$FILLER_ALT" ]; then
  bad "the derivation read no word list" "label ${#LABEL_ALT} chars, filler ${#FILLER_ALT} chars"
else
  # Top-level alternatives only: depth counts both bracket kinds, so the `|`
  # inside `instruction(s|ed)?` or `pushe[sd]?` does not split an entry.
  split_top() {
    awk '{ d = 0; s = ""; n = split($0, c, "");
           for (i = 1; i <= n; i++) { ch = c[i]
             if (ch == "(" || ch == "[") d++
             else if (ch == ")" || ch == "]") d--
             if (ch == "|" && d == 0) { print s; s = "" } else s = s ch }
           print s }' <<<"$1"
  }
  # An entry spells its own separator class, so the words are what is left
  # once the class, a single-character option and the group punctuation go.
  words_of() { sed 's/\[[ /._-]*\]?*/ /g; s/\([a-z]\)?/ /g; s/[()?]//g; s/  */ /g; s/^ //; s/ $//' <<<"$1"; }
  flatten()  { tr 'A-Z' 'a-z' <<<"$1" | sed 's/[^a-z0-9]\{1,\}/ /g; s/^ //; s/ $//'; }
  in_list()  { printf '%s\n' "$1" | grep -Eqx "($2)"; }

  DERIVED=0
  derive_over() { # derive_over SOURCE_ALT TAIL_ALT LIST_NAME SECTION_HEADING
    local src="$1" tail_alt="$2" name="$3" heading="$4" flat="" found=0 line entry w first rest tw listed
    while IFS= read -r line; do
      flat="$flat
$(flatten "$line")"
    done < <(section "$heading" "$CORPUS/declines-unreasoned.txt")
    while IFS= read -r entry; do
      case "$entry" in *' '*) ;; *) continue ;; esac
      w="$(words_of "$entry")"
      first="${w%% *}"; rest="${w#* }"
      in_list "$first" "$LABEL_ALT" && continue
      in_list "$first" "$FILLER_ALT" && continue
      # Every word after the head, not just the last: the pass ahead of the
      # strips has to delete the whole tail before the strip's reach can walk
      # back onto the head.
      listed=1
      for tw in $rest; do in_list "$tw" "$tail_alt" || { listed=0; break; }; done
      [ "$listed" = 1 ] && continue
      found=$((found + 1))
      if printf '%s' "$flat" | grep -qF " $w "; then
        ok "derived and covered — $name: $entry"
      else
        bad "a derived $name entry has no ordering fixture — $entry" \
            "the derivation strands \"$w\"; add a reply spelling it with spaces, then a count, under \"$heading\""
      fi
    done < <(split_top "$src")
    [ "$found" = 0 ] || [ -n "$flat" ] || bad "the $name ordering section read nothing" "$heading"
    DERIVED=$((DERIVED + found))
  }

  derive_over "$LABEL_ALT"  "$FILLER_ALT" label  'a label phrase, then a count'
  derive_over "$FILLER_ALT" "$LABEL_ALT"  filler 'a filler word, then a count'
  [ "$DERIVED" -gt 0 ] || bad "the derivation named no entry" "neither word list carries a stranding entry, which cannot be right"
fi

echo
echo "--- must-fail probe: the whitespace around the count's slash ---"
# `\s*` on either side of the slash is the only thing that reads "104 / 104"
# as a count. Tightened to a bare slash the name in front of it survives, so
# the fixture that spells the count with spaces flips: a character-level edit
# has to change a VERDICT here, not just stop matching the probe's own text.
SPACED="$(sed 's/..s\*\/..s\*/\//' <<<"$prog")"
if ! planted "the count slash, tightened" sub "$SPACED"; then :
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
echo "--- every pass of reason_left is measured by a fixture ---"
# The probes above each name ONE pass and prove it. This proves the set: every
# line of reason_left is replaced by an identity in turn, and the corpus must
# notice. A pass no reply exercises is a pass whose next reorder or rewrite
# ships unmeasured, and the failure names the line.
#
# DELETION, NOT REORDERING. A swap check would need an allowlist for every
# pair of passes that commutes, which is a rule enumerating its own instances:
# it goes stale on the next change to the pipeline, and re-deriving it costs
# the same hand-measurement it was meant to replace. Deletion needs no
# exceptions. Reordering is not left unheld — a reorder that moves the
# verdict of a reply the corpus holds reds this suite, and the two orderings
# that are load-bearing have named probes above.
#
# The whole corpus goes through in ONE jq call per variant, compared as a
# single aggregate over the corpus rather than reply by reply. What the
# aggregate proves is one-directional and that is all this needs: if it moves,
# some reply's verdict moved, and a reply whose verdict moves is exactly the
# fixture being looked for. Deletion is NOT monotone — a gsub also inserts the
# space it replaces with, so dropping one can join two runs into a single one
# a later strip then takes whole, and a reply can move either way. All that
# costs is a cancelling pair reporting "no fixture" for a line that has one,
# which reds the suite and is read by a person, never a gap passing silently.
lines_page() { # lines_page FILE -> one page holding every reply in the file
  local file="$1" line first=1 nodes=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "$first" = 1 ] && first=0 || nodes="$nodes,"
    nodes="$nodes$(thread true "$(human "$line")")"
  done < "$file"
  printf '%s' "$nodes"
}

CORPUS_NODES=""
for f in declines-unreasoned declines-reasoned declines-known-limit; do
  CORPUS_NODES="$CORPUS_NODES${CORPUS_NODES:+,}$(lines_page "$CORPUS/$f.txt")"
done

# The pass lines are reason_left's body: its first line, then every `| gsub`
# up to the trim. Each is replaced by an identity rather than cut, so the
# pipeline still parses and only the pass under test is gone.
#
# The scan ends at the first line ending in `;`, so a `;` written mid-body
# would shorten the sweep — silently, if the only guard were that it found
# something. What it captured is therefore checked against a second reading
# of the same definition: the `gsub` passes among the captured lines must be
# every `gsub` pass reason_left holds. Both sides are derived from the
# program, so neither an end anchor nor a written-down count can go stale
# and leave a short sweep looking complete.
# Bash 3.2: no mapfile. The line numbers are a space-separated list.
reason_left_body() { awk '/^  def reason_left:/ { f = 1; next } f && /;$/ { print NR; f = 0; next } f { print NR }' <<<"$prog"; }
at_lines() { local n; for n in $1; do sed -n "${n}p" <<<"$prog"; done; }
PASS_LINES="$(reason_left_body)"
held=$(awk '/^  def reason_left:/ { f = 1; next } /^  if / { f = 0 } f' <<<"$prog" | grep -c 'gsub(')
swept=$(at_lines "$PASS_LINES" | grep -c 'gsub(')
if [ -z "$PASS_LINES" ]; then
  bad "the pass sweep read no lines" "reason_left"
elif [ "$swept" != "$held" ]; then
  bad "the pass sweep stopped short of reason_left's end" \
      "it sweeps $swept gsub pass(es) of the $held reason_left holds — a semicolon inside the body ends the scan early"
fi

baseline=$(page_with "$prog" "$CORPUS_NODES")
for ln in $PASS_LINES; do
  text=$(sed -n "${ln}p" <<<"$prog")
  case "$text" in
    *'| '*) repl='    | .' ;;
    *)      repl='    .'   ;;
  esac
  case "$text" in *';') repl="$repl;" ;; esac
  variant=$(awk -v n="$ln" -v r="$repl" 'NR == n { print r; next } { print }' <<<"$prog")
  if [ "$variant" = "$prog" ]; then
    bad "pass sweep planted nothing" "$text"
    continue
  fi
  out=$(page_with "$variant" "$CORPUS_NODES" 2>/dev/null || echo "jq-error")
  label="a fixture notices — $(cut -c1-72 <<<"${text#    }")"
  if [ "$out" = "jq-error" ]; then
    bad "$label" "the variant did not parse"
  elif [ "$out" != "$baseline" ]; then
    ok "$label"
  else
    bad "$label" "deleting this pass moved no corpus verdict: it has no fixture"
  fi
done
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
