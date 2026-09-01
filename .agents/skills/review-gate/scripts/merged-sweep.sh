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
  --limit N          how many recently-updated merged PRs to consider
                     (default 20, max 100). Ordered by UPDATE time, so a
                     merged PR that a late review touched stays in view
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
                       reviews are not findings. Replies are read the way
                       review-predicate.sh reads them: newest non-bot
                       reply, bots exempt because they quote each other.
                       A PR whose findings cannot be fully read in this
                       page shape (every returned review or thread is
                       post-merge, so more may exist; a thread past 50
                       comments) fails CLOSED as attention

Dedupe: per-repo state, the same rising-edge mechanism as oversee-watch's
PW_SEEN. Each finding is keyed by its node id; a key present in the
previous pass is not re-emitted, and a key that clears and later recurs is
news again. The state file is rewritten to the current key set on every
pass, so a finding surfaces ONCE and stays quiet while unchanged. Silence
therefore means "nothing NEW needs you" — use --no-state to re-read what
is still outstanding.

Output: one tab-separated line per merged PR with new findings, the same
shape pr-watch.sh emits, so one reducer consumes both:
  <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>

Exit codes:
  0  nothing new needs attention
  1  at least one attention line
  2  read failure, in two shapes: per-PR failures carry `error` lines on
     stdout (attention lines may also be present), while GLOBAL failures
     (missing GH_REPO, a broken merged-PR listing, an unusable state file)
     report on stderr only with no per-PR lines — surface stderr, not just
     stdout

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

# GraphQL rejects first:0 and caps the page at 100. Both bounds are refused
# rather than clamped: a clamp would silently sweep a different set than the
# operator asked for.
if [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 100 ]; then
  echo "::error::merged-sweep: --limit must be between 1 and 100 (got $LIMIT)" >&2
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
# Bounds are `last:` on purpose — a post-merge review or thread is NEWER
# than every pre-merge one, so the newest page is where they are, and the
# only way to overflow is for the whole page to be post-merge, which the
# reduction below detects and fails closed on.
query='query($owner:String!,$name:String!,$limit:Int!){
  repository(owner:$owner,name:$name){
    pullRequests(first:$limit, states:MERGED, orderBy:{field:UPDATED_AT, direction:DESC}){
      nodes{
        number mergedAt headRefOid
        author{login}
        reviews(last:30){
          totalCount
          nodes{ id createdAt state body author{login __typename} }
        }
        comments(last:50){
          nodes{ createdAt body author{login __typename} }
        }
        reviewThreads(last:30){
          totalCount
          nodes{
            id
            comments(first:50){
              totalCount
              nodes{ createdAt body author{login __typename} }
            }
          }
        }
      }
    }
  }
}'

raw="$(gh api graphql -f query="$query" \
    -f owner="${GH_REPO%%/*}" -f name="${GH_REPO#*/}" -F limit="$LIMIT" 2>/dev/null)" || {
  echo "::error::merged-sweep: could not list recently-merged PRs" >&2
  exit 2
}
if [ -z "$raw" ]; then
  echo "::error::merged-sweep: merged-PR listing produced zero bytes (broken read)" >&2
  exit 2
fi

