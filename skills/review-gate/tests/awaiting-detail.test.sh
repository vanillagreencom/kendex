#!/usr/bin/env bash
# The awaiting verdict's status description. It is the one verdict a reader
# acts on wrongly — read as an approval block, it stalls a PR that only has to
# wait for evidence at the new head — so what it says is pinned here.
#
# The text is DERIVED from the repo's resolved evidence settings, never
# asserted: a gate trusting only human logins must name those people, and a
# gate trusting bots must name the bots. These cases drive the composer the
# predicate itself calls, across both sha forms and the 140-character limit
# GitHub truncates a commit-status description at.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
COMPOSER="$SCRIPT_DIR/../scripts/awaiting-detail.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        got: $2"; }

SHA='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
TRUSTED_LOGINS="" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
# GitHub's own cap, restated here so a loosened constant in the composer is a
# failure rather than a silently wider status the API then truncates.
RG_STATUS_LIMIT=140
grep -qx "RG_STATUS_LIMIT=$RG_STATUS_LIMIT" "$COMPOSER" \
  && ok "the composer caps at $RG_STATUS_LIMIT characters" \
  || bad "the composer caps at $RG_STATUS_LIMIT characters" "constant drifted"

# The predicate must actually route its awaiting arm through this composer: a
# copy of the text left in the arm would pass every case below while
# production said something else.
grep -q 'verdict=awaiting detail=\$(.*awaiting-detail\.sh' "$PRED" \
  && ok "the predicate's awaiting arm calls the composer" \
  || bad "the predicate's awaiting arm calls the composer" "the arm does not call awaiting-detail.sh"

want() { # CASE, EXPECTED
  local got
  got="$(HEAD_SHA="$SHA" TRUSTED_LOGINS="$TRUSTED_LOGINS" \
    TRUSTED_CONTEXTS="$TRUSTED_CONTEXTS" COMMENT_REVIEWERS="$COMMENT_REVIEWERS" \
    "$COMPOSER")"
  [ "$got" = "$2" ] && ok "$1" || bad "$1" "$got"
  if [ "${#got}" -le "$RG_STATUS_LIMIT" ]; then
    ok "$1 — fits the $RG_STATUS_LIMIT-character status limit (${#got})"
  else
    bad "$1 — fits the $RG_STATUS_LIMIT-character status limit" "${#got} characters"
  fi
}

# A human-only gate: bot sources empty, one person trusted. The text names that
# person and never promises automation the configuration does not provide.
TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
want "human-only gate names the human" \
  "no review evidence at $SHA yet; expected from alice"

TRUSTED_LOGINS="alice;bob" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
want "every trusted login is named" \
  "no review evidence at $SHA yet; expected from alice, bob"

# Each source kind contributes, and a comment-form entry contributes its login
# half only — the binding pattern is not a name a reader can act on.
TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="Analysis" COMMENT_REVIEWERS="botty[bot]:Reviewed commit:"
want "status contexts and comment reviewers are named too" \
  "no review evidence at $SHA yet; expected from alice, Analysis, botty[bot]"

# A name reachable two ways is one source, not two.
TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS="alice:REVIEWED-CLEAN"
want "a login named by two settings is listed once" \
  "no review evidence at $SHA yet; expected from alice"

# Empty trust lists mean any non-author review is evidence. That is a source,
# so it is named rather than leaving the clause blank.
TRUSTED_LOGINS="" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
want "nothing configured names the open trust model" \
  "no review evidence at $SHA yet; expected from any non-author review"

# Whitespace around packed entries belongs to the settings file, not to a name.
TRUSTED_LOGINS=" alice ; bob " TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
want "packed entries are trimmed" \
  "no review evidence at $SHA yet; expected from alice, bob"

# Past the limit: the sha shortens to its 12-character prefix before any name
# is dropped, and the names that still do not fit are counted.
TRUSTED_LOGINS="coderabbitai[bot];copilot-pull-request-reviewer[bot];qodo-code-review[bot];chatgpt-codex-connector[bot];bmethod"
TRUSTED_CONTEXTS="CodeRabbit;copilot-pull-request-reviewer"
COMMENT_REVIEWERS="chatgpt-codex-connector[bot]:Reviewed commit:;bmethod:REVIEWED-CLEAN"
want "a list past the limit shortens the sha and counts the remainder" \
  "no review evidence at ${SHA:0:12} yet; expected from coderabbitai[bot], copilot-pull-request-reviewer[bot] and 5 more"

# One name wider than the whole budget: a count, never a name cut mid-word.
TRUSTED_LOGINS="$(printf 'x%.0s' $(seq 1 200))" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
want "a name too wide to show becomes a count" \
  "no review evidence at ${SHA:0:12} yet; expected from 1 configured reviewer"

TRUSTED_LOGINS="$(printf 'x%.0s' $(seq 1 200));$(printf 'y%.0s' $(seq 1 200))"
want "the count is plural for more than one" \
  "no review evidence at ${SHA:0:12} yet; expected from 2 configured reviewers"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
