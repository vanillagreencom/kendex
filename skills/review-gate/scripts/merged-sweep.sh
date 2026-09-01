#!/usr/bin/env bash
# merged-sweep — the post-merge half of the needs-attention reducer
# (kendex#KEN-1021). pr-watch.sh reduces OPEN PRs; nothing read a finding
# that landed after the merge. The gate goes green on the first non-author
# review row with no quiet period, so a bot round landing in the queue's
# final minutes merges unread, the lane shuts down, and the finding is
# never seen. This sweeps recently-merged PRs and says so.
# The authoritative contract — attention kind, output format, exit codes,
# env — is print_usage below: run with --help.
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: merged-sweep.sh [--window SECS] [--limit N] [--no-state]
                       [--state-file PATH]

Sweep recently-merged PRs for reviews and review threads that landed AFTER
the merge and carry no disposition reply. One invocation answers: did a
finding arrive too late for anyone to read it?

  --window SECS      only PRs merged within this many seconds (default
                     172800 — 48h); at most 9 digits
  --limit N          how many merged PRs the one query reads (default 20,
                     max 40). The ceiling is where the query still
                     completes, not where GraphQL stops counting: measured
                     on a busy repo, 40 answers in ~4s and 80 returns HTTP
                     504. A window holding more than this is itself a
                     fail-closed line, never silence over the remainder
  --no-state         report every current finding, deduping nothing — the
                     audit form; the sweep writes no state file
  --state-file PATH  override the per-repo state file (default:
                     $MERGED_SWEEP_STATE_DIR/<repo-slug>, itself
                     defaulting to tmp/review-gate-merged-sweep/)

Attention kind:
  post-merge-findings  a merged PR carries a review or a review thread
                       created after its mergedAt with no disposition
                       reply (Fixed in <sha>, Declined: <reason>, or a
                       track-word NAMING an issue — a bare track-word is
                       not an answer), so nothing has read it. Approvals and
                       dismissals are not findings; the PR author's own
                       reviews are not findings. A thread counts on ANY
                       post-merge comment, not only a post-merge opening,
                       because a reviewer re-raising on a line it already
                       flagged lands in a pre-merge thread. The STANDING
                       reply is the LAST non-bot one in a reply form, as in
                       review-predicate.sh, so an older canonical reply
                       never outranks a newer bare one; bots are exempt
                       because they quote each other. Anything the read
                       cannot prove fails CLOSED: a truncated
                       reviewThreads page (GitHub documents no ordering
                       for it), a review or comment page whose every entry
                       is post-merge, an unparsable timestamp, and a window
                       holding more merged PRs than --limit read

Dedupe: per-repo state, the same rising-edge mechanism as oversee-watch's
PW_SEEN. Each finding is keyed by its node id; a key present in the
previous pass is not re-emitted, and one that clears and later recurs is
news again. So a finding surfaces ONCE and stays quiet while unchanged, and
silence means "nothing NEW needs you" — use --no-state to re-read what is
still outstanding.

Output: one tab-separated line per merged PR with new findings, the same
shape pr-watch.sh emits, so one reducer consumes both:
  <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>
The sweep-level truncation line belongs to no single PR and carries "-" and
"--------" in those two columns.

Exit codes:
  0  nothing new needs attention
  1  at least one attention line
  2  a read or config failure — always GLOBAL (missing or malformed
     GH_REPO, a bad flag, a broken merged-PR listing, an unusable state
     file). One query answers for the whole sweep, so there is no per-PR
     failure to isolate: exit 2 reports on stderr and prints NO lines on
     stdout at all. Surface stderr, never stdout alone. Attention lines are
     buffered until the state file is written, so a state write that fails
     exits 2 with nothing printed rather than looking like ordinary
     attention

Env (required): GH_TOKEN (or ambient gh auth), GH_REPO
Env (optional): MERGED_SWEEP_STATE_DIR — directory holding the per-repo
state files (default tmp/review-gate-merged-sweep, relative to the cwd)
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) print_usage; exit 0 ;;
  esac
done

if [ -z "${GH_REPO:-}" ]; then
  echo "::error::merged-sweep: GH_REPO is required" >&2
  exit 2
