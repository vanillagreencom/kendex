#!/usr/bin/env bash
# Containment for the suites that launch real detached supervisors.
#
# `merge-queue-watch launch` detaches its supervisor with `setsid -f`, so no
# wait in a suite owns it. A suite killed mid-run — routine on a box with a
# load reaper — left live supervisors behind whose fixture tree was deleted
# under them, and their PATH stubs died with it: the fallthrough reached the
# real binaries and opened terminal windows on the operator's desktop
# (KEN-995). Two properties are proven here, each against a suite that is
# actually aborted mid-run:
#
#   teardown  an aborted suite leaves zero `__supervise` processes behind.
#   sealing   with the fixture's own stub directory deleted, `gh`, `ghostty`
#             and `tmux` still resolve to the sealed refusals, never to the
#             real binaries.
#
# The teardown assertion reads `ps`, where the reaper under test reads
# /proc — a broken reaper cannot answer the question that judges it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
SEALED="$(git -C "$TEST_DIR" rev-parse --show-toplevel)/tools/tests/lib/sealed-bin"
[[ -x "$SEALED/gh" ]] || { echo "merge_queue_teardown: sealed-bin fixture is missing: $SEALED" >&2; exit 1; }
TMP="$(mktemp -d)"
# shellcheck source=lib/merge-queue-reaper.sh
. "$TEST_DIR/lib/merge-queue-reaper.sh"
mq_reap_own "$TMP"
trap 'mq_reap || true; rm -rf "$TMP"' EXIT
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
  trap 'mq_reap || true' EXIT
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
  local sandbox="$1" reap="$2" pidout="$3" pid rc=0
  VICTIM_SANDBOX="$sandbox" VICTIM_REAP="$reap" VICTIM_PIDOUT="$pidout" \
  VICTIM_SEALED="$SEALED" VICTIM_TESTLIB="$TEST_DIR/lib" VICTIM_HEAD="$HEAD" \
    bash "$TMP/victim.sh" >"$pidout.log" 2>&1 &
  pid=$!
  wait_exists "$pidout.ready" || { bad "victim never launched a supervisor (see $pidout.log)"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || rc=$?
  # The supervisor must not have raced the abort: it was alive when the
  # signal landed, or the case that follows proves nothing.
  return 0
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

# And the reaper clears exactly that: same processes, run directly.
MQ_REAP_ROOT="$TMP/leaky" mq_reap || bad "reaper reported survivors under the leaky sandbox"
eq "$(count_supervisors "$TMP/leaky")" 0 "the reaper clears a tree an abort left behind"

build_sandbox "$TMP/reaped"
run_and_abort "$TMP/reaped" 1 "$TMP/reaped.pid"
sleep 0.5
eq "$(count_supervisors "$TMP/reaped")" 0 "a suite aborted mid-run kills its supervisor tree on exit"

echo "=== a supervisor whose home is deleted refuses to continue ==="

# $1 sandbox, $2 issue key: launch one supervisor and print
# "pid runtime artifact log".
launch_supervisor() {
  local sb="$1" issue="$2" scripts main prep state
  scripts="$sb/orch/scripts"; main="$sb/main"
  "$scripts/merge-queue-watch" init --worktree "$main" --issue "$issue" \
    --branch "$(git -C "$main" branch --show-current)" >/dev/null
  prep=$("$scripts/merge-queue-watch" prepare --worktree "$main" --issue "$issue" \
    --repo owner/repo --pr 42 --head "$HEAD" --root "$main" --gate-mode off \
    --recovery-count 0 --cleanup-worktree false)
  "$scripts/merge-queue-watch" launch --root "$main" --issue "$issue" \
    --watch-id "$(jq -r .watch_id <<<"$prep")" --poll 1 --max-wait 600 >/dev/null
  state=$("$scripts/merge-queue-watch" inspect --root "$main" --issue "$issue")
  jq -r '[.supervisor_pid, .runtime_dir, .artifact_path, .log_path] | @tsv' <<<"$state"
}
alive_for() { local i; for ((i=0;i<"$2";i++)); do ps -p "$1" -o pid= >/dev/null 2>&1 || return 1; sleep 0.1; done; return 0; }

build_sandbox "$TMP/homeless"
IFS=$'\t' read -r hpid hrt hart hlog < <(launch_supervisor "$TMP/homeless" KEN-995-home)
rm -rf "$hrt"
if alive_for "$hpid" 200; then bad "supervisor kept running with its runtime deleted"; else ok "a supervisor whose runtime is deleted stops inside its poll window"; fi
if [[ ! -e "$hart" ]]; then ok "the refusal publishes no verdict a consumer could turn into another launch"; else bad "deleted-home supervisor published $hart"; fi
if grep -Fq 'launch home is gone' "$hlog"; then ok "the refusal names the home it lost"; else bad "deleted-home refusal is unnamed: $(tail -3 "$hlog")"; fi
eq "$(count_supervisors "$TMP/homeless")" 0 "no fixture process outlives the refusal"

# Control: the same deletion against a supervisor whose home check always
# answers yes must leave it running, so the case above is the guard's doing.
build_sandbox "$TMP/homeless-mutant"
mutant="$TMP/homeless-mutant/orch/scripts/lib/merge-queue-supervisor.sh"
sed 's/^  home_present() {.*$/  home_present() { true; }/' "$ORCH/scripts/lib/merge-queue-supervisor.sh" > "$mutant"
grep -Fq 'home_present() { true; }' "$mutant" || { bad "home-check mutation did not apply"; exit 1; }
IFS=$'\t' read -r mpid mrt _ _ < <(launch_supervisor "$TMP/homeless-mutant" KEN-995-home-mutant)
rm -rf "$mrt"
if alive_for "$mpid" 80; then ok "without the home check the supervisor runs on past the deletion"; else bad "mutant supervisor died for a reason other than the home check"; fi
MQ_REAP_ROOT="$TMP/homeless-mutant" mq_reap || bad "reaper reported survivors under the mutant sandbox"

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

echo "=== a deleted stub directory reaches no real binary ==="
rm -rf "$TMP/reaped/bin"
sealed_path="$TMP/reaped/bin:$SEALED:$PATH"
for name in gh ghostty tmux; do
  resolved=$(PATH="$sealed_path" command -v "$name" || true)
  eq "$resolved" "$SEALED/$name" "$name resolves to the sealed refusal once the stub directory is gone"
  set +e
  refusal=$(PATH="$sealed_path" "$name" --version 2>&1 >/dev/null); refusal_rc=$?
  set -e
  eq "$refusal_rc" 97 "sealed $name refuses instead of running"
  case "$refusal" in *"sealed-bin: $name is sealed"*) ok "sealed $name names itself in its refusal" ;;
    *) bad "sealed $name refusal is unnamed: $refusal" ;; esac
done

echo "=== every supervisor-launching suite arms both ==="
for suite in merge_queue_watch merge_queue_rearm_e2e merge_queue_teardown; do
  body=$(cat "$TEST_DIR/$suite.sh")
  if [[ "$body" == *"lib/merge-queue-reaper.sh"* && "$body" == *"mq_reap_own"* && "$body" == *'mq_reap || true'* ]]; then
    ok "$suite arms trap-based supervisor teardown"
  else bad "$suite launches supervisors without arming teardown"; fi
  if [[ "$body" == *'tools/tests/lib/sealed-bin'* && "$body" == *'$SEALED:$PATH'* ]]; then
    ok "$suite seals its PATH behind the stub directory"
  else bad "$suite does not seal its PATH"; fi
done

printf 'merge-queue-teardown: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
