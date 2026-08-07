#!/usr/bin/env bash
# Layer-2 E2E replay for the v2 single writer against a LIVE sandbox repo
# (docs/plans/review-gate-v2-single-writer.md, "Validation and cutover").
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
#   - GitHub Actions may create PRs (repo/org/enterprise setting).
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

REPO="${E2E_REPO:-vanillagreencom/review-gate-sandbox}"
SCENARIOS="${E2E_SCENARIOS:-s1 s2 s3 s4 s5 s6 s7 s9 s10a s10b s10d sfinal}"
GATE_CTX="Review gate"
OVERRIDE_CTX="vstack-reviewer-outage"

PASS=0
FAIL=0
CURRENT=""

note() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "${CURRENT:-driver}" "$*"; }
ok()   { PASS=$((PASS + 1)); note "ok    $*"; }
bad()  { FAIL=$((FAIL + 1)); note "FAIL  $*"; }

ME="$(gh api user --jq .login)" || { echo "gh auth required"; exit 1; }
note "driver identity: $ME (repo $REPO)"

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
    -f content="$(printf '%s\n' "$content" | base64 -w0)" \
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

# The standard proof-cycle assertion: after approval evidence lands on a head
# whose attempt 1 ran gate-closed, the writer must (1) never post success
# before a proof attempt (>= 2) exists, (2) rerun exactly once, (3) post
# success after the proof attempt completes.
await_proof_success() { # sha label [timeout]
  local sha="$1" label="$2" timeout="${3:-600}"
  if await_gate "$sha" success "$timeout"; then
    ok "$label: gate success"
  else
    bad "$label: gate success"; return 1
  fi
  local attempts
  attempts="$(ci_attempts "$sha")"
  if [ "$attempts" -ge 2 ]; then
    ok "$label: proof attempt exists (attempt $attempts)"
  else
    bad "$label: expected a proof rerun (attempt >= 2), saw attempt $attempts"
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
  await_proof_success "$sha" "copilot COMMENTED-only profile"
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
  await_proof_success "$sha" "coderabbit review+status profile"
  close_pr "$pr" "$br"

  # --- qodo profile: plain APPROVED review; ride it through the merge queue
  #     (scenario 8) ---
  br=s1-qodo; mkbranch "$br"; pr="$(open_pr "$br" "s1 qodo profile + queue merge")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "qodo: fresh head pends awaiting"
  review "$pr" APPROVE
  await_proof_success "$sha" "qodo APPROVED profile"
  gh pr merge "$pr" -R "$REPO" --squash --auto >/dev/null 2>&1 || bad "queue: enqueue failed"
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
  await_proof_success "$sha" "thread resolution (no webhook; floor tick converges)"
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
  await_proof_success "$sha" "dismiss + re-approve"
  close_pr "$pr" "$br"
}

s4() { # push discards evidence -> re-review -> docs-only push CARRIES with
       # ZERO rerun (binding F1's showcase: one heavy bill on the carry push)
  CURRENT=s4
  local br=s4-carry pr shaA shaB shaC
  mkbranch "$br"; pr="$(open_pr "$br" "s4 carry-forward")" || { bad "open PR"; return; }
  shaA="$(head_sha "$pr")"
  review "$pr" APPROVE
  await_proof_success "$shaA" "initial approval"
  # Code push: evidence is head-bound, so the gate must close on the new head.
  put_file "$br" "scenario/$br.txt" "scenario $br line one CHANGED" "code delta"
  shaB="$(await_new_head "$pr" "$shaA")" || bad "code push never surfaced a new head"
  assert_gate "$shaB" pending 300 "awaiting" "code push closes the gate (evidence head-bound)"
  review "$pr" APPROVE "re-review after the code push"
  await_proof_success "$shaB" "re-review"
  # Docs-only push: carry-forward (docs class) keeps the gate open WITHOUT
  # re-review, and F1's ordering fast path must spare the redundant rerun.
  put_file "$br" "docs/note-$br.md" "just a doc line" "docs-only delta"
  shaC="$(await_new_head "$pr" "$shaB")" || bad "docs push never surfaced a new head"
  assert_gate "$shaC" success 480 "carried" "docs-only push carries WITHOUT re-review"
  if await_ci_settled "$shaC" 120; then :; fi
  local attempts
  attempts="$(ci_attempts "$shaC")"
  if [ "$attempts" = "1" ]; then
    ok "carry push ran heavy CI exactly ONCE (zero-rerun, binding F1)"
  else
    bad "carry push must not rerun heavy CI (attempts=$attempts, wanted 1)"
  fi
  close_pr "$pr" "$br"
}

