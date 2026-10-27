#!/usr/bin/env bash
# One complete repository job in a disposable consumer, on real production
# operations with fake external services and no CI (plan step 3, decisions
# 46 to 54): admission, launch, dev result, the configured review route,
# publication preparation, verification and report, then close.
#
# Inputs: orch's scripts and runtime (scripts/orch-runtime through
# scripts/setup), agent-runtime's launch and stop, the worktree, dev,
# reviewer, mailbox, github and change-scope skills, the workflow commands
# tests/job/stub-harness runs, and the gh fake in github/tests/lib/gh-stub.sh.
#
# Rows, one job each: a GitHub issue at the small tier (launch-time
# item-tier --body --path, the internal panel route, gh issue close), a
# tracker-less local key at the small tier (new-local-key, no tracker read),
# and a GitHub issue at the micro tier (no dev round, no review). An argument
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
ORCH_RUNTIME="$REPO_ROOT/skills/orch/scripts/orch-runtime"
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
# ci-wait reads its grace from the environment alone; the auth ladder takes
# the env token and validates it against the fake's seeded `api user`.
export CI_WAIT_NO_CHECKS_GRACE=1 GH_TOKEN=stub
mkdir -p "$TMP_ROOT/home"
one_job_server "$TMP_ROOT/server" fleet
# The runtime resolves the fleet server from its own $TMUX, as a lane does.
export TMUX="$ONE_JOB_SOCKET,0,0"

FILTER="${1:-}"

# await FILE PATTERN BOUND_TENTHS — wait for a line matching PATTERN in FILE.
await() {
  local tries=0
  until [[ -f "$1" ]] && grep -qE -- "$2" "$1"; do
    tries=$((tries + 1))
    [[ "$tries" -lt "$3" ]] || return 1
    sleep 0.1
  done
}

state_get() { # STATE FILTER
  jq -r "$2" "$1"
}

