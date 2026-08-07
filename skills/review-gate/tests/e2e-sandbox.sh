#!/usr/bin/env bash
# Layer-2 E2E replay for the v2 single writer against a LIVE sandbox repo
# (the v2 single-writer plan's "Validation and cutover" section — vanillagreencom/vstack#1099).
# Drives the end-to-end PR lifecycles observed on hyprtrade/drovr through the
# real GitHub API — real events, real merge queue, real branch protection —
# and asserts the posted gate state after each step. This is the durable
# answer to "how do we catch problems": re-run it before any future engine
# change.
#
# Prerequisites (see the plan's single-account sandbox constraints):
#   - $E2E_REPO is a throwaway repo with the v2 writer installed
#     (.agents/skills/review-gate/ vendored, review-gate-writer.yml, the
#     tiered ci.yml with the .sandbox-slow-gate/.sandbox-heavy-fail hooks,
#     open-pr.yml, mint-status.yml, vstack.settings.toml trusting the
#     driver identity) and hyprtrade-shaped rulesets (merge queue requiring
#     "CI Required" + "Review gate"; zero-bypass thread resolution).
#   - gh is authenticated as the scripted-reviewer identity (repo admin,
#     NOT github-actions): scenario PRs are opened by github-actions[bot]
#     via the open-pr dispatch so review-object evidence from this identity
#     counts (author exclusion); fork scenarios use this identity's fork.
#   - GitHub Actions may create PRs (repo/org/enterprise setting), and the
#     repo allows auto-merge (`allow_auto_merge`) so scenario 1 can enqueue.
#   - Scenario 5 (true fork PR) additionally needs a FORK of the sandbox in
#     another namespace. A private repo in an org that forbids private
#     forking cannot provide one; s5 then SKIPS loudly rather than failing.
#     Use a public sandbox for that scenario, or create the fork by hand.
#
# Invocation: E2E_REPO=<owner>/<repo> bash tests/e2e-sandbox.sh
# Without E2E_REPO the driver SKIPS — it is a live driver, and the repo's
# offline skill-suite sweep runs every tests/*.sh.
#
# Scenario selection: E2E_SCENARIOS="s1 s2 ..." (default: all). Scenarios
# are independent; each opens its own PR(s) and closes them on exit.
#
# Bot fixture profiles (recorded shapes from live fleet PRs, 2026-08):
#   copilot     COMMENTED review object at head, never approves
#               (copilot-pull-request-reviewer[bot] posts COMMENTED rows;
#               trust via REVIEW_OBJECT_MIN_STATE=any)
#   coderabbit  review object + "CodeRabbit" success status; ALSO the
#               rate-limited success-status shape ("Review rate limited")
#               that must be skip-filtered to not-evidence
#   qodo        plain APPROVED review object
set -uo pipefail

# LIVE driver, opt-in by design: it drives a real GitHub repo through real
# PR lifecycles, so it must never run as part of the offline skill-suite
# sweep (which executes every skills/*/tests/*.sh). Setting E2E_REPO is the
# opt-in. Bash parses a script INCREMENTALLY, so exiting here would leave
# everything below unparsed — the sweep must still catch a malformed driver,
# hence the explicit syntax check before the skip.
if [ -z "${E2E_REPO:-}" ]; then
  if bash -n "${BASH_SOURCE[0]}"; then
    echo "e2e-sandbox: LIVE Layer-2 driver — syntax OK; skipped (set E2E_REPO=<owner>/<repo> to run against a sandbox)"
    exit 0
  fi
  echo "e2e-sandbox: SYNTAX ERROR in the replay driver (above)" >&2
  exit 1
fi
REPO="$E2E_REPO"
SCENARIOS="${E2E_SCENARIOS:-s1 s2 s3 s4 s5 s6 s7 s9 s10a s10b s11 sfinal}"
GATE_CTX="Review gate"
OVERRIDE_CTX="vstack-reviewer-outage"

PASS=0
FAIL=0
CURRENT=""

note() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "${CURRENT:-driver}" "$*"; }
ok()   { PASS=$((PASS + 1)); note "ok    $*"; }
bad()  { FAIL=$((FAIL + 1)); note "FAIL  $*"; }

ME="$(gh api user --jq .login)" || { echo "gh auth required"; exit 1; }

