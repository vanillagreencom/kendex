#!/usr/bin/env bash
# Containment for the suites that launch real detached supervisors.
#
# `merge-queue-watch launch` detaches its supervisor with `setsid -f`, so no
# wait in a suite owns it. A suite killed mid-run — routine on a box with a
# load reaper — left live supervisors behind whose fixture tree was deleted
# under them, and their PATH stubs died with it: the fallthrough reached the
# real binaries and opened terminal windows on the operator's desktop
# (KEN-995). Each `===` section below states the property it proves; between
# them they cover the three things that had to hold for that to stop
# happening: a suite aborted mid-run takes its fixture processes with it, a
# supervisor or a wait whose home has been deleted under it refuses rather
# than carrying on, and a fixture tree whose own stub directory is gone
# reaches a sealed refusal rather than a real binary. Every section carries
# its own control, because each of these reads green for the wrong reason if
# nothing was there to catch.
#
# The teardown assertions read `ps`. Where /proc is readable the reaper under
# test reads that instead, so instrument and subject are independent; where it
# is not, the reaper's own fallback is `ps` too and they share a source.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
# Relative first, so an exported tree that is no git checkout still runs
# these suites — the mutation harness extracts one with git archive.
SEALED="$(cd "$TEST_DIR/../../.." && pwd)/tools/tests/lib/sealed-bin"
# git's own failure must not become this script's: in a non-git tree the
# substitution exits 128, and under set -e that would end the run before the
# named error below ever printed.
if [[ ! -x "$SEALED/gh" ]]; then
  REPO_TOP="$(git -C "$TEST_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  SEALED="$REPO_TOP/tools/tests/lib/sealed-bin"
fi
[[ -x "$SEALED/gh" ]] || { echo "merge_queue_teardown: sealed-bin fixture is missing: $SEALED" >&2; exit 1; }
TMP="$(mktemp -d)"
# shellcheck source=lib/merge-queue-reaper.sh
. "$TEST_DIR/lib/merge-queue-reaper.sh"
mq_reap_own "$TMP"
trap mq_reap_teardown EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT

PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected $2, got $1)"; fi; }
wait_exists() { local i; for ((i=0;i<300;i++)); do [[ -e "$1" ]] && return 0; sleep 0.05; done; return 1; }

# The independent census: every live process whose command line names this
# sandbox and runs the supervisor entry point. The snapshot is taken before
# the scan runs — piped, `ps` would see the scanner, whose own argument list
# carries both strings it is looking for.
supervisors_under() {
  ps -e -ww -o pid=,args= > "$TMP/ps.snapshot" 2>/dev/null || true
  awk -v root="$1" 'index($0, "__supervise") && index($0, root) { print $1 }' "$TMP/ps.snapshot"
}
count_supervisors() { supervisors_under "$1" | grep -c . || true; }

HEAD=dddddddddddddddddddddddddddddddddddddddd

build_sandbox() {
  local sb="$1" main scripts bin
  main="$sb/main"; scripts="$sb/orch/scripts"; bin="$sb/bin"
  mkdir -p "$main" "$scripts/lib" "$bin"
  git -C "$main" init -q
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name Test
  touch "$main/seed"; printf 'tmp/\n' > "$main/.gitignore"
  git -C "$main" add seed .gitignore; git -C "$main" commit -qm seed
  printf 'GH_BOT_TOKEN=ghp_project\n' > "$main/.env.local"
  ln -s "$(cd "$ORCH/.." && pwd)/github" "$sb/github"
  cp "$ORCH/scripts/merge-queue-watch" "$ORCH/scripts/workflow-state" "$ORCH/scripts/orch-env" "$scripts/"
  cp "$ORCH/scripts/lib/merge-queue-supervisor.sh" "$ORCH/scripts/lib/merge-queue-state.sh" \
     "$ORCH/scripts/lib/kendex-env.sh" "$scripts/lib/"
  # The worker never returns on its own, so the supervisor is still waiting
  # when the suite around it is aborted — the shape that leaked.
  printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$scripts/queue-wait"
  printf '#!/usr/bin/env bash\necho "unexpected gh: $*" >&2\nexit 1\n' > "$bin/gh"
  chmod +x "$scripts/merge-queue-watch" "$scripts/workflow-state" "$scripts/orch-env" \
    "$scripts/queue-wait" "$bin/gh"
}

cat > "$TMP/victim.sh" <<'VICTIM'
#!/usr/bin/env bash
# One aborted suite. Everything it needs arrives in the environment, so its own
# command line never names the sandbox and cannot be confused for a fixture
# process by anything counting them.
set -euo pipefail
SCRIPTS="$VICTIM_SANDBOX/orch/scripts"; MAIN="$VICTIM_SANDBOX/main"
export PATH="$VICTIM_SANDBOX/bin:$VICTIM_SEALED:$PATH"
if [[ "$VICTIM_REAP" == 1 ]]; then
  . "$VICTIM_TESTLIB/merge-queue-reaper.sh"
  mq_reap_own "$VICTIM_SANDBOX"
  # Not mq_reap_teardown: the parent built this sandbox and reads it after the
  # abort, so the victim clears the processes and leaves the tree standing. A
  # tree it could not clear is still this victim's failure.
  victim_teardown() { local rc=$?; mq_reap || rc=1; exit "$rc"; }
  trap victim_teardown EXIT
  trap 'exit 143' TERM HUP
fi
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN GH_REPO GITHUB_REPOSITORY
"$SCRIPTS/merge-queue-watch" init --worktree "$MAIN" --issue KEN-995-teardown \
  --branch "$(git -C "$MAIN" branch --show-current)" >/dev/null
