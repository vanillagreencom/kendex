#!/usr/bin/env bash
# Surface: scripts/overseer-run, the path a recorded overseer launch line runs
# its harness command through.
# Inputs: skills/orch/scripts/overseer-run
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'overseer_run: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'overseer_run: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer_run: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# One launch through ENTRY: VERDICT is `RC|STDOUT|STDERR KEY`.
VERDICT=""
launch() { # ENTRY INPUT [ARG]...
  local entry="$1" input="$2" rc=0 out
  shift 2
  out="$(printf '%s' "$input" | env ORCH_MODEL_LINES_HELD=1 "$entry" "$@" 2>"$TMP_ROOT/err")" || rc=$?
  VERDICT="$rc|$out|$(sed -n '1s/=.*//p' "$TMP_ROOT/err")"
}

LIVE="$TEST_DIR/../scripts/overseer-run"
launch "$LIVE" '' sh -c 'exit 3'
assert_eq "$VERDICT" '3||' "the command's exit is the launch's"
launch "$LIVE" 'pane input' cat
assert_eq "$VERDICT" '0|pane input|' "the command reads the launch's stdin and writes its stdout"
launch "$LIVE" '' sh -c 'printf %s "${ORCH_MODEL_LINES_HELD-unset}"'
assert_eq "$VERDICT" '0|unset|' "the command starts without the launcher's model-line hold"
launch "$LIVE" ''
assert_eq "$VERDICT" '2||overseer-run: usage' 'a launch line with no command is refused by key'

# Control: an entry that runs something other than the command it was given.
cp -p -- "$LIVE" "$TMP_ROOT/overseer-run"
mutate_file "$TMP_ROOT/overseer-run" 'exec "$@"' 'exec true'
launch "$TMP_ROOT/overseer-run" '' sh -c 'exit 3'
assert_eq "$VERDICT" '0||' 'control: an entry that drops the command answers 0 where the exit row wants 3'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