b64() { # stdin -> base64 with no line wrapping, GNU and BSD alike
  base64 | tr -d '\n'
}

iso_epoch() { # ISO-8601 Z instant -> epoch seconds (GNU date, then BSD date)
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}
# Stamped once: every cross-cutting check in sfinal is bounded to runs
# created after the driver started, so prior sessions never colour a result.
REPLAY_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "driver identity: $ME (repo $REPO); replay window starts $REPLAY_SINCE"

# ---------------------------------------------------------------- helpers ---

head_sha() { gh api "repos/$REPO/pulls/$1" --jq .head.sha; }

gate_read() { # sha -> "state<TAB>description" of the newest gate entry
  gh api "repos/$REPO/commits/$1/statuses?per_page=100" --paginate 2>/dev/null \
    | jq -rs --arg ctx "$GATE_CTX" \
        '[add // [] | .[] | select(.context == $ctx)] | if length == 0 then "absent\t" else "\(.[0].state)\t\(.[0].description // "")" end'
}

gate_entry_count() { # sha -> number of gate-context entries
  gh api "repos/$REPO/commits/$1/statuses?per_page=100" --paginate 2>/dev/null \
    | jq -rs --arg ctx "$GATE_CTX" '[add // [] | .[] | select(.context == $ctx)] | length'
}

await_gate() { # sha, want-state, timeout-s, [desc-substr] -> 0/1
  local sha="$1" want="$2" timeout="$3" substr="${4:-}" waited=0 state desc line
  while [ "$waited" -le "$timeout" ]; do
    line="$(gate_read "$sha")"
    state="${line%%$'\t'*}"; desc="${line#*$'\t'}"
    if [ "$state" = "$want" ] && { [ -z "$substr" ] || grep -qF -- "$substr" <<<"$desc"; }; then
      return 0
    fi
    sleep 15; waited=$((waited + 15))
  done
  note "timeout: gate on ${sha:0:8} is '$line', wanted '$want${substr:+ ($substr)}' after ${timeout}s"
  return 1
}

assert_gate() { # sha, want-state, timeout, [desc-substr], label
  local label="${5:-gate reaches ${2}}"
  if await_gate "$1" "$2" "$3" "${4:-}"; then ok "$label"; else bad "$label"; fi
}

mkbranch() { # branch [extra-file extra-content]
  local branch="$1" extra="${2:-}" content="${3:-}"
  local base
  base="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)"
  gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$branch" -f sha="$base" >/dev/null
  put_file "$branch" "scenario/$branch.txt" "scenario $branch line one" "seed $branch"
  if [ -n "$extra" ]; then
    put_file "$branch" "$extra" "$content" "hook file for $branch"
  fi
}

put_file() { # branch path content message  (create or update, driver-authored)
  local branch="$1" path="$2" content="$3" message="$4" sha_arg=()
  local existing
  existing="$(gh api "repos/$REPO/contents/$path?ref=$branch" --jq .sha 2>/dev/null)" && sha_arg=(-f sha="$existing")
  gh api -X PUT "repos/$REPO/contents/$path" \
    -f message="$message" -f branch="$branch" \
    -f content="$(printf '%s\n' "$content" | b64)" \
    "${sha_arg[@]+"${sha_arg[@]}"}" >/dev/null
}

open_pr() { # branch title -> PR number (opened by github-actions[bot], then a
            # driver-authored empty commit fires the suppressed events)
  local branch="$1" title="$2" waited=0 num=""
  gh workflow run open-pr -R "$REPO" -f branch="$branch" -f title="$title" >/dev/null
  while [ "$waited" -le 120 ]; do
    num="$(gh pr list -R "$REPO" --head "$branch" --json number --jq '.[0].number // empty')"
    [ -n "$num" ] && break
    sleep 5; waited=$((waited + 5))
  done
  [ -n "$num" ] || { note "open-pr dispatch never produced a PR for $branch"; return 1; }
  # The PR's reported head lags the ref update; wait until it shows the
  # empty commit so callers never assert against a stale sha.
  local new
  new="$(empty_commit "$branch")"
  waited=0
  while [ "$waited" -le 90 ]; do
    [ "$(head_sha "$num")" = "$new" ] && break
    sleep 5; waited=$((waited + 5))
  done
  printf '%s' "$num"
}