prep=$("$SCRIPTS/merge-queue-watch" prepare --worktree "$MAIN" --issue KEN-995-teardown \
  --repo owner/repo --pr 42 --head "$VICTIM_HEAD" --root "$MAIN" --gate-mode off \
  --recovery-count 0 --cleanup-worktree false)
"$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-995-teardown \
  --watch-id "$(jq -r .watch_id <<<"$prep")" --poll 1 --max-wait 600 >/dev/null
"$SCRIPTS/merge-queue-watch" inspect --root "$MAIN" --issue KEN-995-teardown \
  | jq -r .supervisor_pid > "$VICTIM_PIDOUT"
touch "$VICTIM_PIDOUT.ready"
while :; do sleep 1; done
VICTIM

# Abort a victim exactly the way the box's load reaper does: a signal, while
# its supervisor is still waiting on a worker that never returns.
run_and_abort() {
  local sandbox="$1" reap="$2" pidout="$3" pid supervisor
  VICTIM_SANDBOX="$sandbox" VICTIM_REAP="$reap" VICTIM_PIDOUT="$pidout" \
  VICTIM_SEALED="$SEALED" VICTIM_TESTLIB="$TEST_DIR/lib" VICTIM_HEAD="$HEAD" \
    bash "$TMP/victim.sh" >"$pidout.log" 2>&1 &
  pid=$!
  wait_exists "$pidout.ready" || { bad "victim never launched a supervisor (see $pidout.log)"; return 1; }
  # The supervisor must not have raced the abort. A supervisor that had
  # already exited on its own would satisfy "zero survivors" just as well, so
  # the signal only lands while it is provably alive.
  supervisor=$(cat < "$pidout")
  ps -p "$supervisor" -o pid= >/dev/null 2>&1 || {
    bad "supervisor $supervisor exited before the abort; the case that follows proves nothing"
    kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    return 1
  }
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

echo "=== an aborted suite leaves no supervisor behind ==="

# Control first: the same abort with teardown disarmed must leave the
# supervisor running. Without this, "zero survivors" would also be the answer
# a supervisor that never started gives.
build_sandbox "$TMP/leaky"
run_and_abort "$TMP/leaky" 0 "$TMP/leaky.pid"
leaked=$(cat < "$TMP/leaky.pid")
sleep 0.5
leaked_count=$(count_supervisors "$TMP/leaky")
if [[ "$leaked_count" -gt 0 ]]; then ok "an abort with no teardown leaves the supervisor running"; else bad "abort control left nothing to reap; the case that follows proves nothing"; fi
if ps -p "$leaked" -o pid= >/dev/null 2>&1; then ok "the leaked supervisor is the pid the launch registered"; else bad "registered supervisor pid $leaked is not the survivor"; fi

# And the reaper clears exactly that: same processes, run directly — through
# the ps fallback, which is the only branch a macOS run takes and which CI,
# being Linux-only, would otherwise never execute. This case and the starved
# census below force that branch; every other reap in the file takes the /proc
# walk, so both are covered.
export MQ_REAP_FORCE_PS=1
mq_reap "$TMP/leaky" || bad "reaper reported survivors under the leaky sandbox"
unset MQ_REAP_FORCE_PS
eq "$(count_supervisors "$TMP/leaky")" 0 "the ps fallback clears a tree an abort left behind"

build_sandbox "$TMP/reaped"
run_and_abort "$TMP/reaped" 1 "$TMP/reaped.pid"
sleep 0.5
eq "$(count_supervisors "$TMP/reaped")" 0 "a suite aborted mid-run kills its supervisor tree on exit"

# A tree the teardown could not clear is the KEN-995 condition itself, so it
# has to reach the runner as a failing suite and not only as a printed line.
# The reap is stubbed rather than starved: an unkillable process is not
# something a test can arrange, and the status is what is under test.
cat > "$TMP/escalate.sh" <<'ESC'
set -euo pipefail
. "$ESC_TESTLIB/merge-queue-reaper.sh"
mq_reap_own "$ESC_ROOT"
if [[ "$ESC_FAIL" == 1 ]]; then mq_reap() { return 1; }; fi
trap mq_reap_teardown EXIT
exit "$ESC_EXIT"
ESC
# $1 whether the reap fails, $2 the status the suite itself ends on.
run_escalation() {
  local fail="$1" suite_exit="$2" root rc=0
  root="$TMP/escalation-$1-$2"
  mkdir -p "$root"
  ESC_TESTLIB="$TEST_DIR/lib" ESC_ROOT="$root" ESC_FAIL="$fail" ESC_EXIT="$suite_exit" \
    bash "$TMP/escalate.sh" >/dev/null 2>&1 || rc=$?
  printf '%s %s\n' "$rc" "$([[ -d "$root" ]] && echo kept || echo removed)"
}
eq "$(run_escalation 1 0)" "1 removed" "a teardown that cannot clear the tree fails the suite and still removes the root"
eq "$(run_escalation 0 0)" "0 removed" "a teardown that clears the tree leaves a passing suite passing"
# The direction a lost status capture would break: a clean reap must not
# rescue a suite that failed on its own assertions.
eq "$(run_escalation 0 3)" "3 removed" "a clean reap carries a failing suite's own status out"

echo "=== a supervisor whose launch home breaks refuses to continue ==="

# $1 sandbox, $2 issue key, $3 the repository root to record (default the
# sandbox's own main): launch one supervisor and print
# "pid runtime artifact log state main_root".
#
# Recording a SUBDIRECTORY of the repository as the root is what lets the
# repository clause be broken on its own: the shared git directory, and so the
# state file and the runtime under it, resolve the same either way.
#
# Same posture as victim.sh — the sandbox's own bin and the sealed directory
# ahead of the ambient PATH, no inherited GitHub token — so nothing these
# supervisors reach for resolves to a real binary.
launch_supervisor() {
  local sb="$1" issue="$2" root="${3:-}" scripts main prep state state_path
  scripts="$sb/orch/scripts"; main="$sb/main"; root="${root:-$main}"
  (
    export PATH="$sb/bin:$SEALED:$PATH"
    unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN GH_REPO GITHUB_REPOSITORY
    "$scripts/merge-queue-watch" init --worktree "$main" --issue "$issue" \
      --branch "$(git -C "$main" branch --show-current)" >/dev/null
    prep=$("$scripts/merge-queue-watch" prepare --worktree "$main" --issue "$issue" \
      --repo owner/repo --pr 42 --head "$HEAD" --root "$root" --gate-mode off \
      --recovery-count 0 --cleanup-worktree false)
    "$scripts/merge-queue-watch" launch --root "$root" --issue "$issue" \
      --watch-id "$(jq -r .watch_id <<<"$prep")" --poll 1 --max-wait 600 >/dev/null
    state=$("$scripts/merge-queue-watch" inspect --root "$root" --issue "$issue")
    state_path=$(cd "$main" && "$scripts/workflow-state" --state-dir "$main/tmp" \
      get "$issue" .merge_queue_watch.state_path)
    jq -r --arg sp "$state_path" \
      '[.supervisor_pid, .runtime_dir, .artifact_path, .log_path, $sp, .main_repo_root] | @tsv' <<<"$state"
  )
}
alive_for() { local i; for ((i=0;i<"$2";i++)); do ps -p "$1" -o pid= >/dev/null 2>&1 || return 1; sleep 0.1; done; return 0; }

# One breaker per clause of the supervisor's home check, each leaving every
# other clause satisfied so the clause under test is the sole cause. A clause
# with no fixture of its own is one the suite cannot notice the loss of.
# Args to every breaker: runtime, state file, repository root, sandbox.
break_runtime() { local rt="$1"; rm -rf -- "${rt:?}"; }
break_symlink() { local rt="$1" sb="$4"; rm -rf -- "${rt:?}"; ln -s "$sb/main" "$rt"; }
break_state() { local sf="$2"; rm -f -- "${sf:?}"; }
break_repository() { local rr="$3"; rm -rf -- "${rr:?}"; }

# $1 label, $2 breaker, $3 the root to record (empty for the sandbox's main).
home_clause_case() {
  local label="$1" breaker="$2" root_arg="${3:-}" sb root=""
  sb="$TMP/home-$label"
  local hpid hrt hart hlog hstate hmain
  build_sandbox "$sb"
  if [[ -n "$root_arg" ]]; then mkdir -p "$sb/main/$root_arg"; root="$sb/main/$root_arg"; fi
  IFS=$'\t' read -r hpid hrt hart hlog hstate hmain < <(launch_supervisor "$sb" "KEN-995-$label" "$root")
  "$breaker" "$hrt" "$hstate" "$hmain" "$sb"
  if alive_for "$hpid" 200; then bad "$label: the supervisor kept running"
  else ok "$label: the supervisor stops inside its poll window"; fi
  if grep -Fq 'launch home is gone' "$hlog"; then ok "$label: the refusal names the home it lost"
  else bad "$label: the refusal is unnamed: $(tail -3 "$hlog" 2>/dev/null)"; fi
  eq "$(count_supervisors "$sb")" 0 "$label: no fixture process outlives the refusal"
}

home_clause_case runtime-deleted break_runtime
home_clause_case runtime-swapped-for-a-symlink break_symlink
# The teardown's own marker follows the same rule as its fallback: a runtime
# swapped for a symlink gets no terminal file at the symlink's target.
[[ ! -e "$TMP/home-runtime-swapped-for-a-symlink/main/terminal" ]] \
  && ok "runtime-swapped-for-a-symlink: no terminal marker lands at the symlink target" \
  || bad "runtime-swapped-for-a-symlink: the teardown wrote through the symlink"
home_clause_case state-file-deleted break_state
home_clause_case repository-deleted break_repository altroot

# Controls, one per clause: with THAT clause cut out of the check, its own
# fixture must stop refusing. This is what makes the four cases above coverage
# rather than four spellings of the first one.
# $1 label, $2 the exact clause text to cut, $3 breaker, $4 recorded root.
home_clause_control() {
  local label="$1" clause="$2" breaker="$3" root_arg="${4:-}" sb root=""
  sb="$TMP/mutant-$label"
  local mutant mpid mrt mart mlog mstate mmain
  build_sandbox "$sb"
  mutant="$sb/orch/scripts/lib/merge-queue-supervisor.sh"
  edit_once "$ORCH/scripts/lib/merge-queue-supervisor.sh" "$mutant" "$clause" \
    || { bad "$label: clause mutation did not apply"; return; }
  if [[ -n "$root_arg" ]]; then mkdir -p "$sb/main/$root_arg"; root="$sb/main/$root_arg"; fi
  IFS=$'\t' read -r mpid mrt mart mlog mstate mmain < <(launch_supervisor "$sb" "KEN-995-$label" "$root")
  "$breaker" "$mrt" "$mstate" "$mmain" "$sb"
  if alive_for "$mpid" 80; then ok "$label: cutting the clause stops the refusal"
  else bad "$label: the supervisor stopped for a reason other than the clause"; fi
  mq_reap "$sb" || bad "$label: reaper reported survivors under the mutant sandbox"
}

# Rewrite the one occurrence of $3 as $4 in a copy of $1, refusing unless the
# source carried it exactly once and the copy came out changed — a mutation
# that did not apply is a control that proves nothing. An empty $4 cuts.
edit_once() {
  local src="$1" dst="$2" needle="$3" repl="${4:-}" hits
  hits=$(grep -Fc -- "$needle" "$src") || return 1
  [[ "$hits" -eq 1 ]] || return 1
  awk -v needle="$needle" -v repl="$repl" \
    '{ i = index($0, needle); if (i) $0 = substr($0, 1, i-1) repl substr($0, i+length(needle)); print }' \
    "$src" > "$dst" || return 1
  if [[ -n "$repl" ]]; then grep -Fq -- "$repl" "$dst"; else ! grep -Fq -- "$needle" "$dst"; fi
}

home_clause_control without-runtime-clause '-d "$runtime" && ' break_runtime
home_clause_control without-symlink-clause '! -L "$runtime" && ' break_symlink
# The reaper's TERM runs that mutant's teardown, which no longer sees the
# symlink and so writes its marker through it: the assertion above is not free.
[[ -e "$TMP/mutant-without-symlink-clause/main/terminal" ]] \
  && ok "without-symlink-clause: cutting the clause writes the marker through the symlink" \
  || bad "without-symlink-clause: no marker at the symlink target; the symlink-target assertion above is free"
home_clause_control without-state-clause '-f "$state_file" && ' break_state
home_clause_control without-repository-clause ' && -d "$main_root"' break_repository altroot

# A census that could not run must not read as a clear tree, now that the
# reap's status gates the suite: the fallback forced, and ps starved.
census="$TMP/census"
mkdir -p "$census/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$census/bin/ps"; chmod +x "$census/bin/ps"
set +e
census_err=$(PATH="$census/bin:$PATH" MQ_REAP_FORCE_PS=1 \
  bash -c 'set -euo pipefail; . "$1"; mq_reap "$2"' bash "$TEST_DIR/lib/merge-queue-reaper.sh" "$census" 2>&1)
census_rc=$?
set -e
eq "$census_rc" 1 "a census that could not run fails the reap"
case "$census_err" in *"could not enumerate processes"*) ok "the failed census names itself" ;;
  *) bad "the failed census is unnamed: $census_err" ;; esac

