#!/usr/bin/env bash
# Review-gate SINGLE WRITER — the one place the gate commit status is written
# (review-gate v2; vanillagreencom/vstack#1099). Shipped by the vstack
# review-gate skill, vendored into consumers at
# .agents/skills/review-gate/scripts/, invoked only by the writer workflow
# (templates/review-gate-writer.yml).
#
# THE GATE ANSWERS EXACTLY ONE QUESTION: has this head been reviewed by
# someone the repo trusts, with no standing objection and no unresolved
# threads? It evaluates review-predicate.sh and converges the gate commit
# status (context: REVIEW_GATE_CONTEXT) to that answer. Nothing else.
# (REVIEW_GATE_MODE=off changes the predicate's answer, not this writer:
# the converged status is green with a disabled-by-settings attestation.)
#
# IT DELIBERATELY DOES NOT POLICE CI. Whether untested code can reach the
# default branch is branch protection's job. A gate that tries to prove "the
# tests really ran" must reverse-engineer that from run numbers, job
# conclusions and timestamps — the machinery this version deletes, and the
# source of every correctness defect found reviewing v2. ADOPTION
# PRECONDITION, one of two (references/adoption.md):
#
#   (1) RECOMMENDED — a merge queue whose required contexts include the
#       repo's test aggregate. The queue runs the suite on the MERGED result
#       and refuses the merge if it fails, so the suite runs once, against
#       the code that actually ships. Proven in the sandbox: a PR whose head
#       attempt skipped its heavy jobs, with a green gate and no proof of
#       any kind, still could not merge.
#   (2) no held-back jobs — every required check runs on every push, so
#       "skipped counts as satisfied" never arises.
#
# A repo that holds jobs back behind the gate AND has no merge queue
# satisfies neither, and untested code can merge there. That is a branch
# protection gap; this script cannot close it and no longer pretends to.
#
# CONVERGE-ALL, EVERY LEG: except for the merge_group leg and the fork
# read-only no-op, EVERY invocation enumerates and converges EVERY open PR.
# The writer's single concurrency group means bursts evict pending runs;
# because whichever run survives converges everyone, eviction is harmless
# rather than silently stranding the evicted events' heads until the cron
# (8 evictions observed in one sandbox replay, zero stranded). Per-head work
# happens in a recursive single-head invocation (PR_NUMBER + HEAD_SHA set),
# an internal contract rather than a workflow input.
#
# WRITE DISCIPLINE (VST-65): two writer runs can interleave on one head, so
# before ANY success post the current gate status is RE-READ and the post is
# DEFERRED when any gate entry was created at/after this run's evaluation
# instant (that run evaluated newer state — deferring protects both the
# state and the description, which carries the audit detail); a failed
# re-read defers too, because withholding success is the fail-safe side.
# Downward posts never defer — moving toward closed is always safe. Writes are
# idempotent: when the current entry already matches state + description the
# writer no-ops, so idle cron ticks append nothing.
#
# NO FORK SPECIAL CASES: every leg holds a write-capable default-branch
# token, so fork heads take the same path as same-repo heads. The one
# exception is pull_request_review fired by a FORK PR, whose token GitHub
# downgrades to read-only: the workflow flags it with WRITER_READ_ONLY=1 and
# this script exits GREEN as a no-op before touching anything — fork review
# evidence converges on the cron floor.
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO.
# Env (leg selection):
#   EVENT_NAME    the triggering event. "merge_group" posts the queue
#                 success (HEAD_SHA required, no PR identifiers); every
#                 other value — including empty — is equivalent.
#   WRITER_READ_ONLY  "1": exit 0 immediately, reading and posting nothing.
#   PR_NUMBER / HEAD_SHA / PR_AUTHOR  the INTERNAL single-head contract used
#                 by the enumeration's recursive per-PR invocation.
# Settings (lib/settings.sh — env > vstack.settings.toml > default):
#   REVIEW_GATE_CONTEXT   gate commit-status context (default "Review gate").
#                 Every trust and evidence knob belongs to the predicate;
#                 see references/settings.md.
#
# Read errors fail LOUDLY (exit 1) without acting: treating a transient API
# failure as absent evidence could flip a healthy PR's state.
set -u

# The fork read-only no-op precedes everything, including settings
# resolution: such a run must exit green even under a broken settings file
# it could not have acted on anyway.
if [ "${WRITER_READ_ONLY:-0}" = "1" ]; then
  echo "read-only token (fork pull_request_review); no-op — the scheduled writer pass converges this head"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/settings.sh"

EVENT_NAME="${EVENT_NAME:-}"