await_new_head() { # pr, old-sha -> prints the new head once it differs
  local pr="$1" old="$2" waited=0 sha
  while [ "$waited" -le 90 ]; do
    sha="$(head_sha "$pr")"
    if [ -n "$sha" ] && [ "$sha" != "$old" ]; then
      printf '%s' "$sha"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  printf '%s' "$old"
  return 1
}

empty_commit() { # branch — driver-authored empty commit (fires synchronize)
  local branch="$1" head tree new
  head="$(gh api "repos/$REPO/git/ref/heads/$branch" --jq .object.sha)"
  tree="$(gh api "repos/$REPO/git/commits/$head" --jq .tree.sha)"
  new="$(gh api -X POST "repos/$REPO/git/commits" \
    -f message="empty: fire synchronize" -f tree="$tree" -f "parents[]=$head" --jq .sha)"
  gh api -X PATCH "repos/$REPO/git/refs/heads/$branch" -f sha="$new" >/dev/null
  printf '%s' "$new"
}

review() { # pr event [body]  (driver-authored review object)
  gh api -X POST "repos/$REPO/pulls/$1/reviews" \
    -f event="$2" -f body="${3:-scripted $2 review}" >/dev/null
}

review_with_thread() { # pr path  (COMMENT review carrying one thread)
  gh api -X POST "repos/$REPO/pulls/$1/reviews" \
    --input - >/dev/null <<EOF
{"event": "COMMENT", "body": "findings round",
 "comments": [{"path": "$2", "line": 1, "side": "RIGHT", "body": "please fix this line"}]}
EOF
}

resolve_all_threads() { # pr
  local ids id
  ids="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:50){nodes{id isResolved}}}}}' \
    -F o="${REPO%/*}" -F r="${REPO#*/}" -F n="$1" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id')"
  for id in $ids; do
    gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
      -F t="$id" >/dev/null
  done
}

post_status() { # sha context state description (driver-authored: creator=$ME)
  gh api -X POST "repos/$REPO/statuses/$1" \
    -f state="$3" -f context="$2" -f description="$4" >/dev/null
}

dispatch_writer() { # fire a writer pass and wait for it to complete
  local before after waited=0
  before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run "Review gate writer" -R "$REPO" >/dev/null
  while [ "$waited" -le 180 ]; do
    after="$(gh run list -R "$REPO" --workflow "Review gate writer" \
      --json status,createdAt,event \
      --jq '[.[] | select(.event == "workflow_dispatch" and .createdAt >= "'"$before"'")] | if length > 0 and all(.status == "completed") then "done" else "" end')"
    [ "$after" = "done" ] && return 0
    sleep 10; waited=$((waited + 10))
  done
  note "writer dispatch did not complete within 180s"
  return 1
}

ci_attempts() { # sha -> highest run_attempt among CI pull_request runs
  gh api "repos/$REPO/actions/runs?head_sha=$1&per_page=100" \
    --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI") | .run_attempt] | max // 0'
}

ci_run_id() { # sha -> newest CI pull_request run id
  gh api "repos/$REPO/actions/runs?head_sha=$1&per_page=100" \
    --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI")] | sort_by(.id) | last | .id // empty'
}

await_ci_settled() { # sha timeout — wait until no CI pull_request run is in flight (and >=1 exists)
  local sha="$1" timeout="$2" waited=0 st
  while [ "$waited" -le "$timeout" ]; do
    st="$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
      --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI")] | if length == 0 then "none" elif any(.status != "completed") then "running" else "settled" end')"
    [ "$st" = "settled" ] && return 0
    sleep 10; waited=$((waited + 10))
  done
  return 1
}

close_pr() { # pr branch
  gh pr close "$1" -R "$REPO" --delete-branch >/dev/null 2>&1 || true
}

# The standard assertion under the simplified engine: review evidence opens
# the gate, and the writer re-runs NOTHING. Whether the tests passed is the
# required checks' business, enforced by the merge queue (scenario 11).
await_review_success() { # sha label [timeout]
  local sha="$1" label="$2" timeout="${3:-420}" before after
  before="$(ci_attempts "$sha")"
  if await_gate "$sha" success "$timeout"; then
    ok "$label: gate opens on the review verdict"
  else
    bad "$label: gate opens on the review verdict"; return 1
  fi
  after="$(ci_attempts "$sha")"
  if [ "${after:-0}" -le "${before:-0}" ]; then
    ok "$label: and the writer re-ran nothing (attempts $before -> $after)"
  else
    bad "$label: the writer re-ran CI (attempts $before -> $after); it must not"
  fi
}