# What the refusal is FOR, read where it lands: a consumer finds nothing to
# route. Asserted through consume rather than through the artifact file,
# because the teardown publishes no fallback once the home is gone: there is
# nothing to publish into. What can go wrong is the refusal publishing on its
# way out, and consume is where that shows.
consume_after_refusal() {
  local sb="$1" issue="$2"
  (
    export PATH="$sb/bin:$SEALED:$PATH"
    unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN GH_REPO GITHUB_REPOSITORY
    "$sb/orch/scripts/merge-queue-watch" consume --root "$sb/main" --issue "$issue"
  )
}
refusal_consume=$(consume_after_refusal "$TMP/home-repository-deleted" KEN-995-repository-deleted)
eq "$(jq -r .status <<<"$refusal_consume")" failed "the refusal terminalizes rather than leaving a lifecycle to retry"
eq "$(jq -r '.verdict // "null"' <<<"$refusal_consume")" null "the refusal leaves no verdict for a consumer to route"
eq "$(jq -r '.diagnostic.cause' <<<"$refusal_consume")" watch_lost "the consumer names the missing watch, not a producer verdict"

# Control: a refusal that publishes on its way out routes on that verdict
# instead, so the three assertions above are not free.
publishing="$TMP/home-publishing-refusal"
build_sandbox "$publishing"
mkdir -p "$publishing/main/altroot"
edit_once "$ORCH/scripts/lib/merge-queue-supervisor.sh" \
  "$publishing/orch/scripts/lib/merge-queue-supervisor.sh" \
  'then report_home_lost; return 1; fi' \
  'then publish_unknown home_lost 1; report_home_lost; return 1; fi' \
  || { bad "publishing-refusal mutation did not apply"; exit 1; }
