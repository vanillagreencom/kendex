#!/usr/bin/env bash
# The awaiting verdict's status description. It is the one verdict a reader
# acts on wrongly — read as an approval block, it stalls a PR that only has to
# wait for evidence at the new head — so what it says is pinned here.
#
# Two layers, one judge each. review-predicate.sh decides WHICH sources could
# still open the gate at this head (its resolution is extracted below, never
# restated), and awaiting-detail.sh only fits that answer into the 140
# characters GitHub keeps of a status description.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
COMPOSER="$SCRIPT_DIR/../scripts/awaiting-detail.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        got: $2"; }

SHA='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'

# GitHub's own cap, restated here so a loosened constant in the composer is a
# failure rather than a silently wider status the API then truncates.
RG_STATUS_LIMIT=140
grep -qx "RG_STATUS_LIMIT=$RG_STATUS_LIMIT" "$COMPOSER" \
  && ok "the composer caps at $RG_STATUS_LIMIT characters" \
  || bad "the composer caps at $RG_STATUS_LIMIT characters" "constant drifted"

# The predicate must route its awaiting arm through the composer and hand it
# the resolved list: a copy of either judgment left elsewhere would pass every
# case below while production said something else.
grep -q 'SOURCES="\$(awaiting_sources)".*awaiting-detail\.sh' "$PRED" \
  && ok "the awaiting arm passes the predicate's resolved sources to the composer" \
  || bad "the awaiting arm passes the predicate's resolved sources to the composer" "the arm does not"
grep -q 'verdict=awaiting detail=\$awaiting_detail' "$PRED" \
  && ok "the arm prints a captured description, not a substitution inside echo" \
  || bad "the arm prints a captured description, not a substitution inside echo" "still interpolated"
# A composer that failed must take the verdict with it: `exit 2` inside a
# command substitution would leave only the subshell, so the guard has to sit
# outside one.
grep -q 'awaiting_detail.*|| awaiting_rc=\$?' "$PRED" \
  && grep -q 'awaiting-detail.sh failed' "$PRED" \
  && ok "a failed composer is captured and exits 2 before any verdict" \
  || bad "a failed composer is captured and exits 2 before any verdict" "no failure guard"
if grep -q 'TRUSTED_LOGINS\|TRUSTED_CONTEXTS\|COMMENT_REVIEWERS' "$COMPOSER"; then
  bad "the composer models no trust setting of its own" "it reads a trust setting"
else
  ok "the composer models no trust setting of its own"
fi

# One representation, shared. The evidence reads and the label must be given
# the SAME packed lists, or a value can be an open trust model to one and a
# named list to the other.
if grep -q -- '--arg trusted "\$TRUSTED_LOGINS"' "$PRED"; then
  bad "the evidence read is given the normalized trust list" "it is given the raw value"
else
  ok "the evidence read is given the normalized trust list"
fi
[ "$(grep -c 'rg_pack "\$TRUSTED_LOGINS" ' "$PRED")" = 1 ] \
  && ok "the trust list is parsed exactly once" \
  || bad "the trust list is parsed exactly once" "$(grep -c 'rg_pack "\$TRUSTED_LOGINS" ' "$PRED") parse sites"

# ---------------------------------------------------------------- layer 1 ---
# The predicate's own resolution, extracted from the script rather than
# restated, so a rule that changes there changes here.
eval "$(sed -n '/^rg_pack() {/,/^}/p' "$PRED")"
eval "$(sed -n '/^aw_eligible() {/,/^}/p' "$PRED")"
eval "$(sed -n '/^awaiting_sources() {/,/^}/p' "$PRED")"
if declare -F awaiting_sources >/dev/null; then
  ok "the predicate's source resolution is extractable"
else
  echo "FAIL: could not extract awaiting_sources from $PRED"
  exit 1
fi

MIN_STATE="any"
# The operator override is a source too; cases that are not about it disable
# it the way a repo does, with an empty context.
OUTAGE_CONTEXT=""
# Each case is written in the raw settings a repo commits, and packs them
# through the predicate's own rg_pack — the single parse every consumer of
# these lists shares.
sources_are() { # CASE, EXPECTED (comma-joined)
  local got
  TRUSTED_LOGINS_N="$(rg_pack "$TRUSTED_LOGINS" ';,')"
  TRUSTED_CONTEXTS_N="$(rg_pack "$TRUSTED_CONTEXTS" ';')"
  COMMENT_REVIEWERS_N="$(rg_pack "$COMMENT_REVIEWERS" ';')"
  got="$(awaiting_sources | tr '\n' ',' | sed 's/,$//')"
  [ "$got" = "$2" ] && ok "$1" || bad "$1" "$got"
}

