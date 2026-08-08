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
#   threads-open       unresolved review threads (the detail carries the
#                      predicate's count wording; QUEUED PRs are annotated —
#                      a queued PR needs a DEQUEUE before any fix push,
#                      GitHub rejects pushes to queued branches)
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
#   --no-evaluate      cheap mode: skip the predicate; only thread counts
#                      (direct GraphQL read) and the disarmed check run —
#                      no gate-stale / changes-requested / awaiting-stale
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
      PR_ARGS="$PR_ARGS $1"
      ;;
  esac
  shift
done

GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 2
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
}

# --- enumerate ----------------------------------------------------------
# Same fail-loud page discipline as the writer: a zero-byte or non-array
# page is a broken read, never an empty repo — silently watching zero PRs
# is exactly the blindness this tool exists to remove.
if [ -n "$PR_ARGS" ]; then
  prs="[]"
  for n in $PR_ARGS; do
    row="$(gh api "repos/$GH_REPO/pulls/$n" 2>/dev/null)" || {
      emit "$n" "--------" error "could not read PR #$n"
      errored=1
      continue
    }
    prs="$(jq -c --argjson r "$row" '. + [$r]' <<<"$prs")"
  done
else
  raw_prs="$(gh api "repos/$GH_REPO/pulls?state=open&per_page=100" --paginate)" || {
    echo "::error::pr-watch: could not list open PRs" >&2
    exit 2
  }
  if [ -z "$raw_prs" ]; then
    echo "::error::pr-watch: open-PR listing produced zero bytes (broken read)" >&2
    exit 2
  fi
  prs="$(jq -cs 'if (length > 0) and all(type == "array")
                 then add
                 else error("not an array page") end' <<<"$raw_prs" 2>/dev/null)" || {
    echo "::error::pr-watch: open-PR listing pages are not arrays (broken read)" >&2
    exit 2
  }
fi

# --- per-PR reduction ---------------------------------------------------
while IFS=$'\t' read -r number head author state draft armed; do
  [ -z "$number" ] && continue
  # Closed/merged PRs need nothing (reachable only via explicit PR args).
  [ "$state" = "open" ] || continue

  # Queue membership: pushes to a queued PR's branch are rejected, so every
  # attention line on a queued PR carries the annotation.
  queued="$(gh api graphql -f query="query{repository(owner:\"${GH_REPO%%/*}\",name:\"${GH_REPO#*/}\"){pullRequest(number:$number){mergeQueueEntry{position}}}}" \
      --jq 'if .data.repository.pullRequest.mergeQueueEntry == null then "" else " (QUEUED: dequeue before pushing)" end' 2>/dev/null)" || queued=""

  if [ "$EVALUATE" = "1" ]; then
    verdict_line="$(GH_REPO="$GH_REPO" PR_NUMBER="$number" HEAD_SHA="$head" PR_AUTHOR="$author" \
        "$script_dir/review-predicate.sh" 2>/dev/null)" || {
      emit "$number" "$head" error "predicate evaluation failed (exit 2 — read failure or invalid config)"
      errored=1
      continue
    }
    verdict="$(sed -n 's/^verdict=\([a-z-]*\) .*/\1/p' <<<"$verdict_line")"
    detail="$(sed -n 's/^verdict=[a-z-]* detail=//p' <<<"$verdict_line")"
  else
    # Cheap mode: thread count only — the one term whose transition has no
    # webhook anywhere and therefore the one agents most often sleep
    # through.
    unresolved="$(gh api graphql -f query="query{repository(owner:\"${GH_REPO%%/*}\",name:\"${GH_REPO#*/}\"){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}" \
        --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length' 2>/dev/null)" || {
      emit "$number" "$head" error "thread read failed"
      errored=1
      continue
    }
    if [ "$unresolved" -gt 0 ]; then
      emit "$number" "$head" threads-open "$unresolved unresolved review thread(s)$queued"
      attention=1
    fi
    verdict=""
    detail=""
  fi

  case "$verdict" in
    threads-open)
      emit "$number" "$head" threads-open "$detail$queued"
      attention=1
      continue
      ;;
    changes-requested)
      emit "$number" "$head" changes-requested "$detail$queued"
      attention=1
      continue
      ;;
  esac

  # Gate context's NEWEST row (list endpoint, newest-first — the same
  # projection the predicate documents for the status surface).
  gate_state="$(gh api "repos/$GH_REPO/commits/$head/statuses?per_page=100" --paginate 2>/dev/null \
      | jq -rs --arg ctx "$GATE_CONTEXT" 'add // [] | map(select(.context == $ctx)) | (.[0].state // "absent")')" || {
    emit "$number" "$head" error "gate-status read failed"
    errored=1
    continue
  }

  case "$verdict" in
    approved)
      if [ "$gate_state" != "success" ]; then
        emit "$number" "$head" gate-stale "predicate says approved but the newest '$GATE_CONTEXT' row is $gate_state — the writer has not converged$queued"
        attention=1
        if [ "$HEAL" = "1" ] && [ "$healed" = "0" ]; then
          if gh workflow run "$WRITER_WORKFLOW" --repo "$GH_REPO" >/dev/null 2>&1; then
            emit "$number" "$head" heal-dispatched "writer workflow '$WRITER_WORKFLOW' dispatched (once per invocation)"
            healed=1
          else
            emit "$number" "$head" error "writer dispatch failed for '$WRITER_WORKFLOW'"
            errored=1
          fi
        fi
      elif [ "$armed" = "false" ] && [ -z "$queued" ] && [ "$draft" != "true" ]; then
        emit "$number" "$head" disarmed "gate open but auto-merge is not armed and the PR is not queued — nothing will merge this (re-arm)"
        attention=1
      fi
      ;;
    awaiting)
      # Quiet-period check keys on the HEAD COMMIT's age: reviewer silence
      # counts from the last push, matching the waiters' clock model.
      head_at="$(gh api "repos/$GH_REPO/commits/$head" --jq '.commit.committer.date' 2>/dev/null)" || {
        emit "$number" "$head" error "head-commit read failed"
        errored=1
        continue
      }
      # date -d is GNU; BSD/macOS uses -j -f. Try GNU first, fall back.
      head_epoch="$(date -d "$head_at" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$head_at" +%s 2>/dev/null)" || head_epoch=""
      if [ -n "$head_epoch" ]; then
        age=$(( $(date +%s) - head_epoch ))
        if [ "$age" -gt "$AWAITING_AFTER" ]; then
          emit "$number" "$head" awaiting-stale "no review evidence for ${age}s (quiet period ${AWAITING_AFTER}s) — trigger a re-review or apply the on-timeout policy$queued"
          attention=1
        fi
      fi
      ;;
  esac
done < <(jq -r '.[] | [.number, .head.sha, (.user.login // ""), .state, (.draft // false | tostring), (if .auto_merge == null then "false" else "true" end)] | @tsv' <<<"$prs")

if [ "$errored" = "1" ]; then exit 2; fi
if [ "$attention" = "1" ]; then exit 1; fi
exit 0
