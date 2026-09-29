#!/usr/bin/env bash
# pr-watch — reduce every open PR to normalized needs-attention lines, each
# read from GitHub's own review state: unresolved review threads, the pull
# request's reviewDecision, its auto-merge arm and its merge-queue entry. A PR
# sitting steadily over an open thread TRANSITIONS NOTHING, so a watcher keyed
# on state transitions idles for hours over a thread posted minutes after its
# last pass; this reducer reports the standing state on every call.
# The authoritative contract — attention kinds, output format, exit
# codes, env — is print_usage below: run with --help.
# Stdout is the whole-text attention protocol consumed by orch oversee-watch
# and lane-close: PR number, head prefix, kind, and detail separated by
# literal tabs. The detail includes the queue and submit-size annotations.
# Preserve these payloads.
# Global refusals use diagnostic records on stderr, followed by explanation.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -r "$script_dir/lib/diagnostics.sh" ]; then
  printf 'review-gate-error=diagnostics-load value=%q\n%s\n' "$script_dir/lib/diagnostics.sh" 'Could not load the diagnostics library.' >&2
  exit 2
fi
. "$script_dir/lib/diagnostics.sh" 2>/dev/null || {
  printf 'review-gate-error=diagnostics-load value=%q\n%s\n' "$script_dir/lib/diagnostics.sh" 'Could not load the diagnostics library.' >&2
  exit 2
}
# shellcheck source=lib/settings.sh
. "$script_dir/lib/settings.sh"

