#!/usr/bin/env bash
# pr-watch — reduce every open PR to normalized needs-attention lines
# (vstack#1117), the long-horizon third piece beside the predicate (one
# head's verdict) and the writer (converge the gate). Those two keep the
# GATE correct; nothing told the AGENT when a PR needs a human/agent hand.
# Sessions watching several PRs across hours hand-rolled monitors keyed on
# gate-state transitions — and a PR sitting steadily at "pending because
# review threads are open" TRANSITIONS NOTHING, so the observed failure
# mode was an agent idling for hours over a thread a reviewer posted
# minutes after its last pass.
#
# One invocation answers: does any open PR need attention RIGHT NOW?
#
#   threads-open       unresolved review threads — read DIRECTLY in both
#                      modes (never only via the predicate: a repo running
#                      REVIEW_GATE_THREADS=off gets approved verdicts with
#                      threads open, and thread transitions have no webhook
#                      anywhere — seeing them is this tool's reason to
#                      exist). Over 100 threads fails CLOSED as attention.
#                      QUEUED PRs are annotated — a queued PR needs a
#                      DEQUEUE before any fix push, GitHub rejects pushes
#                      to queued branches
#   changes-requested  a standing objection blocks the gate
#   gate-stale         the predicate says approved but the gate context's
#                      newest row is not success — the writer has not
#                      converged (event missed, cron slipped). With --heal,
#                      one writer dispatch per invocation self-heals it.
#   disarmed           gate open (success) on an un-queued PR with
#                      auto-merge NOT armed — mergeable, but nothing will
#                      merge it (the known eviction-disarm failure mode)
#   awaiting-stale     no evidence and the head has sat unreviewed longer
#                      than the quiet period (PR_REVIEW_WAIT_SECS, default
#                      900) — time for a manual re-review trigger or the
#                      caller's on-timeout policy
#   error              this PR could not be evaluated (predicate exit 2 /
#                      read failure) — fail LOUD per engine ethos, never
#                      silently skipped
#
# A verdict of awaiting inside the quiet period, and approved+success with
# auto-merge armed or queued, are healthy states and emit NOTHING — the
# contract is that silence on stdout means "nothing needs you", which is
# what makes the exit code a cheap loop/cron predicate.
#
# Output: one tab-separated line per finding on stdout:
#   <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>
# Exit: 0 = nothing needs attention; 1 = at least one attention line;
#       2 = at least one PR errored (attention lines may also be present).
#
# Usage: pr-watch.sh [PR# ...] [--no-evaluate] [--heal] [--awaiting-after SECS]
#   PR# ...            watch only these PRs (default: every open PR)
#   --no-evaluate      cheap mode: skips ONLY the predicate (the expensive
#                      multi-read evaluation) — the thread, queue, and
#                      gate-status reads still run, so threads-open and
#                      disarmed both fire; gate-stale / changes-requested /
#                      awaiting-stale need the predicate and do not
#   --heal             on gate-stale, dispatch the writer workflow once per
#                      invocation (name: PR_WATCH_WRITER_WORKFLOW, default
#                      "Review gate writer")
#   --awaiting-after S override the awaiting-stale threshold (default: the
#                      PR_REVIEW_WAIT_SECS setting, else 900)
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO
# Consumers: orch's waiters/workflows treat this as the single state
# reducer for multi-PR watching (orch's approval-wait remains the
# single-PR foreground wait with nudge/on-timeout policy); harness wake-up
# mechanisms (a monitor loop, cron, a scheduler) wrap it in a few lines
# instead of re-deriving state keys per session.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/settings.sh
. "$script_dir/lib/settings.sh"

if [ -z "${GH_REPO:-}" ]; then
  echo "::error::pr-watch: GH_REPO is required" >&2
  exit 2
fi

EVALUATE=1
HEAL=0
AWAITING_AFTER=""
PR_ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-evaluate) EVALUATE=0 ;;
    --heal) HEAL=1 ;;
    --awaiting-after)
      shift
      AWAITING_AFTER="${1:-}"
      case "$AWAITING_AFTER" in
        ''|*[!0-9]*) echo "::error::pr-watch: --awaiting-after needs a positive integer" >&2; exit 2 ;;
      esac
      ;;
    -*) echo "::error::pr-watch: unknown flag $1" >&2; exit 2 ;;
    *)
      case "$1" in
        ''|*[!0-9]*) echo "::error::pr-watch: PR arguments must be numbers (got '$1')" >&2; exit 2 ;;
      esac
      # Base-10 normalization: a zero-padded "09" is not valid JSON for the
      # --argjson binding check downstream.
      PR_ARGS="$PR_ARGS $((10#$1))"
      ;;
  esac
  shift