# `|| exit 1`: rg_setting fails on a present-but-unparseable assignment, and
# that is a configuration error to surface, never an empty value to act on.
GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 1
if [ -z "$GATE_CONTEXT" ]; then
  echo "::error::review-writer: REVIEW_GATE_CONTEXT must not be empty"
  exit 1
fi

if [ -z "${GH_REPO:-}" ]; then
  echo "::error::review-writer: GH_REPO is required"
  exit 1
fi

# --- merge-queue leg ----------------------------------------------------
# A PR only enters the queue after its own head satisfied the required gate
# status, so the ephemeral merge-group sha inherits that answer: the queue
# entry is post-approval by construction. No predicate read, and no ordering
# guard — nothing else ever writes on a merge-group sha.
if [ "$EVENT_NAME" = "merge_group" ]; then
  if [ -z "${HEAD_SHA:-}" ]; then
    echo "::error::review-writer: HEAD_SHA is required on the merge_group leg"
    exit 1
  fi
  gh api -X POST "repos/$GH_REPO/statuses/$HEAD_SHA" \
    -f state=success -f context="$GATE_CONTEXT" \
    -f description="merge-queue entry: post-approval by construction" >/dev/null || {
    echo "::error::could not post $GATE_CONTEXT on merge-group sha $HEAD_SHA"
    exit 1
  }
  echo "posted $GATE_CONTEXT=success on merge-group sha $HEAD_SHA"
  exit 0
fi

self="$script_dir/$(basename "${BASH_SOURCE[0]}")"

# --- converge-all enumeration: every leg --------------------------------
if [ -z "${PR_NUMBER:-}" ]; then
  # Full pagination (one array per page, slurped flat) — a fixed page limit
  # would silently leave PRs beyond it unconverged forever.
  raw_prs="$(gh api "repos/$GH_REPO/pulls?state=open&per_page=100" --paginate)" || {
    echo "::error::could not list open PRs"
    exit 1
  }
  # A SUCCESSFUL call that produced zero bytes is a broken read, not an
  # empty repo — a truly-empty PR list is the two-byte page `[]`. Slurping
  # nothing to [] would report "converging 0 open PR(s)" and exit green,
  # silently stranding every gate until the next pass.
  if [ -z "$raw_prs" ]; then
    echo "::error::open-PR listing produced zero bytes (broken read); taking no action"
    exit 1
  fi
  # Page-shape validation, not just parse success: a whitespace-only body
  # slurps to [] and an error-object page slurps to {} — both would read
  # as "zero open PRs" and exit green with every gate silently stranded.
  # A healthy page is an ARRAY (an empty repo is the two-byte page []).
  prs="$(jq -s 'if (length > 0) and all(type == "array")
                then [add | .[] | {number, headRefOid: .head.sha, author: {login: (.user.login // "")}}]
                else error("not an array page") end' <<<"$raw_prs" 2>/dev/null)" || {
    echo "::error::open-PR listing pages are not arrays (broken read); taking no action"
    exit 1
  }
  count="$(jq length <<<"$prs")"
  echo "converging $count open PR(s)"
  failed=0
  while read -r number head author; do
    [ -z "$number" ] && continue
    if ! EVENT_NAME="$EVENT_NAME" PR_NUMBER="$number" \
        HEAD_SHA="$head" PR_AUTHOR="$author" bash "$self" </dev/null; then
      echo "::error::convergence failed for PR #$number (see log above)"
      failed=1
    fi
  done < <(jq -r '.[] | "\(.number) \(.headRefOid) \(.author.login // "")"' <<<"$prs")
  exit "$failed"
fi

# --- single-head evaluation (the enumeration's recursive contract) -------
if [ -z "${HEAD_SHA:-}" ]; then
  echo "::error::review-writer: HEAD_SHA is required alongside PR_NUMBER"
  exit 1
fi

# Stamped BEFORE the predicate reads (VST-65): any gate status created at or
# after this instant may reflect newer review state than this evaluation —
# the success-post ordering guard compares against it.
evaluated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

verdict_line="$("$script_dir/review-predicate.sh")" || {
  echo "::error::review predicate evaluation failed for PR #$PR_NUMBER; taking no action - the next writer pass retries"
  exit 1
}
verdict="$(sed -n 's/^verdict=\([a-z-]*\) .*/\1/p' <<<"$verdict_line")"
detail="$(sed -n 's/^verdict=[a-z-]* detail=//p' <<<"$verdict_line")"
if [ -z "$verdict" ]; then
  echo "::error::could not parse predicate output: $verdict_line"
  exit 1
fi
echo "PR #$PR_NUMBER: verdict=$verdict ($detail)"

case "$verdict" in
  approved)              desired="success" ;;
  changes-requested)     desired="failure" ;;
  awaiting|threads-open) desired="pending" ;;
  *)
    echo "::error::unknown verdict '$verdict'"
    exit 1
    ;;
