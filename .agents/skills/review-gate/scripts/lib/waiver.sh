# shellcheck shell=bash
# The merge route's thread waiver: the one owner of what the reply it leaves
# says, which threads a `none` class row waives, and when a thread it resolved
# stands resolved. Two readers source this file: review-predicate.sh's thread
# term, and the github skill's pr-merge. Sourced, never run; it defines and
# runs nothing else.
#
# A waiver resolution lapses when the merge route's resolution is still the
# thread's last word and the class policy at the current head does not waive
# the thread. Its last word: the resolver is the identity that posted the
# newest waiver reply in the thread, and that identity has written nothing
# since. A thread someone answered and resolved again is theirs, not a waiver.
# review-predicate.sh's thread term and pr-merge count a lapsed waiver as an
# open thread. Readers of isResolved alone (pr-watch's threads-open, github
# pr-threads' unresolved_count, orch queue-wait's late-findings guard) see it
# as resolved until the merge route reopens it.

# The waiver reply's opening, which names the class and the head the class
# was measured at. Anchored, and the head is a whole commit SHA, so a quote of
# it inside another comment does not read as the reply.
RG_WAIVER_REPLY_RE='^Resolved by the merge route: change class [a-z]+ at [0-9a-f]{40}, '

rg_waiver_reply() { # CLASS HEAD -> the reply body
  printf 'Resolved by the merge route: change class %s at %s, review evidence none under REVIEW_GATE_CLASS_POLICY' "$1" "$2"
}

# jq definitions over one thread shaped as
#   {is_resolved, resolved_by, comment_count, comments: [{author, author_type, body}]}
# which is github pr-threads' safe shape; rg_waiver_view maps a raw GraphQL
# reviewThreads node (isResolved, resolvedBy{login}, comments{totalCount
# nodes{body author{login __typename}}}) onto it. $bots is the review-bot
# login list `review-policy --review-bots` names, in GraphQL's spelling.
#   rg_waivable($bots)           every comment a listed Bot's or a waiver
#                                reply, the first a listed Bot's, all read
#   rg_waiver_stands             resolved, and the waiver is the last word
#   rg_lapsed_waiver($ev; $bots) stands, and evidence $ev does not waive it
# A resolver login carries GitHub's `[bot]` suffix where a comment author's
# does not, so it is compared with the suffix dropped.
# shellcheck disable=SC2034  # read by the scripts that source this file
RG_WAIVER_JQ='
def rg_waiver_reply: (.body // "") | test("'"$RG_WAIVER_REPLY_RE"'");
def rg_by_review_bot($bots): .author_type == "Bot" and (.author as $a | any($bots[]; . == $a));
def rg_waivable($bots):
  (.comment_count == (.comments | length))
  and ((.comments | length) > 0)
  and (.comments[0] | rg_by_review_bot($bots))
  and all(.comments[]; rg_by_review_bot($bots) or rg_waiver_reply);
def rg_waiver_stands:
  ((.resolved_by // "") | sub("\\[bot\\]$"; "")) as $resolver
  | ([.comments | to_entries[] | select(.value | rg_waiver_reply)] | last) as $reply
  | (.is_resolved == true) and ($resolver != "") and ($reply != null)
    and ($reply.value.author == $resolver)
    and all(.comments[($reply.key + 1):][]; .author != $resolver);
def rg_lapsed_waiver($evidence; $bots):
  rg_waiver_stands and (($evidence != "none") or (rg_waivable($bots) | not));
def rg_waiver_view:
  {is_resolved: .isResolved,
   resolved_by: (.resolvedBy.login // ""),
   comment_count: (.comments.totalCount // null),
   comments: [(.comments.nodes // [])[]
     | {author: (.author.login // ""), author_type: (.author.__typename // ""), body: (.body // "")}]};
'
