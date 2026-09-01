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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Both libs are SOURCED, and under set -e a missing one ends the run at
# exit 1 — the code that promises attention lines — with nothing on stdout,
# which a consumer reduces to "nothing to do". Both fail closed at 2.
lib_readable() { # PATH
  [ -r "$1" ] || { echo "::error::merged-sweep: cannot read $1 — the skill install is incomplete; re-run kendex refresh, or check the file mode" >&2; exit 2; }
}
lib_defines() { # PATH SYMBOL — a truncated or mismatched lib defines nothing
  { [ -n "${!2+x}" ] || command -v "$2" >/dev/null 2>&1; } \
    || { echo "::error::merged-sweep: $1 defines no $2 — it is truncated or from another version; re-run kendex refresh" >&2; exit 2; }
}

lib_readable "$script_dir/lib/settings.sh"
# shellcheck source=lib/settings.sh
. "$script_dir/lib/settings.sh"
lib_defines "$script_dir/lib/settings.sh" rg_setting

# Both scratch paths go on ANY exit, signals included: an interrupted pass
# leaves neither a half-written state file nor the read's stderr capture.
gh_err=""
state_tmp=""
cleanup() { [ -z "$gh_err" ] || rm -f -- "$gh_err"; [ -z "$state_tmp" ] || rm -f -- "$state_tmp"; }
trap cleanup EXIT

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
                     max 80). The ceiling is where the query still
                     completes, not where GraphQL stops counting: measured
                     2026-09-01 on one busy repo, 40 in ~4s and 80 in ~8s
                     over six runs with none failing, 100 failing once in
                     two. Load-dependent, so re-measure before trusting it
                     elsewhere
  --no-state         report every current finding, deduping nothing — the
                     audit form; the sweep writes no state file
  --state-file PATH  override the per-repo state file (default:
                     <state-dir>/<repo-slug>, the state dir being
                     REVIEW_GATE_MERGED_SWEEP_STATE_DIR, default
                     tmp/review-gate-merged-sweep). A relative state dir is
                     anchored on the REPOSITORY ROOT, not the cwd, so a
                     caller that changes directory keeps its baseline.
                     GITIGNORE it: the default writes inside the repository

Attention kinds (column 3):
  post-merge-findings  a merged PR carries a review, or a review thread
                       COMMENT, created after its mergedAt with no
                       disposition reply (Fixed in <sha>, Declined:
                       <reason>, or a track-word NAMING an issue — a bare
                       track-word is not an answer), so nothing has read
                       it. Approvals and dismissals are not findings; the
                       PR author's own reviews are not findings. A thread
                       counts on its newest post-merge comment that is not
                       itself a reply form, never on the thread opening: a
                       reviewer re-raising on a line it already flagged
                       lands in a PRE-merge thread, and a thread whose only
                       post-merge comment IS a reply is answered. The STANDING reply is the
                       LAST non-bot one in a reply form, as in
                       review-predicate.sh, so an older canonical reply
                       never outranks a newer bare one; bots are exempt
                       because they quote each other. The two surfaces
                       differ deliberately: INSIDE a thread a human comment
                       that is not a reply form is new content and reopens
                       the finding, while on the PR CONVERSATION the same
                       comment is chatter and the standing disposition
                       holds. What the read cannot prove fails CLOSED: a
                       truncated reviewThreads page (GitHub documents no
                       ordering for it), a review or comment page whose
                       every entry is post-merge, and an unparsable
                       timestamp. One gap is invisible and so uncovered:
                       search is eventually consistent, so a PR the index
                       has not caught up with is absent from the page AND
                       uncounted. A loop recovers what one shot misses
  sweep:window-truncated  the window holds more merged PRs than this page
                       read, so the sweep cannot answer for the remainder.
                       Belongs to no single PR, so it carries "-" and
                       "--------" in the first two columns

Dedupe: per-repo state, the same rising-edge mechanism as oversee-watch's
PW_SEEN. A finding is keyed by the node id of its review or thread, the
per-PR fail-closed arm by a synthetic <number>:overflow. A key present in
the previous pass is not re-emitted; one that clears and recurs is news. So a finding surfaces ONCE and stays quiet while unchanged, and
silence means "nothing NEW needs you" — use --no-state to re-read what is
still outstanding. sweep:window-truncated is EXEMPT: a shortfall no reply
can clear is a standing property, not an event, so it carries no key and
REPEATS every pass while it holds. Announce-once there would leave the
gap, and a gap that worsens, silent from the second pass on.

Output: one tab-separated attention line, the same shape pr-watch.sh
emits, so one reducer consumes both:
  <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>

Exit codes:
  0  nothing new needs attention
  1  at least one attention line
  2  a read or config failure — always GLOBAL (missing or malformed
     GH_REPO, a bad flag, a repository the read could not reach, a broken
     merged-PR listing, an unusable state file). One query answers for the
     whole sweep, so there is no per-PR failure to isolate: exit 2 reports
     on stderr and prints NO lines on stdout at all. Surface stderr, never stdout alone. Attention lines are
     buffered until the state file is written, so a state write that fails
     exits 2 with nothing printed rather than looking like ordinary
     attention