IFS=$'\t' read -r ppid _prt _part _plog _pstate pmain < <(launch_supervisor "$publishing" KEN-995-publishing "$publishing/main/altroot")
break_repository "" "" "$pmain" "$publishing"
if alive_for "$ppid" 200; then bad "the publishing mutant kept running"; fi
publishing_consume=$(consume_after_refusal "$publishing" KEN-995-publishing)
if [[ "$(jq -r '.diagnostic.cause' <<<"$publishing_consume")" != watch_lost ]]; then
  ok "a refusal that publishes routes the consumer somewhere else"
else bad "the publishing mutant still consumed as watch_lost"; fi
mq_reap "$publishing" || bad "reaper reported survivors under the publishing sandbox"

echo "=== every supervisor exit runs its teardown ==="

# The teardown is an EXIT trap reading state the function once declared
# local. An EXIT trap fires when the shell exits, after `return` and a set -e
# failure have both popped the function's frame, so the trap ran empty on
# every such exit: no worker reaped, no unknown fallback, no terminal file
# (KEN-1060). The state is process-scoped now. Each case below forces one
# exit kind while the supervisor holds everything teardown exists to retire
# (a live worker, an open runtime, the promise of a consumable artifact) and
# asserts the teardown ran; its control re-plants `local` on the worker's
# pid, which is the original defect, and asserts the same teardown did not.

# The worker alone: the process whose executed script is the sandbox's
# queue-wait. The supervisor's own argv carries that path too (the waiter is
# its seventh argument), and so does the worker subshell forked from it, so a
# substring census would count them both as workers.
workers_under() {
  ps -e -ww -o pid=,args= > "$TMP/ps.worker.snapshot" 2>/dev/null || true
  awk -v script="$1/orch/scripts/queue-wait" '$3 == script { print $1 }' "$TMP/ps.worker.snapshot"
}
count_workers() { workers_under "$1" | grep -c . || true; }