# ------------------------------------------------------------- scenarios ----

s1() { # per-profile: open PR -> bot reviews at head -> gate opens; qodo's PR
       # then merges THROUGH THE QUEUE (scenario 8: the merge_group leg).
  CURRENT=s1

  # --- copilot profile: COMMENTED review, never approves ---
  local br=s1-copilot pr sha
  mkbranch "$br"; pr="$(open_pr "$br" "s1 copilot profile")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "copilot: fresh head pends awaiting (event-fast)"
  review "$pr" COMMENT "Pull request overview: looks fine overall."
  await_review_success "$sha" "copilot COMMENTED-only profile"
  close_pr "$pr" "$br"

  # --- coderabbit profile: rate-limited status is NOT evidence; the real
  #     review + clean status is ---
  br=s1-coderabbit; mkbranch "$br"; pr="$(open_pr "$br" "s1 coderabbit profile")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "coderabbit: fresh head pends awaiting"
  post_status "$sha" "CodeRabbit" success "Review rate limited"
  dispatch_writer || true
  local line state
  line="$(gate_read "$sha")"; state="${line%%$'\t'*}"
  if [ "$state" = "pending" ]; then
    ok "coderabbit: rate-limited success status is skip-filtered (gate still pending)"
  else
    bad "coderabbit: rate-limited status must not open the gate (state=$state)"
  fi
  review "$pr" COMMENT "CodeRabbit review round"
  post_status "$sha" "CodeRabbit" success "Reviewed and clean"
  await_review_success "$sha" "coderabbit review+status profile"
  close_pr "$pr" "$br"

  # --- qodo profile: plain APPROVED review; ride it through the merge queue
  #     (scenario 8) ---
  br=s1-qodo; mkbranch "$br"; pr="$(open_pr "$br" "s1 qodo profile + queue merge")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "qodo: fresh head pends awaiting"
  review "$pr" APPROVE
  await_review_success "$sha" "qodo APPROVED profile"
  # --auto enqueues under a merge queue. gh reports "the merge strategy for
  # main is set by the merge queue" as a nonzero exit even when the enqueue
  # SUCCEEDS, so the enqueue is verified by observing the merge below rather
  # than by this exit status. (Repo prerequisite: allow_auto_merge.)
  gh pr merge "$pr" -R "$REPO" --squash --auto >/dev/null 2>&1 || true
  local waited=0 merged=""
  while [ "$waited" -le 600 ]; do
    merged="$(gh api "repos/$REPO/pulls/$pr" --jq .merged)"
    [ "$merged" = "true" ] && break
    sleep 15; waited=$((waited + 15))
  done
  if [ "$merged" = "true" ]; then
    ok "queue: approved PR merged through the merge queue"
  else
    bad "queue: PR did not merge through the queue within 10m"
  fi
  local mg
  mg="$(gh run list -R "$REPO" --workflow "Review gate writer" --json event,conclusion \
    --jq '[.[] | select(.event == "merge_group")] | length')"
  if [ "${mg:-0}" -ge 1 ]; then
    ok "queue: the writer's merge_group leg ran for the queue entry"
  else
    bad "queue: no merge_group writer run observed"
  fi
}

s2() { # findings -> threads -> resolve -> gate opens (the no-webhook case:
       # a dispatched/scheduled tick converges it)
  CURRENT=s2
  local br=s2-threads pr sha
  mkbranch "$br"; pr="$(open_pr "$br" "s2 threads round-trip")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  review_with_thread "$pr" "scenario/$br.txt"
  assert_gate "$sha" pending 300 "unresolved review thread" "review with findings pends threads-open (event-fast)"
  resolve_all_threads "$pr"
  dispatch_writer || true
  await_review_success "$sha" "thread resolution (no webhook; floor tick converges)"
  close_pr "$pr" "$br"
}