# run_job NAME KEY_KIND TIER — one row: the overseer side here, the lane side
# in the stub, then the assertions on the artifacts the job left.
run_job() { # NAME KEY_KIND TIER
  local name="$1" key_kind="$2" tier="$3" root main orch key number tracker body tier_line delta
  local wt brief request launched pid pane fleet state status lane_status run_dir dev_rid review_rid pushed
  local closed ci calls expected_calls cmdline
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
    number="${name##*-}"
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
    number=""
    key="$(cd "$main" && "$orch/workflow-state" new-local-key)"
    assert_eq "$([[ "$key" =~ ^local-[0-9]+-[0-9]+-[0-9a-f]+$ ]] && echo shaped || echo "$key")" shaped "$name: a local key is minted"
    one_job_stage_gh 1 /dev/null
    tier_line="$(cd "$main" && "$orch/item-tier" --production "$delta" --path lib.sh --repo "$main")" || tier_line="exit=$?"
    assert_eq "$tier_line" "tier=$tier brief=$tier cause=estimate-within-$tier production=$delta estimate=$delta delta=- paths=1" \
      "$name: launch-time admission reads the tier from the estimate and the Location path"
  fi

  # --- the worktree and the lane (skills/orch/workflows/start.md § 4, skills/orch/workflows/oversee.md § 3) ---
  wt="$(cd "$main" && "$main/.agents/skills/worktree/scripts/worktree" create "$key" 2>"$root/create.err")" \
    || { fail "$name: worktree create" "$(cat "$root/create.err")"; return 0; }
  assert_eq "$(git -C "$wt" branch --show-current)" "$key" "$name: the worktree is on the item branch"
  mkdir -p "$wt/tmp"
  brief="$wt/tmp/brief-$key.md"
  {
    printf 'item=%s\n' "$key"
    printf 'tier=%s\n' "$tier"
    printf 'tracker=%s\n' "$tracker"
    printf 'repo=owner/repo\n'
    printf 'number=%s\n' "$number"
    printf 'worktree=%s\n' "$wt"
    printf 'main=%s\n' "$main"
    printf 'fixture_lib=%s\n' "$TEST_DIR/lib/one-job-fixture.sh"
  } > "$brief"
  request="$root/launch.json"
  jq -cn --arg item "$key" --arg wt "$wt" --arg home "$TMP_ROOT/home" --arg brief "$brief" --arg tracker "$tracker" \
    '{op: "launch-lane", item: $item, harness: "claude", mail_root: $wt, account: $home, repo: "owner/repo", brief_file: $brief}
     + (if $tracker == "github" then {tracker: "github"} else {} end)' > "$request"
  launched="$(cd "$main" && "$orch/orch-runtime" op --fleet --request "$request" 2>"$root/launch.err")" \
    || { fail "$name: launch-lane" "$(cat "$root/launch.err")"; return 0; }
  assert_eq "$(jq -r '.result.effect.report.intent.outcome' <<<"$launched")" confirmed "$name: the launch confirms"
  assert_eq "$(jq -r '.result.effect.report.lane.status' <<<"$launched")" running "$name: the lane runs"
  pid="$(jq -r '.result.effect.report.lane.launch.pid' <<<"$launched")"
  pane="$(jq -r '.result.effect.report.lane.launch.pane' <<<"$launched")"
  fleet="$main/tmp/workflow-state-oversee.json"
  assert_eq "$(jq -c --arg k "$key" '[.lanes[] | select(.item == $k)] | map({status, server: .launch.server, pane: .launch.pane, pid: .launch.pid})' "$fleet")" \
    "$(jq -cn --argjson s "$ONE_JOB_SERVER_PID" --arg p "$pane" --argjson pid "$pid" '[{status: "running", server: $s, pane: $p, pid: $pid}]')" \
    "$name: the fleet record holds the lane with its launch identity on the suite's server"
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo unreadable)"
  assert_eq "$(case "$cmdline" in *"$STUB"*) echo stub ;; *) echo "$cmdline" ;; esac)" stub "$name: the recorded pid is the stub harness"

  # --- the lane runs the job; the overseer waits for its report -------------
  lane_status="$wt/tmp/lane-status"
  if ! await "$lane_status" '^lane-(done|failed)' 2400; then
    fail "$name: the lane ends its job within the bound" "$(cat "$lane_status" 2>/dev/null)"
    return 0
  fi
  assert_eq "$(tail -n 1 "$lane_status")" lane-done "$name: every lane step ran" "$wt/tmp/lane.log"
  assert_eq "$(sed -n 's/^lane-env: .* gh=//p' "$wt/tmp/lane.log")" "$TMP_ROOT/bin/gh" "$name: the lane resolves gh to the fake"
  state="$main/tmp/workflow-state-$key.json"
  pushed="$(git --git-dir="$ONE_JOB_ORIGIN" rev-parse refs/heads/main)"

  # --- state keys ---------------------------------------------------------
  assert_eq "$(state_get "$state" '.tier')" "$tier" "$name: state records the tier"
  assert_eq "$(state_get "$state" '.worktree')" "$wt" "$name: state names the worktree"
  if [[ "$tier" == small ]]; then
    dev_rid="$(state_get "$state" '.dev_round_id // empty')"
    review_rid="$(state_get "$state" '.review_round_id // empty')"
    assert_eq "$([[ "$dev_rid" =~ ^[0-9]+-[0-9]+$ ]] && echo minted || echo "$dev_rid")" minted "$name: a dev round was minted"
    assert_eq "$([[ "$review_rid" =~ ^[0-9]+-[0-9]+$ ]] && echo minted || echo "$review_rid")" minted "$name: a review round was minted"
    assert_eq "$(state_get "$state" '.pr_order')" review-first "$name: the publication order is recorded"
    run_dir="$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' "$wt/tmp/validate.out")"
    assert_eq "$(jq -c --arg d "$dev_rid" --arg r "$review_rid" --arg run "$run_dir" \
      '[.stages[] | {kind, round: (if .round_id == $d then "dev" elif .round_id == $r then "review" else .round_id end), run_dir: (.run_dir // null), closed: (.end != null)}]' "$state")" \
      "$(jq -cn --arg run "$run_dir" '[{kind: "implement", round: "dev", run_dir: null, closed: true}, {kind: "validate", round: "dev", run_dir: $run, closed: true}, {kind: "review", round: "review", run_dir: null, closed: true}]')" \
      "$name: the stages are the dev round (its kind set to the receipt's by dev-artifact-check), exactly one validate row opened by admission and closed by accept, and the review round"
    assert_eq "$(state_get "$state" '.validate_rounds | length')" 1 "$name: dev-artifact-check recorded one validate round"
    assert_eq "$(state_get "$state" '.child_sessions | to_entries | map(.value.status) | unique | join(",")')" closed \
      "$name: every child session is retired"
    assert_eq "$(sed -n 's/^review-depth: //p' "$wt/tmp/lane.log")" "change_class=small review_depth=bot native_approval=unchanged" \
      "$name: review-depth measures the dev result small and selects package review"
    assert_eq "$(state_get "$state" '.first_panel.agents | join(",")')" reviewer-correctness "$name: the panel is recorded"
    assert_eq "$(state_get "$state" '.json_paths | length')" 1 "$name: one review artifact path is recorded"
    # --- the dev result's artifacts ---------------------------------------
    assert_eq "$(sed -n 's/^\(guard-exit=0\) at=.*/\1/p' "$run_dir/exit")" guard-exit=0 "$name: the validation run's sentinel records a passing guard exit"
    assert_eq "$(grep -c -- "${run_dir##*/}" "$wt/tmp/validation-runs")" 1 "$name: the run is in the worktree's run index"
    assert_eq "$(jq -r '.round_id + " " + .validate + " " + .kind' "$wt/tmp/dev-return-$key-$dev_rid.json")" "$dev_rid pass implement" \
      "$name: the dev receipt binds the round and a passing validation"
    assert_eq "$(jq -r '.verdict + " " + .head' "$(state_get "$state" '.json_paths[0]')")" "pass $(jq -r '.commit' "$wt/tmp/dev-return-$key-$dev_rid.json")" \
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
  # --- verification ---------------------------------------------------------
  ci="$wt/tmp/ci-wait.json"
  assert_eq "$(jq -r '.status + " " + .verdict + " " + .repo' "$ci")" "complete none owner/repo" "$name: ci-wait --required-only answers the none verdict for the repository"
  assert_eq "$(state_get "$state" '.verification | [.head, .verdict, .source, (.reason | startswith("no CI configured")), (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))] | map(tostring) | join(" ")')" \
    "$pushed none ci-wait --required-only true true" "$name: the verification record names the published head, the none verdict, its reader and the absence evidence"
  assert_eq "$(jq -r '.op + " " + (.replaced | tostring)' "$wt/tmp/verification-report.json")" "record-verification false" "$name: the verdict was recorded once"
  # --- report -------------------------------------------------------------
  assert_eq "$(jq -r '.kind + " " + .text' "$wt/tmp/lane-mail/$key/to-overseer.jsonl")" "notice Pushed $pushed to main." \
    "$name: the lane's notice names the pushed commit"
  # One line per call: a multi-line --jq program (the required-set read's)
  # continues on indented lines, which are dropped, and its first line is
  # trimmed of the trailing space that precedes the program.
  calls="$(gh_stub_calls | grep -v '^ ' | sed 's/ *$//')"
  if [[ "$tracker" == github ]]; then
    expected_calls="issue view $number --repo owner/repo --json number,title,body,url,labels,state
pr list --state open --head $key --limit 1 --json number,url --jq .[0] | select(.) | \"\\(.number)\\t\\(.url)\"
pr list --state open --head $key --limit 1 --json number,url --jq .[0] | select(.) | \"\\(.number)\\t\\(.url)\""
    [[ "$tier" == micro ]] || expected_calls="$expected_calls
issue view $number --json labels --jq .labels[].name
issue view $number --repo owner/repo --json body --jq .body"
    expected_calls="$expected_calls
issue view $number --repo owner/repo --json body"
  else
    expected_calls="pr list --state open --head $key --limit 1 --json number,url --jq .[0] | select(.) | \"\\(.number)\\t\\(.url)\"
pr list --state open --head $key --limit 1 --json number,url --jq .[0] | select(.) | \"\\(.number)\\t\\(.url)\""
  fi
  expected_calls="$expected_calls
api user --jq .login
repo view --json nameWithOwner -q .nameWithOwner
pr view ${number:-1} --repo owner/repo --json mergeStateStatus --jq .mergeStateStatus
pr view ${number:-1} --repo owner/repo --json headRefOid --jq .headRefOid
pr checks ${number:-1} --repo owner/repo --json name,state,bucket,link,startedAt,workflow
pr view ${number:-1} --repo owner/repo --json headRefOid --jq .headRefOid
pr view ${number:-1} --repo owner/repo --json baseRefName --jq .baseRefName
api repos/owner/repo/rules/branches/main --paginate --jq
api repos/owner/repo/branches/main
pr view ${number:-1} --repo owner/repo --json headRefOid --jq .headRefOid
api repos/owner/repo/actions/workflows --jq [.workflows[] | select(.state == \"active\")] | length
pr view ${number:-1} --repo owner/repo --json baseRefName --jq .baseRefName
api repos/owner/repo/branches/main --jq .protected
api repos/owner/repo/rules/branches/main --jq [.[] | select(.type == \"required_status_checks\")] | length
pr view ${number:-1} --repo owner/repo --json headRefOid --jq .headRefOid
api repos/owner/repo/commits/$pushed/status --jq .total_count"
  [[ "$tracker" != github ]] || expected_calls="$expected_calls
issue close $number --repo owner/repo --reason completed"
  assert_eq "$calls" "$expected_calls" "$name: the gh calls are the job's tracker reads, the verification's reads and the completion, in order, and nothing else"
  # --- close (the overseer, after the report) ------------------------------
  printf '{"op": "close-owned-resources", "item": "%s"}\n' "$key" > "$root/close.json"
  closed="$(cd "$main" && "$orch/orch-runtime" op --fleet --request "$root/close.json" 2>"$root/close.err")" \
    || { fail "$name: close-owned-resources" "$(cat "$root/close.err")"; return 0; }
  assert_eq "$(jq -r '.result.effect.report.intent.outcome + " " + .result.effect.report.lane.status' <<<"$closed")" "confirmed done" \
    "$name: the close confirms and the lane is done"
  assert_eq "$(jq -r --arg k "$key" '[.lanes[] | select(.item == $k) | .status] | join(",")' "$fleet")" done "$name: the fleet record holds the lane as done"
  assert_eq "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)" gone "$name: the harness process recorded at launch is gone"
  assert_eq "$(tmux -S "$ONE_JOB_SOCKET" list-panes -a -F '#{pane_id}' | grep -c -x -- "$pane")" 0 "$name: the lane's window is closed"
}

ROWS='github-small|github|small
local-small|local|small
github-micro|github|micro'
ran=0
while IFS='|' read -r name key_kind tier; do
  [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || continue
  ran=$((ran + 1))
  run_job "$name" "$key_kind" "$tier"
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