# --- reduce -------------------------------------------------------------
# The disposition forms are review-predicate.sh's, read the same way: the
# canonical `Fixed in <sha>` / `Declined:` reply, or any reply carrying a
# track-word. This asks only "did anyone answer this", so it does NOT
# re-run the predicate's narrower untracked-claim and unreasoned-decline
# reductions — those judge an answer's quality on an OPEN PR, where the
# gate can still act on the judgement.
reduce_jq='
def disposition: test("^\\s*(fixed in [0-9a-f]{7,40}\\b|declined:)"; "i");
def tracking: test("(?i)\\btrack(ed|ing|s)?\\b");
def names_an_issue: test("([A-Z][A-Z0-9]+-[0-9]+|#[0-9]+)\\b");
# A track-word alone is NOT an answer here. review-predicate.sh accepts one
# as a thread'"'"'s standing disposition and then files it as an
# untracked-claim finding; this sweep has no second finding to file, so a
# bare "tracking that separately" would silence the last net over a late
# finding — the fail-open direction the whole pass exists to close.
def answered: disposition or (tracking and names_an_issue);
def human: (.author.__typename // "User") != "Bot";
def epoch: if type == "string" then (try (sub("\\.[0-9]+";"") | fromdateiso8601) catch null) else null end;

if (.errors? // [] | length) > 0 then error("graphql errors present")
elif (.data.repository.pullRequests.nodes | type) != "array" then error("malformed merged-PR container")
else
  [ .data.repository.pullRequests.nodes[]
    | . as $pr
    | (.mergedAt | epoch) as $merged
    | if ($pr.number | type) != "number"
         or (($pr.headRefOid // "") | test("^[0-9a-fA-F]{40}$") | not)
         or $merged == null
      then error("malformed merged-PR row")
      else . end
    | select($merged >= $cutoff)
    # Answers that can clear a late REVIEW: a later human ISSUE COMMENT in
    # a disposition form. A review object has no reply thread of its own,
    # so the PR conversation is where its answer lands. Review bodies are
    # deliberately NOT answers — a review is the finding side, and one
    # whose own body carried a track-word would otherwise clear itself.
    | ([ ($pr.comments.nodes // [])[]
         | select(human) | select((.body // "") | answered)
         | (.createdAt | epoch) | select(. != null) ] | max // -1) as $answered_at
    | ([ ($pr.reviews.nodes // [])[]
         | select((.createdAt | epoch) != null and (.createdAt | epoch) > $merged)
         | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED")
         | select((.author.login // "") != ($pr.author.login // ""))
         | select($answered_at <= (.createdAt | epoch))
         | .id ]) as $late_reviews
    | ([ ($pr.reviewThreads.nodes // [])[]
         | . as $t
         | (($t.comments.nodes // []) | first | (.createdAt // null) | epoch) as $opened
         | select($opened != null and $opened > $merged)
         | select([ ($t.comments.nodes // [])[]
                    | select(human)
                    | select((.createdAt | epoch) != null and (.createdAt | epoch) > $opened)
                    | select((.body // "") | answered) ] | length == 0)
         | $t.id ]) as $late_threads
    # Fail closed where the page cannot prove it is complete: every
    # returned review or thread being post-merge means more may sit behind
    # the bound, and a thread past the comment bound may hide its answer.
    | ([ ($pr.reviews.nodes // [])[] | select((.createdAt | epoch) != null and (.createdAt | epoch) > $merged) ] | length) as $post_reviews
    | ([ ($pr.reviewThreads.nodes // [])[]
         | select(((.comments.nodes // []) | first | (.createdAt // null) | epoch) != null)
         | select((((.comments.nodes // []) | first | .createdAt) | epoch) > $merged) ] | length) as $post_threads
    | (($pr.reviews.totalCount > ($pr.reviews.nodes | length) and $post_reviews == ($pr.reviews.nodes | length))
       or ($pr.reviewThreads.totalCount > ($pr.reviewThreads.nodes | length) and $post_threads == ($pr.reviewThreads.nodes | length))
       or ([ ($pr.reviewThreads.nodes // [])[]
             | select(.comments.totalCount > (.comments.nodes | length)) ] | length > 0)) as $overflow
    | select(($late_reviews | length) > 0 or ($late_threads | length) > 0 or $overflow)
    | ($late_reviews + $late_threads + (if $overflow then ["\($pr.number):overflow"] else [] end)) as $keys
    | [ ($pr.number | tostring), ($pr.headRefOid[0:8]), ($keys | join(" ")),
        (if $overflow
         then "post-merge activity beyond the read bound on a merged PR — fail closed; re-read #\($pr.number) by hand"
         else "\($late_reviews | length) review(s) and \($late_threads | length) review thread(s) landed after the merge with no disposition reply — merged \($pr.mergedAt); nothing has read them"
         end) ]
    | @tsv
  ] | .[]
end'

now="$(date -u +%s)"
cutoff=$((now - WINDOW))
rows="$(jq -r --argjson cutoff "$cutoff" "$reduce_jq" <<<"$raw" 2>/dev/null)" || {
  echo "::error::merged-sweep: merged-PR listing is malformed (broken read, a row without a number/head/mergedAt, or graphql errors)" >&2
  exit 2
}

# --- emit ---------------------------------------------------------------
attention=0
current=""
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
  printf '%s\t%s\t%s\t%s\n' "$number" "$head" "post-merge-findings" "$detail"
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

if [ "$attention" = "1" ]; then exit 1; fi
exit 0