# $1 sandbox, then needle/replacement pairs applied in order to the sandbox's
# supervisor copy; each must apply exactly once.
plant() {
  local sb="$1" src="$ORCH/scripts/lib/merge-queue-supervisor.sh" dst
  dst="$sb/orch/scripts/lib/merge-queue-supervisor.sh"; shift
  build_sandbox "$sb"
  while (($# >= 2)); do
    edit_once "$src" "$dst.next" "$1" "$2" || return 1
    mv -- "$dst.next" "$dst"; src="$dst"; shift 2
  done
}

# $1 sandbox, $2 issue: launch under the sandbox's supervisor copy. The caller
# arranges for the supervisor to exit or be held before the worker-liveness
# marker, so the launch command itself must fail; on that failure, print
# "runtime<TAB>artifact" for the attempt.
launch_return_path() {
  local sb="$1" issue="$2" scripts main rc=0
  scripts="$sb/orch/scripts"; main="$sb/main"
  (
    export PATH="$sb/bin:$SEALED:$PATH"
    unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN GH_REPO GITHUB_REPOSITORY
    "$scripts/merge-queue-watch" init --worktree "$main" --issue "$issue" \
      --branch "$(git -C "$main" branch --show-current)" >/dev/null
    prep=$("$scripts/merge-queue-watch" prepare --worktree "$main" --issue "$issue" \
      --repo owner/repo --pr 42 --head "$HEAD" --root "$main" --gate-mode off \
      --recovery-count 0 --cleanup-worktree false)
    "$scripts/merge-queue-watch" launch --root "$main" --issue "$issue" \
      --watch-id "$(jq -r .watch_id <<<"$prep")" --poll 1 --max-wait 600 >/dev/null 2>&1
  ) || rc=$?
  [[ "$rc" -ne 0 ]] || return 1
  "$scripts/merge-queue-watch" inspect --root "$main" --issue "$issue" \
    | jq -r '[.runtime_dir, .artifact_path] | @tsv'
}

# $1 sandbox, $2 runtime, $3 artifact, $4 label.
assert_teardown_ran() {
  local i
  wait_exists "$2/terminal" && ok "$4: the terminal file is written" || bad "$4: no terminal file"
  eq "$(jq -r '.verdict // "missing"' "$3" 2>/dev/null || echo missing)" unknown "$4: the unknown fallback is published"
  eq "$(jq -r '.cause // "missing"' "$3" 2>/dev/null || echo missing)" supervisor_exit "$4: the fallback names the supervisor exit"
  for ((i=0;i<100;i++)); do [[ "$(count_workers "$1")" -eq 0 && "$(count_supervisors "$1")" -eq 0 ]] && break; sleep 0.05; done
  eq "$(count_workers "$1")" 0 "$4: the worker is reaped"
  eq "$(count_supervisors "$1")" 0 "$4: no supervisor outlives the exit"
}
# The same four facts, negated: this is the silent no-op the assertions
# above must catch, so a control that fails any of them frees an assertion.
assert_teardown_skipped() {
  [[ ! -e "$2/terminal" ]] && ok "$4: the empty trap writes no terminal" || bad "$4: the control wrote a terminal; that assertion is free"
  [[ ! -e "$3" ]] && ok "$4: the empty trap publishes no fallback" || bad "$4: the control published a fallback; that assertion is free"
  [[ "$(count_workers "$1")" -gt 0 ]] && ok "$4: the empty trap leaks the worker" || bad "$4: the control leaked no worker; that assertion is free"
  mq_reap "$1" || bad "$4: reaper reported survivors under the control sandbox"
}
# $1 sandbox, $2 issue, $3 label, $4 ran|skipped: launch, then assert.
teardown_case() {
  local sb="$1" issue="$2" label="$3" expect="$4" runtime="" artifact=""
  if IFS=$'\t' read -r runtime artifact < <(launch_return_path "$sb" "$issue"); then
    ok "$label: the launch fails"
  else
    bad "$label: the launch did not fail; the assertions below prove nothing"; return 0
  fi
  case "$expect" in
    ran) assert_teardown_ran "$sb" "$runtime" "$artifact" "$label" ;;
    skipped) assert_teardown_skipped "$sb" "$runtime" "$artifact" "$label" ;;
  esac
}

RETURN_SITE='kill -0 "$worker_pid" 2>/dev/null || return 1'
SET_E_SITE=': > "$runtime/ready"; chmod 600 "$runtime/ready"'
LOCAL_PID='  worker_pid="" worker_rc=0 event="" watchdog_pid=""'

# A `return` after the worker is forked: the liveness check forced false.
plant "$TMP/return-path" "$RETURN_SITE" 'false || return 1' \
  || { bad "return-path mutation did not apply"; exit 1; }
teardown_case "$TMP/return-path" KEN-1060-return "return" ran
plant "$TMP/return-path-local" "$RETURN_SITE" 'false || return 1' "$LOCAL_PID" "  local$LOCAL_PID" \
  || { bad "return-path control mutation did not apply"; exit 1; }
teardown_case "$TMP/return-path-local" KEN-1060-return-local "return control" skipped

# A set -e exit after the worker is forked: the ready marker's write fails.
plant "$TMP/set-e" "$SET_E_SITE" ': > "$runtime/missing/ready"; chmod 600 "$runtime/ready"' \
  || { bad "set -e mutation did not apply"; exit 1; }
teardown_case "$TMP/set-e" KEN-1060-set-e "set -e" ran
plant "$TMP/set-e-local" "$SET_E_SITE" ': > "$runtime/missing/ready"; chmod 600 "$runtime/ready"' "$LOCAL_PID" "  local$LOCAL_PID" \
  || { bad "set -e control mutation did not apply"; exit 1; }
teardown_case "$TMP/set-e-local" KEN-1060-set-e-local "set -e control" skipped

