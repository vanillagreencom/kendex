# shellcheck shell=bash
# Review rows vary by trust, state, author, time and attestation text.
ERRORED_MARK='encountered an error and was unable to review'
ERRORED_BODY='Copilot encountered an error and was unable to review this pull request. You can try again by re-requesting a review.'
review_row() { # NAME VERDICT TRUST MIN_STATE ERROR_PATTERNS REVIEW_JSON...
  local name="$1" want="$2" trust="$3" state="$4" errors="$5"
  shift 5
  jq -cn --arg name "$name" --arg want "$want" --arg trust "$trust" \
    --arg state "$state" --arg errors "$errors" --args \
    '{name:$name,want:$want,trust:$trust,state:$state,errors:$errors,reviews:($ARGS.positional | map(fromjson))}' "$@"
}
review_rows="$(
  set -e
  review_row "empty trust list: any non-author review counts" approved "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "rando" APPROVED)"
  review_row "trust list set: UNTRUSTED login's review is not evidence" awaiting "trusted-bot;other-bot" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "rando" APPROVED)"
  review_row "trust list set: trusted login's review counts" approved "trusted-bot;other-bot" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "trusted-bot" APPROVED)"
  review_row "trust list set: the PR author is never evidence, even when listed" awaiting "trusted-bot;$AUTHOR" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "$AUTHOR" APPROVED)"
  review_row "min_state=approved: COMMENTED-only review is not evidence" awaiting "" "approved" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" COMMENTED)"
  review_row "min_state=approved: APPROVED review counts" approved "" "approved" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" APPROVED)"
  review_row "min_state=any: COMMENTED review with a body counts (compatible default)" approved "" "any" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$HEAD" "Reviewed 3 of 3 changed files.")"
  review_row "an errored auto-review alone is NOT evidence (silence)" awaiting "" "any" "$ERRORED_MARK" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$ERRORED_BODY")"
  review_row "errored auto-review then a genuine re-review: the genuine row counts" approved "" "any" "$ERRORED_MARK" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$ERRORED_BODY")" \
            "$(review "auto-reviewer" COMMENTED "2026-08-02T19:00:00Z" "$HEAD" "Reviewed 4 of 4 changed files and generated 1 comment.")"
  review_row "errored auto-review + later genuine approval approves" approved "" "any" "$ERRORED_MARK" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$ERRORED_BODY")" \
            "$(review "reviewer" APPROVED "2026-08-02T19:00:00Z")"
  review_row "errored auto-review does not mask a genuine changes-requested" changes-requested "" "any" "$ERRORED_MARK" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$ERRORED_BODY")" \
            "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T19:00:00Z")"
  review_row "genuine approval alone still approves (errored filter is inert on it)" approved "" "any" "$ERRORED_MARK" \
    "$(review "reviewer" APPROVED)"
  review_row "a genuine body mentioning errors is NOT the attestation (no over-match)" approved "" "any" "$ERRORED_MARK" \
    "$(review "reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "The parser encountered an error path worth a second look; otherwise fine.")"
  review_row "a CONFIGURED error pattern withdraws a matching review body" awaiting "" "any" "analysis could not be completed" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "Automated review: analysis could not be completed for this revision.")"
  review_row "configured error patterns REPLACE the default list (not extend)" approved "" "any" "analysis could not be completed" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$ERRORED_BODY")"
  review_row "empty error-pattern list disables the filter (explicit opt-out)" approved "" "any" "" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$ERRORED_BODY")"
  review_row "a body BEGINNING with a pattern is NOT evidence" awaiting "" "any" "$ERRORED_MARK" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "encountered an error and was unable to review this pull request.")"
  review_row "a body QUOTING a pattern in later text IS evidence" approved "" "any" "$ERRORED_MARK" \
    "$(review "reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(printf 'Reviewed 2 of 2 changed files.\n\nThe doc edit quotes the marker "encountered an error and was unable to review" verbatim; the wording matches the shipped default.')")"
  review_row "leading blank line and quote marker are trimmed before matching" awaiting "" "any" "$ERRORED_MARK" \
    "$(review "auto-reviewer" COMMENTED "2026-08-02T18:00:00Z" "$HEAD" "$(printf '\n> Copilot encountered an error and was unable to review this pull request.')")"
  review_row "approval NOT superseded by a later COMMENTED (min_state=approved)" approved "" "approved" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" APPROVED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" COMMENTED "2026-08-02T18:28:50Z")"
  review_row "approval NOT superseded by a later COMMENTED (min_state=any)" approved "" "any" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" APPROVED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" COMMENTED "2026-08-02T18:28:50Z")"
  review_row "a PENDING draft after CHANGES_REQUESTED does not clear the objection" changes-requested "$ACTIVE_TRUSTED_LOGINS" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:00:00Z")" \
            "$(review "reviewer" PENDING "2026-08-02T18:30:00Z")"
  review_row "a lone PENDING draft is not review evidence" awaiting "$ACTIVE_TRUSTED_LOGINS" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" PENDING)"
  review_row "APPROVED then later CHANGES_REQUESTED fails closed" changes-requested "" "approved" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" APPROVED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:30:00Z")"
  review_row "cleared CR fed in reversed array order stays cleared" approved "" "approved" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" APPROVED "2026-08-02T19:00:00Z")" \
            "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:00:00Z")"
  review_row "CR on a previous commit still blocks a freshly-approved head" changes-requested "" "any" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "objector" CHANGES_REQUESTED "2026-08-02T18:00:00Z" "$OTHER")" \
            "$(review "reviewer" APPROVED "2026-08-02T19:00:00Z")"
  review_row "the objector re-approving at the new head clears their old-commit CR" approved "" "any" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "objector" CHANGES_REQUESTED "2026-08-02T18:00:00Z" "$OTHER")" \
            "$(review "objector" APPROVED "2026-08-02T19:00:00Z")"
  review_row "trailing COMMENTED does not withdraw a standing CR" changes-requested "$ACTIVE_TRUSTED_LOGINS" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:00:00Z")" \
            "$(review "reviewer" COMMENTED "2026-08-02T19:00:00Z")" \
            "$(review "other-reviewer" APPROVED "2026-08-02T19:30:00Z")"
  review_row "CHANGES_REQUESTED then later APPROVED re-opens" approved "" "approved" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" APPROVED "2026-08-02T18:30:00Z")"
  review_row "trusted approval + untrusted changes-requested fails closed" changes-requested "trusted-bot" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review "trusted-bot" APPROVED)" "$(review "rando" CHANGES_REQUESTED)"
  review_row "a DISMISSED review at head is not evidence" awaiting "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review reviewer DISMISSED)"
  review_row "a dismissed CHANGES_REQUESTED does not stand" approved "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" \
    "$(review objector DISMISSED '2026-08-02T18:00:00Z')" "$(review reviewer APPROVED '2026-08-02T19:00:00Z')"
)" || exit 1
while IFS= read -r row; do
  reset
  CFG_TRUSTED_LOGINS="$(jq -r .trust <<<"$row")" || exit 1
  CFG_MIN_STATE="$(jq -r .state <<<"$row")" || exit 1
  CFG_ERROR_PATTERNS="$(jq -r .errors <<<"$row")" || exit 1
  jq .reviews <<<"$row" >"$fixtures/reviews.json" || exit 1
  name="$(jq -r .name <<<"$row")" || exit 1
  want="$(jq -r .want <<<"$row")" || exit 1
  run "$name" "$want"