fi
case "$GH_REPO" in
  */*/*|/*|*/) echo "::error::merged-sweep: GH_REPO must be OWNER/REPO (got '$GH_REPO')" >&2; exit 2 ;;
  */*) ;;
  *) echo "::error::merged-sweep: GH_REPO must be OWNER/REPO (got '$GH_REPO')" >&2; exit 2 ;;
esac

WINDOW=172800
LIMIT=20
USE_STATE=1
STATE_FILE=""

# Digit-only AND bounded, the same discipline pr-watch.sh applies to
# PR_REVIEW_WAIT_SECS: a digit string past Bash's integer range passes a
# [!0-9] check and then errors INSIDE the later arithmetic, where the
# failure is swallowed and the window silently stops filtering.
numeric_arg() { # FLAG VALUE — normalized value on stdout; exits 2 otherwise
  local flag="$1" val="${2:-}"
  case "$val" in
    ''|*[!0-9]*)
      echo "::error::merged-sweep: $flag needs a non-negative integer" >&2
      exit 2
      ;;
  esac
  val="$(printf '%s' "$val" | sed 's/^0*//')"
  [ -z "$val" ] && val=0
  if [ "${#val}" -gt 9 ]; then
    echo "::error::merged-sweep: $flag is out of range (max 9 digits)" >&2
    exit 2
  fi
  printf '%s' "$val"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --window) shift; WINDOW="$(numeric_arg --window "${1:-}")" ;;
    --limit) shift; LIMIT="$(numeric_arg --limit "${1:-}")" ;;
    --no-state) USE_STATE=0 ;;
    --state-file)
      shift
      STATE_FILE="${1:-}"
      [ -n "$STATE_FILE" ] || { echo "::error::merged-sweep: --state-file needs a path" >&2; exit 2; }
      ;;
    *) echo "::error::merged-sweep: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

# GraphQL rejects first:0, and the upper bound is the MEASURED one, not the
# API's: against vanillagreencom/kendex this query answers in about 4s at 40
# and returns HTTP 504 at 80 and above. Both bounds are refused rather than
# clamped — a clamp would silently sweep a different set than the operator
# asked for, and the saturation line below is what reports a window this
# page cannot cover.
LIMIT_MAX=40
if [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt "$LIMIT_MAX" ]; then
  echo "::error::merged-sweep: --limit must be between 1 and $LIMIT_MAX (got $LIMIT)" >&2
  exit 2
fi

# --- state --------------------------------------------------------------
# One file per repo, the same shape oversee-watch keeps for PW_SEEN: the
# keys of the previous pass, one per line, replaced atomically.
if [ "$USE_STATE" = "1" ] && [ -z "$STATE_FILE" ]; then
  state_dir="${MERGED_SWEEP_STATE_DIR:-tmp/review-gate-merged-sweep}"
  mkdir -p "$state_dir" || {
    echo "::error::merged-sweep: could not create the state directory $state_dir (set MERGED_SWEEP_STATE_DIR, or pass --no-state)" >&2
    exit 2
  }
  STATE_FILE="$state_dir/$(printf '%s' "$GH_REPO" | tr -c 'A-Za-z0-9._-' '_')"
fi
seen=""
if [ "$USE_STATE" = "1" ] && [ -e "$STATE_FILE" ]; then
  seen="$(cat "$STATE_FILE")" || {
    echo "::error::merged-sweep: cannot read the state file $STATE_FILE (set MERGED_SWEEP_STATE_DIR, or pass --no-state)" >&2
    exit 2
  }
fi

# --- read ---------------------------------------------------------------
# ONE query for the whole sweep: this runs on a poll loop beside pr-watch,
# and a per-PR fan-out would multiply every pass by the window size.
# The enumeration is `search` with a merged: qualifier, because
# repository.pullRequests offers no MERGED_AT ordering — a page of it can
# never prove it covered the window, which is the silence this sweep exists
# to end. search bounds the set by mergedAt and counts it, so coverage is a
# comparison rather than a premise; sort:updated-desc truncates at the end
# a late review has not touched.
# Nested bounds are `last:` because a post-merge review or thread comment
# is newer than every pre-merge one, so truncation hides only content that
# could neither BE a post-merge finding nor ANSWER one. reviewThreads is
# the exception: GitHub documents no ordering for it, so its bound rests on
# nothing and any truncation there fails closed outright.
query='query($q:String!,$limit:Int!){
  search(query:$q, type:ISSUE, first:$limit){
    issueCount
    pageInfo{ hasNextPage }
    nodes{
      ... on PullRequest {
        number mergedAt headRefOid
        author{login}
        reviews(last:30){
          totalCount
          nodes{ id createdAt state body author{login __typename} }
        }
        comments(last:50){
          nodes{ createdAt body author{login __typename} }
        }
        reviewThreads(last:50){
          totalCount
          nodes{
            id
            comments(last:30){
              totalCount
              nodes{ createdAt body author{login __typename} }
            }
          }
        }
      }
    }
  }
}'

now="$(date -u +%s)"
cutoff=$((now - WINDOW))
cutoff_iso="$(date -u -d "@$cutoff" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "$cutoff" +%Y-%m-%dT%H:%M:%SZ)" || cutoff_iso=""
if [ -z "$cutoff_iso" ]; then
  echo "::error::merged-sweep: could not format the window cutoff (date does not accept -d @SECS or -r SECS)" >&2
  exit 2
fi