s3() { # changes-requested -> gate red -> dismiss -> gate opens
  CURRENT=s3
  local br=s3-cr pr sha rid
  mkbranch "$br"; pr="$(open_pr "$br" "s3 changes-requested round-trip")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  review "$pr" REQUEST_CHANGES "needs work"
  assert_gate "$sha" failure 300 "" "changes-requested reds the gate (event-fast)"
  rid="$(gh api "repos/$REPO/pulls/$pr/reviews" --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | last | .id')"
  gh api -X PUT "repos/$REPO/pulls/$pr/reviews/$rid/dismissals" \
    -f message="objection addressed" -f event="DISMISS" >/dev/null
  review "$pr" APPROVE
  await_review_success "$sha" "dismiss + re-approve"
  close_pr "$pr" "$br"
}

s4() { # push discards evidence -> re-review -> docs-only push CARRIES with
       # ZERO rerun (binding F1's showcase: one heavy bill on the carry push)
  CURRENT=s4
  local br=s4-carry pr shaA shaB shaC
  mkbranch "$br"; pr="$(open_pr "$br" "s4 carry-forward")" || { bad "open PR"; return; }
  shaA="$(head_sha "$pr")"
  review "$pr" APPROVE
  await_review_success "$shaA" "initial approval"
  # Code push: evidence is head-bound, so the gate must close on the new head.
  put_file "$br" "scenario/$br.txt" "scenario $br line one CHANGED" "code delta"
  shaB="$(await_new_head "$pr" "$shaA")" || bad "code push never surfaced a new head"
  assert_gate "$shaB" pending 300 "awaiting" "code push closes the gate (evidence head-bound)"
  review "$pr" APPROVE "re-review after the code push"
  await_review_success "$shaB" "re-review"
  # Docs-only push: carry-forward (docs class) keeps the gate open WITHOUT
  # re-review, and F1's ordering fast path must spare the redundant rerun.
  put_file "$br" "docs/note-$br.md" "just a doc line" "docs-only delta"
  shaC="$(await_new_head "$pr" "$shaB")" || bad "docs push never surfaced a new head"
  assert_gate "$shaC" success 480 "carried" "docs-only push carries WITHOUT re-review"
  # A budget expiry must FAIL the scenario, not pass vacuously: an attempt
  # still in flight also reports ci_attempts=1, so an unsettled head would
  # "prove" the zero-rerun claim without proving anything.
  local attempts
  if ! await_ci_settled "$shaC" 300; then
    bad "carry push: CI never settled, so the zero-rerun claim is unproven"
    close_pr "$pr" "$br"
    return
  fi
  attempts="$(ci_attempts "$shaC")"
  if [ "$attempts" = "1" ]; then
    ok "carry push ran the suite exactly once (the writer never re-runs)"
  else
    bad "carry push must not rerun heavy CI (attempts=$attempts, wanted 1)"
  fi
  close_pr "$pr" "$br"
}

