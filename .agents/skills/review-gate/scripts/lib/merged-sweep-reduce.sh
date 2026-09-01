# shellcheck shell=bash
# The post-merge reduction, sourced by merged-sweep.sh. It lives in its own
# file because it is one jq program with one caller: the shell around it is
# argument handling, one read and one state write, and reading either half
# should not mean scrolling the other.
#
# Inputs bound by the caller: $cutoff (epoch seconds — the window floor),
# $limit and $limit_max (the page size actually asked for, and its ceiling).
# Output: one @tsv row per attention line —
#   <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <keys> <TAB> <detail>
# The kind is decided HERE, because the reduction is what knows which
# condition it found; the caller prints column 3 as given. A keys column of
# "-" means the row carries NO dedupe key: it is a standing condition, not
# an event, so the caller emits it on every pass while it holds.

# shellcheck disable=SC2034 # read by merged-sweep.sh, which sources this file
MERGED_SWEEP_REDUCE_JQ='
# The disposition forms are review-predicate.sh'"'"'s, read the way that script
# reads them: the STANDING reply is the LAST non-bot reply in a
# `Fixed in <sha>` / `Declined:` form or carrying a track-word, and an
# older reply never outranks a newer one. This asks only "did anyone answer
# this", so it does not re-run the predicate'"'"'s narrower untracked-claim and
# unreasoned-decline reductions.
def disposition: test("^\\s*(fixed in [0-9a-f]{7,40}\\b|declined:)"; "i");
def tracking: test("(?i)\\btrack(ed|ing|s)?\\b");
def names_an_issue: test("([A-Z][A-Z0-9]+-[0-9]+|#[0-9]+)\\b");
# A track-word alone is NOT an answer here: the predicate files that as an
# untracked-claim finding, this sweep has no second finding to file, and a
# bare "tracking that separately" would silence the last net over a late
# finding. The narrowing composes ON TOP of the standing-reply rule.
def answered: disposition or (tracking and names_an_issue);
def human: (.author.__typename // "User") != "Bot";
def epoch: if type == "string" then (try (sub("\\.[0-9]+";"") | fromdateiso8601) catch null) else null end;
def at: (.createdAt | epoch);
def is_reply: human and ((.body // "") | (disposition or tracking));

if (.errors? // [] | length) > 0 then error("graphql errors present")
# The repository probe is the positive proof that the named repo was READ.
# search answers an unreadable or misspelled repo with issueCount 0 and no
# error at all, so without this the sweep would exit 0 in silence over a
# repository it never reached.
elif (.data.repository | not) then error("the repository named by GH_REPO could not be read")
elif (.data.search.nodes | type) != "array" then error("malformed merged-PR container")
elif ((.data.search.issueCount | type) != "number")
     or ((.data.search.pageInfo.hasNextPage | type) != "boolean")
then error("merged-PR listing carries no coverage metadata")
else
  .data.search as $s
  # A page that did not reach the whole window says so and fails closed
  # instead of reporting silence over the remainder. The two counts are the
  # only datum offered: under sort:updated-desc the page holds the most
  # recently UPDATED merged PRs, scattered across the window rather than a
  # contiguous newest-merged block, so no timestamp here bounds the unread
  # remainder and quoting one would send the operator to a window that is
  # also truncated. The row carries NO key: a coverage shortfall is a
  # standing property of the read that no reply clears, so announce-once
  # would leave the gap silent from the second pass on, and a gap that
  # WORSENS silent with it.
  | (if ($s.issueCount > ($s.nodes | length)) or $s.pageInfo.hasNextPage
     then [ [ "-", "--------", "sweep:window-truncated", "-",
              "\($s.issueCount) merged PR(s) in the window, \($s.nodes | length) read at --limit \($limit) — the rest is UNSWEPT; \(if $limit < $limit_max then "raise --limit (max \($limit_max)), or narrow --window, until those two counts meet" else "narrow --window until those two counts meet; --limit is already at its \($limit_max) ceiling" end)" ]
            | @tsv ]
     else [] end)
  + [ $s.nodes[]
    | . as $pr
    | (.mergedAt | epoch) as $merged
    | if ($pr.number | type) != "number"
         or (($pr.headRefOid // "") | test("^[0-9a-fA-F]{40}$") | not)
         or $merged == null
      then error("malformed merged-PR row")
      else . end
    | select($merged >= $cutoff)
    # Answers that can clear a late REVIEW: human ISSUE COMMENTS, since a
    # review object has no reply thread of its own. Review bodies are
    # deliberately NOT answers — a review is the finding side, and one
    # whose own body carried a track-word would otherwise clear itself.
    | ([ ($pr.comments.nodes // [])[] | select(at != null) | select(is_reply) ]) as $pr_replies
    | ([ ($pr.reviews.nodes // [])[]
         | . as $r
         | ($r | at) as $rat
         | select($rat != null and $rat > $merged)
         | select($r.state == "CHANGES_REQUESTED" or $r.state == "COMMENTED")
         | select(($r.author.login // "") != ($pr.author.login // ""))
         | ([ $pr_replies[] | select(at > $rat) ] | last) as $standing
         | select(($standing == null) or (($standing.body // "") | answered | not))
         | $r.id ]) as $late_reviews
    # A thread is a finding when it carries a post-merge comment that is
    # not itself a disposition reply and the newest reply after that
    # comment is missing or is not an answer. Judged on the comment, not on
    # the thread opening: a reviewer re-raising on a line it already
    # commented on lands in a PRE-merge thread.
    | ([ ($pr.reviewThreads.nodes // [])[]
         | . as $t
         | ([ ($t.comments.nodes // [])[] | select(at != null) | select(at > $merged) ]) as $post
         | ([ $post[] | select(is_reply | not) | at ] | max // null) as $finding_at
         | select($finding_at != null)
         | ([ $post[] | select(is_reply) | select(at > $finding_at) ] | last) as $standing
         | select(($standing == null) or (($standing.body // "") | answered | not))
         | $t.id ]) as $late_threads
    # Fail closed wherever the read cannot prove itself: reviews come back
    # in creation order, so their bound hides content only when every
    # returned review is post-merge; reviewThreads has no documented order,
    # so any truncation there fails closed; thread comments are read
    # newest-first, so truncation is harmless unless every returned comment
    # is post-merge; and a timestamp that will not parse cannot be placed
    # either side of the merge, so it is never silently dropped.
    | ([ ($pr.reviews.nodes // [])[] | select(at != null) | select(at > $merged) ] | length) as $post_reviews
    | (([ ($pr.reviews.nodes // [])[] | select(at == null) ] | length)
       + ([ ($pr.reviewThreads.nodes // [])[] | (.comments.nodes // [])[] | select(at == null) ] | length)) as $bad_ts
    | (($pr.reviews.totalCount > ($pr.reviews.nodes | length) and $post_reviews == ($pr.reviews.nodes | length))
       or ($pr.reviewThreads.totalCount > ($pr.reviewThreads.nodes | length))
       or ([ ($pr.reviewThreads.nodes // [])[]
             | select(.comments.totalCount > (.comments.nodes | length))
             | select([ (.comments.nodes // [])[] | select(at != null) | select(at <= $merged) ] | length == 0) ] | length > 0)
       or $bad_ts > 0) as $overflow
    | select(($late_reviews | length) > 0 or ($late_threads | length) > 0 or $overflow)
    | ($late_reviews + $late_threads + (if $overflow then ["\($pr.number):overflow"] else [] end)) as $keys
    | [ ($pr.number | tostring), ($pr.headRefOid[0:8]), "post-merge-findings",
        ($keys | join(" ")),
        (if $bad_ts > 0
         then "a review or thread comment carries a timestamp that will not parse, so post-merge activity cannot be placed either side of the merge — fail closed; re-read #\($pr.number) by hand"
         elif $overflow
         then "post-merge activity beyond the read bound on a merged PR — fail closed; re-read #\($pr.number) by hand"
         else "\($late_reviews | length) review(s) and \($late_threads | length) review thread(s) landed after the merge with no disposition reply — merged \($pr.mergedAt); nothing has read them"
         end) ]
    | @tsv
  ] | .[]
end'
