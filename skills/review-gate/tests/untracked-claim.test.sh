#!/usr/bin/env bash
# Behavioral coverage for the untracked-claim term: the predicate's thread
# jq (extracted from the script, not restated) flags a human tracking claim
# with no issue id, passes claims carrying any ABC-123 or #123 id, exempts
# bot comments, and fails closed on a comments page it cannot finish.
# The writer maps the verdict to a failure status.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
WRITER="$SCRIPT_DIR/../scripts/review-writer.sh"
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

out=$(page "$(thread true "$(human 'Tracked: KEN-536')"),$(thread true "$(human 'Tracked: DRV-12')"),$(thread true "$(human 'Fixed in abc123, tracked as #77')")")
case "$out" in "0 0 "*) ok "claims naming KEN-/other-prefix/#id pass";; *) bad "claims naming KEN-/other-prefix/#id pass" "$out";; esac

out=$(page "$(thread true "$(bot 'this should be tracked somewhere')")")
case "$out" in "0 0 "*) ok "bot comments are exempt";; *) bad "bot comments are exempt" "$out";; esac

out=$(page "$(thread true "$(human 'Declined: probe is intentional')")")
case "$out" in "0 0 "*) ok "a decline is not a claim";; *) bad "a decline is not a claim" "$out";; esac

out=$(page "$(thread false "$(human 'looking')")")
case "$out" in "1 0 "*) ok "unresolved counting unchanged";; *) bad "unresolved counting unchanged" "$out";; esac

out=$(page "$(thread true "$(human 'Tracked: KEN-1')" true)")
case "$out" in malformed) ok "a 50+-comment thread fails closed as malformed";; *) bad "a 50+-comment thread fails closed as malformed" "$out";; esac

grep -q 'untracked-claim)       desired="failure"' "$WRITER" \
  && ok "writer maps untracked-claim to failure" \
  || bad "writer maps untracked-claim to failure" "mapping line missing"
grep -q 'untracked-claim' "$SCRIPT_DIR/../scripts/pr-watch.sh" \
  && ok "pr-watch accepts and surfaces the verdict" \
  || bad "pr-watch accepts and surfaces the verdict" "not referenced"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
