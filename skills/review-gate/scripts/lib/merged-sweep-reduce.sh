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
# this", so the judgment it leaves to the predicate and the merge gate is
# the corpus-driven one — whether a stated reason is a REAL reason, and
# whether a tracking claim names a live issue.
def disposition: test("^\\s*(fixed in [0-9a-f]{7,40}\\b|declined:)"; "i");
def declined: test("^\\s*declined:"; "i");
def reasoned_decline: test("^\\s*declined:\\s*\\S"; "i");
def tracking: test("(?i)\\btrack(ed|ing|s)?\\b");
def names_an_issue: test("([A-Z][A-Z0-9]+-[0-9]+|#[0-9]+)\\b");
# Two narrowings compose ON TOP of the standing-reply rule, each closing a
# reply shape that would otherwise silence the last net over a late finding.
# A track-word alone is NOT an answer: the predicate files that as an
# untracked-claim finding and this sweep has no second finding to file, so a
# bare "tracking that separately" would answer nothing at all. Nor is a bare
# `Declined:` — the contract is `Declined: <reason>` and the gate rejects an
# empty one, but the gate never sees these replies, because this sweep'"'"'s
# whole population is post-merge activity. Recognising an EMPTY reason needs
# no corpus, so it belongs here; recognising a BAD one does, so it does not.
def answered: (disposition and ((declined | not) or reasoned_decline))
              or (tracking and names_an_issue);
