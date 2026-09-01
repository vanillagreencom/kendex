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
# shellcheck source=lib/settings.sh
. "$script_dir/lib/settings.sh"

# Both scratch paths are removed on ANY exit, including a signal: an
# interrupted pass must not leave a half-written state file beside the real
# one, nor the read'"'"'s stderr capture in the temp dir.
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
                     max 40). The ceiling is where the query still
                     completes, not where GraphQL stops counting: measured
                     on a busy repo, 40 answers in ~4s and 80 returns HTTP
                     504. A window holding more than this is itself a
                     fail-closed line, never silence over the remainder
  --no-state         report every current finding, deduping nothing — the
                     audit form; the sweep writes no state file
  --state-file PATH  override the per-repo state file (default:
                     <state-dir>/<repo-slug>, the state dir being
                     REVIEW_GATE_MERGED_SWEEP_STATE_DIR, itself defaulting
                     to tmp/review-gate-merged-sweep). A relative state dir
                     is anchored on the REPOSITORY ROOT, not the cwd, so a
                     caller that changes directory between passes keeps its
                     baseline. GITIGNORE it: the default writes inside the
                     repository

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
Settings: REVIEW_GATE_MERGED_SWEEP_STATE_DIR — the directory holding the
per-repo state files, resolved like every other engine key (env >
.env.local > .kendex/settings.toml > kendex.settings.toml > the built-in
tmp/review-gate-merged-sweep).
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
# keys of the previous pass, one per line, replaced atomically. The path is
# anchored on the REPOSITORY ROOT, never the process cwd — oversee-watch
# anchors its equivalent the same way, and a poll loop that changed
# directory between passes would otherwise start from an empty baseline and
# re-announce every outstanding finding as news with nothing said.
SETTING_HINT="set REVIEW_GATE_MERGED_SWEEP_STATE_DIR, pass --state-file, or pass --no-state"
if [ "$USE_STATE" = "1" ] && [ -z "$STATE_FILE" ]; then
  state_dir="$(rg_setting REVIEW_GATE_MERGED_SWEEP_STATE_DIR "tmp/review-gate-merged-sweep")" || exit 2
  if [ -z "$state_dir" ]; then
    echo "::error::merged-sweep: REVIEW_GATE_MERGED_SWEEP_STATE_DIR is explicitly empty — a state directory is required; $SETTING_HINT" >&2
    exit 2
  fi
  case "$state_dir" in
    /*) ;;
    *)
      repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
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
# shellcheck source=lib/merged-sweep-reduce.sh
. "$script_dir/lib/merged-sweep-reduce.sh"

rows="$(jq -r --argjson cutoff "$cutoff" --argjson limit "$LIMIT" \
    --argjson limit_max "$LIMIT_MAX" "$MERGED_SWEEP_REDUCE_JQ" <<<"$raw" 2>/dev/null)" || {
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
