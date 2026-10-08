#!/usr/bin/env bash
# Execute the documented Codex round launch and completion poll against the
# production artifact checker. The injected clock reaches a five-minute
# receipt after the caller entered its wait. This proves the shell route and
# caller continuation; it does not prove that a Codex model follows the rule.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'codex_round_wait: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'codex_round_wait: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'codex_round_wait: scratch=resolve-failed' >&2; exit 1; }
caller_pid=""
cleanup() {
  local runner leader
  if [[ -n "$caller_pid" ]]; then kill -TERM "$caller_pid" 2>/dev/null || true; wait "$caller_pid" 2>/dev/null || true; fi
  for runner in "$TMP_ROOT"/*/wait.runner; do
    [[ -f "$runner" ]] || continue
    leader="$(pgrep -f "${runner%.runner} " || true)"
    [[ -z "$leader" || "$leader" == *$'\n'* ]] || "$SKILL_DIR/scripts/lib/job-unit.sh" stop-job "$runner" "$leader" "*${runner%.runner}*" >/dev/null 2>&1 || true
  done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
REAL_SLEEP="$(command -v sleep)"
REAL_DATE="$(command -v date)"
TIMEOUT="$(command -v timeout || command -v gtimeout)" || { echo 'skip: timeout is unavailable'; exit 0; }
command -v setsid >/dev/null || { echo 'skip: setsid is unavailable'; exit 0; }

awk '/^```sh$/ { active=1; blocks++; next } /^```$/ && active { active=0; next } active { print } END { if (blocks != 1 || active) exit 1 }' \
  "$SKILL_DIR/references/waiter-launch.md" > "$TMP_ROOT/launch.sh"
awk '/^## Delegated round wait$/ { section=1; next } /^## / && section { section=0 } section && /^```bash$/ { active=1; blocks++; next } /^```$/ && active { active=0; next } active { print } END { if (blocks != 1 || active) exit 1 }' \
  "$SKILL_DIR/references/codex-runtime.md" > "$TMP_ROOT/command"
# The completion command has one owner. Execute it, rather than reproducing
# the poll in this fixture.
awk 'match($0, /foreground poll `[^`]+`/) { print substr($0, RSTART + 17, RLENGTH - 18); hits++ } END { if (hits != 1) exit 1 }' \
  "$SKILL_DIR/../reviewer/SKILL.md" > "$TMP_ROOT/poll"
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/systemd-run" <<'SH'
#!/bin/sh
exit 1
SH
cat > "$TMP_ROOT/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == +%s ]]; then cat "$ROUND_CASE/clock"; else exec "$REAL_DATE" "$@"; fi
SH
cat > "$TMP_ROOT/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  5)
    : > "$ROUND_CASE/check-waiting"
    while [[ ! -f "$ROUND_CASE/release" ]]; do "$REAL_SLEEP" 0.01; done
    now="$(cat "$ROUND_CASE/clock")"
    now=$((now + 5))
    printf '%s\n' "$now" > "$ROUND_CASE/clock"
    if [[ "$now" -eq 300 && "$ROUND_LANDS" == yes ]]; then
      cp "$ROUND_CASE/receipt" "$ROUND_CASE/tmp/dev-return-issue-3409-round-1.json"
    fi ;;
  30) : > "$ROUND_CASE/caller-waiting"; "$REAL_SLEEP" 0.01 ;;
  *) exec "$REAL_SLEEP" "$@" ;;
esac
SH
chmod +x "$TMP_ROOT/bin/"*
# Only the poll receives these PATHs, so its command lookup cannot find the
# other supported name elsewhere on the host.
for dependency in timeout gtimeout; do
  mkdir "$TMP_ROOT/$dependency-bin"
  ln -s "$(command -v sh)" "$TMP_ROOT/$dependency-bin/sh"
  ln -s "$TMP_ROOT/bin/sleep" "$TMP_ROOT/$dependency-bin/sleep"
  ln -s "$(command -v bash)" "$TMP_ROOT/$dependency-bin/bash"
  ln -s "$TIMEOUT" "$TMP_ROOT/$dependency-bin/$dependency"
done
cp "$TMP_ROOT/poll" "$TMP_ROOT/timeout-only-poll"
mutate_file "$TMP_ROOT/timeout-only-poll" \
  'command -v timeout || command -v gtimeout' 'command -v timeout'
cat > "$TMP_ROOT/caller.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$ROUND_CASE"
command="$(cat "$ROUND_SOURCE/command")"
command="${command//\[RUN_DIR\]/$ROUND_CASE}"
command="${command//\[WORKTREE_PATH\]/$ROUND_CASE}"
command="${command//\[ISSUE_ID\]/issue-3409}"
command="${command//\[DEV_ROUND_ID\]/round-1}"
"$BASH" -c "$command"
poll="$(cat "$ROUND_SOURCE/$ROUND_POLL_SOURCE")"
poll="${poll//\[RUN_DIR\]/$ROUND_CASE}"
PATH="$ROUND_POLL_PATH" "$BASH" -c "$poll"
code="$(cat "$ROUND_CASE/wait.exit")"
[[ "$code" == 0 || "$code" == 1 ]] || exit "$code"
sed '1d' "$ROUND_CASE/wait.log" | jq -r '.verdict' > "$ROUND_CASE/continued"
SH
cp "$TMP_ROOT/caller.sh" "$TMP_ROOT/old-turn-end.sh"
mutate_file "$TMP_ROOT/old-turn-end.sh" \
  'PATH="$ROUND_POLL_PATH" "$BASH" -c "$poll"' 'exit 0
PATH="$ROUND_POLL_PATH" "$BASH" -c "$poll"'

await_file() {
  local i
  for ((i=0; i<2000; i++)); do
    [[ ! -s "$1" && ! -f "$1" ]] || return 0
    "$REAL_SLEEP" 0.01
  done
  printf 'codex_round_wait: marker-timeout path=%s\n' "$1" >&2
  return 1
}

while IFS='|' read -r name caller dependency poll_source lands elapsed verdict continuation expected_rc; do
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/tmp" "$case_dir/.agents/skills"
  ln -s "$SKILL_DIR" "$case_dir/.agents/skills/orch"
  cp "$TMP_ROOT/launch.sh" "$case_dir/launch.sh"
  printf '0\n' > "$case_dir/clock"
  printf '%s\n' '{"schema_version":1,"round_id":"round-1","kind":"implement","issue":"issue-3409","branch":"fixture","commit":"abc123f","baseline_lines":1,"validate":"pass","validate_mode":"full","validate_time":{"started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:05:00Z","seconds":300},"qa_labels":[],"summary_posted":true,"summary":null,"bundled":false,"items":[]}' > "$case_dir/receipt"
  env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$HOME" ROUND_CASE="$case_dir" ROUND_LANDS="$lands" \
    ROUND_SOURCE="$TMP_ROOT" REAL_SLEEP="$REAL_SLEEP" REAL_DATE="$REAL_DATE" \
    ROUND_POLL_PATH="$TMP_ROOT/$dependency-bin" ROUND_POLL_SOURCE="$poll_source" \
    "$BASH" "$TMP_ROOT/$caller.sh" > "$case_dir/caller.log" 2>&1 &
  caller_pid=$!
  await_file "$case_dir/check-waiting"
  if [[ "$caller" == caller && "$expected_rc" == 0 ]]; then
    await_file "$case_dir/caller-waiting"
  else
    caller_rc=0
    wait "$caller_pid" || caller_rc=$?
    assert_eq "$caller_rc" "$expected_rc" "$name: caller exit" "$case_dir/caller.log"
    caller_pid=""
  fi
  : > "$case_dir/release"
  if [[ -n "$caller_pid" ]]; then
    caller_rc=0
    wait "$caller_pid" || caller_rc=$?
    caller_pid=""
    assert_eq "$caller_rc" "$expected_rc" "$name: caller exit" "$case_dir/caller.log"
  fi
  await_file "$case_dir/wait.exit"
  got_continuation=absent
  [[ ! -f "$case_dir/continued" ]] || got_continuation="$(cat "$case_dir/continued")"
  got_verdict="$(sed '1d' "$case_dir/wait.log" | jq -r '.verdict')"
  assert_eq "$(cat "$case_dir/clock")|$got_verdict|$got_continuation" \
    "$elapsed|$verdict|$continuation" "$name" "$case_dir/caller.log"
done <<'ROWS'
delayed-round-same-turn|caller|timeout|poll|yes|300|accept|accept|0
delayed-round-gtimeout-only|caller|gtimeout|poll|yes|300|accept|accept|0
deadline-same-turn|caller|timeout|poll|no|600|wait|wait|0
control-old-turn-end-stalls|old-turn-end|timeout|poll|yes|300|accept|absent|0
control-timeout-only-refuses|caller|gtimeout|timeout-only-poll|yes|300|accept|absent|127
ROWS
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