# The `return` before the worker is forked, driven with no mutation: the
# post-registration currency recheck. The supervisor is held at its event
# fifo, so the launch command times out waiting for worker liveness and
# claims launch_failed; released, the supervisor's recheck refuses and
# returns 1. That launch_failed state still admits the unknown fallback,
# which is the reason publish accepts it.
regate="$TMP/recheck"
build_sandbox "$regate"
TD_REAL_MKFIFO="$(command -v mkfifo)"
export TD_MKFIFO_GATE="$TMP/recheck-mkfifo-gate" TD_REAL_MKFIFO
cat > "$regate/bin/mkfifo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$TD_MKFIFO_GATE.enabled" && "$*" == *"/events"* ]]; then
  touch "$TD_MKFIFO_GATE.entered"
  while [[ ! -f "$TD_MKFIFO_GATE.release" ]]; do sleep 0.05; done
fi
exec "$TD_REAL_MKFIFO" "$@"
EOF
chmod +x "$regate/bin/mkfifo"
touch "$TD_MKFIFO_GATE.enabled"
rg_runtime="" rg_artifact=""
if IFS=$'\t' read -r rg_runtime rg_artifact < <(launch_return_path "$regate" KEN-1060-recheck); then
  ok "recheck: the held supervisor's launch claims its failure"
else
  bad "recheck: the held launch did not fail; the assertions below prove nothing"
fi
wait_exists "$TD_MKFIFO_GATE.entered" || bad "recheck: the supervisor never reached its event fifo"
touch "$TD_MKFIFO_GATE.release"
[[ -z "$rg_runtime" ]] || assert_teardown_ran "$regate" "$rg_runtime" "$rg_artifact" "recheck"
rm -f -- "$TD_MKFIFO_GATE.enabled" "$TD_MKFIFO_GATE.entered" "$TD_MKFIFO_GATE.release"

echo "=== a wait whose repository is deleted refuses to keep polling ==="
QW="$TMP/qw"
mkdir -p "$QW/orch/scripts/lib" "$QW/bin" "$QW/repo"
ln -s "$(cd "$ORCH/.." && pwd)/github" "$QW/github"
git -C "$QW/repo" init -q
git -C "$QW/repo" config user.email test@example.com
git -C "$QW/repo" config user.name Test
touch "$QW/repo/seed"; git -C "$QW/repo" add seed; git -C "$QW/repo" commit -qm seed
cp "$ORCH/scripts/queue-wait" "$ORCH/scripts/orch-env" "$QW/orch/scripts/"
cp "$ORCH/scripts/lib/gh-auth.sh" "$ORCH/scripts/lib/review-threads.sh" \
   "$ORCH/scripts/lib/kendex-env.sh" "$QW/orch/scripts/lib/"
# Held at repository resolution, the wait is past startup and has not yet
# reached the poll loop — the one point where the repository can be deleted
# under a wait that is definitely running.
cat > "$QW/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  'auth status'|'api user') echo authenticated; exit 0 ;;
  'repo view')
    touch "$QW_GATE.entered"
    while [[ ! -f "$QW_GATE.release" ]]; do sleep 0.05; done
    printf 'owner/repo\n'; exit 0 ;;
esac
echo "unexpected gh: $*" >&2; exit 1
EOF
chmod +x "$QW/bin/gh" "$QW/orch/scripts/queue-wait" "$QW/orch/scripts/orch-env"

# $1 waiter, $2 gate, $3 output prefix -> exit code
wait_through_deletion() {
  local waiter="$1" gate="$2" out="$3" pid rc=0
  rm -rf "$QW/repo"; mkdir -p "$QW/repo"
  git -C "$QW/repo" init -q
  git -C "$QW/repo" config user.email test@example.com
  git -C "$QW/repo" config user.name Test
  touch "$QW/repo/seed"; git -C "$QW/repo" add seed; git -C "$QW/repo" commit -qm seed
  ( cd "$QW/repo" && PATH="$QW/bin:$SEALED:$PATH" GH_TOKEN=ghp_project QW_GATE="$gate" \
      "$waiter" 42 1 60 --json >"$out.out" 2>"$out.err" ) & pid=$!
  wait_exists "$gate.entered" || { bad "the wait never reached repository resolution"; return 1; }
  rm -rf "$QW/repo"
  touch "$gate.release"
  wait "$pid" 2>/dev/null || rc=$?
  printf '%s\n' "$rc"
}

qw_rc=$(wait_through_deletion "$QW/orch/scripts/queue-wait" "$QW/gate" "$QW/live")
eq "$qw_rc" 4 "a wait whose repository was deleted exits 4"
if [[ ! -s "$QW/live.out" ]]; then ok "the refusal emits no result object a caller could route"; else bad "deleted-repo wait still printed a result: $(cat "$QW/live.out")"; fi
if grep -Fq 'the repository this wait started in is gone' "$QW/live.err"; then ok "the refusal names the missing repository"; else bad "deleted-repo refusal is unnamed: $(cat "$QW/live.err")"; fi

# Control: with the check removed the poll runs, and the run ends on the
# unstaged `pr view` instead — a different code, and a result object.
sed 's/^  if \[ ! -d "\$PROJECT_ROOT" \]; then$/  if false; then/' \
  "$ORCH/scripts/queue-wait" > "$QW/orch/scripts/queue-wait-unguarded"