print_usage() {
  cat <<'USAGE'
Usage: pr-watch.sh [PR# ...] [--awaiting-after SECS]

Reduce every open PR to normalized needs-attention lines, read from GitHub's
review state alone: unresolved review threads, the PR's reviewDecision, its
auto-merge arm and its merge-queue entry. One invocation answers: does any
open PR need attention RIGHT NOW?

  PR# ...            watch only these PRs (default: every open PR)
  --awaiting-after S override the awaiting-stale threshold (default: the
                     PR_REVIEW_WAIT_SECS setting, else 900)

Attention kinds:
  threads-open       unresolved review threads, which the base branch's
                     thread rule holds the merge on. Counted across pages
                     (bound: 20 pages / 2000 threads); past the bound, or on
                     pagination metadata that cannot advance, the count
                     fails CLOSED as attention. QUEUED PRs are annotated — a
                     queued PR needs a DEQUEUE before any fix push; GitHub
                     rejects pushes to queued branches. While a thread
                     stands, the PR reports neither disarmed nor
                     awaiting-stale: answering the thread comes first
  changes-requested  reviewDecision CHANGES_REQUESTED: a standing objection
                     holds the merge. Reported beside threads-open
  disarmed           reviewDecision APPROVED on an open, un-queued,
                     non-draft PR with auto-merge NOT armed — nothing will
                     merge it (the known eviction-disarm failure mode). The
                     line also carries the size orch's branch-size-check
                     recorded for this head branch at submit (workflow state
                     `pr.size_check`): the production lines it added, the
                     allowance the issue stated and the ratio between them,
                     and the head it measured. A record of any other head
                     reads `stale`, and no record at all `unavailable`. A
                     verdict other than pass is named, so a branch over its
                     test allowance is not read off a passing production
                     ratio — read only, never re-measured, refusing nothing
  awaiting-stale     reviewDecision REVIEW_REQUIRED and the head has sat
                     unapproved longer than the quiet period
                     (PR_REVIEW_WAIT_SECS, default 900), counted from the
                     newest of the head commit, the PR's creation, and a
                     ready-for-review, reopen or re-review-request event.
                     Drafts are never reported. Time for a re-review trigger
                     or the fallback approval
  head-moved         the head changed while this PR was being reduced —
                     the findings (or the silence) describe the OLD head;
                     re-run. Attention, not an error: the race is
                     ordinary, the response is one more poll
  error              this PR could not be reduced (a read failed or
                     answered malformed data) — fail LOUD, never silently
                     skipped

REVIEW_REQUIRED inside the quiet period, and an approved PR with auto-merge
armed or queued, are healthy states and emit NOTHING — silence on stdout
means "nothing needs you", which is what makes the exit code a cheap
loop/cron predicate.

A null reviewDecision, which GitHub answers on a base no approval rule
targets (a stacked PR's base among them), is not an approval: that PR gets
neither a disarmed nor an awaiting-stale line.

Output: one tab-separated line per finding on stdout:
  <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>

Exit codes:
  0  nothing needs attention
  1  at least one attention line
  2  read failure, in two shapes: per-PR failures carry `error` lines on
     stdout (attention lines may also be present), while GLOBAL failures
     (missing GH_REPO, a broken open-PR listing) report on stderr only
     with no per-PR lines — surface stderr, not just stdout

Env (required): GH_TOKEN (or ambient gh auth), GH_REPO
Env (optional): ORCH_STATE_DIR — where the disarmed line reads the submit
size record from, else tmp/ under the working directory. That is the
environment fallback orch's workflow-state honours; its --state-dir flag has
no equivalent here, so a record written under one reads unavailable. The
record is found by its own branch name, so one directory serving a fleet can
match a same-named branch in another repo — the head binding then reads that
record stale rather than as this PR's size

Consumers: orch's workflows treat this as the single state reducer for
multi-PR watching (orch's approval-wait remains the single-PR foreground
wait with on-timeout policy; orch's oversee consumes it through
oversee-watch, and lane-close reads its silence before a park); harness
wake-up mechanisms (a monitor loop, cron, a scheduler) wrap it in a few
lines instead of re-deriving state keys per session — the wrap-in-anything
loop lives in references/adoption.md.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) print_usage; exit 0 ;;
  esac
done

if [ -z "${GH_REPO:-}" ]; then
  rg_message error watch-repo-missing "${GH_REPO:-}" "::error::pr-watch: GH_REPO is required" >&2
  exit 2
fi

AWAITING_AFTER=""
PR_ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --awaiting-after)
      shift
      AWAITING_AFTER="${1:-}"
      case "$AWAITING_AFTER" in
        ''|*[!0-9]*) rg_message error watch-wait-invalid "$AWAITING_AFTER" "::error::pr-watch: --awaiting-after needs a positive integer" >&2; exit 2 ;;
      esac
      # Same bound as the settings path: past Bash's integer range the later
      # [ -gt ] comparisons fail silently inside their ifs. Leading zeros
      # are stripped first so a zero-padded fixed-width value is judged by
      # its numeric magnitude, not its character count.
      AWAITING_AFTER="$(printf '%s' "$AWAITING_AFTER" | sed 's/^0*//')"
      [ -z "$AWAITING_AFTER" ] && AWAITING_AFTER=0
      if [ "${#AWAITING_AFTER}" -gt 9 ]; then
        rg_message error watch-wait-range "$AWAITING_AFTER" "::error::pr-watch: --awaiting-after is out of range (max 9 digits)" >&2
        exit 2
      fi
      ;;
    -*) rg_message error watch-flag-unknown "$1" "::error::pr-watch: unknown flag $1" >&2; exit 2 ;;
    *)
      case "$1" in
        ''|*[!0-9]*) rg_message error watch-pr-invalid "$1" "::error::pr-watch: PR arguments must be numbers (got '$1')" >&2; exit 2 ;;
      esac
      # Base-10 normalization: a zero-padded "09" is not valid JSON for the
      # --argjson binding check downstream.
      PR_ARGS="$PR_ARGS $((10#$1))"
      ;;
  esac
  shift
done

if [ -z "$AWAITING_AFTER" ]; then
  AWAITING_AFTER="$(rg_setting PR_REVIEW_WAIT_SECS "900")" || exit 2
  # Fail-loud, same as --awaiting-after: a typo ("90s") must never silently
  # become the 900 default — a silent fallback CHANGES the review-silence
  # policy the operator thinks they set. Digit-only AND bounded: a digit
  # string beyond Bash's integer range (e.g. 20 digits) passes a pure [!0-9]
  # check but then errors inside the later [ -gt ] comparisons — swallowed by
  # the if, silently disabling the awaiting-stale alert. 9 digits (~31 years)
  # is bound enough.
  case "$AWAITING_AFTER" in
    ''|*[!0-9]*)
      rg_message error watch-wait-setting-invalid "$AWAITING_AFTER" "::error::pr-watch: PR_REVIEW_WAIT_SECS must be a non-negative integer, got '$AWAITING_AFTER'" >&2
      exit 2
      ;;
  esac
  AWAITING_AFTER="$(printf '%s' "$AWAITING_AFTER" | sed 's/^0*//')"
  [ -z "$AWAITING_AFTER" ] && AWAITING_AFTER=0
  if [ "${#AWAITING_AFTER}" -gt 9 ]; then
    rg_message error watch-wait-setting-range "$AWAITING_AFTER" "::error::pr-watch: PR_REVIEW_WAIT_SECS is out of range (max 9 digits), got '$AWAITING_AFTER'" >&2
    exit 2
  fi