done <<<"$review_rows"

# A review counts only with content of its own. Answering a thread submits a
# bodyless COMMENTED review whose every comment is a reply; which threads a
# bodyless review opened is read from the review-comment listing, and only
# where that answer can change the verdict.
content_row() { # NAME VERDICT READS_COMMENTS MIN_STATE CARRY REVIEWS_JSON REVIEW_COMMENT_JSON...
  local name="$1" want="$2" reads="$3" min="$4" carry="$5" reviews_json="$6"
  shift 6
  jq -cn --arg name "$name" --arg want "$want" --arg reads "$reads" --arg min "$min" --arg carry "$carry" \
    --argjson reviews "$reviews_json" --args \
    '{name:$name,want:$want,reads:$reads,min:$min,carry:$carry,reviews:$reviews,comments:($ARGS.positional | map(fromjson))}' "$@"
}
reviews_of() { jq -cn --args '$ARGS.positional | map(fromjson)' "$@"; }
content_rows="$(
  set -e
  content_row "a reply-only COMMENTED review is not evidence" awaiting yes any "" \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$HEAD" "" 7)")" "$(review_comment 7 100)"
  content_row "a bodyless COMMENTED review that opened a thread counts" approved yes any "" \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$HEAD" "" 7)")" "$(review_comment 7)"
  content_row "a thread another review opened lends no content" awaiting yes any "" \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$HEAD" "" 7)")" "$(review_comment 8)"
  content_row "a whitespace-only body is no content" awaiting yes any "" \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$HEAD" "$(printf ' \n\t ')" 7)")"
  content_row "a bodyless APPROVED counts without the review-comment read" approved no any "" \
    "$(reviews_of "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$HEAD" "" 7)")"
  content_row "a COMMENTED review with a body counts without the review-comment read" approved no any "" \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$HEAD" "Reviewed 3 of 3 changed files." 7)")"
  content_row "an approval beside a reply at head decides without the review-comment read" approved no any "" \
    "$(reviews_of "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$HEAD" "" 7)" \
                  "$(review "reviewer" COMMENTED "2026-01-01T01:00:00Z" "$HEAD" "" 8)")" "$(review_comment 8 100)"
  content_row "min_state=approved: a bodyless COMMENTED row never takes the review-comment read" approved no approved "" \
    "$(reviews_of "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$HEAD" "" 7)" \
                  "$(review "other-reviewer" COMMENTED "2026-01-01T01:00:00Z" "$HEAD" "" 8)")" "$(review_comment 8)"
  content_row "carry off: a bodyless ancestor row takes no review-comment read" awaiting no any "" \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER" "" 7)")" "$(review_comment 7)"
  content_row "carry on: a bodyless ancestor row is judged from the review comments" awaiting yes any docs \
    "$(reviews_of "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER" "" 7)")" "$(review_comment 7 100)"
)" || exit 1
while IFS= read -r row; do
  reset
  CFG_TRUSTED_LOGINS=""
  CFG_MIN_STATE="$(jq -r .min <<<"$row")" || exit 1
  CFG_CARRY="$(jq -r .carry <<<"$row")" || exit 1
  jq .reviews <<<"$row" >"$fixtures/reviews.json" || exit 1
  jq .comments <<<"$row" >"$fixtures/review-comments.json" || exit 1
  name="$(jq -r .name <<<"$row")" || exit 1
  want="$(jq -r .want <<<"$row")" || exit 1
  reads="$(jq -r .reads <<<"$row")" || exit 1
  run "$name" "$want"
  read_seen=no
  if grep -qxF 'repos/owner/repo/pulls/1/comments?per_page=100' "$fixtures/.urls.log"; then read_seen=yes; fi
  cases=$((cases + 1))
  if [ "$read_seen" = "$reads" ]; then
    echo "ok    $name: review-comment read $reads"
  else
    rg_message error selftest-review-comment-read "$name" "FAIL  $name: review-comment read $read_seen, wanted $reads" >&2
    failures=$((failures + 1))
  fi
done <<<"$content_rows"
