#!/usr/bin/env bash
# One complete repository job in a disposable consumer, on real production
# operations with fake external services and no CI (plan step 3, decisions
# 46 to 54, 79 to 83, 93, 100 to 103): admission, launch, dev result, the
# configured review route, publication preparation, verification and report,
# then close; and the two interruptions the design survives, a context
# handoff resumed by a relaunch and a lane killed with a validation run
# admitted and going.
#
# Inputs: orch's scripts and runtime (scripts/orch-runtime through
# scripts/setup), agent-runtime's launch and stop, the worktree, dev,
# reviewer, mailbox, github and change-scope skills, the workflow commands
# tests/job/stub-harness runs, and the gh fake in github/tests/lib/gh-stub.sh.
#
# Rows, one job each: a GitHub issue at the small tier (launch-time
# item-tier --body --path, the internal panel route, gh issue close), a
# tracker-less local key at the small tier (new-local-key, no tracker read,
# a lane that exits when done), a GitHub issue at the micro tier (no dev
# round, no review), the local handoff row (the lane records a handoff after
# its dev receipt and ends; the relaunch resumes the same round) and the
# GitHub killed row (the lane dies with its admitted run held; the close
# stops the run, the relaunch reconciles the round and retries). An argument
# runs the rows whose name contains it.
#
# The job runs inside a mktemp -d root: a consumer repository, its bare
# origin, a private tmux server on the suite's own socket, and the lane's
# worktree. The harness is tests/job/stub-harness, selected through
# ORCH_HARNESS_BINARIES; ONE_JOB_STUB_HARNESS names another copy, which is
# how a control runs a mutated stub without touching the tracked one.
# Nothing here reaches a real harness home, GitHub, Linear or a network
# remote: PATH is sealed behind tools/tests/lib/sealed-bin.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# shellcheck source=../lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=../lib/sealed-bin.sh
source "$TEST_DIR/lib/sealed-bin.sh"
# shellcheck source=../lib/one-job-fixture.sh
source "$TEST_DIR/lib/one-job-fixture.sh"