fi
# Read as the file orch's schema documents, not through orch's own
# workflow-state CLI: orch calls this reducer, so calling back would close a
# loop, and a PR is not the issue key that CLI addresses state by.
SIZE_STATE_DIR="${ORCH_STATE_DIR:-tmp}"

attention=0
errored=0

emit() { # pr, head, kind, detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$(printf %.8s "$2")" "$3" "$4"
  emitted_this_pr=1
}

# The size the reader needs BEFORE arming, read and never re-measured: an
# oversized branch is refused at submit, and refusing it again here would be
# one rule in two tools. The kinds block above is the output contract.
#
# Every failure lands on stale or unavailable — an absent state directory, a
# head branch the PR object did not carry, an unreadable file — because this
# annotation informs a line that already stands, and a local state file must
# never turn a real disarmed finding into an error.
size_note() { # branch, head -> the annotation, prefixed for the detail
  local branch="$1" head="$2" note="" file
  local files=()
  if [ -n "$branch" ]; then
    for file in "$SIZE_STATE_DIR"/workflow-state-*.json; do
      if [ -f "$file" ]; then files+=("$file"); fi
    done
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    note="size unavailable: no submit measurement is recorded for this branch"
  else
    note="$(jq -rs --arg branch "$branch" --arg head "$head" '
        def pct($n; $d): (($n * 100) / $d | floor);
        map(select(type == "object" and (.branch? // "") == $branch
                   and ((.pr?.size_check? | type) == "object"))
            | .pr.size_check
            | select((.head_sha? | type) == "string"
                     and (.production_lines? | type) == "number")) as $records
        | ($records | map(select(.head_sha == $head)) | first) as $current
        | if $current != null then
            "size "
            + (if ($current.production_allowance | type) == "number"
               then "\($current.production_lines) of \($current.production_allowance) production lines added"
                    + (if $current.production_allowance > 0
                       then " (\(pct($current.production_lines; $current.production_allowance))% of the allowance)"
                       else "" end)
               else "\($current.production_lines) production lines added, no allowance stated"
               end)
            + ", measured at \($current.head_sha[0:8])"
            + (($current.verdict? // "") as $v
               | if ($v | type) == "string" and $v != "" and $v != "pass"
                    and $v != "allowance_missing"
                 then ", submit recorded \($v)" else "" end)
          elif ($records | length) > 0 then
            "size stale: the recorded measurement is of \($records[0].head_sha[0:8]), not this head"
          else
            "size unavailable: no submit measurement is recorded for this branch"
          end' "${files[@]}" 2>/dev/null)" \
      || note=""
  fi
  [ -n "$note" ] || note="size unavailable: the recorded measurement could not be read"
  printf ' — %s' "$note"
}


# Queue membership and GitHub's review decision, in one read. The answer is
# two words: queued or unqueued, then APPROVED, CHANGES_REQUESTED,
# REVIEW_REQUIRED, or NONE for a null reviewDecision, which GitHub answers on
# a base no approval rule targets. GraphQL errors, a missing field, or a value outside
# either enum is a malformed read, never an unqueued or unreviewed PR: read
# as unqueued it would print a false disarmed line and drop the dequeue note.
REVIEW_STATE_QUERY='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){isInMergeQueue mergeQueueEntry{position} reviewDecision}}}'
REVIEW_STATE_JQ='if ((.errors? // []) | length) > 0 then error("graphql errors present")
  else .data.repository.pullRequest as $p
  | if ($p | type) != "object"
       or (($p.isInMergeQueue | type) != "boolean")
       or ((($p.mergeQueueEntry | type) != "null") and (($p.mergeQueueEntry | type) != "object"))
       or (($p | has("reviewDecision")) | not)
       or ((($p.reviewDecision | type) != "null")
           and (($p.reviewDecision | IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED")) | not))
    then error("malformed review-state envelope")
    else (if $p.isInMergeQueue or ($p.mergeQueueEntry != null) then "queued" else "unqueued" end)
         + " " + ($p.reviewDecision // "NONE")
    end
  end'

read_review_state() { # pr, head, what — sets queued (the annotation) and decision; returns 1 after emitting an error
  local resp words queue_word
  resp="$(gh api graphql -f query="$REVIEW_STATE_QUERY" \
      -f owner="${GH_REPO%%/*}" -f name="${GH_REPO#*/}" -F number="$1" 2>/dev/null)" || {
    emit "$1" "$2" error "$3 failed"
    errored=1
    return 1
  }
  if [ -z "$resp" ]; then
    emit "$1" "$2" error "$3 produced zero bytes (broken read)"
    errored=1
    return 1
  fi
  words="$(jq -r "$REVIEW_STATE_JQ" <<<"$resp" 2>/dev/null)" || {
    emit "$1" "$2" error "$3 is malformed (GraphQL errors, a missing field, or a value outside the queue or reviewDecision enums)"
    errored=1
    return 1
  }
  queue_word="${words%% *}"
  decision="${words#* }"
  case "$queue_word" in
    queued) queued=" (QUEUED: dequeue before pushing)" ;;
    unqueued) queued="" ;;
    *)
      emit "$1" "$2" error "$3 produced no usable sentinel (broken read)"
      errored=1
      return 1
      ;;
  esac
  return 0
}
# An ISO-8601 UTC timestamp as epoch seconds; non-zero when it does not parse.
# date -d is GNU; BSD/macOS uses -u -j -f (the -u is load-bearing: the
# trailing Z is a LITERAL in this format string, so without -u BSD date reads
# the timestamp in the machine's local zone and the silence clock shifts by
# the UTC offset in either direction).
to_epoch() { # timestamp
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

# Whether the decision read last is an approval. NONE is not: a base no
# approval rule targets, such as a stacked PR's, reads null before any
# review, so counting it as met would nudge an unreviewed PR to arm.
classify_decision() { # pr, head, where — sets review_met; returns 1 after emitting an error
  case "$decision" in
    APPROVED) review_met=1 ;;
    NONE|CHANGES_REQUESTED|REVIEW_REQUIRED) review_met=0 ;;
    *)
      emit "$1" "$2" error "reviewDecision '$decision' reached the $3 unhandled — read_review_state admits only APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED and NONE"
      errored=1
      return 1
      ;;
  esac
  return 0
}

# --- enumerate ----------------------------------------------------------
# Enumeration yields PR NUMBERS ONLY; every PR object is fetched FRESH at
# reduction time. A snapshot row would be a TOCTOU hazard: a push between
# the listing and this PR's reduction would leave the loop evaluating an
# old head (and old auto-merge state) while the queue/thread reads observe
# the replacement — an approved OLD head reading as healthy right after an
# unreviewed push. A zero-byte or non-array page is a broken read, never an
# empty repo.
if [ -n "$PR_ARGS" ]; then
  pr_numbers="$PR_ARGS"
else
  raw_prs="$(gh api "repos/$GH_REPO/pulls?state=open&per_page=100" --paginate)" || {
    rg_message error watch-list-failed "$GH_REPO" "::error::pr-watch: could not list open PRs" >&2
    exit 2
  }
  if [ -z "$raw_prs" ]; then
    rg_message error watch-list-empty "$GH_REPO" "::error::pr-watch: open-PR listing produced zero bytes (broken read)" >&2
    exit 2
  fi
  pr_numbers="$(jq -rs 'if (length > 0) and all(type == "array")
      then (add | map(if (.number | type) != "number" then error("row without a number") else .number end) | join(" "))
      else error("not an array page") end' <<<"$raw_prs" 2>/dev/null)" || {
    rg_message error watch-list-malformed "$GH_REPO" "::error::pr-watch: open-PR listing pages are malformed (broken read or a row without a number)" >&2
    exit 2
  }
