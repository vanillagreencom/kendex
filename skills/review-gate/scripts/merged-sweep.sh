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

# Every lib is SOURCED, and under set -e a missing one ends the run at
# exit 1 — the code promising attention lines — with nothing on stdout,
# which a consumer reads as "nothing to do". All fail closed at 2 instead.
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
lib_readable "$script_dir/lib/merged-sweep-usage.sh"
# shellcheck source=lib/merged-sweep-usage.sh
. "$script_dir/lib/merged-sweep-usage.sh"
lib_defines "$script_dir/lib/merged-sweep-usage.sh" print_usage

# Both scratch paths go on ANY exit, signals included: an interrupted pass
# leaves neither a half-written state file nor the read's stderr capture.
gh_err=""
state_tmp=""
cleanup() { [ -z "$gh_err" ] || rm -f -- "$gh_err"; [ -z "$state_tmp" ] || rm -f -- "$state_tmp"; }
trap cleanup EXIT

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
# Both are refused, never clamped — a clamp would sweep a different set than
# the operator asked for, and the saturation row reports what one page cannot.
LIMIT_MAX=80
if [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt "$LIMIT_MAX" ]; then
  echo "::error::merged-sweep: --limit must be between 1 and $LIMIT_MAX (got $LIMIT)" >&2
  exit 2
fi

# --- state --------------------------------------------------------------
# One file per repo, the shape oversee-watch keeps for PW_SEEN: the previous
# pass's keys, one per line, replaced atomically. Anchored on the REPOSITORY
# ROOT, never the cwd, as oversee-watch anchors its own — a poll loop that
# changed directory would otherwise re-announce everything.
SETTING_HINT="set REVIEW_GATE_MERGED_SWEEP_STATE_DIR, pass --state-file, or pass --no-state"
if [ "$USE_STATE" = "1" ] && [ -z "$STATE_FILE" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
  # The KEY resolves from the repository root, not only the path it names:
  # rg_setting reads .env.local and the settings TOMLs as CWD-relative paths,
  # so an off-root caller finds none, takes the built-in default and anchors a
  # DIFFERENT directory under the same root, re-announcing everything forever.
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
  mkdir -p -- "$state_dir" || {
    echo "::error::merged-sweep: could not create the state directory $state_dir ($SETTING_HINT)" >&2
    exit 2
  }
  # INJECTIVE. Slugging the slash to an underscore made acme/foo_bar and
  # acme_foo/bar one file, so two repos in one state dir overwrote each other
  # and a synthetic key — which, unlike a node id, repeats across repos —
  # could suppress the other's FIRST alert. %2F cannot collide: the validator
  # above accepts no percent, and every other character passes through.
  STATE_FILE="$state_dir/${GH_REPO%%/*}%2F${GH_REPO#*/}"
fi
seen=""
if [ "$USE_STATE" = "1" ] && [ -e "$STATE_FILE" ]; then
  seen="$(cat -- "$STATE_FILE")" || {
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
# review has not touched. The bound needs the FULL timestamp: measured on
# vanillagreencom/kendex 2026-09-01, the Z-suffixed merged:>= counted 78 in
# a 48h window where the date-only form counted 95. A malformed qualifier
# degrades search to free text, so ms34 asserts what was sent.
# submittedAt and publishedAt ride along because createdAt is when a review
# was STARTED: measured on a real PENDING review the same day, submittedAt
# was null while publishedAt EQUALLED createdAt, and that review's inline
# comment had publishedAt null. def at in the reduce lib resolves both.
# Nested bounds are `last:` because a post-merge review or thread comment
# is newer than every pre-merge one, so truncation hides only content that
# could neither BE a finding nor ANSWER one. reviewThreads is the
# exception: no documented ordering, so any truncation fails closed.
# repository(owner,name){id} is the POSITIVE proof the named repo was READ:
# search answers a misspelled, renamed or unauthorized repository with
# issueCount 0, no errors and gh exit 0 — a quiet window's shape — while
# this field answers NOT_FOUND and a null, which both handlers fail closed on.
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
          nodes{ id createdAt submittedAt state body author{login __typename} }
        }
        comments(last:50){
          nodes{ createdAt publishedAt body author{login __typename} }
        }
        reviewThreads(last:50){
          totalCount
          nodes{
            id
            comments(last:30){
              totalCount
              nodes{ id createdAt publishedAt body author{login __typename} }
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
# check_pr_watch reads a non-zero run that printed lines as findings and one
# that printed none as a failure, so a failed state write must print nothing.
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

# STAGE, deliver, then PUBLISH. Both orderings are required and only this
# one satisfies both: staging precedes every line, so a state failure still
# exits 2 with empty stdout, which is what check_pr_watch reads as a failure
# rather than as findings; and the baseline lands only after the lines are
# out, so a killed process or a closed pipe leaves the OLD baseline and the
# next pass repeats instead of marking undelivered findings seen forever.
if [ "$USE_STATE" = "1" ]; then
  state_tmp="$STATE_FILE.$$.tmp"
  printf '%s' "$current" > "$state_tmp" || {
    echo "::error::merged-sweep: could not write the state file $STATE_FILE ($SETTING_HINT)" >&2
    exit 2
  }
fi

if ! { [ -z "$out" ] || printf '%s' "$out"; }; then
  echo "::error::merged-sweep: could not deliver the attention lines; the baseline is unchanged, so the next pass reports them again" >&2
  exit 2
fi

if [ "$USE_STATE" = "1" ]; then
  mv -f -- "$state_tmp" "$STATE_FILE" || {
    echo "::error::merged-sweep: could not write the state file $STATE_FILE ($SETTING_HINT)" >&2
    exit 2
  }
  state_tmp=""
fi

if [ "$attention" = "1" ]; then exit 1; fi
exit 0