Env (required): GH_TOKEN (or ambient gh auth), GH_REPO — OWNER/REPO, and
only letters, digits, '.', '_' and '-' either side of the slash, because it
is spliced into the search query where a qualifier would change the set
Settings: REVIEW_GATE_MERGED_SWEEP_STATE_DIR — the directory holding the
per-repo state files, resolved like every other engine key (env >
.env.local > .kendex/settings.toml > kendex.settings.toml > the built-in
tmp/review-gate-merged-sweep), except that the settings FILES are read from
the REPOSITORY ROOT, so the key is anchored the way the path it names is.
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
# The shape arm alone is not enough: GH_REPO is spliced into the search
# query STRING below, so anything between the slashes becomes search syntax
# — "acme/widgets is:draft" sweeps an empty set and exits 0 in silence.
case "$GH_REPO" in
  */*/*|/*|*/) echo "::error::merged-sweep: GH_REPO must be OWNER/REPO (got '$GH_REPO')" >&2; exit 2 ;;
  *[!A-Za-z0-9._/-]*)
    echo "::error::merged-sweep: GH_REPO may hold only letters, digits, '.', '_' and '-' either side of the slash (got '$GH_REPO'); it is spliced into a search query, where a space or a qualifier would silently change the set swept" >&2
    exit 2 ;;
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

# GraphQL rejects first:0, and the upper bound is MEASURED, not the API's:
# print_usage carries the figures, the date and the repo they came from.
# Both bounds are refused, never clamped — a clamp would sweep a different
# set than the operator asked for, and the saturation row below is what
# reports a window one page cannot cover.
LIMIT_MAX=80
if [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt "$LIMIT_MAX" ]; then
  echo "::error::merged-sweep: --limit must be between 1 and $LIMIT_MAX (got $LIMIT)" >&2
  exit 2
fi

# --- state --------------------------------------------------------------
# One file per repo, the same shape oversee-watch keeps for PW_SEEN: the
# keys of the previous pass, one per line, replaced atomically. Anchored on
# the REPOSITORY ROOT, never the process cwd, as oversee-watch anchors its
# equivalent — a poll loop that changed directory would otherwise start
# from an empty baseline and re-announce everything with nothing said.
SETTING_HINT="set REVIEW_GATE_MERGED_SWEEP_STATE_DIR, pass --state-file, or pass --no-state"
if [ "$USE_STATE" = "1" ] && [ -z "$STATE_FILE" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
  # The KEY resolves from the repository root, not only the path it names:
  # rg_setting reads .env.local and the settings TOMLs as CWD-relative
  # paths, so an off-root caller finds none of them, takes the built-in
  # default, and anchors a DIFFERENT directory under the same root —
  # re-announcing every finding every pass, the failure the anchoring
  # exists to stop. One key, one anchor, on both halves.
  if [ -n "$repo_root" ]; then
    state_dir="$(cd "$repo_root" && rg_setting REVIEW_GATE_MERGED_SWEEP_STATE_DIR "tmp/review-gate-merged-sweep")" || exit 2
  else
    state_dir="$(rg_setting REVIEW_GATE_MERGED_SWEEP_STATE_DIR "tmp/review-gate-merged-sweep")" || exit 2
  fi
  if [ -z "$state_dir" ]; then
    echo "::error::merged-sweep: REVIEW_GATE_MERGED_SWEEP_STATE_DIR is explicitly empty — a state directory is required; $SETTING_HINT" >&2
    exit 2
  fi
  case "$state_dir" in
    /*) ;;
    *)
      if [ -z "$repo_root" ]; then
        echo "::error::merged-sweep: a relative state directory ($state_dir) is anchored on the repository root, and this is not a git working tree — $SETTING_HINT with an absolute path" >&2
        exit 2
      fi
      state_dir="$repo_root/$state_dir"
      ;;
  esac
  mkdir -p "$state_dir" || {
    echo "::error::merged-sweep: could not create the state directory $state_dir ($SETTING_HINT)" >&2
    exit 2
  }
  STATE_FILE="$state_dir/$(printf '%s' "$GH_REPO" | tr -c 'A-Za-z0-9._-' '_')"
fi
seen=""
if [ "$USE_STATE" = "1" ] && [ -e "$STATE_FILE" ]; then
  seen="$(cat "$STATE_FILE")" || {
    echo "::error::merged-sweep: cannot read the state file $STATE_FILE ($SETTING_HINT)" >&2
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
# comparison, not a premise; sort:updated-desc truncates at the end a late
# review has not touched. The bound needs the FULL timestamp: on
# vanillagreencom/kendex, 2026-09-01, the Z-suffixed merged:>= counted 78
# for a 48h window where the date-only form counted 95. A malformed
# qualifier degrades search to free text, so ms34 asserts what was sent.
# Nested bounds are `last:` because a post-merge review or thread comment
# is newer than every pre-merge one, so truncation hides only content that
# could neither BE a post-merge finding nor ANSWER one. reviewThreads is
# the exception: no documented ordering, so any truncation fails closed.
# repository(owner,name){id} rides along as the POSITIVE proof that the
# named repo was READ. search answers a misspelled, renamed or
# no-longer-authorized repository with issueCount 0, no errors and gh exit
# 0 — indistinguishable from a quiet window — while this field answers it
# with NOT_FOUND and a null, which both handlers below fail closed on.
query='query($owner:String!,$name:String!,$q:String!,$limit:Int!){
  repository(owner:$owner, name:$name){ id }
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

# gh's stderr is KEPT: at high --limit values GitHub answers HTTP 504, and
# a generic "could not list" sends the operator after an auth or network
# fault instead of the one knob that fixes it.
gh_err="$(mktemp)" || { echo "::error::merged-sweep: could not create a temporary file for the read" >&2; exit 2; }
raw="$(gh api graphql -f query="$query" \
    -f owner="${GH_REPO%%/*}" -f name="${GH_REPO#*/}" \
    -f q="repo:$GH_REPO is:pr is:merged sort:updated-desc merged:>=$cutoff_iso" \
    -F limit="$LIMIT" 2>"$gh_err")" || {
  echo "::error::merged-sweep: could not read $GH_REPO for merged PRs in the last ${WINDOW}s at --limit $LIMIT; the gh lines below name the cause — NOT_FOUND is a misspelled or renamed repository, or one outside this token's access, and HTTP 504 is an over-large page, so lower --limit before suspecting auth or network" >&2
  sed 's/^/::error::merged-sweep: gh: /' "$gh_err" >&2
  exit 2
}
if [ -z "$raw" ]; then
  echo "::error::merged-sweep: merged-PR listing produced zero bytes (broken read)" >&2
  exit 2