# An empty review-object trust list accepts any non-author review, and a
# configured status context does not withdraw that. Reporting only the context
# would hide a way to unblock the gate.
PR_AUTHOR="carol" TRUSTED_LOGINS="" TRUSTED_CONTEXTS="Analysis" COMMENT_REVIEWERS=""
sources_are "an empty trust list keeps any non-author review beside a context" \
  "any non-author review,Analysis"

# The author's own review and comment are never evidence, so a trust list that
# names the author must not send anyone to ask them.
PR_AUTHOR="alice" TRUSTED_LOGINS="alice;bob" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
sources_are "a trusted login equal to the author is omitted" "bob"

PR_AUTHOR="alice" TRUSTED_LOGINS="bob" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS="alice:REVIEWED-CLEAN"
sources_are "a comment reviewer equal to the author is omitted" "bob"

# A status context is a check name, not a login, so it survives an author of
# the same name.
PR_AUTHOR="Analysis" TRUSTED_LOGINS="bob" TRUSTED_CONTEXTS="Analysis" COMMENT_REVIEWERS=""
sources_are "a status context is not author-filtered" "bob,Analysis"

PR_AUTHOR="carol" TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="Analysis" COMMENT_REVIEWERS="botty[bot]:Reviewed commit:"
sources_are "every source kind contributes, comment reviewers by login" \
  "alice,Analysis,botty[bot]"

PR_AUTHOR="carol" TRUSTED_LOGINS=" alice ; bob " TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
sources_are "packed entries are trimmed" "alice,bob"

PR_AUTHOR="carol" TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS="alice:REVIEWED-CLEAN"
sources_are "a login reachable two ways is listed once" "alice"

# Every configured source is the author: nothing is eligible, and the status
# must not claim otherwise.
PR_AUTHOR="alice" TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS="alice:REVIEWED-CLEAN"
sources_are "an author-only configuration with no override leaves nothing eligible" ""

# The operator override is evidence this predicate accepts, so it is a way to
# open the gate. Reporting nothing eligible while it is configured pointed an
# operator away from the recovery path they own.
OUTAGE_CONTEXT="kendex-reviewer-outage"
PR_AUTHOR="alice" TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS="alice:REVIEWED-CLEAN"
sources_are "an author-only configuration still names the configured override" \
  "kendex-reviewer-outage"

PR_AUTHOR="carol" TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="Analysis" COMMENT_REVIEWERS=""
sources_are "the override joins the ordinary sources" \
  "alice,Analysis,kendex-reviewer-outage"

# An override context equal to a trusted status context is one source.
PR_AUTHOR="carol" TRUSTED_LOGINS="" TRUSTED_CONTEXTS="kendex-reviewer-outage" COMMENT_REVIEWERS=""
sources_are "an override matching a trusted context is listed once" \
  "any non-author review,kendex-reviewer-outage"

OUTAGE_CONTEXT=""
PR_AUTHOR="carol" TRUSTED_LOGINS="alice" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
sources_are "an empty override context contributes nothing" "alice"

# A delimiter-only trust list is what the evidence jq calls an EMPTY trust
# list — it splits, trims and drops empties before deciding — so it is the
# open trust model here too. Testing the raw value said the opposite: no
# eligible source, on a gate that would accept any non-author review.
PR_AUTHOR="carol" TRUSTED_LOGINS=" ; , " TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
sources_are "a delimiter-only trust list is the open trust model" \
  "any non-author review"

PR_AUTHOR="carol" TRUSTED_LOGINS="   " TRUSTED_CONTEXTS="Analysis" COMMENT_REVIEWERS=""
sources_are "a whitespace-only trust list keeps the open model beside a context" \
  "any non-author review,Analysis"

# The comment-form evidence loop trims the PAIR and then takes everything
# before the first colon, so a login with inner whitespace is matched as
# 'alice ' — the label has to name that same string, not a tidier one.
PR_AUTHOR="carol" TRUSTED_LOGINS="" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=" alice :Reviewed commit: "
sources_are "a comment login is labelled as the evidence loop splits it" \
  "any non-author review,alice "

# The review-object minimum state is policy, not decoration: under 'approved'
# a COMMENTED review does not satisfy the open trust model, so the text must
# not send a reader to leave one.
MIN_STATE="approved"
PR_AUTHOR="carol" TRUSTED_LOGINS="" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
sources_are "min_state=approved words the open trust model as an approval" \
  "any non-author approval"
MIN_STATE="any"
PR_AUTHOR="carol" TRUSTED_LOGINS="" TRUSTED_CONTEXTS="" COMMENT_REVIEWERS=""
sources_are "min_state=any keeps the review wording" "any non-author review"