done

GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 2
if [ -z "$GATE_CONTEXT" ]; then
  echo "::error::pr-watch: REVIEW_GATE_CONTEXT is explicitly empty — the predicate rejects this configuration and so does the watcher (cheap mode would otherwise search for an empty context)" >&2
  exit 2
fi
THREADS_TERM="$(rg_setting REVIEW_GATE_THREADS "enforce")" || exit 2
case "$THREADS_TERM" in
  enforce|off) ;;
  *)
    echo "::error::pr-watch: invalid REVIEW_GATE_THREADS value '$THREADS_TERM' (enforce|off) — refusing to reduce against unknown enforcement semantics" >&2
    exit 2
    ;;
esac
if [ -z "$AWAITING_AFTER" ]; then
  AWAITING_AFTER="$(rg_setting PR_REVIEW_WAIT_SECS "900")" || exit 2
  case "$AWAITING_AFTER" in ''|*[!0-9]*) AWAITING_AFTER=900 ;; esac
fi
WRITER_WORKFLOW="${PR_WATCH_WRITER_WORKFLOW:-Review gate writer}"

attention=0
errored=0
healed=0

emit() { # pr, head, kind, detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$(printf %.8s "$2")" "$3" "$4"
  emitted_this_pr=1
}

heal() { # pr, head — one bounded writer dispatch ATTEMPT per invocation
  [ "$HEAL" = "1" ] || return 0
  [ "$healed" = "0" ] || return 0
  # The attempt is recorded BEFORE the outcome: during an API/workflow
  # outage a per-stale-PR retry storm would violate the once-per-invocation
  # bound the docs promise.
  healed=1
  if gh workflow run "$WRITER_WORKFLOW" --repo "$GH_REPO" >/dev/null 2>&1; then
    emit "$1" "$2" heal-dispatched "writer workflow '$WRITER_WORKFLOW' dispatched (once per invocation)"
  else
    emit "$1" "$2" error "writer dispatch failed for '$WRITER_WORKFLOW'"
    errored=1
  fi
}

# --- enumerate ----------------------------------------------------------
# Enumeration yields PR NUMBERS ONLY; every PR object is fetched FRESH at
# reduction time. A snapshot row would be a TOCTOU hazard: a push between
# the listing and this PR's reduction would leave the loop evaluating an
# old head (and old auto-merge state) while the queue/thread reads observe
# the new one — an approved green OLD head reading as healthy right after
# an unreviewed push. Same fail-loud page discipline as the writer: a
# zero-byte or non-array page is a broken read, never an empty repo.
if [ -n "$PR_ARGS" ]; then
  pr_numbers="$PR_ARGS"