s5() { # true fork PR: no special-casing; the pull_request_review-triggered
       # writer run no-ops GREEN; status-form evidence converges the head
  CURRENT=s5
  # PREREQUISITE, not a defect when absent: a true fork PR needs a fork in
  # another namespace. A PRIVATE sandbox in an org that forbids private
  # forking (the vanillagreencom default) cannot be forked at all, and
  # loosening that org/enterprise policy to run a test is the wrong trade.
  # Run this scenario against a PUBLIC sandbox, or fork manually and re-run
  # with the fork already in place. Skipping is loud and never silent — the
  # fork path has NO special-casing by design (that is the point of v2), and
  # the read-only-token no-op is pinned offline by w24.
  local fork="$ME/${REPO#*/}" br=s5-fork pr sha base
  if ! gh api "repos/$fork" --jq .id >/dev/null 2>&1; then
    gh repo fork "$REPO" --clone=false >/dev/null 2>&1 || true
    sleep 5
  fi
  if ! gh api "repos/$fork" --jq .id >/dev/null 2>&1; then
    note "SKIP s5: no fork at $fork and this repo cannot be forked (private repo + org policy). Run against a public sandbox, or create the fork manually first."
    return
  fi
  # Sync the fork's main, then branch on the fork.
  gh api -X POST "repos/$fork/merge-upstream" -f branch=main >/dev/null 2>&1 || true
  base="$(gh api "repos/$fork/git/ref/heads/main" --jq .object.sha)"
  gh api -X POST "repos/$fork/git/refs" -f ref="refs/heads/$br" -f sha="$base" >/dev/null 2>&1 || true
  gh api -X PUT "repos/$fork/contents/scenario/$br.txt" \
    -f message="seed $br" -f branch="$br" \
    -f content="$(printf 'fork scenario line\n' | b64)" >/dev/null
  pr="$(gh pr create -R "$REPO" --base main --head "$ME:$br" \
    --title "s5 true fork PR" --body "fork scenario (driver-authored)" 2>/dev/null | grep -o '[0-9]*$')"
  [ -n "$pr" ] || { bad "fork PR creation"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "" "fork head converges to pending with no special-casing"
  # Fire the fork pull_request_review leg: the run must be a GREEN no-op.
  local before
  before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  review "$pr" COMMENT "fork review event (evidence void: driver is the author)"
  sleep 45
  local conc
  conc="$(gh run list -R "$REPO" --workflow "Review gate writer" --json event,conclusion,createdAt \
    --jq '[.[] | select(.event == "pull_request_review" and .createdAt >= "'"$before"'")] | last | .conclusion // "none"')"
  if [ "$conc" = "success" ]; then
    ok "fork pull_request_review writer run is a GREEN no-op (read-only token)"
  elif [ "$conc" = "none" ]; then
    bad "no pull_request_review writer run observed for the fork review"
  else
    bad "fork pull_request_review writer run concluded $conc (must never be red)"
  fi
  # Status-form evidence (no author exclusion) opens the fork gate.
  post_status "$sha" "CodeRabbit" success "Reviewed and clean"
  await_review_success "$sha" "fork PR via status evidence" 900
  close_pr "$pr" "$br"
  gh api -X DELETE "repos/$fork/git/refs/heads/$br" >/dev/null 2>&1 || true
}

s6() { # operator override opens; a workflow-minted override is REJECTED
  CURRENT=s6
  local br=s6-override pr sha
  mkbranch "$br"; pr="$(open_pr "$br" "s6 operator override")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 240 "awaiting" "fresh head pends"
  post_status "$sha" "$OVERRIDE_CTX" success "internal review recorded: loop run clean (driver attestation)"
  await_review_success "$sha" "operator override (PAT-posted, reason carried)"
  close_pr "$pr" "$br"

  br=s6-minted; mkbranch "$br"; pr="$(open_pr "$br" "s6 minted override (must not open)")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 240 "awaiting" "fresh head pends"
  gh workflow run mint-status -R "$REPO" -f sha="$sha" -f context="$OVERRIDE_CTX" \
    -f description="minted by workflow" >/dev/null
  sleep 45
  dispatch_writer || true
  local line state
  line="$(gate_read "$sha")"; state="${line%%$'\t'*}"
  if [ "$state" = "pending" ]; then
    ok "workflow-minted override is publisher-rejected (gate still pending)"
  else
    bad "minted override must not open the gate (state=$state)"
  fi
  close_pr "$pr" "$br"
}

s7() { # no reviewer at all -> pending forever (never opens on silence)
  CURRENT=s7
  local br=s7-silence pr sha
  mkbranch "$br"; pr="$(open_pr "$br" "s7 silence never opens")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "silent head pends"
  dispatch_writer || true
  local line state
  line="$(gate_read "$sha")"; state="${line%%$'\t'*}"
  if [ "$state" = "pending" ]; then
    ok "gate stays pending on reviewer silence"
  else
    bad "gate must stay pending on silence (state=$state)"
  fi
  close_pr "$pr" "$br"
}

s9() { # idle-tick idempotence: two writer passes with no events append nothing
  CURRENT=s9
  local br=s9-idle pr sha n1 n2
  mkbranch "$br"; pr="$(open_pr "$br" "s9 idle idempotence")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "fresh head pends"
  dispatch_writer || true
  n1="$(gate_entry_count "$sha")"
  dispatch_writer || true
  dispatch_writer || true
  n2="$(gate_entry_count "$sha")"
  if [ "$n1" = "$n2" ]; then
    ok "idle passes append zero gate entries ($n1 before, $n2 after)"
  else
    bad "idle passes appended entries ($n1 -> $n2)"
  fi
  close_pr "$pr" "$br"
}

s10a() { # approval landing WHILE CI is in flight (the modal bot-review
         # timing). Under the simplified engine this is unremarkable: the
         # gate reflects the review verdict whatever CI is doing, and the
         # queue decides whether the code may merge. Kept because it was
         # the hardest case for the old proof-based design.
  CURRENT=s10a
  local br=s10a-midci pr sha waited=0 st=""
  mkbranch "$br" ".sandbox-slow-gate" "widen the in-flight window"
  pr="$(open_pr "$br" "s10a approval mid-CI")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  while [ "$waited" -le 180 ]; do
    st="$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
      --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI" and .status != "completed")] | length')"
    [ "${st:-0}" -ge 1 ] && break
    sleep 5; waited=$((waited + 5))
  done
  [ "${st:-0}" -ge 1 ] || bad "attempt 1 never appeared in flight"
  review "$pr" APPROVE "approved while CI is in flight"
  await_review_success "$sha" "approval mid-CI" 600
  close_pr "$pr" "$br"
}

s10b() { # a FAILING test suite must not affect the gate, and must still
         # block the merge. Gate red means "a reviewer objects" and nothing
         # else; build failure is the required checks' business.
  CURRENT=s10b
  local br=s10b-red pr sha heavy
  mkbranch "$br" ".sandbox-heavy-fail" "fail the heavy job"
  pr="$(open_pr "$br" "s10b failing suite")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "fresh head pends"
  review "$pr" APPROVE
  await_review_success "$sha" "a failing suite does not close the review gate" 600
  # And the failure is visible where it belongs — on the check itself.
  gh pr merge "$pr" -R "$REPO" --squash --auto >/dev/null 2>&1 || true
  local waited=0 merged=""
  while [ "$waited" -le 420 ]; do
    merged="$(gh api "repos/$REPO/pulls/$pr" --jq .merged)"
    [ "$merged" = "true" ] && break
    heavy="$(gh run list -R "$REPO" --workflow CI --event merge_group --limit 5 \
      --json conclusion,createdAt --jq '[.[] | select(.createdAt >= "'"$REPLAY_SINCE"'")] | sort_by(.createdAt) | last | .conclusion // "absent"')"
    [ "$heavy" = "failure" ] && break
    sleep 20; waited=$((waited + 20))
  done
  if [ "$merged" = "true" ]; then
    bad "a PR with a failing suite MERGED — the required checks are not blocking"
  else
    ok "the failing suite blocks the merge (queue CI conclusion=${heavy:-pending})"
  fi
  gh pr merge "$pr" -R "$REPO" --disable-auto >/dev/null 2>&1 || true
  close_pr "$pr" "$br"
}

sfinal() { # cross-cutting: the cron leg is alive and green, and NO writer run
           # of any leg red'd during the replay
  CURRENT=sfinal
  local reds evicted killed unknown id started
  # Bounded to THIS replay: an unbounded window would drag in runs from
  # earlier sessions (including deliberately-broken engine versions) and
  # either fail a healthy replay or hide a fresh regression behind old runs.
  # REPLAY_SINCE is stamped at driver start.
  reds="$(gh run list -R "$REPO" --workflow "Review gate writer" --limit 200 \
    --json conclusion,createdAt \
    --jq '[.[] | select(.createdAt >= "'"$REPLAY_SINCE"'" and .conclusion == "failure")] | length')"
  if [ "${reds:-0}" = "0" ]; then
    ok "no writer run of ANY leg failed during the replay"
  else
    bad "$reds writer run(s) failed during the replay"
  fi
  # `cancelled` covers TWO very different things, and only one is a fault:
  # a pending run EVICTED from the concurrency group (never starts a step —
  # harmless by design, because every executing run converges every open PR)
  # versus a run KILLED by its own timeout mid-work (a malfunction the
  # VST-36 escalation exists for). Tell them apart by whether any step ran.
  evicted=0
  killed=0
  unknown=0
  for id in $(gh run list -R "$REPO" --workflow "Review gate writer" --limit 200 \
      --json databaseId,conclusion,createdAt \
      --jq '.[] | select(.createdAt >= "'"$REPLAY_SINCE"'" and .conclusion == "cancelled") | .databaseId'); do
    # An UNREADABLE jobs list is not evidence of a harmless eviction — it is
    # no evidence at all. Separate the read failure from the verdict so a
    # transient 5xx or a permission fault cannot launder a killed run into
    # the benign bucket.
    if ! started="$(gh api "repos/$REPO/actions/runs/$id/jobs" \
        --jq '[.jobs[] | .steps[]? | select(.conclusion != "skipped" and (.started_at // "") != "")] | length')"; then
      unknown=$((unknown + 1))
      note "cancelled run $id: jobs list unreadable — cannot classify"
      continue
    fi
    case "$started" in
      ''|*[!0-9]*)
        unknown=$((unknown + 1))
        note "cancelled run $id: unparseable jobs response — cannot classify"
        ;;
      0) evicted=$((evicted + 1)) ;;
      *)
        killed=$((killed + 1))
        note "cancelled run $id executed steps before dying — investigate"
        ;;
    esac
  done
  if [ "$unknown" -gt 0 ]; then
    bad "$unknown cancelled writer run(s) could not be classified (jobs list unreadable)"
  fi
  note "concurrency evictions during the replay: $evicted (harmless: converge-all means the surviving run covers those heads)"
  if [ "$killed" = "0" ]; then
    ok "no writer run was killed mid-work (evictions only)"
  else
    bad "$killed writer run(s) were cancelled after executing steps"
  fi
  if [ "$evicted" -gt 0 ]; then
    ok "eviction actually occurred ($evicted runs) and no scenario stranded — converge-all (binding F2) proven live, not theoretically"
  fi
  # The cron leg is a LIVENESS check, not a replay-window one: the schedule
  # fires every 15 minutes (best-effort), so a short replay can legitimately
  # contain zero ticks. Assert instead that a tick landed recently and that
  # every recent tick was green — which is what "the floor is alive" means.
  local recent now newest_age n_recent
  # --event filters SERVER-SIDE: a client-side filter over the newest N runs
  # finds nothing on a busy repo, where event-leg runs fill the whole slice.
  recent="$(gh run list -R "$REPO" --workflow "Review gate writer" \
    --event schedule --limit 5 \
    --json conclusion,createdAt --jq 'sort_by(.createdAt) | reverse')"
  n_recent="$(jq length <<<"$recent")"
  if [ "${n_recent:-0}" -eq 0 ]; then
    bad "cron floor: no schedule-leg writer runs exist at all (is the schedule trigger disabled?)"
    return
  fi
  now="$(date -u +%s)"
  newest_age=$(( now - $(iso_epoch "$(jq -r '.[0].createdAt' <<<"$recent")") ))
  # 40 minutes: two 15-minute ticks plus slack for GitHub's best-effort
  # delivery, which can slip 10-20+ minutes under load.
  if [ "$newest_age" -le 2400 ]; then
    ok "cron floor: a schedule tick landed ${newest_age}s ago (the floor is alive)"
  else
    bad "cron floor: newest schedule tick is ${newest_age}s old — the schedule may be disabled or slipping"
  fi
  # Only SETTLED ticks can be judged: a tick still running has no conclusion
  # yet, and a `cancelled` one is a concurrency eviction — harmless, and
  # already accounted for by the global classifier above. Counting either
  # against greenness would fail a perfectly healthy replay. Genuine
  # failures, timeout kills, and unclassifiable cancellations are caught by
  # the global checks; this one asks only "are the ticks that finished
  # normally green?".
  local settled n_settled green_recent
  settled="$(jq '[.[] | select((.conclusion // "") != "" and .conclusion != "cancelled")]' <<<"$recent")"
  n_settled="$(jq length <<<"$settled")"
  green_recent="$(jq '[.[] | select(.conclusion == "success")] | length' <<<"$settled")"
  if [ "${n_settled:-0}" -eq 0 ]; then
    note "cron floor: no settled schedule ticks in the recent window (all active or evicted) — liveness above is the signal"
  elif [ "$green_recent" = "$n_settled" ]; then
    ok "cron floor: all $n_settled settled schedule ticks are green"
  else
    bad "cron floor: only $green_recent of $n_settled settled schedule ticks are green"
  fi
}

# ------------------------------------------------------------------- main ---

for s in $SCENARIOS; do
  if ! declare -F "$s" >/dev/null; then
    echo "unknown scenario: $s" >&2; exit 2
  fi
  "$s"
done

CURRENT=""
echo
printf 'e2e-sandbox: pass %d, fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