grep -Fq '  if false; then' "$QW/orch/scripts/queue-wait-unguarded" || { bad "repository-check mutation did not apply"; exit 1; }
chmod +x "$QW/orch/scripts/queue-wait-unguarded"
mutant_rc=$(wait_through_deletion "$QW/orch/scripts/queue-wait-unguarded" "$QW/mutant-gate" "$QW/mutant")
if [[ "$mutant_rc" != 4 ]]; then ok "without the check the deleted repository routes nothing special (exit $mutant_rc)"; else bad "unguarded wait still exited 4"; fi
# The exit code alone would also pass on a mutant that died at startup. What
# the guard suppresses is a ROUTABLE reading, so the control has to show one.
if [[ -s "$QW/mutant.out" ]] && jq -e '.verdict' "$QW/mutant.out" >/dev/null 2>&1; then
  ok "the unguarded wait polled on and emitted the verdict the guard suppresses"
else bad "the unguarded control never reached a poll: $(head -c 200 "$QW/mutant.out" 2>/dev/null)"; fi

echo "=== a deleted stub directory reaches no real binary ==="
rm -rf -- "${TMP:?}/reaped/bin"
# The directory is the roster: every name it holds is tested, so a name added
# there without a working symlink is caught rather than skipped.
sealed_names=""
for entry in "$SEALED"/*; do
  name=$(basename "$entry")
  [[ "$name" != refuse ]] || continue
  sealed_names="$sealed_names $name"
done
if [[ -n "$sealed_names" ]]; then ok "the sealed roster derived a non-empty set"; else bad "the sealed directory named nothing; the cases below would pass vacuously"; fi
# A decoy for every sealed name, placed AFTER the sealed directory: without
# one the case passes on any runner where the real binary is simply not
# installed, which proves nothing about ordering. With it, each name has
# something reachable to be kept away from.
decoys="$TMP/decoy-bin"; mkdir -p "$decoys"
for name in $sealed_names; do
  printf '#!/usr/bin/env bash\necho "decoy ran"\nexit 0\n' > "$decoys/$name"
  chmod +x "$decoys/$name"
done
sealed_path="$TMP/reaped/bin:$SEALED:$decoys:$PATH"
for name in $sealed_names; do
  eq "$(PATH="$decoys:$PATH" command -v "$name")" "$decoys/$name" "the $name decoy is reachable when nothing shadows it"
  resolved=$(PATH="$sealed_path" command -v "$name" || true)
  eq "$resolved" "$SEALED/$name" "$name resolves to the sealed refusal ahead of a reachable real one"
  set +e
  refusal=$(PATH="$sealed_path" "$name" --version 2>&1 >/dev/null); refusal_rc=$?
  set -e
  eq "$refusal_rc" 97 "sealed $name refuses instead of running"
  case "$refusal" in *"sealed-bin: $name is sealed"*) ok "sealed $name names itself in its refusal" ;;
    *) bad "sealed $name refusal is unnamed: $refusal" ;; esac
done

echo "=== every supervisor-launching suite arms both ==="

# The roster is derived, never listed: a suite that starts launching real
# supervisors and forgets to arm is caught because it is FOUND, where a list
# would simply not hold it and still report all-ok. Launching means the suite
# stands up its own copy of the script that detaches supervisors, which the
# doc audits that merely quote a launch command line do not — so the predicate
# excludes them by what it matches and needs no exemption list to maintain.
#
# One grep, never a pipeline: `grep -q` closes the pipe on its first hit, and
# under pipefail the upstream SIGPIPE fails the whole test.
launching_suites() {
  grep -lE 'cp [^#]*scripts/merge-queue-watch' "$1"/*.sh 2>/dev/null || true
}

# What arming looks like. The EXIT traps a suite installs, heredoc bodies left
# out: a second EXIT trap silently replaces the first, so counting them is the
# check, and a match living only in fixture text arms nothing. Both shapes are
# planted as controls below.
#
# A bounded scanner, not a shell parser. Its stated limits: a heredoc opened
# with a space before its delimiter is not followed, and a line whose first
# character is a hash is skipped entirely. Both make it read MORE of a file
# than a shell would, which can only reject a suite, never pass one.
exit_traps_in() {
  [[ -r "$1" ]] || { echo "merge_queue_teardown: cannot read $1 to scan its EXIT traps" >&2; return 2; }
  awk -v q='\047' '
    BEGIN {
      # A heredoc opener is << with an optional -, an optional quote or
      # backslash, and a real identifier. Anything else after << is arithmetic,
      # a comparison, or prose, and opening a body on it made the rest of the
      # file invisible.
      openre = "<<-?[" q "\"\\\\]?[A-Za-z_][A-Za-z0-9_]*"
      stripre = "^<<-?[" q "\"\\\\]?"
    }
    delim != "" {
      line = $0; sub(/^\t+/, "", line)
      if (line == delim) delim = ""
      next
    }
    /^[ \t]*#/ { next }
    {
      # A here-string opens no body, and its <<< would otherwise be read as a
      # << followed by whatever it redirects.
      scan = $0; gsub(/<<</, "   ", scan)
      if (match(scan, openre)) {
        d = substr(scan, RSTART, RLENGTH)
        sub(stripre, "", d)
        delim = d; opened = FNR
      }
      line = $0; sub(/^[ \t]+/, "", line)
      if (line ~ /^trap[ \t].*[ \t]EXIT([ \t]|$)/) found = found line "\n"
    }
    END {
      # Reaching the end still inside a body means the scan lost its place, and
      # every trap after that point went unseen. Report nothing rather than a
      # partial reading.
      if (delim != "") {
        printf "merge_queue_teardown: end of file while still inside the heredoc %s opened at line %d; the scan could not complete\n", delim, opened > "/dev/stderr"
        exit 2
      }
      printf "%s", found
    }
  ' "$1"
}
# 0 armed, 1 scanned and not armed, 2 the scan itself could not run — a
# broken scan reported as an unarmed suite would name the wrong defect.
suite_arms_teardown() {
  local traps
  traps=$(exit_traps_in "$1") || return 2
  [[ "$traps" == 'trap mq_reap_teardown EXIT' ]]
}
suite_seals_path() {
  local body
  body=$(grep -v '^[[:space:]]*#' "$1") || return 1
  grep -q 'tools/tests/lib/sealed-bin' <<<"$body" && grep -qF '$SEALED:$PATH' <<<"$body"
}

roster=$(launching_suites "$TEST_DIR")
if [[ -n "$roster" ]]; then ok "the launching-suite roster derived a non-empty set"; else bad "no suite derived as launching supervisors; the audit below would pass vacuously"; fi
while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  suite_name=$(basename "$suite" .sh)
  arm_rc=0; suite_arms_teardown "$suite" || arm_rc=$?
  case "$arm_rc" in
    0) ok "$suite_name installs the reaping teardown" ;;
    1) bad "$suite_name launches supervisors without arming teardown" ;;
    *) bad "$suite_name could not be scanned for its EXIT traps" ;;
  esac
  if suite_seals_path "$suite"; then ok "$suite_name seals its PATH behind the stub directory"
  else bad "$suite_name launches supervisors without sealing its PATH"; fi
done <<< "$roster"

# Controls. The derivation must FIND a suite nobody listed, and the arming
# check must accept only a suite that really installs the reaping teardown.
# Two of the planted shapes are the reason the check counts rather than
# matches: override_suite and heredoc_only_suite both pass a plain whole-line
# match and both leak.
planted="$TMP/planted"
mkdir -p "$planted"
printf '#!/usr/bin/env bash\ncp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"\n' > "$planted/unarmed_suite.sh"
planted_roster=$(launching_suites "$planted")
case "$planted_roster" in *"$planted/unarmed_suite.sh"*) ok "the derivation finds a launching suite no list names" ;;
  *) bad "the derivation missed a planted launching suite: $planted_roster" ;; esac

cat > "$planted/armed_suite.sh" <<'ARMED'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap mq_reap_teardown EXIT
ARMED
# The shape every merge-queue suite had before KEN-995: the fixture tree
# removed, the processes it started left running.
cat > "$planted/old_teardown_suite.sh" <<'OLD'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap 'rm -rf -- "${TMP:?}"' EXIT
OLD
# Armed, then silently disarmed: bash keeps only the last EXIT handler.
cat > "$planted/override_suite.sh" <<'OVERRIDE'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap mq_reap_teardown EXIT
trap 'rm -rf -- "${TMP:?}"' EXIT
OVERRIDE
# Armed nowhere but in a fixture it writes for a child.
cat > "$planted/heredoc_only_suite.sh" <<'HEREDOC'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap 'rm -rf -- "${TMP:?}"' EXIT
cat > "$TMP/child.sh" <<'CHILD'
trap mq_reap_teardown EXIT
CHILD
HEREDOC
# A comment mentioning a heredoc opener used to open a body that never closed,
# and everything after it went unread — including an overriding trap.
cat > "$planted/comment_phantom_suite.sh" <<'PHANTOM'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap mq_reap_teardown EXIT
# a note about <<HEREDOC bodies
trap 'rm -rf -- "${TMP:?}"' EXIT
PHANTOM
# Ordinary code did it too: a shift, or a comparison inside a string.
cat > "$planted/shift_phantom_suite.sh" <<'SHIFT'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap mq_reap_teardown EXIT
mask=$(( 1 << 2 ))
trap 'rm -rf -- "${TMP:?}"' EXIT
SHIFT
# And a body that genuinely never closes is a scan that lost its place, not a
# suite that is not armed — the traps after it were never seen either way.
cat > "$planted/unterminated_suite.sh" <<'UNTERM'
#!/usr/bin/env bash
cp "$ORCH/scripts/merge-queue-watch" "$SCRIPTS/"
trap mq_reap_teardown EXIT
cat > /dev/null <<NEVERCLOSED
UNTERM
printf '#!/usr/bin/env bash\n# trap mq_reap_teardown EXIT\n# tools/tests/lib/sealed-bin and "$SEALED:$PATH"\n' > "$planted/comment_decoy.sh"

if suite_arms_teardown "$planted/armed_suite.sh"; then ok "a suite that installs the reaping teardown passes the arming check"
else bad "the arming check rejects a suite that is armed"; fi
for shape in old_teardown_suite override_suite heredoc_only_suite comment_decoy \
             comment_phantom_suite shift_phantom_suite; do
  shape_rc=0; suite_arms_teardown "$planted/$shape.sh" || shape_rc=$?
  if [[ "$shape_rc" -eq 1 ]]; then ok "the arming check rejects $shape"
  else bad "the arming check answered $shape with $shape_rc, not a scanned rejection"; fi
done
# And a scan that could not run says so instead of blaming the suite.
unscannable_rc=0; unscannable_err=$(suite_arms_teardown "$planted/no-such-suite.sh" 2>&1) || unscannable_rc=$?
eq "$unscannable_rc" 2 "a suite that cannot be scanned is not reported as unarmed"
case "$unscannable_err" in *"cannot read"*) ok "the failed scan names the file it could not read" ;;
  *) bad "the failed scan is unnamed: $unscannable_err" ;; esac
unterm_rc=0; unterm_err=$(suite_arms_teardown "$planted/unterminated_suite.sh" 2>&1) || unterm_rc=$?
eq "$unterm_rc" 2 "a scan that ends inside a heredoc is not reported as unarmed"
case "$unterm_err" in *"could not complete"*) ok "the incomplete scan names the body it was still inside" ;;
  *) bad "the incomplete scan is unnamed: $unterm_err" ;; esac
if suite_seals_path "$planted/comment_decoy.sh"; then bad "a comment naming the sealed directory passed the sealing check"
else ok "a comment naming the sealed directory does not pass for a statement"; fi

printf 'merge-queue-teardown: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