s5() { # true fork PR: no special-casing; the pull_request_review-triggered
       # writer run no-ops GREEN; status-form evidence converges the head
  CURRENT=s5
  gh repo fork "$REPO" --clone=false >/dev/null 2>&1 || true
  sleep 5
  local fork="$ME/${REPO#*/}" br=s5-fork pr sha base
  # Sync the fork's main, then branch on the fork.
  gh api -X POST "repos/$fork/merge-upstream" -f branch=main >/dev/null 2>&1 || true
  base="$(gh api "repos/$fork/git/ref/heads/main" --jq .object.sha)"
  gh api -X POST "repos/$fork/git/refs" -f ref="refs/heads/$br" -f sha="$base" >/dev/null 2>&1 || true
  gh api -X PUT "repos/$fork/contents/scenario/$br.txt" \
    -f message="seed $br" -f branch="$br" \
    -f content="$(printf 'fork scenario line\n' | base64 -w0)" >/dev/null
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
  await_proof_success "$sha" "fork PR via status evidence" 900
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
  await_proof_success "$sha" "operator override (PAT-posted, reason carried)"
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

s10a() { # approval mid-CI (the modal bot timing) + 10c temporal proof + 10e
         # completion-signal latency
  CURRENT=s10a
  local br=s10a-midci pr sha
  mkbranch "$br" ".sandbox-slow-gate" "widen the in-flight window"
  pr="$(open_pr "$br" "s10a approval mid-CI")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  # Wait for attempt 1 to be IN FLIGHT, then land the approval inside it.
  local waited=0 st=""
  while [ "$waited" -le 180 ]; do
    st="$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
      --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI" and .status != "completed")] | length')"
    [ "${st:-0}" -ge 1 ] && break
    sleep 5; waited=$((waited + 5))
  done
  [ "${st:-0}" -ge 1 ] || bad "attempt 1 never appeared in flight"
  review "$pr" APPROVE "approved while attempt 1 is in flight"
  await_proof_success "$sha" "approval mid-CI (10a)" 900
  # 10c: temporal assertion — the success postdates the proof attempt's
  # start, and no success exists from before the rerun was issued.
  local success_at attempt2_start
  success_at="$(gh api "repos/$REPO/commits/$sha/statuses?per_page=100" --paginate \
    | jq -rs --arg ctx "$GATE_CTX" '[add // [] | .[] | select(.context == $ctx and .state == "success")] | sort_by(.created_at) | first | .created_at // ""')"
  attempt2_start="$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
    --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI")] | last | .run_started_at // ""')"
  if [ -n "$success_at" ] && [ -n "$attempt2_start" ] && [[ "$success_at" > "$attempt2_start" ]]; then
    ok "10c: first success ($success_at) postdates the proof attempt's start ($attempt2_start)"
  else
    bad "10c: success/rerun ordering violated (success=$success_at, attempt-start=$attempt2_start)"
  fi
  # 10e: completion-signal latency — success must arrive within the event
  # path's claimed bound (seconds-to-minutes), not the cron window.
  local attempt2_end delta
  attempt2_end="$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
    --jq '[.workflow_runs[] | select(.event == "pull_request" and .name == "CI")] | last | .updated_at // ""')"
  delta=$(( $(date -d "$success_at" +%s) - $(date -d "$attempt2_end" +%s) ))
  if [ "$delta" -le 300 ]; then
    ok "10e: success arrived ${delta}s after the proof attempt completed (event path, not cron)"
  else
    bad "10e: success took ${delta}s after completion (silent degradation to the cron floor?)"
  fi
  close_pr "$pr" "$br"
}