fi

# --- reduce -------------------------------------------------------------
lib_readable "$script_dir/lib/merged-sweep-reduce.sh"
# shellcheck source=lib/merged-sweep-reduce.sh
. "$script_dir/lib/merged-sweep-reduce.sh"
lib_defines "$script_dir/lib/merged-sweep-reduce.sh" MERGED_SWEEP_REDUCE_JQ

rows="$(jq -r --argjson cutoff "$cutoff" --argjson limit "$LIMIT" \
    --argjson limit_max "$LIMIT_MAX" "$MERGED_SWEEP_REDUCE_JQ" <<<"$raw" 2>/dev/null)" || {
  echo "::error::merged-sweep: merged-PR listing is malformed, or $GH_REPO could not be read (broken read, an unreadable or misspelled repository, a row without a number/head/mergedAt, or graphql errors)" >&2
  exit 2
}

# --- reduce to lines, then persist, then print ---------------------------
# Nothing reaches stdout until the state file is on disk. Exit 2 is the
# GLOBAL failure shape and consumers key on it: oversee-watch's
# check_pr_watch reads a non-zero run that printed lines as findings and
# one that printed none as a hard failure, so a sweep whose state write
# failed must print nothing or its stderr is never surfaced.
attention=0
current=""
out=""
# Node ids are opaque: split them on whitespace with globbing OFF, so a
# metacharacter in a future id shape can never expand against the cwd.
set -f
while IFS=$'\t' read -r number head kind keys detail; do
  [ -n "$number" ] || continue
  if [ "$keys" = "-" ]; then
    # A standing condition, not an event: no key, so nothing marks it seen
    # and it re-emits every pass while it holds. That is what makes "narrow
    # --window until the line stops" a usable instruction instead of one
    # that appears to succeed on pass two.
    new=1
  else
    new=0
    for key in $keys; do
      current="$current$key"$'\n'
      if [ "$USE_STATE" = "0" ]; then
        new=1
      elif ! grep -qxF -- "$key" <<<"$seen"; then
        new=1
      fi
    done
  fi
  [ "$new" = "1" ] || continue
  out="$out$(printf '%s\t%s\t%s\t%s' "$number" "$head" "$kind" "$detail")"$'\n'
  attention=1
done <<<"$rows"
set +f

if [ "$USE_STATE" = "1" ]; then
  state_tmp="$STATE_FILE.$$.tmp"
  { printf '%s' "$current" > "$state_tmp" && mv -f "$state_tmp" "$STATE_FILE"; } || {
    echo "::error::merged-sweep: could not write the state file $STATE_FILE ($SETTING_HINT)" >&2
    exit 2
  }
  state_tmp=""
fi

[ -z "$out" ] || printf '%s' "$out"

if [ "$attention" = "1" ]; then exit 1; fi
exit 0