TMP_ROOT="$(mktemp -d)" || { echo "one-job: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "one-job: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "one-job: scratch=resolve-failed" >&2; exit 1; }
cleanup() {
  local status=$?
  if [[ "$status" != 0 && -n "${wt:-}" && -f "$wt/tmp/lane.log" ]]; then
    printf -- '--- lane.log (%s)\n' "$wt" >&2
    tail -n 60 "$wt/tmp/lane.log" >&2
  fi
  # The suite's own server, by its socket; never a kill by name.
  [[ -z "${ONE_JOB_SOCKET:-}" || ! -S "$ONE_JOB_SOCKET" ]] || tmux -S "$ONE_JOB_SOCKET" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT

STUB="${ONE_JOB_STUB_HARNESS:-$TEST_DIR/job/stub-harness}"
[[ -x "$STUB" ]] || { echo "one-job: stub-harness=not-executable path=[$STUB]" >&2; exit 1; }
# The runtime binary for these sources, through the shipped setup route;
# a cache that already holds it builds nothing.
"$REPO_ROOT/skills/orch/scripts/setup" >"$TMP_ROOT/setup.out" 2>&1 || { cat "$TMP_ROOT/setup.out" >&2; exit 1; }

# Nothing of the caller's orchestration environment reaches the job: the
# settings file is the one source of the job's configuration, the gh fake
# is its GitHub, and its tmux server is the private one.
unset ORCH_STATE_DIR ORCH_DELIVERY ORCH_PR_ORDER ORCH_TMUX_SESSION ORCH_HARNESS_BINARIES ORCH_LAUNCH_PERMISSION \
  ORCH_TMUX_VERIFY_SECS ORCH_LANE_CLOSE_SECS DEV_VALIDATE_CMD DEV_VALIDATE_RANGE_CMD DEV_VALIDATE_CI_CONTEXT \
  DEV_VALIDATE_SELECTION_CMD DEV_VALIDATE_TIMEOUT_SECS WORKTREE_DEFAULT_BRANCH WORKTREE_BASE_DIR WORKTREE_SYMLINKS \
  KENDEX_ENV_FILE GH_REPO GITHUB_REPOSITORY GITHUB_TOKEN GH_BOT_TOKEN KENDEX_SESSION_OWNER HT_SESSION_OWNER \
  CI_WAIT_MAX_SECS
one_job_bin "$TMP_ROOT/bin"
export PATH="$TMP_ROOT/bin:$SEALED:$PATH"
mkdir -p "$TMP_ROOT/home"
one_job_server "$TMP_ROOT/server" fleet
# The runtime resolves the fleet server from its own $TMUX, as a lane does.
export TMUX="$ONE_JOB_SOCKET,0,0"

FILTER="${1:-}"

# The gh reads verify-head makes for a head nothing has checked on a base
# with no rule, in the order the op makes them (the runtime's evidence
# reader): one row per read as PATH|SELECTOR|REPLY. PATH carries SHA for the
# pinned head; the fake answers a read whose PATH names the head by SELECTOR,
# a part of the call no head appears in, and every other read under its
# exact PATH.
VERIFY_READS='repos/owner/repo/commits/SHA/check-runs?filter=all&per_page=100&page=1|/check-runs?filter=all&per_page=100&page=1|{"total_count":0,"check_runs":[]}
repos/owner/repo/commits/SHA/check-suites?per_page=100&page=1|/check-suites?per_page=100&page=1|{"total_count":0,"check_suites":[]}
repos/owner/repo/commits/SHA/status?per_page=100&page=1|/status?per_page=100&page=1|{"state":"pending","total_count":0,"statuses":[]}
repos/owner/repo/actions/runs?head_sha=SHA&per_page=100&page=1|/actions/runs?head_sha=|{"total_count":0,"workflow_runs":[]}
repos/owner/repo/actions/workflows?per_page=100&page=1|-|{"total_count":0,"workflows":[]}
repos/owner/repo/rules/branches/main?per_page=100&page=1|-|[]
repos/owner/repo/branches/main|-|{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}'

# stage_verify_reads — every answer of VERIFY_READS, staged before the lane
# launches (the head is not known until the job pushes it).
stage_verify_reads() {
  local path selector reply
  while IFS='|' read -r path selector reply; do
    if [[ "$path" == *SHA* ]]; then
      gh_stub_answer "api:$selector" "$reply"
    else
      gh_stub_answer "api-$path" "$reply"
    fi
  done <<<"$VERIFY_READS"
}

# await FILE PATTERN BOUND_TENTHS — wait for a line matching PATTERN in FILE.
await() {
  local tries=0
  until [[ -f "$1" ]] && grep -qE -- "$2" "$1"; do
    tries=$((tries + 1))
    [[ "$tries" -lt "$3" ]] || return 1
    sleep 0.1
  done
}

# await_gone PID BOUND_TENTHS — wait until no process answers for PID.
await_gone() {
  local tries=0
  while kill -0 "$1" 2>/dev/null; do
    tries=$((tries + 1))
    [[ "$tries" -lt "$2" ]] || return 1
    sleep 0.1
  done
}

state_get() { # STATE FILTER
  jq -r "$2" "$1"
}

# validate_stages STATE ROUND_ID — the round's validate stages as the rows
# the suite compares: run directory, closed, outcome.
validate_stages() { # STATE ROUND_ID
  jq -c --arg r "$2" '[.stages[] | select(.kind == "validate" and .round_id == $r)] | map({run_dir, closed: (.end != null), outcome: (.outcome // null)})' "$1"
}

# launch_lane NAME ROOT REQUEST — one launch-lane op (skills/orch/workflows/oversee.md § 3):
# confirmed, running, the recorded pid the stub. Sets PID and PANE. Returns 1
# on a refused launch, after failing the row.
launch_lane() { # NAME ROOT REQUEST
  local launched cmdline
  launched="$(cd "$main" && "$orch/orch-runtime" op --fleet --request "$3" 2>"$2/launch.err")" \
    || { fail "$1: launch-lane" "$(cat "$2/launch.err")"; return 1; }
  assert_eq "$(jq -r '.result.effect.report.intent.outcome + " " + .result.effect.report.lane.status' <<<"$launched")" \
    "confirmed running" "$1: the launch confirms and the lane runs"
  PID="$(jq -r '.result.effect.report.lane.launch.pid' <<<"$launched")"
  PANE="$(jq -r '.result.effect.report.lane.launch.pane' <<<"$launched")"
  cmdline="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || echo unreadable)"
  assert_eq "$(case "$cmdline" in *"$STUB"*) echo stub ;; *) echo "$cmdline" ;; esac)" stub "$1: the recorded pid is the stub harness"
}

# close_lane NAME ROOT GROUND — one close-owned-resources op on GROUND, the
# request's ground fields as a JSON object ({} for a bare close of an exited
# lane): confirmed, the lane done, the ground recorded on the intent as the
# request gave it. Sets CLOSED to the reply.
close_lane() { # NAME ROOT GROUND
  jq -cn --arg item "$key" --argjson ground "$3" '{op: "close-owned-resources", item: $item} + $ground' > "$2/close.json"
  CLOSED="$(cd "$main" && "$orch/orch-runtime" op --fleet --request "$2/close.json" 2>"$2/close.err")" \
    || { fail "$1: close-owned-resources" "$(cat "$2/close.err")"; return 1; }
  assert_eq "$(jq -r '.result.effect.report.intent.outcome + " " + .result.effect.report.lane.status' <<<"$CLOSED")" "confirmed done" \
    "$1: the close confirms and the lane is done"
  assert_eq "$(jq -c '.result.effect.report.intent.close' <<<"$CLOSED")" \
    "$(jq -cn --argjson g "$3" 'if $g.terminal then {ground: "terminal"} + $g.terminal else {ground: "exited"} end')" \
    "$1: the close stands on the ground the request gave"
  assert_eq "$(jq -r --arg k "$key" '[.lanes[] | select(.item == $k) | .status] | join(",")' "$fleet")" "done" "$1: the fleet record holds the lane as done"
}

# run_job NAME KEY_KIND TIER SCENARIO — one row: the overseer side here, the
# lane side in the stub, then the assertions on the artifacts the job left.
# SCENARIO is the stub's (plain, handoff, killed); a GitHub lane idles when
# done and is closed on the tracker's terminal answer, a local lane exits
# when done and is closed exited.
run_job() { # NAME KEY_KIND TIER SCENARIO
  local name="$1" key_kind="$2" tier="$3" scenario="$4" root main orch key number tracker body tier_line delta after
  local wt brief request fleet state lane_status run_dir dev_rid review_rid pushed artifact
  local calls first_run first_id retry_run ground
  root="$TMP_ROOT/$name"
  mkdir -p -- "$root"
  gh_stub_reset
  one_job_consumer "$root" "$STUB"
  main="$ONE_JOB_MAIN"
  orch="$main/.agents/skills/orch/scripts"

  # --- the fleet record and the launch-time admission (skills/orch/workflows/oversee.md § 3) ---
  (cd "$main" && "$orch/orch-runtime" state init --fleet >/dev/null) || { fail "$name: fleet init"; return 0; }
  case "$tier" in small) delta=30 ;; micro) delta=2 ;; esac
  if [[ "$key_kind" == github ]]; then
    tracker=github
    after=idle
    number=7
    [[ "$tier" != micro ]] || number=9
    key="issue-$number"
    one_job_issue_body "$number" "$delta" > "$root/body.md"
    one_job_stage_gh "$number" "$root/body.md"
    body="$(cd "$main" && gh issue view "$number" --repo owner/repo --json number,title,body,url,labels,state)"
    assert_eq "$(jq -r '.state' <<<"$body")" OPEN "$name: the tracker read answers an open issue"
    jq -r '.body' <<<"$body" > "$root/issue-body.md"
    tier_line="$(cd "$main" && "$orch/item-tier" --body "$root/issue-body.md" --path lib.sh --repo "$main")" || tier_line="exit=$?"
    assert_eq "$tier_line" "tier=$tier brief=$tier cause=estimate-within-$tier production=$delta estimate=- delta=$delta paths=1" \
      "$name: launch-time admission reads the tier from the body and the Location path"
  else
    tracker=local
    after="exit"
    number=""
    key="$(cd "$main" && "$orch/workflow-state" new-local-key)"
    assert_eq "$([[ "$key" =~ ^local-[0-9]+-[0-9]+-[0-9a-f]+$ ]] && echo shaped || echo "$key")" shaped "$name: a local key is minted"
    one_job_stage_gh 1 /dev/null
    tier_line="$(cd "$main" && "$orch/item-tier" --production "$delta" --path lib.sh --repo "$main")" || tier_line="exit=$?"
    assert_eq "$tier_line" "tier=$tier brief=$tier cause=estimate-within-$tier production=$delta estimate=$delta delta=- paths=1" \
      "$name: launch-time admission reads the tier from the estimate and the Location path"
  fi
  stage_verify_reads

  # --- the worktree and the lane (skills/orch/workflows/start.md § 4, skills/orch/workflows/oversee.md § 3) ---
  wt="$(cd "$main" && "$main/.agents/skills/worktree/scripts/worktree" create "$key" 2>"$root/create.err")" \
    || { fail "$name: worktree create" "$(cat "$root/create.err")"; return 0; }
  assert_eq "$(git -C "$wt" branch --show-current)" "$key" "$name: the worktree is on the item branch"
  mkdir -p "$wt/tmp"
  brief="$wt/tmp/brief-$key.md"
  write_brief() { # FILE SCENARIO
    {
      printf 'item=%s\n' "$key"
      printf 'tier=%s\n' "$tier"
      printf 'tracker=%s\n' "$tracker"
      printf 'repo=owner/repo\n'
      printf 'number=%s\n' "$number"
      printf 'worktree=%s\n' "$wt"
      printf 'main=%s\n' "$main"
      printf 'scenario=%s\n' "$2"
      printf 'after=%s\n' "$after"
    } > "$1"
  }
  write_brief "$brief" "$scenario"
  request="$root/launch.json"
  jq -cn --arg item "$key" --arg wt "$wt" --arg home "$TMP_ROOT/home" --arg brief "$brief" --arg tracker "$tracker" \
    '{op: "launch-lane", item: $item, harness: "claude", mail_root: $wt, account: $home, repo: "owner/repo", brief_file: $brief}
     + (if $tracker == "github" then {tracker: "github"} else {} end)' > "$request"
  launch_lane "$name" "$root" "$request" || return 0
  fleet="$main/tmp/workflow-state-oversee.json"
  assert_eq "$(jq -c --arg k "$key" '[.lanes[] | select(.item == $k)] | map({status, server: .launch.server, pane: .launch.pane, pid: .launch.pid})' "$fleet")" \
    "$(jq -cn --argjson s "$ONE_JOB_SERVER_PID" --arg p "$PANE" --argjson pid "$PID" '[{status: "running", server: $s, pane: $p, pid: $pid}]')" \
    "$name: the fleet record holds the lane with its launch identity on the suite's server"
  lane_status="$wt/tmp/lane-status"
  state="$main/tmp/workflow-state-$key.json"

  case "$scenario" in
    handoff)
      # --- the lane ends out of context with its round open; the relaunch resumes it ---
      if ! await "$lane_status" '^lane-handoff$' 2400; then
        fail "$name: the lane records its handoff within the bound" "$(cat "$lane_status" 2>/dev/null)"
        return 0
      fi
      dev_rid="$(state_get "$state" '.dev_round_id // empty')"
      first_run="$(jq -r '.run_dir' "$wt/tmp/admission-report.json")"
      assert_eq "$(jq -c '[.recorded_now, .replaced]' "$wt/tmp/handoff-report.json")" '[true,false]' \
        "$name: the handoff is recorded once"
      assert_eq "$(jq -c '[(.handoff.round_id == .dev_round_id), .handoff.relaunch, .handoff.resumed_at, (.handoff.remaining | length)]' "$state")" \
        '[true,"resume",null,3]' "$name: the record names the open round, asks for a resume and is not yet consumed"
      assert_eq "$(validate_stages "$state" "$dev_rid")" "$(jq -cn --arg run "$first_run" '[{run_dir: $run, closed: false, outcome: null}]')" \
        "$name: the admitted run's stage is still open when the session ends"
      assert_eq "$(await_gone "$PID" 100 && echo gone || echo alive)" gone "$name: the session's harness has exited"
      close_lane "$name" "$root" '{}' || return 0
      assert_eq "$(state_get "$state" '.handoff.resumed_at')" null "$name: closing the exited lane leaves the handoff standing"
      launch_lane "$name" "$root" "$request" || return 0
      assert_eq "$(jq -c --arg k "$key" '[.lanes[] | select(.item == $k)] | map({status, pid: .launch.pid})' "$fleet")" \
        "$(jq -cn --argjson pid "$PID" '[{status: "running", pid: $pid}]')" "$name: the relaunch is the same lane record under a new harness"
      if ! await "$lane_status" '^lane-(done|failed)' 2400; then
        fail "$name: the relaunched lane ends its job within the bound" "$(cat "$lane_status" 2>/dev/null)"
        return 0
      fi
      assert_eq "$(jq -c --arg r "$dev_rid" --arg run "$first_run" '[.resumed_now, (.round_id == $r), (.open_runs == [$run]), .relaunch]' "$wt/tmp/resume-report.json")" \
        '[true,true,true,"resume"]' "$name: the continuation resumes the recorded round and finds its admitted run open"
      assert_eq "$(jq -c --slurpfile r "$wt/tmp/resume-report.json" '[(.handoff.resumed_at == $r[0].resumed_at), (.handoff.resumed_at | type)]' "$state")" \
        '[true,"number"]' "$name: the record is stamped resumed once, with the stamp the continuation read"
      assert_eq "$(state_get "$state" '.dev_round_id')" "$dev_rid" "$name: the relaunch continues the same dev round"
      ;;
    killed)
      # --- the lane dies with its validation run admitted and held; the close ends the run, the relaunch retries ---
      if ! await "$lane_status" '^step=validate-held$' 2400; then
        fail "$name: the lane holds its validation run within the bound" "$(cat "$lane_status" 2>/dev/null)"
        return 0
      fi
      dev_rid="$(state_get "$state" '.dev_round_id // empty')"
      first_run="$(jq -r '.run_dir' "$wt/tmp/admission-report.json")"
      first_id="$(jq -r '.run_id' "$wt/tmp/admission-report.json")"
      assert_eq "$(validate_stages "$state" "$dev_rid")" "$(jq -cn --arg run "$first_run" '[{run_dir: $run, closed: false, outcome: null}]')" \
        "$name: the held run's stage is open while it runs"
      held_pid="$(cat "$first_run/pid")"
      assert_eq "$(kill -0 "$held_pid" 2>/dev/null && echo alive || echo gone)" alive "$name: the admitted run's child is alive when the lane is killed"
      # The lane's process group dies, harness and what it started with it;
      # the detached run is the runner's and survives.
      kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID"
      assert_eq "$(await_gone "$PID" 100 && echo gone || echo alive)" gone "$name: the killed harness is gone"
      assert_eq "$(kill -0 "$held_pid" 2>/dev/null && echo alive || echo gone)" alive "$name: the admitted run outlives the lane that started it"
      close_lane "$name" "$root" '{}' || return 0
      assert_eq "$(await_gone "$held_pid" 100 && echo gone || echo alive)" gone "$name: the close stopped the admitted run's child"
      assert_eq "$([[ -e "$first_run/exit" ]] && echo present || echo absent)" absent "$name: the stopped run left no verdict"
      assert_eq "$(validate_stages "$state" "$dev_rid")" "$(jq -cn --arg run "$first_run" '[{run_dir: $run, closed: false, outcome: null}]')" \
        "$name: the close itself closes no stage"
      write_brief "$wt/tmp/brief-$key-retry.md" retry
      jq -c --arg brief "$wt/tmp/brief-$key-retry.md" '.brief_file = $brief' "$request" > "$root/relaunch.json"
      launch_lane "$name" "$root" "$root/relaunch.json" || return 0
      if ! await "$lane_status" '^lane-(done|failed)' 2400; then
        fail "$name: the relaunched lane ends its job within the bound" "$(cat "$lane_status" 2>/dev/null)"
        return 0
      fi
      assert_eq "$(jq -c '.runs | map({run_dir, state, outcome, cause, seconds: (.seconds // null)})' "$wt/tmp/reconcile-retry.json")" \
        "$(jq -cn --arg run "$first_run" '[{run_dir: $run, state: "closed", outcome: "lost", cause: "process-gone", seconds: null}]')" \
        "$name: the next session's reconcile closes the stopped run lost, by its gone child, with no wall time to report"
      retry_run="$(jq -r '.run_dir' "$wt/tmp/admission-retry.json")"
      assert_eq "$(jq -c --arg id "$first_id" --arg run "$first_run" '[.minted, .admitted_now, (.run_id != $id), (.run_dir != $run)]' "$wt/tmp/admission-retry.json")" \
        '[true,true,true,true]' "$name: the retry's admission mints the next attempt under a new directory"
      assert_eq "$(validate_stages "$state" "$dev_rid")" \
        "$(jq -cn --arg a "$first_run" --arg b "$retry_run" '[{run_dir: $a, closed: true, outcome: "lost"}, {run_dir: $b, closed: true, outcome: "pass"}]')" \
        "$name: the lost attempt stays as a closed stage with its directory beside the passing retry"
      assert_eq "$(state_get "$state" '.dev_round_id')" "$dev_rid" "$name: the retry runs under the same dev round"
      ;;
    *)
      if ! await "$lane_status" '^lane-(done|failed)' 2400; then
        fail "$name: the lane ends its job within the bound" "$(cat "$lane_status" 2>/dev/null)"
        return 0
      fi
      ;;
  esac
  assert_eq "$(tail -n 1 "$lane_status")" lane-done "$name: every lane step ran" "$wt/tmp/lane.log"
  assert_eq "$(sed -n 's/^lane-env: .* gh=//p' "$wt/tmp/lane.log" | head -n 1)" "$TMP_ROOT/bin/gh" "$name: the lane resolves gh to the fake"
  pushed="$(git --git-dir="$ONE_JOB_ORIGIN" rev-parse refs/heads/main)"

  # --- state keys ---------------------------------------------------------
  assert_eq "$(state_get "$state" '.tier')" "$tier" "$name: state records the tier"
  assert_eq "$(state_get "$state" '.worktree')" "$wt" "$name: state names the worktree"
  if [[ "$tier" == small ]]; then
    dev_rid="$(state_get "$state" '.dev_round_id // empty')"
    review_rid="$(state_get "$state" '.review_round_id // empty')"
    assert_eq "$([[ -n "$dev_rid" && -n "$review_rid" && "$dev_rid" != "$review_rid" ]] && echo two || echo "$dev_rid/$review_rid")" two \
      "$name: a dev round and a review round were minted"
    assert_eq "$(state_get "$state" '.pr_order')" review-first "$name: the publication order is recorded"
    # --- admission before the run (decisions 51, 79, 100) ---------------------
    run_dir="$(jq -r '.run_dir' "$wt/tmp/admission-report.json")"
    assert_eq "$(jq -c '[.minted, .admitted_now]' "$wt/tmp/admission-report.json")" '[true,true]' \
      "$name: the round's first admission mints the run"
    assert_eq "$(jq -c . "$wt/tmp/admission-stage.json")" "$(jq -cn --arg run "$run_dir" '[{run_dir: $run, end: null}]')" \
      "$name: the validate stage stood open for the admitted directory before the run started"
    assert_eq "$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' "$wt/tmp/validate.out")" "$run_dir" \
      "$name: the run wrote into the directory its admission named"
    if [[ "$scenario" == killed ]]; then
      run_dir="$(jq -r '.run_dir' "$wt/tmp/admission-retry.json")"
      assert_eq "$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' "$wt/tmp/validate-retry.out")" "$run_dir" \
        "$name: the retry wrote into the directory its admission named"
    fi
    assert_eq "$(jq -c --arg r "$dev_rid" --arg run "$run_dir" '[(.round_id == $r), (.runs | map({run_dir, state, outcome, cause, timed: (.seconds | type)}))]' "$wt/tmp/reconcile-report.json")" \
      "$(jq -cn --arg run "$run_dir" '[true, [{run_dir: $run, state: "closed", outcome: "pass", cause: "sentinel", timed: "number"}]]')" \
      "$name: the accept's reconcile closes the admitted run with its sentinel's word and wall time"
    assert_eq "$(jq -c '[.kind, .outcome, .closed_now]' "$wt/tmp/accept-dev.json")" '["implement","pass",true]' \
      "$name: the runtime closes the dev stage with the acceptance word"
    assert_eq "$(jq -c --arg d "$dev_rid" --arg r "$review_rid" \
      '[.stages[] | select(.kind != "validate")] | map({kind, round: (if .round_id == $d then "dev" elif .round_id == $r then "review" else .round_id end), outcome, closed: (.end != null)})' "$state")" \
      '[{"kind":"implement","round":"dev","outcome":"pass","closed":true},{"kind":"review","round":"review","outcome":"pass","closed":true}]' \
      "$name: the round stages are the dev round (its kind set to the receipt's by dev-artifact-check) and the review round, each closed once with its word"
    [[ "$scenario" == killed ]] || assert_eq "$(validate_stages "$state" "$dev_rid")" \
      "$(jq -cn --arg run "$run_dir" '[{run_dir: $run, closed: true, outcome: "pass"}]')" \
      "$name: exactly one validate stage, opened by admission and closed by the reconcile"
    assert_eq "$(state_get "$state" '.validate_rounds | length')" 1 "$name: dev-artifact-check recorded one validate round"
    assert_eq "$(state_get "$state" '.child_sessions | to_entries | map(.value.status) | unique | join(",")')" closed \
      "$name: every child session is retired"
    assert_eq "$(sed -n 's/^review-depth: //p' "$wt/tmp/lane.log")" "change_class=small review_depth=bot native_approval=unchanged" \
      "$name: review-depth measures the dev result small and selects package review"
    assert_eq "$(state_get "$state" '.first_panel.agents | join(",")')" reviewer-correctness "$name: the panel is recorded"
    assert_eq "$(state_get "$state" '.json_paths | length')" 1 "$name: one review artifact path is recorded"
    # --- the review stage end: the runtime's one write, timed by the artifact (decisions 81, 103) ---
    artifact="$(state_get "$state" '.json_paths[0]')"
    assert_eq "$(jq -c '[.kind, .outcome, .closed_now]' "$wt/tmp/accept-review.json")" '["review","pass",true]' \
      "$name: the review accept carries the computed outcome and is the stage's one closer"
    assert_eq "$(jq -r --arg r "$review_rid" --slurpfile a "$wt/tmp/accept-review.json" \
      '([.stages[] | select(.round_id == $r)] | map(.end == $a[0].end) | tostring) + " " + ($a[0].end | tostring)' "$state")" \
      "[true] $(stat -c %Y -- "$artifact")" "$name: the review stage carries the one end the accept wrote, the accepted artifact's modification time"
    # --- the dev result's artifacts ---------------------------------------
    assert_eq "$(sed -n 's/^\(guard-exit=0\) at=.*/\1/p' "$run_dir/exit")" guard-exit=0 "$name: the validation run's sentinel records a passing guard exit"
    assert_eq "$(grep -c -- "${run_dir##*/}" "$wt/tmp/validation-runs")" 1 "$name: the run is in the worktree's run index"
    assert_eq "$(jq -r '.round_id + " " + .validate + " " + .kind' "$wt/tmp/dev-return-$key-$dev_rid.json")" "$dev_rid pass implement" \
      "$name: the dev receipt binds the round and a passing validation"
    assert_eq "$(jq -r '.verdict + " " + .head' "$artifact")" "pass $(jq -r '.commit' "$wt/tmp/dev-return-$key-$dev_rid.json")" \
      "$name: the review artifact passes the reviewed head"
    assert_eq "$(cat "$wt/tmp/hook-count")" $'hook\nhook' "$name: the dev commit and the preparation fold each ran the commit hook"
  else
    assert_eq "$(state_get "$state" '[.dev_round_id, .review_round_id, (.stages // [] | length)] | map(tostring) | join(",")')" "null,null,0" \
      "$name: a micro item runs no dev round and no review"
    assert_eq "$(cat "$wt/tmp/hook-count")" $'hook\nhook' "$name: the edit commit and the preparation fold each ran the commit hook"
  fi
  # --- publication --------------------------------------------------------
  assert_eq "$pushed" "$(git -C "$wt" rev-parse HEAD)" "$name: origin's main is the prepared commit"
  assert_eq "$(git -C "$wt" rev-list --count "$ONE_JOB_BASE..HEAD")" 1 "$name: the item lands as one commit above the base"
  assert_eq "$(git -C "$wt" rev-parse HEAD^)" "$ONE_JOB_BASE" "$name: the prepared commit's parent is the base the job started from"
  assert_eq "$([[ -e "$(git -C "$wt" rev-parse --git-path kendex-rebase-map)" ]] && echo present || echo absent)" absent \
    "$name: the rebase map is consumed"
  assert_eq "$(cd "$wt" && bash tests/greet.test.sh && bash tests/*.test.sh && echo green)" green "$name: the consumer's tests pass on the published tree"
  # --- verification (decisions 46, 52, 93) -----------------------------------
  assert_eq "$(jq -c --arg head "$pushed" '[.ok, .result.status, .result.verdict, .result.repo, (.result.head == $head), (.result.checks | length)]' "$wt/tmp/verify-report.json")" \
    '[true,"complete","none","owner/repo",true,0]' "$name: verify-head reads the published head complete with the none verdict and no check"
  assert_eq "$(jq -c --arg head "$pushed" '.result.recorded.report | [.op, (.head == $head), .verdict, .replaced]' "$wt/tmp/verify-report.json")" \
    '["record-verification",true,"none",false]' "$name: the op recorded the verdict itself, in the same call, as the head's first record"
  assert_eq "$(jq -c --slurpfile v "$wt/tmp/verify-report.json" '.verification | [.head, .verdict, .source, (.reason == $v[0].result.reason)]' "$state")" \
    "$(jq -cn --arg head "$pushed" '[$head, "none", "verify-head", true]')" \
    "$name: the verification record names the published head, the none verdict, its reader and the absence evidence the reply gave"
  # --- report -------------------------------------------------------------
  assert_eq "$(jq -r '.kind + " " + .text' "$wt/tmp/lane-mail/$key/to-overseer.jsonl")" "notice Pushed $pushed to main." \
    "$name: the lane's notice names the pushed commit"
  # One line per call: a multi-line --jq program continues on indented lines,
  # which are dropped, and its first line is trimmed of the trailing space
  # that precedes the program.
  calls="$(gh_stub_calls | grep -v '^ ' | sed 's/ *$//')"
  # --- the service boundary: the fake gh and the local remote are the job's
  # only services (PATH is sealed; origin's main is asserted above), and what
  # reaches gh is a tracker read or close of an issue of owner/repo, the
  # open-PR probe of the item's branch or a verify-head read of owner/repo.
  # An api call with any flag beside its path would be a write.
  assert_eq "$(awk -v k="$key" '
      $1 == "issue" && $2 == "view" && $3 ~ /^[0-9]+$/ && $4 == "--repo" && $5 == "owner/repo" { next }
      $1 == "issue" && $2 == "close" && $3 ~ /^[0-9]+$/ && $4 == "--repo" && $5 == "owner/repo" && $6 == "--reason" && $7 == "completed" && NF == 7 { next }
      index($0, "pr list --state open --head " k " ") == 1 { next }
      $1 == "api" && index($2, "repos/owner/repo/") == 1 && NF == 2 { next }
      { print "outside: " $0 }' <<<"$calls")" "" \
    "$name: every gh call is a tracker read or close on owner/repo, the open-PR probe of the item's branch or a verify-head read of owner/repo"
  # --- local versus tracker: a GitHub item's tracker calls name its own issue
  # and close it once; a local item reaches no tracker.
  if [[ "$tracker" == github ]]; then
    assert_eq "$(awk -v n="$number" '$1 == "issue" && $3 != n { print "other-issue: " $0 } $1 == "issue" && $2 == "close" { closes++ } END { print "closes=" closes + 0 }' <<<"$calls")" \
      "closes=1" "$name: the tracker calls name the job's issue and close it once"
    # --- verification before completion: a verify-head read after the close
    # would verify a job the tracker already holds done.
    assert_eq "$(awk '$1 == "issue" && $2 == "close" { closed = 1; next } closed && $1 == "api" { print "after-close: " $0 }' <<<"$calls")" "" \
      "$name: every verify-head read precedes the tracker close"
  else
    assert_eq "$(awk '$1 == "issue" { print "tracker: " $0 }' <<<"$calls")" "" "$name: a local item makes no tracker call"
  fi
  # --- the published head: verify-head's reads of a head name the pushed
  # commit and no other.
  assert_eq "$(awk -v sha="$pushed" '$1 == "api" && /\/commits\/|head_sha=/ { if (index($0, sha)) own++; else print "other-head: " $0 } END { print "published-head-read=" (own > 0) }' <<<"$calls")" \
    "published-head-read=1" "$name: verify-head reads the published commit and no other head"
  # --- close (the overseer, after the report) ------------------------------
  # Decision 83's guard: a GitHub lane idles at its composer after the job
  # and is ended on the tracker's own answer to the close the job made; a
  # local lane has exited and is closed on that reading alone.
  if [[ "$tracker" == github ]]; then
    assert_eq "$(jq -c '[.command, .status]' "$wt/tmp/issue-close.json")" '["gh issue close",0]' "$name: the tracker answered the job's close"
    ground="$(jq -c '{terminal: {verdict: .reason, source: .command}}' "$wt/tmp/issue-close.json" 2>/dev/null)" \
      || { fail "$name: close ground" "the job recorded no tracker answer"; return 0; }
  else
    assert_eq "$(await_gone "$PID" 100 && echo gone || echo alive)" gone "$name: the local lane's harness exited after its job"
    ground='{}'
  fi
  close_lane "$name" "$root" "$ground" || return 0
  assert_eq "$(kill -0 "$PID" 2>/dev/null && echo alive || echo gone)" gone "$name: the harness process recorded at launch is gone"
  assert_eq "$(tmux -S "$ONE_JOB_SOCKET" list-panes -a -F '#{pane_id}' | grep -c -x -- "$PANE")" 0 "$name: the lane's window is closed"
}

ROWS='github-small|github|small|plain
local-small|local|small|plain
github-micro|github|micro|plain
local-handoff|local|small|handoff
github-killed|github|small|killed'
ran=0
while IFS='|' read -r name key_kind tier scenario; do
  [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || continue
  ran=$((ran + 1))
  run_job "$name" "$key_kind" "$tier" "$scenario"
done <<<"$ROWS"
[[ "$ran" -gt 0 ]] || { echo "one-job: no row matches [$FILTER]" >&2; exit 1; }

tmux -S "$ONE_JOB_SOCKET" kill-server
# kill-server returns once the server has the signal; its exit follows.
tries=0
while kill -0 "$ONE_JOB_SERVER_PID" 2>/dev/null && [[ "$tries" -lt 100 ]]; do
  tries=$((tries + 1))
  sleep 0.05
done
assert_eq "$(kill -0 "$ONE_JOB_SERVER_PID" 2>/dev/null && echo alive || echo gone)" gone "the private tmux server is gone by its recorded pid"
assert_eq "$(tmux -S "$ONE_JOB_SOCKET" list-sessions >/dev/null 2>&1 && echo answers || echo silent)" silent "no server answers on the private socket"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