s10b() { # red proof attempt: gate posts success once the attempt has RUN;
         # the red required check blocks merge on its own
  CURRENT=s10b
  local br=s10b-red pr sha
  mkbranch "$br" ".sandbox-heavy-fail" "fail the heavy job"
  pr="$(open_pr "$br" "s10b red proof attempt")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "fresh head pends"
  review "$pr" APPROVE
  await_proof_success "$sha" "red-attempt semantics (gate success once the attempt RAN)" 900
  local heavy
  heavy="$(gh api "repos/$REPO/commits/$sha/check-runs?per_page=100" \
    --jq '[.check_runs[] | select(.name == "heavy")] | sort_by(.completed_at) | last | .conclusion // "none"')"
  if [ "$heavy" = "failure" ]; then
    ok "the heavy check itself is red (blocks merge as its own required check)"
  else
    bad "expected the proof attempt's heavy job to fail (saw $heavy)"
  fi
  close_pr "$pr" "$br"
}

s10d() { # cap exhaustion: a head already at MAX_RERUN_ATTEMPTS is left
         # alone — gate stays non-success, writer run stays green (stuck,
         # not malfunction)
  CURRENT=s10d
  local br=s10d-cap pr sha rid i
  mkbranch "$br"; pr="$(open_pr "$br" "s10d rerun cap")" || { bad "open PR"; return; }
  sha="$(head_sha "$pr")"
  assert_gate "$sha" pending 300 "awaiting" "fresh head pends"
  await_ci_settled "$sha" 300 || bad "attempt 1 never settled"
  rid="$(ci_run_id "$sha")"
  for i in 2 3 4 5; do
    gh run rerun "$rid" -R "$REPO" >/dev/null 2>&1 || note "manual rerun $i refused"
    await_ci_settled "$sha" 300 || note "attempt $i never settled"
  done
  local attempts
  attempts="$(ci_attempts "$sha")"
  note "head is at attempt $attempts (cap is 5)"
  local before
  before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  review "$pr" APPROVE "approval at the cap"
  sleep 60
  dispatch_writer || true
  local line state
  line="$(gate_read "$sha")"; state="${line%%$'\t'*}"
  if [ "$state" != "success" ]; then
    ok "10d: gate stays non-success at the rerun cap (state=$state), never silently open"
  else
    bad "10d: gate opened at the cap without a fresh proof attempt"
  fi
  local reds
  reds="$(gh run list -R "$REPO" --workflow "Review gate writer" --json conclusion,createdAt \
    --jq '[.[] | select(.createdAt >= "'"$before"'" and .conclusion == "failure")] | length')"
  if [ "${reds:-0}" = "0" ]; then
    ok "10d: cap exhaustion is STUCK, not malfunction (no red writer runs)"
  else
    bad "10d: writer runs redded on a stuck head ($reds red runs)"
  fi
  close_pr "$pr" "$br"
}

sfinal() { # cross-cutting: the cron leg is alive and green; no writer run
           # has red'd unexpectedly during the whole replay
  CURRENT=sfinal
  local sched
  sched="$(gh run list -R "$REPO" --workflow "Review gate writer" --limit 100 \
    --json event,conclusion \
    --jq '[.[] | select(.event == "schedule")] | {n: length, green: [.[] | select(.conclusion == "success")] | length}')"
  note "schedule-leg runs: $sched"
  if [ "$(jq -r .n <<<"$sched")" -ge 1 ] && [ "$(jq -r .n <<<"$sched")" = "$(jq -r .green <<<"$sched")" ]; then
    ok "cron floor: schedule-leg writer runs exist and are all green"
  else
    bad "cron floor: missing or red schedule-leg runs ($sched)"
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
