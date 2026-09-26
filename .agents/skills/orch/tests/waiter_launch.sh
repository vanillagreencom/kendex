#!/usr/bin/env bash
# Execute the documented launch against approval-wait while its gh call waits.
# Killing the harness process group must leave the waiter's exit writer alive.
# Every case runs once per runner the launch can take: as a systemd user unit
# where a user manager answers on this host, and under setsid behind a
# systemd-run that fails, which is what a host with no user manager gets. A
# host with no manager skips the unit rows and says so.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assertions.sh"
# The INT rows below read a signal disposition no suite owns. A non-interactive
# shell sets SIGINT and SIGQUIT to SIG_IGN in every job it starts with `&`, the
# ignore survives exec, and no later `trap` takes it back — and open-terminal's
# run_detached starts a GUI-surface lane and every woken turn that way, so that
# lane's harness, its shell and `tools/guard --full` under it all carry that
# ignore. There the detached job
# the launch spelling starts exits 0 rather than 130 and the row reports the
# launcher adding an ignore the launcher did not add, which is a red suite on a
# gate every branch must pass and no defect in the script under test. This
# prefix restores both dispositions in the process it execs, so each row states
# the caller it measures the launcher against instead of inheriting one.
# shellcheck source=../../github/scripts/lib/group-leader.sh
source "$SKILL_DIR/../github/scripts/lib/group-leader.sh"
for dep in setsid perl; do
  if ! command -v "$dep" >/dev/null; then
    printf 'skip: waiter launch requires %s\n' "$dep"
    exit 0
  fi