esac

raw_statuses="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/statuses" --paginate)" || {
  echo "::error::could not read commit statuses for $HEAD_SHA; taking no action"
  exit 1
}
# Zero bytes from a successful read is broken, not "no statuses" (that is
# `[]`): slurped to an empty list it would read as gate-absent and trigger
# a redundant post at best, a misread current state at worst.
if [ -z "$raw_statuses" ]; then
  echo "::error::commit-statuses read for $HEAD_SHA produced zero bytes (broken read); taking no action"
  exit 1
fi
gate_statuses="$(jq -s --arg ctx "$GATE_CONTEXT" 'if (length > 0) and all(type == "array")
                  then [add | .[] | select(.context == $ctx)]
                  else error("not an array page") end' <<<"$raw_statuses" 2>/dev/null)" || {
  echo "::error::commit-status pages for $HEAD_SHA are not arrays (broken read); taking no action"
  exit 1
}
current_state="$(jq -r '.[0].state // "absent"' <<<"$gate_statuses")"
current_desc="$(jq -r '.[0].description // ""' <<<"$gate_statuses")"

post_status() {
  # 140-char API limit on description.
  gh api -X POST "repos/$GH_REPO/statuses/$HEAD_SHA" \
    -f state="$1" -f context="$GATE_CONTEXT" \
    -f description="${2:0:140}" \
    -f target_url="https://github.com/$GH_REPO/pull/$PR_NUMBER" >/dev/null || {
    echo "::error::could not post $GATE_CONTEXT=$1 on $HEAD_SHA"
    exit 1
  }
  echo "posted $GATE_CONTEXT=$1 on $HEAD_SHA ($2)"
}

# Idempotent no-op: idle passes append nothing.
if [ "$current_state" = "$desired" ] && [ "$current_desc" = "${detail:0:140}" ]; then
  echo "PR #$PR_NUMBER: $GATE_CONTEXT already $desired; nothing to do"
  exit 0
fi

if [ "$desired" != "success" ]; then
  # Downward posts never defer — toward closed is the safe direction.
  post_status "$desired" "$detail"
  exit 0
fi

# POST-ORDERING GUARD (VST-65). Before posting SUCCESS, re-read the current
# gate status and DEFER when ANY gate entry was created at/after this run's
# evaluation — that run evaluated newer state than this one, and overwriting
# its post would regress either the gate state (a changes-requested landing
# in the evaluate→post gap becoming a stale approved) or its description
# (a newer success's operator-override reason replaced by a stale detail —
# the audit trail rides in the description, so it is protected like the
# state). Deferring self-heals: the next event or cron tick re-reads live
# state. Fetch and filter are SEPARATE steps: a pipe would replace gh's exit
# status with jq's, so a failed or truncated re-read could slurp to an empty
# array and report newer=0 — the exact stale-success fail-open this guard
# closes. A failed re-read defers too — and so does a MALFORMED one: the
# same non-vacuous all-arrays validation as the projection read above,
# because a whitespace-only success slurps to [] and a non-array page
# collapses through `add`, both reporting newer=0 and permitting exactly
# the stale success this guard exists to block. And `>=`, not `>`: both
# timestamps have one-second resolution, so a write landing later within
# the evaluation second compares EQUAL — deferring on equality self-heals.
#
# The re-read deliberately uses bare `gh api`, not a retry wrapper (the
# predicate's gh_read is predicate-internal): every failure mode here lands
# on the fail-safe side — a failed read defers, and the next pass retries
# from live state. In-process retries would only shave deferral latency, and
# the writer stays minimal by design.
guard_newer=""
if guard_pages="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/statuses?per_page=100" --paginate)" \
   && [ -n "$guard_pages" ]; then
  guard_newer="$(jq -rs --arg ctx "$GATE_CONTEXT" --arg since "$evaluated_at" \
      'if (length > 0) and all(type == "array")
       then [add | .[] | select(.context == $ctx
         and (($since | length) > 0) and ((.created_at // "") >= $since))] | length
       else error("guard re-read pages are not arrays") end' \
      <<<"$guard_pages" 2>/dev/null)" || guard_newer=""
fi
if [ "$guard_newer" != "0" ]; then
  echo "::warning::deferring the success post: $GATE_CONTEXT was re-written (or unreadable) after this run's evaluation at $evaluated_at — a newer writer run's verdict stands; the next pass converges"
  exit 0
fi
post_status success "$detail"