# gh'"'"'s stderr is KEPT: at high --limit values GitHub answers HTTP 504, and
# a generic "could not list" sends the operator after an auth or network
# fault instead of the one knob that fixes it.
gh_err="$(mktemp)" || { echo "::error::merged-sweep: could not create a temporary file for the read" >&2; exit 2; }
trap 'rm -f -- "$gh_err"' EXIT
raw="$(gh api graphql -f query="$query" \
    -f q="repo:$GH_REPO is:pr is:merged sort:updated-desc merged:>=$cutoff_iso" \
    -F limit="$LIMIT" 2>"$gh_err")" || {
  echo "::error::merged-sweep: could not list merged PRs in the last ${WINDOW}s at --limit $LIMIT; GitHub answers HTTP 504 on an over-large page, so lower --limit before suspecting auth or network" >&2
  sed 's/^/::error::merged-sweep: gh: /' "$gh_err" >&2
  exit 2
}
if [ -z "$raw" ]; then
  echo "::error::merged-sweep: merged-PR listing produced zero bytes (broken read)" >&2
  exit 2
fi

# --- reduce -------------------------------------------------------------
reduce_jq='
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
elif (.data.search.nodes | type) != "array" then error("malformed merged-PR container")
elif ((.data.search.issueCount | type) != "number")
     or ((.data.search.pageInfo.hasNextPage | type) != "boolean")
then error("merged-PR listing carries no coverage metadata")
else
  .data.search as $s
  # A page that did not reach the whole window says so and fails closed
  # instead of reporting silence over the remainder. Keyed like every other
  # finding, so it dedupes.
  | (if ($s.issueCount > ($s.nodes | length)) or $s.pageInfo.hasNextPage
     then [ [ "-", "--------", "sweep:window-truncated",
              "\($s.issueCount) merged PR(s) in the window, \($s.nodes | length) read at --limit \($limit) — the rest is UNSWEPT; \(if $limit < $limit_max then "raise --limit (max \($limit_max)) or narrow --window" else "narrow --window, since --limit is already at its \($limit_max) ceiling" end). Oldest merged PR read: \([$s.nodes[] | .mergedAt // empty] | min // "none")" ]
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
    | [ ($pr.number | tostring), ($pr.headRefOid[0:8]), ($keys | join(" ")),
        (if $bad_ts > 0
         then "a review or thread comment carries a timestamp that will not parse, so post-merge activity cannot be placed either side of the merge — fail closed; re-read #\($pr.number) by hand"
         elif $overflow
         then "post-merge activity beyond the read bound on a merged PR — fail closed; re-read #\($pr.number) by hand"
         else "\($late_reviews | length) review(s) and \($late_threads | length) review thread(s) landed after the merge with no disposition reply — merged \($pr.mergedAt); nothing has read them"
         end) ]
    | @tsv
  ] | .[]
end'

rows="$(jq -r --argjson cutoff "$cutoff" --argjson limit "$LIMIT" \
    --argjson limit_max "$LIMIT_MAX" "$reduce_jq" <<<"$raw" 2>/dev/null)" || {
  echo "::error::merged-sweep: merged-PR listing is malformed (broken read, a row without a number/head/mergedAt, or graphql errors)" >&2
  exit 2
}

# --- reduce to lines, then persist, then print ---------------------------
# Nothing reaches stdout until the state file is on disk. Exit 2 is the
# GLOBAL failure shape and consumers key on it: oversee-watch's
# check_pr_watch treats a non-zero run that printed lines as findings and a
# non-zero run that printed none as a hard failure, so a sweep whose state
# write failed must print nothing at all or it reads as ordinary attention
# and its stderr is never surfaced.
attention=0
current=""
out=""
# Node ids are opaque: split them on whitespace with globbing OFF, so a
# metacharacter in a future id shape can never expand against the cwd.
set -f
while IFS=$'\t' read -r number head keys detail; do
  [ -n "$number" ] || continue
  new=0
  for key in $keys; do
    current="$current$key"$'\n'
    if [ "$USE_STATE" = "0" ]; then
      new=1
    elif ! grep -qxF -- "$key" <<<"$seen"; then
      new=1
    fi
  done
  [ "$new" = "1" ] || continue
  out="$out$(printf '%s\t%s\t%s\t%s' "$number" "$head" "post-merge-findings" "$detail")"$'\n'
  attention=1
done <<<"$rows"
set +f

if [ "$USE_STATE" = "1" ]; then
  tmp="$STATE_FILE.$$.tmp"
  { printf '%s' "$current" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; } || {
    rm -f "$tmp"
    echo "::error::merged-sweep: could not write the state file $STATE_FILE (set MERGED_SWEEP_STATE_DIR, or pass --no-state)" >&2
    exit 2
  }
fi

[ -z "$out" ] || printf '%s' "$out"

if [ "$attention" = "1" ]; then exit 1; fi
exit 0