else
  raw_prs="$(gh api "repos/$GH_REPO/pulls?state=open&per_page=100" --paginate)" || {
    echo "::error::pr-watch: could not list open PRs" >&2
    exit 2
  }
  if [ -z "$raw_prs" ]; then
    echo "::error::pr-watch: open-PR listing produced zero bytes (broken read)" >&2
    exit 2
  fi
  pr_numbers="$(jq -rs 'if (length > 0) and all(type == "array")
      then (add | map(if (.number | type) != "number" then error("row without a number") else .number end) | join(" "))
      else error("not an array page") end' <<<"$raw_prs" 2>/dev/null)" || {
    echo "::error::pr-watch: open-PR listing pages are malformed (broken read or a row without a number)" >&2
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
  if ! jq -e --argjson n "$number" 'type == "object" and .number == $n and ((.head.sha? // null) | type) == "string" and ((.state? // null) | type) == "string"' >/dev/null 2>&1 <<<"$row"; then
    emit "$number" "--------" error "PR #$number response is not a well-formed PR object (broken read)"
    errored=1
    continue
  fi
  head="$(jq -r '.head.sha' <<<"$row")"
  state="$(jq -r '.state' <<<"$row")"
  author="$(jq -r '.user.login // ""' <<<"$row")"
  draft="$(jq -r '.draft // false | tostring' <<<"$row")"
  armed="$(jq -r 'if .auto_merge == null then "false" else "true" end' <<<"$row")"
  created_at="$(jq -r '.created_at // ""' <<<"$row")"
  # Closed/merged PRs need nothing (reachable via explicit PR args).
  [ "$state" = "open" ] || continue

  # Queue membership: pushes to a queued PR's branch are rejected, so every
  # attention line on a queued PR carries the annotation. REQUIRED input —
  # a failed read silently treated as "not queued" would emit a false
  # disarmed finding and drop the dequeue warning, so it fails loud like
  # every other read here.
  queued="$(gh api graphql -f query="query{repository(owner:\"${GH_REPO%%/*}\",name:\"${GH_REPO#*/}\"){pullRequest(number:$number){isInMergeQueue mergeQueueEntry{position}}}}" \
      --jq 'if ((.errors? // []) | length) > 0 then error("graphql errors present")
            elif (.data.repository.pullRequest | type) != "object"
               or ((.data.repository.pullRequest.isInMergeQueue | type) != "boolean")
               or ((.data.repository.pullRequest.mergeQueueEntry | type) != "null" and (.data.repository.pullRequest.mergeQueueEntry | type) != "object")
            then error("malformed queue envelope")
            elif (.data.repository.pullRequest.isInMergeQueue or (.data.repository.pullRequest.mergeQueueEntry != null))
            then " (QUEUED: dequeue before pushing)" else "" end' 2>/dev/null)" || {
    emit "$number" "$head" error "merge-queue membership read failed or malformed"
    errored=1
    continue
  }

  # Gate context's NEWEST row (list endpoint, newest-first — the same
  # projection the predicate documents for the status surface). Fetch and
  # merge are SEPARATE steps with a zero-byte guard, the engine's required
  # pattern: a pipe would replace gh's exit status with jq's, and a
  # successful call producing zero bytes is a broken read, not an empty
  # status set (that is the two-byte page []).
  status_pages="$(gh api "repos/$GH_REPO/commits/$head/statuses?per_page=100" --paginate 2>/dev/null)" || {
    emit "$number" "$head" error "gate-status read failed"
    errored=1
    continue
  }

  if [ -z "$status_pages" ]; then
    emit "$number" "$head" error "gate-status read produced zero bytes (broken read)"
    errored=1
    continue
  fi
  gate_state="$(jq -rs --arg ctx "$GATE_CONTEXT" 'if (length > 0) and all(type == "array")
      then (add | map(select(.context == $ctx))
            | if length == 0 then "absent"
              elif (.[0].state | type) != "string" then error("row without a state")
              else .[0].state end)
      else error("not a status page") end' <<<"$status_pages" 2>/dev/null)" || {
    emit "$number" "$head" error "gate-status pages are malformed (broken read or a matching row without a state)"
    errored=1
    continue
  }

  # Threads are read DIRECTLY in BOTH modes, never only through the
  # predicate: a repo running REVIEW_GATE_THREADS=off gets `approved` from
  # the predicate with threads open (thread hygiene is server-side there),
  # and the watcher's whole reason to exist is that thread transitions have
  # no webhook — the reducer must see them regardless of the repo's
  # enforcement point. Over 100 threads fails CLOSED as attention, the same
  # posture as the predicate's own overflow.
  threads_resp="$(gh api graphql -f query="query{repository(owner:\"${GH_REPO%%/*}\",name:\"${GH_REPO#*/}\"){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}" 2>/dev/null)" || {
    emit "$number" "$head" error "thread read failed"
    errored=1
    continue
  }
  if [ -z "$threads_resp" ]; then
    emit "$number" "$head" error "thread read produced zero bytes (broken read)"
    errored=1
    continue
  fi
  # Predicate-parity validation: a node whose isResolved is not a boolean
  # (or a non-boolean hasNextPage) is a malformed response — counting it as
  # resolved would report health from untrustworthy data.
  unresolved="$(jq -r 'if ((.errors? // []) | length) > 0 then error("graphql errors present")
      elif (.data.repository.pullRequest.reviewThreads | type) != "object"
         or (.data.repository.pullRequest.reviewThreads.nodes | type) != "array"
      then error("malformed thread container")
      elif ([.data.repository.pullRequest.reviewThreads.nodes[] | select((.isResolved | type) != "boolean")] | length) > 0
      then error("malformed thread node")
      else [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length end' <<<"$threads_resp" 2>/dev/null)" || {
    emit "$number" "$head" error "thread response malformed (non-boolean isResolved) or unparsable"
    errored=1
    continue
  }
  overflow="$(jq -r 'if (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type) != "boolean"
      then error("malformed pageInfo")
      else .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage end' <<<"$threads_resp" 2>/dev/null)" || {
    emit "$number" "$head" error "thread pagination metadata malformed (non-boolean hasNextPage)"
    errored=1
    continue
  }
  if [ "$overflow" = "true" ] || [ "$unresolved" -gt 0 ]; then
    if [ "$overflow" = "true" ]; then
      emit "$number" "$head" threads-open "over 100 review threads (count overflow — fail closed)$queued"
    else
      emit "$number" "$head" threads-open "$unresolved unresolved review thread(s)$queued"
    fi
    attention=1
    threads_reported=1
    # A GREEN gate over open threads is the inverse writer miss — the
    # merge-enabling direction, so it heals, not just reports. ONLY where
    # the thread term is enforced: under REVIEW_GATE_THREADS=off a green
    # gate over open threads is the DESIGNED state (thread hygiene is the
    # server-side ruleset), and flagging it would false-alert and dispatch
    # the writer on every poll for a status it would only re-affirm.
    if [ "$THREADS_TERM" != "off" ] && [ "$gate_state" = "success" ]; then
      emit "$number" "$head" gate-stale "threads are open but the newest '$GATE_CONTEXT' row is success — the writer has not converged the withdrawal$queued"
      heal "$number" "$head"
    fi
    # One line PER FINDING: open threads must not suppress a standing
    # objection (or, under off, the disarmed nudge) — evaluation proceeds
    # and the predicate's duplicate threads-open verdict dedupes below.
  else
    threads_reported=0
  fi

  if [ "$EVALUATE" = "1" ]; then
    # Ghost authors (user: null — a deleted account) cannot be evaluated by
    # the predicate: its author-exclusion terms need a real login and it
    # exits 2 on an empty one. Name the cause instead of burning the call
    # on a generic failure — the line is the actionable finding.
    if [ -z "$author" ]; then
      emit "$number" "$head" error "PR author is a deleted account (ghost) — the predicate cannot evaluate author-exclusion terms; review and merge this PR manually"
      errored=1
      continue
    fi
    verdict_line="$(GH_REPO="$GH_REPO" PR_NUMBER="$number" HEAD_SHA="$head" PR_AUTHOR="$author" \
        "$script_dir/review-predicate.sh" 2>/dev/null)" || {
      emit "$number" "$head" error "predicate evaluation failed (exit 2 — read failure or invalid config)"
      errored=1
      continue
    }
    verdict="$(sed -n 's/^verdict=\([a-z-]*\) .*/\1/p' <<<"$verdict_line")"
    detail="$(sed -n 's/^verdict=[a-z-]* detail=//p' <<<"$verdict_line")"
    # The writer validates this same interface; an unknown or empty verdict
    # from a zero-exit predicate is a broken reducer, never a healthy PR.
    case "$verdict" in
      approved|awaiting|threads-open|changes-requested) ;;
      *)
        emit "$number" "$head" error "predicate produced no recognizable verdict (broken output)"
        errored=1
        continue
        ;;
    esac
  else
    # Cheap mode skips only the PREDICATE (the expensive multi-read
    # evaluation): threads above and the gate-status/disarmed reduction
    # below still run, so the two cheap-mode findings the header documents
    # are both reachable. gate-stale / changes-requested / awaiting-stale
    # need the predicate and are evaluate-mode only.
    verdict=""
    detail=""
  fi

  case "$verdict" in
    threads-open)
      # Already reported from the direct read — dedupe the predicate's
      # duplicate verdict and stop here (nothing below applies: the gate
      # is, or will converge, closed on the threads).
      if [ "$threads_reported" = "1" ]; then
        continue
      fi
      # Direct count was zero but the predicate saw threads (paging race /
      # mid-read resolution) — the predicate fails closed, so surface it,
      # WITH the same stale-green companion as the direct path (this arm
      # only exists under enforced threads): a merge-enabling green gate
      # over the raced-in thread must heal, not wait for the cron floor.
      emit "$number" "$head" threads-open "$detail$queued"
      attention=1
      # THREADS_TERM guard is belt-and-braces here: the predicate never
      # returns threads-open under off today, but a predicate/config
      # inconsistency must not become false stale alerts + dispatch churn.
      if [ "$THREADS_TERM" != "off" ] && [ "$gate_state" = "success" ]; then
        emit "$number" "$head" gate-stale "threads are open but the newest '$GATE_CONTEXT' row is success — the writer has not converged the withdrawal$queued"
        heal "$number" "$head"
      fi
      continue
      ;;
    changes-requested)
      emit "$number" "$head" changes-requested "$detail$queued"
      attention=1
      if [ "$gate_state" = "success" ]; then
        emit "$number" "$head" gate-stale "a standing objection but the newest '$GATE_CONTEXT' row is success — the writer has not converged the withdrawal$queued"
        heal "$number" "$head"
      fi
      continue
      ;;
  esac


  # Disarmed reduction — BOTH modes (the cheap-mode contract includes it):
  # a gate-open, un-queued, non-draft PR with auto-merge unarmed is
  # mergeable, but nothing will merge it.
  if [ "$gate_state" = "success" ] && [ "$armed" = "false" ] && [ -z "$queued" ] && [ "$draft" != "true" ]; then
    # In evaluate mode only a confirmed approved verdict nominates the
    # disarmed line (an approved gate over an awaiting predicate is the
    # writer's problem, reported below as the state mismatch it is).
    if [ "$EVALUATE" = "0" ] || [ "$verdict" = "approved" ]; then
      emit "$number" "$head" disarmed "gate open but auto-merge is not armed and the PR is not queued — nothing will merge this (re-arm)"
      attention=1
    fi
  fi

  case "$verdict" in
    approved)
      if [ "$gate_state" != "success" ]; then
        emit "$number" "$head" gate-stale "predicate says approved but the newest '$GATE_CONTEXT' row is $gate_state — the writer has not converged$queued"
        attention=1
        heal "$number" "$head"
      fi
      ;;
    awaiting)
      # The INVERSE mismatch is the dangerous one: evidence withdrawn but
      # the gate still green (merge-enabling). Stale success heals too.
      if [ "$gate_state" = "success" ]; then
        emit "$number" "$head" gate-stale "predicate says awaiting but the newest '$GATE_CONTEXT' row is still success — withdrawn evidence left a merge-enabling gate$queued"
        attention=1
        heal "$number" "$head"
      fi
      # Drafts are not awaiting REVIEW — they are awaiting readiness: the
      # silence clock skips them (the gate-mismatch check above still
      # applies), or a long-lived draft pins the watcher at exit 1 asking
      # for re-reviews nobody owes it.
      if [ "$draft" = "true" ]; then
        continue
      fi
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
      # date -d is GNU; BSD/macOS uses -u -j -f (the -u is load-bearing:
      # the trailing Z is a LITERAL in this format string, so without -u
      # BSD date reads the timestamp in the machine's local zone and the
      # silence clock shifts by the UTC offset in either direction).
      head_epoch="$(date -u -d "$head_at" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$head_at" +%s 2>/dev/null)" || head_epoch=""
      created_epoch=""
      if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
        created_epoch="$(date -u -d "$created_at" +%s 2>/dev/null \
          || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null)" || created_epoch=""
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
            ready_epoch="$(date -u -d "$ready_at" +%s 2>/dev/null \
              || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ready_at" +%s 2>/dev/null)" || ready_epoch=""
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
            emit "$number" "$head" awaiting-stale "no review evidence for ${age}s (quiet period ${AWAITING_AFTER}s) — trigger a re-review or apply the on-timeout policy$queued"
            attention=1
          fi
        fi
      else
        # Neither timestamp parsed: silence age is unprovable, and
        # unprovable must never read as healthy (fail-loud contract).
        emit "$number" "$head" error "silence clock has no parsable timestamp (head commit and created_at both unusable) — silence age unprovable"
        errored=1
      fi
      ;;
  esac

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
