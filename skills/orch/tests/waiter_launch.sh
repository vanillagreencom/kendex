#!/usr/bin/env bash
# Execute the documented launch against approval-wait while its gh call waits.
# Killing the harness process group must leave the waiter's exit writer alive.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/waiter-assertions.sh"
if ! command -v setsid >/dev/null; then
  printf 'skip: waiter launch requires setsid\n'
  exit 0
fi
mkdir -p tmp
TMP_ROOT="$(mktemp -d "$PWD/tmp/waiter-launch.XXXXXX")"
parent_pid=
cleanup() {
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
for mode in launch ignore-int; do
  case_dir="$TMP_ROOT/int-$mode"
  mkdir -p "$case_dir"
  bash "$TMP_ROOT/$mode.sh" "$case_dir/wait" sh -c 'kill -INT "$$"'
  wait_for_file "$case_dir/wait.exit"
  result="$(<"$case_dir/wait.exit")"
  if [[ "$mode" == launch ]]; then
    assert_eq "$result" 130 'detached job dies on its own INT' "$case_dir/wait.log"
  else
    assert_eq "$result" 0 'control: a trailing & leaves INT ignored' "$case_dir/wait.log"
  fi
done
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