# The normalization decides the trust boundary, so a broken pipeline must be
# exit 2 with no verdict. Without pipefail the last stage returns 0 on empty
# output, and a RESTRICTED trust list would read as "any non-author" — the
# list would open the gate it was set to close.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_dir/tr"
chmod +x "$stub_dir/tr"
broken_rc=0
broken_out="$(PATH="$stub_dir:$PATH" REVIEW_GATE_SETTINGS_FILE=/dev/null \
  REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="alice" \
  GH_REPO=owner/repo PR_NUMBER=1 HEAD_SHA="$SHA" PR_AUTHOR=bob \
  bash "$PRED" --check-config 2>&1)" || broken_rc=$?
if [ "$broken_rc" = 2 ]; then
  ok "a broken normalization pipeline exits 2"
else
  bad "a broken normalization pipeline exits 2" "exit $broken_rc"
fi
case "$broken_out" in
  *"could not normalize REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS"*)
    ok "the failure names the list it could not normalize" ;;
  *) bad "the failure names the list it could not normalize" "$broken_out" ;;
esac
case "$broken_out" in
  *verdict=*) bad "a broken normalization emits no verdict" "$broken_out" ;;
  *) ok "a broken normalization emits no verdict" ;;
esac

# ---------------------------------------------------------------- layer 2 ---
# The composer, driven by a resolved list exactly as the predicate hands it in.
want() { # CASE, SOURCES, EXPECTED
  local got
  got="$(HEAD_SHA="$SHA" SOURCES="$2" "$COMPOSER")"
  [ "$got" = "$3" ] && ok "$1" || bad "$1" "$got"
  if [ "${#got}" -le "$RG_STATUS_LIMIT" ]; then
    ok "$1 — fits the $RG_STATUS_LIMIT-character status limit (${#got})"
  else
    bad "$1 — fits the $RG_STATUS_LIMIT-character status limit" "${#got} characters"
  fi
}

want "one human reads as that person's name" "alice" \
  "no review evidence at $SHA yet; expected from alice"

want "the open trust model is named" "any non-author review" \
  "no review evidence at $SHA yet; expected from any non-author review"

want "every source is listed while they fit" "$(printf 'alice\nAnalysis\nbotty[bot]')" \
  "no review evidence at $SHA yet; expected from alice, Analysis, botty[bot]"

want "no eligible source names the state, never a blank clause" "" \
  "no review evidence at $SHA yet; no configured source is eligible here"

# Past the limit: the sha shortens to its 12-character prefix before any name
# is dropped, and the names that still do not fit are counted.
want "a list past the limit shortens the sha and counts the remainder" \
  "$(printf 'coderabbitai[bot]\ncopilot-pull-request-reviewer[bot]\nqodo-code-review[bot]\nchatgpt-codex-connector[bot]\nbmethod\nCodeRabbit\ncopilot-pull-request-reviewer')" \
  "no review evidence at ${SHA:0:12} yet; expected from coderabbitai[bot], copilot-pull-request-reviewer[bot] and 5 more"

# Boundary: a list whose SHORT form lands on the limit keeps every name.
# Reserving room for a remainder clause before testing that form dropped the
# last name from a list that fitted.
short_prefix="no review evidence at ${SHA:0:12} yet; expected from "
pad() { printf 'n%.0s' $(seq 1 "$1"); }
two_names() { # TOTAL -> two names whose short form is exactly TOTAL characters
  local first second rest
  first="$(pad 20)"
  rest=$(($1 - ${#short_prefix} - ${#first} - 2))
  second="$(pad "$rest")"
  printf '%s\n%s' "$first" "$second"
}
for total in 130 139 140; do
  names="$(two_names "$total")"
  want "a short-form list of exactly $total characters keeps every name" \
    "$names" \
    "$short_prefix$(printf '%s' "$names" | tr '\n' ',' | sed 's/,/, /g')"
done

# One character past it, and the remainder is counted rather than cut.
names="$(two_names 141)"
want "a short-form list one character over counts the remainder" "$names" \
  "$short_prefix$(printf '%s' "$names" | head -1) and 1 more"

# One name wider than the whole budget: a count, never a name cut mid-word.
want "a source too wide to show becomes a count" "$(printf 'x%.0s' $(seq 1 200))" \
  "no review evidence at ${SHA:0:12} yet; expected from 1 configured source"

# A trusted status context is not a reviewer, and it is the value that
# realistically exhausts the budget — the count must not name a person.
want "a lone oversized status context is counted as a source" "$(printf 'C%.0s' $(seq 1 200))" \
  "no review evidence at ${SHA:0:12} yet; expected from 1 configured source"

want "the count is plural for more than one" \
  "$(printf 'x%.0s' $(seq 1 200); echo; printf 'y%.0s' $(seq 1 200))" \
  "no review evidence at ${SHA:0:12} yet; expected from 2 configured sources"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