fi

# --- per-PR reduction ---------------------------------------------------
for number in $pr_numbers; do
  emitted_this_pr=0
  row="$(gh api "repos/$GH_REPO/pulls/$number" 2>/dev/null)" || {
    emit "$number" "--------" error "could not read PR #$number"
    errored=1
    continue
  }
  if ! jq -e --argjson n "$number" 'type == "object" and .number == $n
      and (((.head.sha? // null) | type) == "string" and (.head.sha | test("^[0-9a-fA-F]{40}$")))
      and ((.state? // null) | type) == "string"
      and (has("draft") and (.draft | type) == "boolean")
      and (has("auto_merge") and ((.auto_merge | type) == "null" or ((.auto_merge | type) == "object" and ((.auto_merge.merge_method? // null) | type) == "string")))
      and ((.created_at? // null) | type) == "string"' >/dev/null 2>&1 <<<"$row"; then
    emit "$number" "--------" error "PR #$number response is not a well-formed PR object (broken read)"
    errored=1
    continue
  fi
  head="$(jq -r '.head.sha' <<<"$row")"
  state="$(jq -r '.state' <<<"$row")"
  draft="$(jq -r '.draft | tostring' <<<"$row")"
  armed="$(jq -r 'if .auto_merge == null then "false" else "true" end' <<<"$row")"
  created_at="$(jq -r '.created_at' <<<"$row")"
  # The head branch keys the size record below and nothing else, so it is
  # NOT part of the well-formed check above: a row without it annotates as
  # unavailable, the same answer a repo running no orch lane gets.
  head_ref="$(jq -r '.head.ref // ""' <<<"$row")"
  # Closed/merged PRs need nothing (reachable via explicit PR args). The
  # REST enum is open|closed — anything else is malformed data, and a
  # malformed state must never read as "closed, skip silently".
  case "$state" in
    open) ;;
    closed) continue ;;
    *)
      emit "$number" "$head" error "PR state '$state' is outside the open|closed enum (malformed response)"
      errored=1
      continue
      ;;
  esac

  # Pushes to a queued PR's branch are rejected, so every attention line on
  # a queued PR carries the queue annotation this read sets.
  read_review_state "$number" "$head" "review-state read" || continue

  # Thread transitions have no webhook anywhere, which is the watcher's whole
  # reason to exist. The count PAGINATES (long-lived PRs accumulate hundreds
  # of RESOLVED threads; failing closed at 100 total made attention permanent
  # regardless of unresolved count) — the fail-closed overflow posture starts
  # at the 20-page/2000-thread bound, or at a truthy hasNextPage whose cursor
  # cannot advance.
  unresolved=0
  overflow=false
  t_cursor=""
  t_pages=0
  t_error=""
  while :; do
    t_pages=$((t_pages + 1))
    if [ "$t_pages" -gt 20 ]; then
      overflow=true
      break
    fi
    # The cursor rides a proper GraphQL VARIABLE, never string
    # interpolation — an opaque cursor must not be able to break query
    # syntax. $after:String is nullable: on the first page it is simply
    # not passed and resolves to null (page one).
    if [ -n "$t_cursor" ]; then
      threads_resp="$(gh api graphql \
        -f query='query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
        -f owner="${GH_REPO%%/*}" -f name="${GH_REPO#*/}" -F number="$number" -f after="$t_cursor" 2>/dev/null)" || {
        t_error="thread read failed"
        break
      }
    else
      threads_resp="$(gh api graphql \
        -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
        -f owner="${GH_REPO%%/*}" -f name="${GH_REPO#*/}" -F number="$number" 2>/dev/null)" || {
        t_error="thread read failed"
        break
      }
    fi
    if [ -z "$threads_resp" ]; then
      t_error="thread read produced zero bytes (broken read)"
      break
    fi
    # A node whose isResolved is not a boolean (or a non-boolean
    # hasNextPage) is a malformed response — counting it as resolved would
    # report health from untrustworthy data.
    page_unresolved="$(jq -r 'if ((.errors? // []) | length) > 0 then error("graphql errors present")
        elif (.data.repository.pullRequest.reviewThreads | type) != "object"
           or (.data.repository.pullRequest.reviewThreads.nodes | type) != "array"
        then error("malformed thread container")
        elif ([.data.repository.pullRequest.reviewThreads.nodes[] | select((.isResolved | type) != "boolean")] | length) > 0
        then error("malformed thread node")
        else [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length end' <<<"$threads_resp" 2>/dev/null)" || {
      t_error="thread response malformed (non-boolean isResolved) or unparsable"
      break
    }
    page_next="$(jq -r 'if (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type) != "boolean"
        then error("malformed pageInfo")
        else .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage end' <<<"$threads_resp" 2>/dev/null)" || {
      t_error="thread pagination metadata malformed (non-boolean hasNextPage)"
      break
    }
    unresolved=$((unresolved + page_unresolved))
    [ "$page_next" = "true" ] || break
    t_cursor_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' <<<"$threads_resp" 2>/dev/null)"
    if [ -z "$t_cursor_next" ] || [ "$t_cursor_next" = "$t_cursor" ]; then
      # hasNextPage with no ADVANCING cursor (missing, or identical to the
      # page just read): cannot verify the remainder — fail closed as
      # overflow immediately instead of burning the page budget on
      # re-reads of the same page.
      overflow=true
      break
    fi
    t_cursor="$t_cursor_next"
  done
  if [ -n "$t_error" ]; then
    emit "$number" "$head" error "$t_error"
    errored=1
    continue
  fi
  threads_open=0
  if [ "$overflow" = "true" ] || [ "$unresolved" -gt 0 ]; then
    if [ "$overflow" = "true" ]; then
      emit "$number" "$head" threads-open "review threads beyond the pagination bound (count overflow — fail closed)$queued"
    else
      emit "$number" "$head" threads-open "$unresolved unresolved review thread(s)$queued"
    fi
    attention=1
    threads_open=1
  fi

  # GitHub's reviewDecision is the review verdict: the base's rules count the
  # approvals, dismiss a stale one on push and name a standing objection. One
  # line PER FINDING: open threads do not suppress an objection.
  if [ "$decision" = "CHANGES_REQUESTED" ]; then
    emit "$number" "$head" changes-requested "a reviewer requested changes (reviewDecision CHANGES_REQUESTED)$queued"
    attention=1
    continue
  fi
  # An open thread holds the merge under the base's thread rule, so neither
  # a re-arm nudge nor a stale-review nudge applies until it is answered.
  if [ "$threads_open" = "1" ]; then
    continue
  fi
  classify_decision "$number" "$head" reduction || continue

  # Disarmed: an approved, un-queued, non-draft PR with auto-merge unarmed is
  # mergeable, but nothing will merge it. Ownership and the decision are
  # re-read JUST-IN-TIME (auto-merge, queue membership and the approval all
  # move during a reduction — a queue ejection mid-reduction must not read
  # healthy, and a concurrent arm must not false-alert).
  if [ "$review_met" = "1" ] && [ "$draft" != "true" ]; then
    ownership_row="$(gh api "repos/$GH_REPO/pulls/$number" 2>/dev/null)" || {
      emit "$number" "$head" error "auto-merge recheck failed (broken read)"
      errored=1
      continue
    }
    # Same schema discipline as the initial fetch: auto_merge must be
    # null|object (a missing field is null in jq and would silently coerce
    # to unarmed — a false disarmed from a broken envelope), and the row
    # must still describe THE SAME HEAD (a push mid-reduction cleared
    # auto-merge on a new head; recommending re-arm against stale reads
    # would arm an unreviewed head).
    if ! jq -e --argjson n "$number" 'type == "object" and .number == $n
        and (has("auto_merge"))
        and ((.auto_merge | type) == "null" or ((.auto_merge | type) == "object" and ((.auto_merge.merge_method? // null) | type) == "string"))
        and ((.state? // null) == "open" or (.state? // null) == "closed")
        and ((.draft | type) == "boolean")
        and (((.head.sha? // null) | type) == "string" and (.head.sha | test("^[0-9a-fA-F]{40}$")))' >/dev/null 2>&1 <<<"$ownership_row"; then
      emit "$number" "$head" error "auto-merge recheck returned a malformed PR object (broken read)"
      errored=1
      continue
    fi
    # A PR that closed or merged mid-reduction needs nothing — never a
    # re-arm nudge for a completed PR; drafts likewise re-load (a PR
    # converted to draft mid-reduction stopped being re-armable).
    if [ "$(jq -r '.state' <<<"$ownership_row")" != "open" ]; then
      continue
    fi
    draft="$(jq -r '.draft | tostring' <<<"$ownership_row")"
    ownership_head="$(jq -r '.head.sha' <<<"$ownership_row")"
    if [ "$ownership_head" != "$head" ]; then
      emit "$number" "$head" head-moved "the head changed during this reduction (now $(printf %.8s "$ownership_head")) — findings describe the old head; re-run"
      attention=1
      continue
    fi
    armed="$(jq -r 'if .auto_merge == null then "false" else "true" end' <<<"$ownership_row")"
    read_review_state "$number" "$head" "review-state recheck" || continue
    classify_decision "$number" "$head" recheck || continue
    if [ "$review_met" = "1" ] && [ "$armed" = "false" ] && [ -z "$queued" ] && [ "$draft" != "true" ]; then
      emit "$number" "$head" disarmed "approved (reviewDecision APPROVED) but auto-merge is not armed and the PR is not queued — nothing will merge this (re-arm)$(size_note "$head_ref" "$head")"
      attention=1
    fi
  fi

  # Awaiting-stale: no approval of this head within the quiet period. Drafts
  # are not awaiting REVIEW — they are awaiting readiness: the silence clock
  # skips them, or a long-lived draft pins the watcher at exit 1 asking for
  # re-reviews nobody owes it.
  if [ "$decision" = "REVIEW_REQUIRED" ] && [ "$draft" != "true" ]; then
    # Quiet-period clock: reviewer silence counts from when this head
    # BECAME the head. GitHub exposes no head-transition timestamp, so
    # the approximation is max(head commit's committer date, PR
    # created_at) — the PR floor covers a cherry-picked or long-prepared
    # commit landing in a freshly opened PR (its commit date can be days
    # old); a future-dated commit clamps to "not stale yet" rather than
    # "stale forever" because the age simply goes negative. A push of an
    # OLD commit onto an old PR still reads stale early — accepted:
    # over-reporting silence errs toward a nudge, never toward a stall.
    head_at="$(gh api "repos/$GH_REPO/commits/$head" --jq '.commit.committer.date' 2>/dev/null)" || {
      emit "$number" "$head" error "head-commit read failed"
      errored=1
      continue
    }
    case "$head_at" in
      ''|null)
        emit "$number" "$head" error "head commit has no usable committer date (broken read)"
        errored=1
        continue
        ;;
    esac
    head_epoch="$(to_epoch "$head_at")" || head_epoch=""
    if [ -z "$head_epoch" ]; then
      emit "$number" "$head" error "head committer date unparsable (broken read) — the silence clock never substitutes the creation time for broken head metadata"
      errored=1
      continue
    fi
    created_epoch=""
    if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
      created_epoch="$(to_epoch "$created_at")" || created_epoch=""
      if [ -z "$created_epoch" ]; then
        emit "$number" "$head" error "PR creation timestamp unparsable (broken read) — the silence floor cannot be computed"
        errored=1
        continue
      fi
    fi
    if [ -n "$created_epoch" ] && { [ -z "$head_epoch" ] || [ "$created_epoch" -gt "$head_epoch" ]; }; then
      head_epoch="$created_epoch"
    fi
    if [ -n "$head_epoch" ]; then
      age=$(( $(date +%s) - head_epoch ))
      # The committer timestamp is AUTHOR-CONTROLLED: a future-dated head
      # would keep age negative and read healthy forever — the exact
      # stall this reducer exists to prevent. Beyond a small skew
      # allowance it is a loud error, never silence. (created_at is
      # server-stamped, so the floor above cannot be forged forward past
      # real PR creation.)
      if [ "$age" -lt -300 ]; then
        emit "$number" "$head" error "silence clock is in the future by $(( -age ))s (author-controlled committer timestamp) — silence age unprovable"
        errored=1
      elif [ "$age" -gt "$AWAITING_AFTER" ]; then
        # A draft marked ready keeps its old commit/creation timestamps,
        # so the first post-readiness poll would read stale instantly.
        # The readiness event is the true start of the review wait —
        # consulted only when the cheap clock already says stale (one
        # timeline read per would-be-stale PR, not per poll).
        timeline_pages="$(gh api "repos/$GH_REPO/issues/$number/timeline?per_page=100" --paginate \
            -H "Accept: application/vnd.github+json" 2>/dev/null)" || {
          emit "$number" "$head" error "timeline read failed while confirming staleness (fail loud, not a stale alert)"
          errored=1
          continue
        }
        if [ -z "$timeline_pages" ]; then
          emit "$number" "$head" error "timeline read produced zero bytes while confirming staleness (broken read)"
          errored=1
          continue
        fi
        # The reviewable period restarts at readiness, at reopening, AND
        # at a re-review request (the exact action the awaiting-stale
        # line recommends — without this floor the next poll would nudge
        # again immediately, forever) — each marks "the review wait
        # started over" without a new head.
        # A matching event whose created_at is not a string is malformed
        # data, not an ignorable row (fail loud, never a stale alert
        # from untrustworthy input).
        ready_at="$(jq -rs 'if (length > 0) and all(type == "array")
            then ([.[] | .[] | select((.event? == "ready_for_review") or (.event? == "reopened") or (.event? == "review_requested"))
                   | if (.created_at | type) != "string" then error("event without a timestamp") else .created_at end]
                  | sort | last // "")
            else error("not a timeline page") end' <<<"$timeline_pages" 2>/dev/null)" || {
          emit "$number" "$head" error "timeline pages malformed while confirming staleness (fail loud, not a stale alert)"
          errored=1
          continue
        }
        if [ -n "$ready_at" ] && [ "$ready_at" != "null" ]; then
          ready_epoch="$(to_epoch "$ready_at")" || ready_epoch=""
          if [ -z "$ready_epoch" ]; then
            emit "$number" "$head" error "readiness/reopen timestamp unparsable while confirming staleness (fail loud, not a stale alert)"
            errored=1
            continue
          fi
          if [ "$ready_epoch" -gt "$head_epoch" ]; then
            age=$(( $(date +%s) - ready_epoch ))
            # Same skew rule as the head clock: a future-dated event must
            # not buy silent health until wall-clock catches up.
            if [ "$age" -lt -300 ]; then
              emit "$number" "$head" error "silence clock is in the future by $(( -age ))s (timeline event timestamp) — silence age unprovable"
              errored=1
              continue
            fi
          fi
        fi
        if [ "$age" -gt "$AWAITING_AFTER" ]; then
          # Head-bind the stale claim: a push after the initial fetch
          # would make every timestamp above describe the OLD head while
          # the new head's quiet period just began. The recheck runs
          # here (the emission below would skip the end-of-loop one).
          stale_row="$(gh api "repos/$GH_REPO/pulls/$number" 2>/dev/null)" || {
            emit "$number" "$head" error "reviewability recheck failed while confirming staleness (broken read)"
            errored=1
            continue
          }
          if ! jq -e --argjson n "$number" 'type == "object" and .number == $n
              and (((.head.sha? // null) | type) == "string" and (.head.sha | test("^[0-9a-fA-F]{40}$")))
              and ((.state? // null) == "open" or (.state? // null) == "closed")
              and (has("draft") and (.draft | type) == "boolean")' >/dev/null 2>&1 <<<"$stale_row"; then
            emit "$number" "$head" error "reviewability recheck returned a malformed PR object while confirming staleness (broken read)"
            errored=1
            continue
          fi
          # Closed or drafted mid-reduction: not awaiting review —
          # silence, per the same rules as the initial reduction.
          if [ "$(jq -r '.state' <<<"$stale_row")" != "open" ] || [ "$(jq -r '.draft' <<<"$stale_row")" = "true" ]; then
            continue
          fi
          stale_head_now="$(jq -r '.head.sha' <<<"$stale_row")" || stale_head_now=""
          if [ -z "$stale_head_now" ]; then
            emit "$number" "$head" error "reviewability recheck head could not be read while confirming staleness (broken read)"
            errored=1
            continue
          fi
          if [ "$stale_head_now" != "$head" ]; then
            emit "$number" "$head" head-moved "the head changed during this reduction (now $(printf %.8s "$stale_head_now")) — findings describe the old head; re-run"
            attention=1
            continue
          fi
          emit "$number" "$head" awaiting-stale "no approval for ${age}s (reviewDecision REVIEW_REQUIRED, quiet period ${AWAITING_AFTER}s) — trigger a re-review, or apply the fallback approval$queued"
          attention=1
        fi
      fi
    else
      # Neither timestamp parsed: silence age is unprovable, and
      # unprovable must never read as healthy (fail-loud contract).
      emit "$number" "$head" error "silence clock has no parsable timestamp (head commit and created_at both unusable) — silence age unprovable"
      errored=1
    fi
  fi

  # Final head recheck — only when this PR would otherwise report healthy:
  # a push DURING the reduction leaves every read above describing the old
  # head, and silence would claim the new, unreviewed head needs nothing.
  # A moved head is attention (re-run), never silence.
  if [ "$emitted_this_pr" = "0" ]; then
    head_now="$(gh api "repos/$GH_REPO/pulls/$number" --jq '.head.sha' 2>/dev/null)" || {
      emit "$number" "$head" error "head recheck failed (broken read)"
      errored=1
      continue
    }
    case "$head_now" in
      ''|null|*[!0-9a-fA-F]*)
        emit "$number" "$head" error "head recheck returned no usable sha (broken read)"
        errored=1
        continue
        ;;
    esac
    if [ "${#head_now}" -ne 40 ]; then
      emit "$number" "$head" error "head recheck returned a non-sha value (broken read)"
      errored=1
      continue
    fi
    if [ "$head_now" != "$head" ]; then
      emit "$number" "$head" head-moved "the head changed during this reduction (now $(printf %.8s "$head_now")) — findings describe the old head; re-run"
      attention=1
    fi
  fi
done

if [ "$errored" = "1" ]; then exit 2; fi
if [ "$attention" = "1" ]; then exit 1; fi
exit 0
