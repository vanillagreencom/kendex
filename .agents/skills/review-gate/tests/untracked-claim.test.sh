#!/usr/bin/env bash
# Behavioral coverage for the untracked-claim term: the predicate's thread
# jq (extracted from the script, not restated) judges each thread by its
# newest non-bot comment that is a Fixed in <sha>/Declined: reply or
# carries a track-word: a claim with no issue id counts, such a reply
# never does, later replies of any other kind, bot replies, and resolving
# the thread do not move it. A comments page it cannot finish fails closed.
# The verdict's mapping to a failure status is review-writer.test.sh w9.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        got: $2"; }

prog="$(sed -n "/^t_threads_page_jq='/,/^  end'/p" "$PRED" | sed "s/^t_threads_page_jq='//; s/^  end'\$/  end/")"
[ -n "$prog" ] || { echo "FAIL: could not extract t_threads_page_jq"; exit 1; }

page() { # page RESOLVED_JSON…  -> jq output
  jq -r "$prog" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$1]}}}}}"
}
thread() { # thread ISRESOLVED COMMENT_JSON… (comma-joined)
  printf '{"isResolved":%s,"comments":{"pageInfo":{"hasNextPage":%s},"nodes":[%s]}}' "$1" "${3:-false}" "$2"
}
human() { printf '{"body":%s,"author":{"__typename":"User"}}' "$(jq -Rn --arg b "$1" '$b')"; }
bot()   { printf '{"body":%s,"author":{"__typename":"Bot"}}'  "$(jq -Rn --arg b "$1" '$b')"; }

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

out=$(page "$(thread false "$(human 'looking')")")
case "$out" in "1 0 "*) ok "unresolved counting unchanged";; *) bad "unresolved counting unchanged" "$out";; esac

out=$(page "$(thread true "$(human 'Tracked: KEN-1')" true)")
case "$out" in malformed) ok "a 50+-comment thread fails closed as malformed";; *) bad "a 50+-comment thread fails closed as malformed" "$out";; esac

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