# ASSUMES an entry with no author is a HUMAN, so its reply can answer a
# finding. GitHub returns a null author only for a deleted account, whose
# reply was written by a person; a bot cannot reach this default, because
# the query asks for __typename and GraphQL always returns it for an author
# that exists. What would break it: a response shape that omits __typename
# on a live author, which would let a bot reply clear a finding.
def human: (.author.__typename // "User") != "Bot";
# Anything that will not parse — a non-string, a malformed date — becomes
# null, which $bad_ts counts and fails closed on; nothing is dropped for
# being unreadable. The fraction is DISCARDED, so two items in the same
# second compare equal: that is what makes the mergedAt tie below possible.
def epoch: if type == "string" then (try (sub("\\.[0-9]+";"") | fromdateiso8601) catch null) else null end;
# The EFFECTIVE PUBLICATION time, and the ONE definition every arm shares.
# createdAt is when a review was STARTED: a reviewer drafting during the
# merge queue and submitting just after the merge — the ordinary shape of
# the finding this sweep exists to catch — leaves createdAt < mergedAt, so
# placing the review by it drops the finding silently. Measured on a real
# PENDING review, 2026-09-01: submittedAt was null while publishedAt
# EQUALLED createdAt, so only submittedAt separates a draft review from a
# submitted one; that review'"'"'s inline comment had publishedAt null, so
# publishedAt is the field that does it for a comment. One expression
# covers both, because a review carries no publishedAt worth having and a
# comment carries no submittedAt at all. createdAt remains the fallback, so
# a response shape carrying neither field behaves exactly as before.
def at: ((.submittedAt // .publishedAt // .createdAt) | epoch);
# A missing body reads as "", which is neither a disposition nor a
# track-word: it never answers a finding, and inside a thread it counts as
# CONTENT. Both directions are the closed one.
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
         # ASSUMES the review states worth reading are exactly these two, so
         # a state this list does not name is dropped in silence. Today the
         # enum holds only PENDING, APPROVED and DISMISSED besides them, and
         # each is deliberately not a finding. What would break it: GitHub
         # adding a member. A deny-list would fail closed instead, but it
         # would first need a ruling on PENDING — reported, not changed here.
         | select($r.state == "CHANGES_REQUESTED" or $r.state == "COMMENTED")
         # A review belongs to the PR author only when that author is KNOWN
         # and the logins match. Defaulting both sides to "" made two
         # unidentifiable accounts compare EQUAL, so a ghost-authored review
         # on a ghost-authored PR was dropped as a self-review — a finding
         # discarded in silence. Measured: that pair was the only affected
         # shape. A named reviewer on a ghost-authored PR was never dropped,
         # because a real login differs from the "" default, so this is one
         # lost review and never a whole silent PR.
         | select(($pr.author.login == null) or ($r.author.login != $pr.author.login))
         | ([ $pr_replies[] | select(at > $rat) ] | last) as $standing
         | select(($standing == null) or (($standing.body // "") | answered | not))
         | $r.id ]) as $late_reviews
    # A thread is a finding when it carries a post-merge comment that is
    # not itself a disposition reply and the newest reply after that
    # comment is missing or is not an answer. Judged on the comment, not on
    # the thread opening: a reviewer re-raising on a line it already
    # commented on lands in a PRE-merge thread.
    # The KEY is that comment, never the thread. A thread id is stable for
    # the life of the thread and a thread takes more than one finding, so
    # keying the container makes the second and every later finding in it
    # unreportable by construction — the next pass recomputes the same key,
    # finds it in the seen set and says nothing. Keying the comment makes a
    # new finding a new key while a re-run over unchanged data still dedupes.
    | ([ ($pr.reviewThreads.nodes // [])[]
         | . as $t
         | ([ ($t.comments.nodes // [])[] | select(at != null) | select(at > $merged) ]) as $post
         | ([ $post[] | select(is_reply | not) ] | max_by(at)) as $finding
         | select($finding != null)
         | ($finding | at) as $finding_at
         # STRICTLY after the finding: a reply in the same second as the
         # finding cannot be proved to answer it, so it does not and the
         # thread surfaces. This boundary already fails closed.
         | ([ $post[] | select(is_reply) | select(at > $finding_at) ] | last) as $standing
         | select(($standing == null) or (($standing.body // "") | answered | not))
         # The thread id is the fallback, not the key: a comment the response
         # returned without the id the query asked for keeps the coarser
         # dedupe rather than emitting an empty key that collides with every
         # other empty one.
         | ($finding.id // $t.id) ]) as $late_threads
    # Fail closed wherever the read cannot prove itself: reviews come back
    # in CREATION order (measured 2026-09-01: first:N returns the OLDEST N)
    # while `at` places them by SUBMISSION, so this bound catches a page
    # that is entirely post-merge but NOT a draft opened before the
    # truncated tail and submitted after the merge; reported rather than
    # closed here, since closing it means failing closed on every truncated
    # review page. reviewThreads has no documented order,
    # so any truncation there fails closed; thread comments are read
    # newest-first, so truncation is harmless unless every returned comment
    # is post-merge; a timestamp that will not parse cannot be placed either
    # side of the merge; and neither can one that lands ON it.
    | ([ ($pr.reviews.nodes // [])[] | select(at != null) | select(at > $merged) ] | length) as $post_reviews
    | (([ ($pr.reviews.nodes // [])[] | select(at == null) ] | length)
       + ([ ($pr.reviewThreads.nodes // [])[] | (.comments.nodes // [])[] | select(at == null) ] | length)) as $bad_ts
    # The mergedAt TIE. GitHub serializes to the second and epoch drops the
    # fraction, so anything published in the same second as the merge lands
    # exactly ON $merged. Neither arm may claim it: `>` drops it in silence
    # and no later pass ever looks again, `>=` reports a finding the read
    # cannot prove is post-merge. So it goes to overflow, which asks for
    # eyes and keys the PR so the ask is not repeated every pass.
    | (([ ($pr.reviews.nodes // [])[] | select(at == $merged) ] | length)
       + ([ ($pr.reviewThreads.nodes // [])[] | (.comments.nodes // [])[] | select(at == $merged) ] | length)) as $ties
    # Each cause is bound BY NAME so the KEY can carry the ones that fired.
    # A key naming only the PR cannot represent a SECOND cause arriving while
    # the first still holds: the pass that found it recomputes the first key,
    # matches the seen set and says nothing, over a PR whose reason for
    # needing eyes has changed. The names are whitespace-free deliberately —
    # merged-sweep.sh splits the keys column on spaces.
    | (($pr.reviews.totalCount > ($pr.reviews.nodes | length))
       and ($post_reviews == ($pr.reviews.nodes | length))) as $rv_bound
    | ($pr.reviewThreads.totalCount > ($pr.reviewThreads.nodes | length)) as $th_bound
    | ([ ($pr.reviewThreads.nodes // [])[]
         | select(.comments.totalCount > (.comments.nodes | length))
         | select([ (.comments.nodes // [])[] | select(at != null) | select(at <= $merged) ] | length == 0) ] | length > 0) as $cm_bound
    | ([ if $rv_bound then "reviews-page" else empty end,
         if $th_bound then "threads-page" else empty end,
         if $cm_bound then "thread-comments" else empty end,
         if $bad_ts > 0 then "unparsable-time" else empty end,
         if $ties > 0 then "merge-tie" else empty end ]) as $causes
    | (($causes | length) > 0) as $overflow
    | select(($late_reviews | length) > 0 or ($late_threads | length) > 0 or $overflow)
    # ONE RULE for every key here: a key names what would have to CHANGE for
    # the report to be news, and where nothing about the condition can
    # change, there is no key at all. A review key is its own node id
    # because a review IS one finding; a thread key is the comment that
    # produced the finding, never the thread, because a thread takes more
    # than one; an overflow key is the PR AND the causes, because a PR
    # accumulates causes; and the coverage row carries "-" because a
    # shortfall is standing, not an event, so announce-once would go silent
    # while the gap held. A key naming the container instead of the finding
    # is the defect this file has had three times.
    # This one ASSUMES every review and thread carries the node id the query
    # asks for by name. A null id joins as an empty segment, so two findings
    # on one PR could share a key and the second would dedupe away. What
    # would break it: a response omitting a requested id on a node it
    # returned.
    | ($late_reviews + $late_threads
       + (if $overflow then ["\($pr.number):overflow:\($causes | join("+"))"] else [] end)) as $keys
    | [ ($pr.number | tostring), ($pr.headRefOid[0:8]), "post-merge-findings",
        ($keys | join(" ")),
        (if $bad_ts > 0
         then "a review or thread comment carries a timestamp that will not parse, so post-merge activity cannot be placed either side of the merge — fail closed; re-read #\($pr.number) by hand"
         elif $ties > 0
         then "a review or thread comment is timestamped in the same second as the merge, so the read cannot place it either side — fail closed; re-read #\($pr.number) by hand"
         elif $overflow
         then "post-merge activity beyond the read bound on a merged PR — fail closed; re-read #\($pr.number) by hand"
         else "\($late_reviews | length) review(s) and \($late_threads | length) review thread(s) landed after the merge with no disposition reply — merged \($pr.mergedAt); nothing has read them"
         end) ]
    | @tsv
  ] | .[]
end'