done
mkdir -p tmp
TMP_ROOT="$(mktemp -d "$PWD/tmp/waiter-launch.XXXXXX")"
parent_pid=
cleanup() {
  local leader runner unit
  # Every job a case launched leads its process group with a shell naming a
  # run path under this root, so a failed case leaves no job behind; a unit is
  # stopped by the name its record carries.
  for runner in $(find "$TMP_ROOT" -name '*.runner' 2>/dev/null || :); do
    unit="$(sed -n 's/^unit=//p' "$runner" 2>/dev/null || :)"
    [[ -z "$unit" ]] || systemctl --user stop -- "$unit.service" >/dev/null 2>&1 || true
  done
  for leader in $(pgrep -f "$TMP_ROOT/" || :); do
    [[ "$leader" != "$$" ]] || continue
    kill -TERM -- "-$leader" 2>/dev/null || true
  done
  if [[ -n "$parent_pid" ]]; then
    kill -KILL -- "-$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# The executable fence is the source under test, not a second launch spelling.
awk '
  /^```sh$/ { active=1; blocks++; next }
  /^```$/ && active { active=0; next }
  active { print }
  END { if (blocks != 1 || active) exit 1 }
' "$SKILL_DIR/references/waiter-launch.md" > "$TMP_ROOT/launch.sh"
# The launch fence's one must-fail control: no-detach swaps the runner for a
# trailing `&`, which drops the new session.
awk '/job-unit\.sh launch / { sub(/^[^ ]*job-unit\.sh launch [^ ]* [^ ]* -- /, ""); $0 = $0 " &"; matches++ } { print } END { if (matches != 1) exit 1 }' \
  "$TMP_ROOT/launch.sh" > "$TMP_ROOT/no-detach.sh"
if cmp -s "$TMP_ROOT/launch.sh" "$TMP_ROOT/no-detach.sh"; then
  printf 'mutation-missing mutant=no-detach path=%s\n' "$TMP_ROOT/launch.sh" >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/project/.agents/skills" "$TMP_ROOT/no-manager" "$TMP_ROOT/lingering"
git -C "$TMP_ROOT/project" init -q
# The launch names the runner from the worktree root, as a lane runs it.
ln -s "$SKILL_DIR" "$TMP_ROOT/project/.agents/skills/orch"
cat > "$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" > "$WAIT_CASE/gh.ready"
for ((attempt=0; attempt<1000; attempt++)); do
  if [[ -f "$WAIT_CASE/release" ]]; then exit 1; fi
  sleep 0.01
done
exit 1
STUB
chmod +x "$TMP_ROOT/bin/gh"
# The runner's one must-fail control: a launch directory whose job-unit.sh
# does not hand its directory over to a unit.
NO_DIR_LIB="$TMP_ROOT/no-dir/.agents/skills/orch/scripts/lib"
mkdir -p "$NO_DIR_LIB"
FROM='      --working-directory="$PWD" ${unit_props[@]+"${unit_props[@]}"} \' \
  TO='      ${unit_props[@]+"${unit_props[@]}"} \' \
  awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; hits++; next } { print } END { if (hits != 1) exit 1 }' \
  "$SKILL_DIR/scripts/lib/job-unit.sh" > "$NO_DIR_LIB/job-unit.sh"
chmod +x "$NO_DIR_LIB/job-unit.sh"
ROOT_REAL="$(cd "$TMP_ROOT" && pwd -P)"
# A systemd-run whose probe fails, as it does where no user manager answers.
printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$TMP_ROOT/no-manager/systemd-run"
# A loginctl that says the user manager lingers, the one manager the runner
# starts a unit under, which this host's may not; the no-manager rows carry it
# too, so what they fall back on is the probe.
printf '#!/bin/sh\necho yes\n' > "$TMP_ROOT/lingering/loginctl"
cp "$TMP_ROOT/lingering/loginctl" "$TMP_ROOT/no-manager/loginctl"
chmod +x "$TMP_ROOT/no-manager/systemd-run" "$TMP_ROOT/no-manager/loginctl" "$TMP_ROOT/lingering/loginctl"
cat > "$TMP_ROOT/parent.sh" <<'PARENT'
#!/usr/bin/env bash
set -euo pipefail
source "$1" "$2/wait" "$3" 1 --json --mode approval > "$2/launch.out" 2>&1
printf '%s\n' "$$" > "$2/parent.ready"
read -r hold < "$2/hold"
PARENT

wait_for_file() {
  local path="$1" attempt
  for ((attempt=0; attempt<1000; attempt++)); do
    [[ ! -s "$path" ]] || return 0
    sleep 0.01
  done
  printf 'wait-file-timeout path=%s\n' "$path" >&2
  return 1
}
# A run directory made as waiter-launch.md makes one.
run_dir() { # PARENT
  mkdir -p "$1"
  mktemp -d "$1/waiter.XXXXXX"
}
# ignoring_caller CMD... — CMD as the async job of a non-interactive shell,
# which is the caller shape that installs the ignore described at the top of
# this file. Every INT row runs under it, so the disposition a row reads is
# the one the row itself installed and never the one this suite was started
# with.
ignoring_caller() { bash -c '"$@" & wait' _ "$@" </dev/null; }

# The cases, under the runner RUNNER (systemd or setsid) with PATH_PREFIX ahead
# of the caller's PATH.
runner_cases() { # RUNNER PATH_PREFIX
  local runner="$1" prefix="$2" mode case_dir result row spelling bare want name cmd
  echo "=== runner=$runner ==="
  for mode in launch no-detach; do
    case_dir="$(run_dir "$TMP_ROOT/$runner-$mode")"
    mkfifo "$case_dir/hold"
    (
      cd "$TMP_ROOT/project"
      export PATH="$prefix$TMP_ROOT/bin:$PATH" WAIT_CASE="$case_dir"
      unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN KENDEX_ENV_FILE
      exec setsid bash "$TMP_ROOT/parent.sh" "$TMP_ROOT/$mode.sh" "$case_dir" "$SKILL_DIR/scripts/approval-wait"
    ) &
    parent_pid=$!
    wait_for_file "$case_dir/parent.ready"
    wait_for_file "$case_dir/gh.ready"
    kill -KILL -- "-$parent_pid"
    if wait "$parent_pid" 2>/dev/null; then
      printf 'parent-survived pid=%s\n' "$parent_pid" >&2
      exit 1
    fi
    parent_pid=
    touch "$case_dir/release"
    if [[ "$mode" == launch ]]; then
      wait_for_file "$case_dir/wait.exit"
      result="$(<"$case_dir/wait.exit")"
      assert_eq "$result" 3 "runner=$runner: detached waiter records its auth-failure exit after parent kill" "$case_dir/wait.log"
      assert_eq "$(sed -n '1s/ .*//p' "$case_dir/wait.log")" "runner=$runner" \
        "runner=$runner: the log's first line is the runner line" "$case_dir/wait.log"
    else
      result=absent
      if [[ -e "$case_dir/wait.exit" ]]; then result=present; fi
      assert_eq "$result" absent "runner=$runner: control: removing detach loses the exit when the parent group dies" "$case_dir/wait.log"
    fi
  done

  # row | launcher spelling | `prefixed` or `bare` | recorded exit | name
  # A unit starts its job with INT at its default whatever the caller ignores;
  # under setsid the caller's own ignore reaches the job.
  while IFS='|' read -r row spelling bare want name; do
    [[ "$row" == "$runner":* ]] || continue
    case_dir="$(run_dir "$TMP_ROOT/int-${row#*:}")"
    cmd=(bash "$TMP_ROOT/$spelling.sh" "$case_dir/wait" sh -c 'kill -INT "$$"')
    [[ "$bare" == bare ]] || cmd=("${KENDEX_GROUP_LEADER[@]}" "${cmd[@]}")
    ( cd "$TMP_ROOT/project" && export PATH="$prefix$PATH" && ignoring_caller "${cmd[@]}" ) > "$case_dir/launch.out" 2>&1
    wait_for_file "$case_dir/wait.exit"
    assert_eq "$(<"$case_dir/wait.exit")" "$want" "runner=$runner: $name" "$case_dir/wait.log"
  done <<'ROWS'
systemd:launch|launch|prefixed|130|detached job dies on its own INT
systemd:bare|launch|bare|130|a unit starts the job with INT at its default, whatever the caller ignores
setsid:launch|launch|prefixed|130|detached job dies on its own INT
setsid:bare|launch|bare|0|control: the caller's own ignore reaches the detached job
ROWS

  # The job runs in the directory the launch ran from and with the pane the
  # caller's TMUX_PANE names, which a unit has only when the runner hands them
  # over. Under setsid the job inherits both, so the control, a runner
  # without the directory hand-over, is a unit row.
  # row | launch directory under the root | outcome against that directory and
  # %42 | name
  while IFS='|' read -r row project outcome name; do
    [[ "$row" == "$runner":* || "$row" == any:* ]] || continue
    case_dir="$(run_dir "$TMP_ROOT/env-$runner-${row#*:}")"
    ( cd "$TMP_ROOT/$project" && export PATH="$prefix$PATH" TMUX_PANE=%42 \
        && sh "$TMP_ROOT/launch.sh" "$case_dir/wait" sh -c 'pwd -P; printf "%s\n" "${TMUX_PANE:-none}"' ) \
      > "$case_dir/launch.out" 2>&1
    wait_for_file "$case_dir/wait.exit"
    result=differs
    [[ "$(sed -n '2,3p' "$case_dir/wait.log" | tr '\n' ' ')" != "$ROOT_REAL/$project %42 " ]] || result=same
    assert_eq "$result" "$outcome" "runner=$runner: $name" "$case_dir/wait.log"
  done <<'ROWS'
any:env|project|same|the job runs in the launch directory and reads the caller's TMUX_PANE
systemd:no-dir|no-dir|differs|control: without the directory hand-over the unit runs elsewhere
ROWS

  if command -v pgrep >/dev/null; then
    watch_read_case "$runner" "$prefix"
  else
    printf 'skip: the watch read case requires pgrep\n'
  fi
}

# The watch read and stop in watch-delivery.md, run as a harness runs them:
# the read inside a shell whose own argv carries the pattern, against a job this
# fence launched under an `env -u` prefix beside a follower of its log, in a run
# directory made as waiter-launch.md makes one, under a parent path holding a
# space and a `+`, the characters a checkout path may carry. With no
# job the read exits 1, never finding its own shell; with the job it prints one
# pid, the job group's leader and, under a unit, the unit's main process; the
# log's first line names the runner, and a unit carries the run id; the stop
# its runner line names ends the job, its `stopped` mark survives, and the read
# then exits 1. The pid's group is compared before any kill, so a read naming
# another process fails here and signals nothing.
watch_read_case() { # RUNNER PATH_PREFIX
  local runner="$1" prefix="$2" read_span read_cmd case_dir run_id read_rc read_out read_group attempt follow_leader
  local line unit main stop_cmd stop_rc
  read_span="$(awk 'match($0, /`pgrep -f [^`]*`/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }' \
    "$SKILL_DIR/references/watch-delivery.md")"
  case_dir="$(run_dir "$TMP_ROOT/read dir+x/$runner")"
  run_id="${case_dir##*/waiter.}"
  read_cmd="${read_span//\[RUN_ID\]/$run_id}"
  assert_eq "$read_cmd" "pgrep -f 'waiter[.]$run_id/watc[h] '" 'the documented watch read is keyed on the run name' "$case_dir/watch.log"
  # A trailing command keeps the shell from exec'ing pgrep, as a harness tool
  # shell running a longer command line never does.
  harness_read() { sh -c "$read_cmd; exit \$?"; }
  read_rc=0
  harness_read >/dev/null || read_rc=$?
  assert_eq "$read_rc" 1 "runner=$runner: with no watch the read exits 1 and finds not its own shell" "$case_dir/watch.log"
  ( cd "$TMP_ROOT/project" && PATH="$prefix$PATH" sh "$TMP_ROOT/launch.sh" "$case_dir/watch" env -u KENDEX_UNSET_PROBE sleep 300 ) >/dev/null
  wait_for_file "$case_dir/watch.log"
  ( cd "$TMP_ROOT/project" && PATH="$prefix$PATH" sh "$TMP_ROOT/launch.sh" "$case_dir/follow" tail -F "$case_dir/watch.log" ) >/dev/null
  for ((attempt=0; attempt<500; attempt++)); do
    harness_read >/dev/null && break
    sleep 0.01
  done
  read_rc=0
  read_out="$(harness_read)" || read_rc=$?
  read_group=none
  [[ "$read_rc" -ne 0 || "$read_out" == *$'\n'* ]] || read_group="$(ps -o pgid= -p "$read_out" | tr -d ' ')"
  assert_eq "$read_rc:$read_group" "0:$read_out" "runner=$runner: the read prints one pid, the leader of the job group" "$case_dir/watch.log"
  line="$(sed -n 1p "$case_dir/watch.log")"
  unit=""
  case "$runner" in
    systemd)
      unit="${line#runner=systemd unit=}"
      main="$(systemctl --user show -p MainPID --value -- "$unit.service" 2>/dev/null || echo none)"
      assert_eq "${unit%-*}|$main" "orch-watch-$run_id|$read_out" \
        "runner=$runner: line 1 of the log names the unit, which carries the run id and whose main process the read finds" "$case_dir/watch.log" ;;
    setsid)
      assert_eq "$line" "runner=setsid reason=probe-failed detail=Failed to connect to bus: No medium found" \
        "runner=$runner: line 1 of the log names the setsid runner and why" "$case_dir/watch.log" ;;
  esac
  printf 'stopped\n' > "$case_dir/watch.exit"
  # The documented stop, its span run as written with the placeholders filled.
  stop_cmd="$(awk 'match($0, /`[.]agents\/skills\/orch\/scripts\/lib\/job-unit[.]sh stop-job [^`]*`/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }' \
    "$SKILL_DIR/references/watch-delivery.md")"
  stop_cmd="${stop_cmd//\[RUN_DIR\]/$case_dir}"
  stop_cmd="${stop_cmd//\[RUN_ID\]/$run_id}"
  stop_cmd="${stop_cmd//\[PID\]/$read_out}"
  stop_rc=0
  [[ "$read_group" == "$read_out" ]] && ( cd "$TMP_ROOT/project" && sh -c "$stop_cmd" ) >/dev/null 2>&1 || stop_rc=$?
  assert_eq "$stop_rc" 0 "runner=$runner: the documented stop-job on the launch's record stops the watch" "$case_dir/watch.log"
  for ((attempt=0; attempt<500; attempt++)); do
    harness_read >/dev/null || break
    sleep 0.01
  done
  read_rc=0
  harness_read >/dev/null || read_rc=$?
  assert_eq "$read_rc" 1 "runner=$runner: the read exits 1 once the stop ends the job" "$case_dir/watch.log"
  assert_eq "$(<"$case_dir/watch.exit")" stopped "runner=$runner: the stop mark written before the stop survives it" "$case_dir/watch.log"
  follow_leader="$(pgrep -f "waiter[.]$run_id/follo[w] ")" || follow_leader=""
  [[ -z "$follow_leader" || "$follow_leader" == *$'\n'* ]] || kill -TERM -- "-$follow_leader" 2>/dev/null || true
}

if systemd-run --user --quiet --collect true </dev/null >/dev/null 2>&1; then
  runner_cases systemd "$TMP_ROOT/lingering:"
else
  printf '  skip  no systemd user manager answers on this host; the runner=systemd rows did not run\n'
fi
runner_cases setsid "$TMP_ROOT/no-manager:"
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
