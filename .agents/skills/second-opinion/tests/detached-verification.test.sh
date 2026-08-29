#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "$3"; printf 'PASS: %s\n' "$3"; }

mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin" "$TMP_ROOT/work"
git -C "$TMP_ROOT/proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"
cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'answer\n'
SH
chmod +x "$TMP_ROOT/bin/codex"
PATH="$TMP_ROOT/bin:$PATH"
export PATH SECOND_OPINION_CURRENT_MODEL=none

mkdir "$TMP_ROOT/identity-runtime"
CODEX_SANDBOX=1 "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/identity-answer" \
  "$TMP_ROOT/identity-runtime" 10 false 1 3 quick question --target=codex \
  --cwd "$TMP_ROOT/work" --timeout 2 --detached-current-model=claude \
  >"$TMP_ROOT/identity-launch.stdout"
identity_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/identity-launch.stdout")"
bash -c "$identity_wait" >"$TMP_ROOT/identity-wait.stdout" 2>"$TMP_ROOT/identity-wait.stderr"
assert_contains "$TMP_ROOT/identity-answer" "answer" \
  "detached worker preserves the parent-selected target"
assert_contains "$TMP_ROOT/identity-wait.stderr" "target=codex" \
  "detached worker runs the parent's target despite an inherited codex marker"
assert_contains "$TMP_ROOT/identity-wait.stderr" "current=claude" \
  "detached worker trusts the private parent identity"

cat > "$TMP_ROOT/bin/hanging-worker" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
chmod +x "$TMP_ROOT/bin/hanging-worker"
cat > "$TMP_ROOT/startup-env" <<'SH'
set -T
cancel_before_event_reader() {
  case "$BASH_COMMAND" in *'exec 10<'*) kill -TERM "$$" ;; esac
}
trap cancel_before_event_reader DEBUG
SH
mkdir "$TMP_ROOT/startup-runtime"
BASH_ENV="$TMP_ROOT/startup-env" "$RUNTIME" launch "$TMP_ROOT/bin/hanging-worker" \
  "$TMP_ROOT/startup-answer" "$TMP_ROOT/startup-runtime" 10 false 1 3 x \
  >"$TMP_ROOT/startup-launch.stdout"
startup_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/startup-launch.stdout")"
startup_rc=0
bash -c "$startup_wait" >"$TMP_ROOT/startup-wait.stdout" \
  2>"$TMP_ROOT/startup-wait.stderr" || startup_rc=$?
[[ $startup_rc -eq 143 ]] || fail "startup-window cancellation returned $startup_rc"
printf 'PASS: event FIFO guard makes startup-window cancellation terminal\n'

guard_line="$(grep -n 'exec 7<>"$event_fifo"' "$RUNTIME" | cut -d: -f1)"
fork_line="$(grep -n '^  set -m$' "$RUNTIME" | tail -1 | cut -d: -f1)"
[[ -n "$guard_line" && -n "$fork_line" && $guard_line -lt $fork_line ]] \
  || fail "event FIFO guard is not open before the worker fork"
printf 'PASS: event FIFO guard precedes the worker fork\n'

mkdir "$TMP_ROOT/terminal-runtime"
printf 'terminal\n' > "$TMP_ROOT/terminal-runtime/token"
printf 'worker log\n' > "$TMP_ROOT/terminal-runtime/worker.log"
printf 'keep\n' > "$TMP_ROOT/terminal-artifact"
terminal_rc=0
"$RUNTIME" wait "$TMP_ROOT/terminal-artifact" "$TMP_ROOT/terminal-runtime" \
  "$(date +%s)" terminal 1 >"$TMP_ROOT/terminal.stdout" \
  2>"$TMP_ROOT/terminal.stderr" || terminal_rc=$?
[[ $terminal_rc -eq 124 ]] || fail "terminal no-completion wait returned $terminal_rc"
[[ ! -e "$TMP_ROOT/terminal-runtime" ]] || fail "terminal 124 left its runtime directory"
[[ "$(cat < "$TMP_ROOT/terminal-artifact")" == "keep" ]] \
  || fail "terminal 124 disturbed the completed artifact path"
printf 'PASS: terminal 124 removes only the owned runtime directory\n'
