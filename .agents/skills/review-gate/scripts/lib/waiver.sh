# shellcheck shell=bash
# The thread waiver the github skill's pr-merge once resolved review-bot
# threads under: when a thread it resolved still stands resolved. pr-merge no
# longer resolves any thread; review-predicate.sh's thread term is the one
# reader, and it counts a waiver resolution that still stands as an open
# thread, since the predicate is reached only where the class policy answered
# other than none. Sourced, never run; it defines and runs nothing else.
#
# A waiver resolution stands while the thread stays resolved and the waiver
# reply is still the resolver's newest comment in it. Comments from other
# authors, a reply in the waiver's words included, neither keep it standing
# nor end it. A thread someone answered and resolved again is theirs.
# Readers of isResolved alone (pr-watch's threads-open, github pr-threads'
# unresolved_count, orch queue-wait's late-findings guard) see it as resolved.

# The waiver reply's opening, which names the class and the head the class
# was measured at. Anchored, and the head is a whole commit SHA, so a quote of
# it inside another comment does not read as the reply.
RG_WAIVER_REPLY_RE='^Resolved by the merge route: change class [a-z]+ at [0-9a-f]{40}, '

# jq definitions over one thread shaped as
#   {is_resolved, resolved_by, comments: [{author, body}]}
# rg_waiver_view maps a raw GraphQL reviewThreads node (isResolved,
# resolvedBy{login}, comments{nodes{body author{login}}}) onto it.
#   rg_waiver_stands             resolved, and the waiver reply is still the
#                                resolver's newest comment in the thread
# A resolver login carries GitHub's `[bot]` suffix where a comment author's
# does not, so it is compared with the suffix dropped.
# shellcheck disable=SC2034  # read by the scripts that source this file
RG_WAIVER_JQ='
def rg_waiver_reply: (.body // "") | test("'"$RG_WAIVER_REPLY_RE"'");
def rg_waiver_stands:
  ((.resolved_by // "") | sub("\\[bot\\]$"; "")) as $resolver
  | ([.comments | to_entries[] | select(.value.author == $resolver and (.value | rg_waiver_reply))] | last) as $reply
  | (.is_resolved == true) and ($reply != null)
    and all(.comments[($reply.key + 1):][]; .author != $resolver);
def rg_waiver_view:
  {is_resolved: .isResolved,
   resolved_by: (.resolvedBy.login // ""),
   comments: [(.comments.nodes // [])[]
     | {author: (.author.login // ""), body: (.body // "")}]};
'
