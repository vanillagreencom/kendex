#!/usr/bin/env bash
# Execute the documented launch against approval-wait while its gh call waits.
# Killing the harness process group must leave the waiter's exit writer alive.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/waiter-assertions.sh"
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
for dep in setsid perl pgrep; do
  if ! command -v "$dep" >/dev/null; then
    printf 'skip: waiter launch requires %s\n' "$dep"
    exit 0
  fi
done
mkdir -p tmp
TMP_ROOT="$(mktemp -d "$PWD/tmp/waiter-launch.XXXXXX")"
parent_pid=
cleanup() {
  local leader
  # Every process group the read case launched leads with a shell naming a
  # run path under it, so a failed case leaves no job behind.
  for leader in $(pgrep -f "$TMP_ROOT/read/" || :); do
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
# Each mutation swaps the fork for a trailing `&`: no-detach drops the new
# session, ignore-int keeps it in the shape that ignores INT and QUIT.
mutate() {
  awk -v to="$1" '/^setsid -f / { sub(/^setsid -f /, to); $0 = $0 " &"; matches++ } { print } END { if (matches != 1) exit 1 }' "$TMP_ROOT/launch.sh"
}
mutate '' > "$TMP_ROOT/no-detach.sh"
mutate 'setsid ' > "$TMP_ROOT/ignore-int.sh"
if cmp -s "$TMP_ROOT/launch.sh" "$TMP_ROOT/no-detach.sh"; then
  printf 'mutation-missing path=%s\n' "$TMP_ROOT/launch.sh" >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/project"
git -C "$TMP_ROOT/project" init -q
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
cat > "$TMP_ROOT/parent.sh" <<'PARENT'
#!/usr/bin/env bash
set -euo pipefail
source "$1" "$2/wait" "$3" 1 --json --mode approval
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

for mode in launch no-detach; do
  case_dir="$TMP_ROOT/$mode"
  mkdir -p "$case_dir"
  mkfifo "$case_dir/hold"
  (
    cd "$TMP_ROOT/project"
    export PATH="$TMP_ROOT/bin:$PATH" WAIT_CASE="$case_dir"
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
    assert_eq "$result" 3 'detached waiter records its auth-failure exit after parent kill' "$case_dir/wait.log"
  else
    result=absent
    if [[ -e "$case_dir/wait.exit" ]]; then result=present; fi
    assert_eq "$result" absent 'control: removing detach loses the exit when the parent group dies' "$case_dir/wait.log"
  fi
done
# ignoring_caller CMD... — CMD as the async job of a non-interactive shell,
# which is the caller shape that installs the ignore described at the top of
# this file. Every row below runs under it, so the disposition a row reads is
# the one the row itself installed and never the one this suite was started
# with.
ignoring_caller() { bash -c '"$@" & wait' _ "$@" </dev/null; }

# row | launcher spelling | `prefixed` or `bare` | recorded exit | name
while IFS='|' read -r row spelling prefix want name; do
  case_dir="$TMP_ROOT/int-$row"
  mkdir -p "$case_dir"
  cmd=(bash "$TMP_ROOT/$spelling.sh" "$case_dir/wait" sh -c 'kill -INT "$$"')
  [[ "$prefix" == bare ]] || cmd=("${KENDEX_GROUP_LEADER[@]}" "${cmd[@]}")
  ignoring_caller "${cmd[@]}"
  wait_for_file "$case_dir/wait.exit"
  assert_eq "$(<"$case_dir/wait.exit")" "$want" "$name" "$case_dir/wait.log"
done <<'ROWS'
launch|launch|prefixed|130|detached job dies on its own INT
ignore|ignore-int|prefixed|0|control: a trailing & leaves INT ignored
bare|launch|bare|0|control: the caller's own ignore reaches the detached job
ROWS
# The watch read in watch-delivery.md, run as written against a job this fence
# launched under an `env -u` prefix: it names the job's launch shell by its run
# path alone, that shell leads the job's group, and after the documented group
# stop the same read exits 1. The pid's group is compared before any kill, so a
# read naming another process fails here and signals nothing.
read_span="$(awk 'match($0, /`pgrep -f [^`]*`/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }' \
  "$SKILL_DIR/references/watch-delivery.md")"
read_pattern="${read_span#pgrep -f \'}"
read_pattern="${read_pattern%\'}"
case_dir="$TMP_ROOT/read"
mkdir -p "$case_dir"
read_pattern="${read_pattern//\[RUN_DIR\]/$case_dir}"
assert_eq "${read_pattern:0:${#case_dir}}" "$case_dir" 'the documented watch read is keyed on the run path' "$case_dir/wait.log"
bash "$TMP_ROOT/launch.sh" "$case_dir/watch" env -u KENDEX_UNSET_PROBE sleep 300
# A follow of the watch's log, launched the same way, names watch.log in its own
# argv; the read must not take it for the watch.
touch "$case_dir/watch.log"
bash "$TMP_ROOT/launch.sh" "$case_dir/follow" tail -F "$case_dir/watch.log"
for ((attempt=0; attempt<500; attempt++)); do
  pgrep -f "$read_pattern" >/dev/null && break
  sleep 0.01
done
read_rc=0
read_out="$(pgrep -f "$read_pattern")" || read_rc=$?
read_group=none
[[ "$read_rc" -ne 0 || "$read_out" == *$'\n'* ]] || read_group="$(ps -o pgid= -p "$read_out" | tr -d ' ')"
assert_eq "$read_rc:$read_group" "0:$read_out" 'the read prints one pid, the leader of the job group' "$case_dir/watch.log"
if [[ "$read_group" == "$read_out" ]]; then
  kill -TERM -- "-$read_out" 2>/dev/null || true
  for ((attempt=0; attempt<500; attempt++)); do
    pgrep -f "$read_pattern" >/dev/null || break
    sleep 0.01
  done
fi
read_rc=0
pgrep -f "$read_pattern" >/dev/null || read_rc=$?
assert_eq "$read_rc" 1 'the read exits 1 once the group stop ends the job' "$case_dir/watch.log"
follow_leader="$(pgrep -f "$case_dir/follo[w] ")" || follow_leader=""
[[ -z "$follow_leader" || "$follow_leader" == *$'\n'* ]] || kill -TERM -- "-$follow_leader" 2>/dev/null || true
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
