#!/usr/bin/env bash
# Tests for open-terminal's per-item worktree-create handling.
#
# The worktree create is the ownership claim for a fleet launch: exit 75 means
# another session holds the item. Under `set -euo pipefail` an unguarded
# `wt="$(worktree create ...)"` aborted the WHOLE batch on the first owned
# item, so its siblings never launched. An owned item must be skipped (named on
# stderr, counted in the summary) and the remaining items still launch; any
# other create failure is that item's failure alone, not an abort.
#
# `--relaunch` covers the replacement launch: the dead lane already created the
# item's worktree, so a bare create reads it as a claim and skips the item. The
# flag reuses that tree; a lease held under another owner still skips, and a
# tree that was cleaned up takes the bare form.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo
# so `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, and
# stubs the worktree CLI (scripted per-item exit codes, call log), the GUI
# terminal, and gh so nothing external is launched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured lane host would turn these local launches into
# hosted ones; the caller environment outranks project settings.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/process-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="${OPEN_TERMINAL_UNDER_TEST:-$SCRIPTS_DIR/open-terminal}"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
# The fixture sessions this suite started; nothing else is killed.
LIVE_PIDS=""
trap 'kill $LIVE_PIDS 2>/dev/null || :; rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# Shared stub bin: a fake GUI terminal (exit 0 so open_gui's success echo runs)
# and a fake gh (exit 1 so resolve_repo yields empty without touching network).
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
# The capture is renamed into place, so it exists only once whole: a test
# waiting for it never reads the empty file a plain redirect would leave first.
[[ -z "${OT_CAPTURE:-}" ]] || { printf '%s\n' "${!#}" >"$OT_CAPTURE.part" && mv -- "$OT_CAPTURE.part" "$OT_CAPTURE"; }
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${0##*/}" == lanes ]]; then [[ "$*" == "list --harness codex --json" ]] || exit 1; printf '%s\n' "${CODEX_INVENTORY:-[]}"; exit; fi
exit 1
EOF
chmod +x "$BIN/ghostty" "$BIN/gh"
ln -s gh "$BIN/lanes"

# $TERMINAL is what open_gui reaches for first, so it is PINNED to the stub on
# PATH here: unset, the branch below it would resolve whatever terminal the
# developer's desktop provides and this suite would open real windows.
export TERMINAL=ghostty

# The process table every wake row reads. `lane_session_state` walks `ps -A`
# for processes named for the harness and reads each one's /proc cwd, so an
# unstubbed row is answered by whoever else is logged into the box: one
# root-owned claude anywhere on it refuses every claude row as `unjudged`.
# Every launcher that runs the script under test — run_case and woken_under —
# puts these stubs on its PATH, and a new one must too, so a row's table is the
# one staged here whatever the host is running.
#
# The default is an EMPTY table: this box runs no harness at all. What a row
# whose wake goes through actually needs is narrower — no process named for the
# harness whose /proc cwd is the lane's worktree — and an empty table is one way
# to reach it. A row wanting a session in that worktree writes its own table
# before the wake. lib/process-table.sh carries the rest of the rationale.
PROC_BIN="$TMP_ROOT/proc-bin"
proc_table_install "$PROC_BIN"
PROC_TABLE="$TMP_ROOT/proc-table.txt"
PROC_CWD_FILE="$TMP_ROOT/proc-cwd.txt"
PROC_HIDDEN_PIDS=""
export PROC_TABLE PROC_CWD_FILE PROC_HIDDEN_PIDS
proc_table_write "$PROC_TABLE"
proc_cwd_write "$PROC_CWD_FILE"

# Stub worktree CLI:
#   exists <item>          "true" when $STUB_EXISTS_DIR/<item> is present
#   create <item>          logs "<item>", exits per $STUB_EXIT_DIR/<item>
#   create <item> --reuse  logs "<item> --reuse", exits per
#                          $STUB_EXIT_DIR/<item>.reuse
#   path <item>            prints the dir create makes, present or not
# With no exit-code file the call makes and prints a worktree dir (exit 0).
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" != "path" ]] || { printf '%s\n' "$TMP_ROOT/wt/\${2:-unknown}"; exit 0; }
if [[ "\${1:-}" == "exists" ]]; then
  [[ -f "\$STUB_EXISTS_DIR/\${2:-unknown}" ]] && echo "true" || echo "false"
  exit 0
fi
if [[ "\${1:-}" == "create" ]]; then
  item="\${2:-unknown}"
  key="\$item"
  logged="\$item"
  if [[ "\${3:-}" == "--reuse" ]]; then key="\$item.reuse"; logged="\$item --reuse"; fi
  printf '%s\n' "\$logged" >> "\$STUB_CALL_LOG"
  if [[ -f "\$STUB_EXIT_DIR/\$key" ]]; then
    echo "stub: refusing \$item" >&2
    exit "\$(cat "\$STUB_EXIT_DIR/\$key")"
  fi
  d="$TMP_ROOT/wt/\$item"
  mkdir -p "\$d"
  git init -q "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SRC_OT" "$REPO/scripts/open-terminal"
cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$REPO/scripts/"
cp "$SRC_LIB_DIR"/*.sh "$REPO/scripts/lib/"
orch_fixture_shared_libs "$REPO"
chmod +x "$REPO/scripts/open-terminal"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"
CMD_ARGS=(--cmd 'echo {item}')

# run_case <name> -- ITEM...   (stub exit codes pre-seeded in $EXIT_DIR)
run_case() {
  local name="$1"; shift; shift
  CALL_LOG="$TMP_ROOT/$name.calls"
  : > "$CALL_LOG"
  : "${EXISTS_DIR:=$TMP_ROOT/exists-none}"
  mkdir -p "$EXISTS_DIR"
  set +e
  OUT=$(PATH="$BIN:$PROC_BIN:$PATH" WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" STUB_CALL_LOG="$CALL_LOG" STUB_EXIT_DIR="$EXIT_DIR" OT_CAPTURE="${OT_CAPTURE:-}" LANES_HOME="${LANES_HOME:-}" CODEX_HOME="${CODEX_HOME_OVERRIDE:-}" CODEX_INVENTORY="${CODEX_INVENTORY:-}" \
    PI_CODING_AGENT_DIR="${PI_AGENT_DIR:-}" PI_CODING_AGENT_SESSION_DIR="${PI_SESSION_DIR:-}" \
    STUB_EXISTS_DIR="$EXISTS_DIR" \
    "$OT" --ghostty ${CMD_ARGS[@]+"${CMD_ARGS[@]}"} "$@" 2>"$TMP_ROOT/$name.err")
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/$name.err")"
}

echo "=== open-terminal: owned item is skipped, siblings launch ==="

# Case 1: one of three items is owned elsewhere (create exit 75).
EXIT_DIR="$TMP_ROOT/exit1"; mkdir -p "$EXIT_DIR"
printf '75' > "$EXIT_DIR/CC-2"
run_case c1 -- CC-1 CC-2 CC-3
assert_eq "$RC" "0" "exit 0 when siblings launched around an owned item"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 CC-2 CC-3 " "create attempted for every item (no abort at the owned one)"
assert_contains "$OUT" "open-terminal: terminal-opened item=CC-1" "item before the owned one launches"
assert_contains "$OUT" "open-terminal: terminal-opened item=CC-3" "item after the owned one launches"
assert_not_contains "$OUT" "open-terminal: terminal-opened item=CC-2" "owned item is not launched"
assert_contains "$ERR" "open-terminal: item-owned item=CC-2 exit=75" "owned item named on stderr"
assert_contains "$OUT" "open-terminal: summary launched=2 skipped=1 failed=0 lanes=0" "summary reports launched=2 skipped=1"

# Case 2: every item owned elsewhere -> nothing launched, exit 75.
EXIT_DIR="$TMP_ROOT/exit2"; mkdir -p "$EXIT_DIR"
printf '75' > "$EXIT_DIR/CC-1"; printf '75' > "$EXIT_DIR/CC-2"
run_case c2 -- CC-1 CC-2
assert_eq "$RC" "75" "exit 75 when every item is owned by another session"
assert_not_contains "$OUT" "open-terminal: terminal-opened" "nothing launched when every item is owned"
assert_contains "$ERR" "open-terminal: summary launched=0 skipped=2 failed=0 lanes=0" "all-skipped summary names the counts"

# Case 3: a non-75 create failure is that item's failure; siblings still launch.
EXIT_DIR="$TMP_ROOT/exit3"; mkdir -p "$EXIT_DIR"
printf '1' > "$EXIT_DIR/CC-2"
run_case c3 -- CC-1 CC-2 CC-3
assert_eq "$RC" "1" "exit 1 when one create fails for a non-ownership reason"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 CC-2 CC-3 " "create attempted for every item (no abort at the failed one)"
assert_contains "$OUT" "open-terminal: terminal-opened item=CC-3" "item after the failed one still launches"
assert_contains "$ERR" "open-terminal: worktree-failed item=CC-2 exit=1" "create failure names the item and exit code"
assert_contains "$ERR" "open-terminal: summary launched=2 skipped=0 failed=1 lanes=0" "summary reports failed=1 launched=2"
assert_not_contains "$ERR" "open-terminal: item-owned item=CC-2" "a non-75 create failure is not reported as skipped"

# Case 4: without --relaunch, an item whose worktree already exists is refused
# by bare create — this is the state a dead lane leaves behind.
EXIT_DIR="$TMP_ROOT/exit4"; mkdir -p "$EXIT_DIR"
EXISTS_DIR="$TMP_ROOT/exists4"; mkdir -p "$EXISTS_DIR"
printf '75' > "$EXIT_DIR/CC-1"; touch "$EXISTS_DIR/CC-1"
run_case c4 -- CC-1
assert_eq "$RC" "75" "an existing worktree is exit 75 to a bare launch"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 " "a bare launch never asks for reuse"

# Case 5: --relaunch reuses the item's own worktree, so the replacement
# session launches instead of being skipped as owned.
EXIT_DIR="$TMP_ROOT/exit5"; mkdir -p "$EXIT_DIR"
EXISTS_DIR="$TMP_ROOT/exists5"; mkdir -p "$EXISTS_DIR"
printf '75' > "$EXIT_DIR/CC-1"; touch "$EXISTS_DIR/CC-1"
run_case c5 -- --relaunch CC-1
assert_eq "$RC" "0" "--relaunch launches into the existing worktree"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 --reuse " "--relaunch creates with --reuse, and never retries bare"
assert_contains "$OUT" "open-terminal: terminal-opened item=CC-1" "the replacement session is launched"
assert_not_contains "$ERR" "open-terminal: item-owned item=CC-1" "a relaunched item is not skipped as owned"

# Case 6: --relaunch on a worktree held under another owner's lease — create
# --reuse still exits 75 — stays a skip.
EXIT_DIR="$TMP_ROOT/exit6"; mkdir -p "$EXIT_DIR"
EXISTS_DIR="$TMP_ROOT/exists6"; mkdir -p "$EXISTS_DIR"
printf '75' > "$EXIT_DIR/CC-1.reuse"; touch "$EXISTS_DIR/CC-1"
run_case c6 -- --relaunch CC-1
assert_eq "$RC" "75" "a live foreign lease is still a skip under --relaunch"
assert_not_contains "$OUT" "open-terminal: terminal-opened" "nothing launches into another owner's worktree"
assert_contains "$ERR" "open-terminal: item-owned item=CC-1 exit=75" "the foreign-lease skip is named on stderr"

# Case 7: --relaunch after the worktree was cleaned up falls back to bare
# create — `create --reuse` requires an existing tree.
EXIT_DIR="$TMP_ROOT/exit7"; mkdir -p "$EXIT_DIR"
EXISTS_DIR="$TMP_ROOT/exists7"; mkdir -p "$EXISTS_DIR"
run_case c7 -- --relaunch CC-1
assert_eq "$RC" "0" "--relaunch with no existing worktree launches"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 " "a missing worktree takes the bare create form"

# Relaunch resumes the newest transcript whose harness kickoff names the item.
# The claude transcript records the item lower case while the launch names the
# canonical upper-case one: a session launched before the canonical brief holds
# whichever case its project's pattern was written in, and a scan that read the
# id case-sensitively would resume nothing and start a second session on the
# lane's worktree.
SESSION_HOME="$TMP_ROOT/session-home"; CLAUDE222=22222222-2222-2222-2222-222222222222; CODEX444=44444444-4444-4444-4444-444444444444; mkdir -p "$SESSION_HOME/.claude-shared/projects/repo" "$SESSION_HOME/.selected-codex/sessions/2026" "$SESSION_HOME/.pi/agent/sessions/repo"
printf '%s\n' '{"type":"user","message":{"content":"start cc-1"}}' >"$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"
cp "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl" "$SESSION_HOME/.claude-shared/projects/repo/11111111-1111-1111-1111-111111111111.jsonl"; touch -t 200001010000 "$SESSION_HOME/.claude-shared/projects/repo/11111111-1111-1111-1111-111111111111.jsonl"
mkdir -p "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222/subagents"
printf '%s\n' '{"type":"user","message":{"content":"start cc-1"}}' >"$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222/subagents/child-agent.jsonl"; touch -t 203001010000 "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222/subagents/child-agent.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$CODEX444\"}}" '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"repository instructions"}]}}' '{"type":"event_msg","payload":{"type":"user_message","message":"start CC-1"}}' >"$SESSION_HOME/.selected-codex/sessions/2026/session.jsonl"
printf '%s\n' '{"type":"message","message":{"role":"user","content":"start CC-1"}}' >"$SESSION_HOME/.pi/agent/sessions/repo/session.jsonl"
EXIT_DIR="$TMP_ROOT/resume-exit"; EXISTS_DIR="$TMP_ROOT/resume-exists"; mkdir -p "$EXIT_DIR" "$EXISTS_DIR"; touch "$EXISTS_DIR/CC-1"
CMD_ARGS=()
for row in "claude|claude -n CC-1 --resume $CLAUDE222" "codex|codex resume $CODEX444" "pi|pi --session $SESSION_HOME/.pi/agent/sessions/repo/session.jsonl"; do
  IFS='|' read -r harness expected <<<"$row"
  capture="$TMP_ROOT/resume-$harness.cmd"
  OT_CAPTURE="$capture" LANES_HOME="$SESSION_HOME" CODEX_HOME_OVERRIDE="$SESSION_HOME/.selected-codex" run_case "resume-$harness" -- --relaunch --harness "$harness" CC-1
  for _ in {1..10000}; do [[ -f "$capture" ]] && break; done; assert_contains "$(cat "$capture")" "$expected" "$harness relaunch uses its native resume command"
done
OT_CAPTURE="$TMP_ROOT/fresh.cmd" LANES_HOME="$SESSION_HOME" run_case fresh -- --relaunch --harness codex CC-9
for _ in {1..10000}; do [[ -f "$TMP_ROOT/fresh.cmd" ]] && break; done; assert_contains "$(cat "$TMP_ROOT/fresh.cmd")" "execute the orch start workflow for CC-9" "a relaunch with no matching session uses the fresh brief"

OLD_CODEX="$SESSION_HOME/.old-codex"; CROSS_CODEX=55555555-5555-5555-5555-555555555555; mkdir -p "$OLD_CODEX/sessions/2026"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$CROSS_CODEX\"}}" '{"type":"event_msg","payload":{"type":"user_message","message":"start CC-2"}}' >"$OLD_CODEX/sessions/2026/cross.jsonl"
CODEX_INVENTORY="$(jq -nc --arg d "$OLD_CODEX" '[{config_dir:$d}]')"; OT_CAPTURE="$TMP_ROOT/resume-codex-cross.cmd" LANES_HOME="$SESSION_HOME" CODEX_HOME_OVERRIDE="$SESSION_HOME/.selected-codex" run_case resume-codex-cross -- --relaunch --harness codex CC-2
for _ in {1..10000}; do [[ -f "$TMP_ROOT/resume-codex-cross.cmd" ]] && break; done; assert_contains "$(cat "$TMP_ROOT/resume-codex-cross.cmd")" "codex resume $CROSS_CODEX" "codex relaunch finds a session in another account store"
assert_eq "$(cat "$SESSION_HOME/.selected-codex/sessions/2026/cross.jsonl")" "$(cat "$OLD_CODEX/sessions/2026/cross.jsonl")" "the destination account can read the discovered transcript"

PI_ABSOLUTE="$TMP_ROOT/pi-absolute"; mkdir -p "$PI_ABSOLUTE" "$SESSION_HOME/.pi/agent"
printf '%s\n' '{"type":"message","message":{"role":"user","content":"start CC-3"}}' >"$PI_ABSOLUTE/session.jsonl"
printf '{"sessionDir":"%s"}\n' "$PI_ABSOLUTE" >"$SESSION_HOME/.pi/agent/settings.json"
OT_CAPTURE="$TMP_ROOT/resume-pi-absolute.cmd" LANES_HOME="$SESSION_HOME" run_case resume-pi-absolute -- --relaunch --harness pi CC-3
for _ in {1..10000}; do [[ -f "$TMP_ROOT/resume-pi-absolute.cmd" ]] && break; done; assert_contains "$(cat "$TMP_ROOT/resume-pi-absolute.cmd")" "pi --session $PI_ABSOLUTE/session.jsonl" "pi relaunch reads an absolute sessionDir from global settings"

PI_WORKTREE="$TMP_ROOT/wt/CC-4"; PI_RELATIVE="$PI_WORKTREE/pi-sessions"; mkdir -p "$PI_WORKTREE/.pi" "$PI_RELATIVE"
printf '%s\n' '{"type":"message","message":{"role":"user","content":"start CC-4"}}' >"$PI_RELATIVE/session.jsonl"
printf '%s\n' '{"sessionDir":"pi-sessions"}' >"$PI_WORKTREE/.pi/settings.json"
jq -nc --arg p "$(cd "$PI_WORKTREE" && pwd -P)" '{($p):true}' >"$SESSION_HOME/.pi/agent/trust.json"
OT_CAPTURE="$TMP_ROOT/resume-pi-relative.cmd" LANES_HOME="$SESSION_HOME" run_case resume-pi-relative -- --relaunch --harness pi CC-4
for _ in {1..10000}; do [[ -f "$TMP_ROOT/resume-pi-relative.cmd" ]] && break; done; assert_contains "$(cat "$TMP_ROOT/resume-pi-relative.cmd")" "pi --session $PI_RELATIVE/session.jsonl" "pi relaunch resolves a project sessionDir from the launched worktree"

PI_UNTRUSTED="$TMP_ROOT/wt/CC-5"; mkdir -p "$PI_UNTRUSTED/.pi" "$PI_UNTRUSTED/pi-sessions"
printf '%s\n' '{"type":"message","message":{"role":"user","content":"start CC-5"}}' >"$PI_UNTRUSTED/pi-sessions/session.jsonl"
printf '%s\n' '{"sessionDir":"pi-sessions"}' >"$PI_UNTRUSTED/.pi/settings.json"
OT_CAPTURE="$TMP_ROOT/resume-pi-untrusted.cmd" LANES_HOME="$SESSION_HOME" run_case resume-pi-untrusted -- --relaunch --harness pi CC-5
for _ in {1..10000}; do [[ -f "$TMP_ROOT/resume-pi-untrusted.cmd" ]] && break; done; assert_contains "$(cat "$TMP_ROOT/resume-pi-untrusted.cmd")" "pi '/skill:orch start CC-5'" "pi relaunch ignores an untrusted project sessionDir"

# --wake hands the lane's own session the line that reads its inbox, through
# the harness's native resume, from a detached command.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >"$OT_CAPTURE.part" && mv -- "$OT_CAPTURE.part" "$OT_CAPTURE"
exit "${WAKE_STUB_RC:-0}"
EOF
chmod +x "$BIN/claude"; ln -s claude "$BIN/codex"; ln -s claude "$BIN/pi-bridge"
WAKE_LINE="Run .agents/skills/orch/scripts/lane-mail inbox --item CC-1 and act on every directive it prints."
for row in "claude|claude -n CC-1 --resume $CLAUDE222 -p $WAKE_LINE" "codex|codex exec resume $CODEX444 $WAKE_LINE" "pi|pi-bridge send --cwd $TMP_ROOT/wt/CC-1 $WAKE_LINE"; do
  IFS='|' read -r harness expected <<<"$row"
  capture="$TMP_ROOT/wake-$harness.cmd"
  OT_CAPTURE="$capture" LANES_HOME="$SESSION_HOME" CODEX_HOME_OVERRIDE="$SESSION_HOME/.selected-codex" run_case "wake-$harness" -- --wake --harness "$harness" CC-1
  assert_contains "$OUT" "open-terminal: lane-woken item=CC-1 harness=$harness log=$TMP_ROOT/wt/CC-1/tmp/lane-wake-CC-1.log" "$harness wake names its log"
  assert_eq "$(cat "$capture" 2>/dev/null)" "$expected" "$harness wake delivers the inbox line through its native resume"
done
OT_CAPTURE="$TMP_ROOT/wake-failed.cmd" WAKE_STUB_RC=3 run_case wake-failed -- --wake --harness pi CC-1
assert_eq "$RC" "1" "a wake whose delivery exits non-zero exits 1"
assert_contains "$ERR" "open-terminal: wake-failed item=CC-1 harness=pi exit=3 log=$TMP_ROOT/wt/CC-1/tmp/lane-wake-CC-1.log" "a failed delivery is refused as wake-failed"
assert_not_contains "$OUT" "open-terminal: lane-woken" "a failed delivery is not reported woken"
# A wake resumes an existing session through open_wake, which reads no
# verification timeout: tmux_wait_launched, tmux_wait_composer,
# tmux_wait_remote_prompt and lane_account_ok are reached only from open_tmux.
# So a malformed ORCH_TMUX_VERIFY_SECS must not abort one, in the shape
# oversee.md hands a wake: from inside tmux, with the lane argument kept.
WAKE_LANE_BIN="$TMP_ROOT/wake-lane-bin"; mkdir -p "$WAKE_LANE_BIN"
cat > "$WAKE_LANE_BIN/lanes" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  check) exit 0 ;;
  list) printf '[{"config_dir":"%s"}]\n' "$SESSION_HOME/.selected-codex" ;;
esac
exit 0
EOF
chmod +x "$WAKE_LANE_BIN/lanes"
WAKE_LANE_DIR="$TMP_ROOT/.wakecodex"; mkdir -p "$WAKE_LANE_DIR"

# woken_under SCRIPT NAME — one codex wake through SCRIPT from inside tmux, with
# a lane and a malformed timeout. Prints `rc=<rc> woken=<n> aborted=<n>`.
woken_under() {
  local script="$1" name="$2" out rc=0
  set +e
  out=$(PATH="$BIN:$PROC_BIN:$PATH" WORKTREE_CLI="$STUB" LANES_CLI="$WAKE_LANE_BIN/lanes" \
    STUB_CALL_LOG="$TMP_ROOT/$name.calls" STUB_EXIT_DIR="$TMP_ROOT/exit-none" \
    STUB_EXISTS_DIR="$TMP_ROOT/exists-none" OT_CAPTURE="$TMP_ROOT/$name.cmd" \
    LANES_HOME="$SESSION_HOME" CODEX_HOME="$SESSION_HOME/.selected-codex" \
    TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=abc \
    "$script" --wake --harness codex --lane "$WAKE_LANE_DIR" CC-1 2>&1)
  rc=$?
  set -e
  printf 'rc=%s woken=%s aborted=%s' "$rc" \
    "$(grep -c '^open-terminal: lane-woken item=CC-1 harness=codex ' <<<"$out" || true)" \
    "$(grep -c '^open-terminal: verify-seconds-invalid ' <<<"$out" || true)"
}
mkdir -p "$TMP_ROOT/exit-none"
assert_eq "$(woken_under "$OT" wake-timeout)" "rc=0 woken=1 aborted=0" \
  "a codex wake with a lane resumes under a malformed timeout it never reads"

# The mutant: the wake exclusion gone, so the gate refuses a setting the wake
# reaches no reader of. A whole copy of the fixture repo, because the script
# resolves its libs beside itself and a lone file finds none.
WAKE_MUTANT_REPO="$TMP_ROOT/wake-mutant-repo"
cp -a "$REPO" "$WAKE_MUTANT_REPO"
WAKE_MUTANT="$WAKE_MUTANT_REPO/scripts/open-terminal"
sed -i.bak 's/if \[\[ "$TERMINAL_MODE" == "tmux" && "$WAKE" != true \]\]; then/if [[ "$TERMINAL_MODE" == "tmux" ]]; then/' "$WAKE_MUTANT"
assert_eq "$(cmp -s "$OT" "$WAKE_MUTANT" && echo same || echo changed)" "changed" \
  "control: the wake-validated mutant really rewrites the timeout gate"
assert_eq "$(woken_under "$WAKE_MUTANT" wake-timeout-mutant)" "rc=1 woken=0 aborted=1" \
  "control: without the wake exclusion a malformed timeout aborts a resume that never reads it"

# A wake with no session, no worktree, or a fresh-start option is refused and starts nothing.
for row in "session-missing item=CC-9 harness=claude|--harness claude CC-9" "directory-missing item=CC-8|--harness codex CC-8" "wake-invalid option=--wake harness=codex relaunch=true|--relaunch --harness codex CC-1"; do
  IFS='|' read -r key rest <<<"$row"
  read -r -a wake_argv <<<"$rest"
  OT_CAPTURE="$TMP_ROOT/wake-refused.cmd" LANES_HOME="$SESSION_HOME" run_case wake-refused -- --wake "${wake_argv[@]}"
  assert_eq "$RC" "1" "wake refusal exits 1: ${key%% *}"
  assert_contains "$ERR" "open-terminal: $key" "wake refusal names its key: ${key%% *}"
  assert_eq "$(cat "$TMP_ROOT/wake-refused.cmd" 2>/dev/null)" "" "wake refusal starts no session: ${key%% *}"
done

# Every WAKE row below reads the fixture table through lib/process-table.sh,
# which says what that pair covers and what a row must still arrange for
# itself. So no wake row runs the real reader, and the one guard row here does
# nothing else: it runs it deliberately, with PROC_BIN off the PATH.
#
# That reader is a `ps -A` piped through an awk that moves the command name
# into a field of its own and strips the executable path macOS puts in `comm`,
# and a matcher that compares the harness name against the third field it
# prints. Let either transform regress and no name matches, the pid loop never
# runs, lane_session_state prints idle, the pane's idle rung stands and the
# wake resumes beside a live session: the fail-open this branch closes, with
# every wake row still green.
#
# The row reads the two lines out of the script under test rather than spelling
# them again, so a change to either moves it. Only the two transforms are
# pinned, not the awk's every detail: the substr offset that trims ps's column
# padding has no consumer, since the matcher and the parent-tree scan below it
# both re-split on whitespace, and a row asserting it would be pinning a
# spelling rather than a guarantee. The path strip is pinned by a wake row
# instead, the macOS one in the table below, which asserts what the wake does
# rather than a count.
REAL_TABLE_READ="$(sed -n 's/^  table="\$(\(.*\))".*$/\1/p' "$SRC_OT")"
REAL_PID_MATCH="$(sed -n 's/^  pids="\$(\(.*\))".*$/\1/p' "$SRC_OT")"
assert_eq "table=$(grep -c . <<<"$REAL_TABLE_READ") match=$(grep -c . <<<"$REAL_PID_MATCH")" \
  "table=1 match=1" "the real reader and its matcher are each one line of the script under test"

# The first runs both against THIS box, with PROC_BIN off the PATH, and asks
# for the pid of the shell running this suite under its own command name. It
# claims nothing about anyone else's processes.
SUITE_PID=$$
real_rc=0
real_found="$(
  HARNESS="${BASH##*/}"
  table="$(eval "$REAL_TABLE_READ")" || exit 3
  pids="$(eval "$REAL_PID_MATCH")" || exit 4
  grep -cx -- "$SUITE_PID" <<<"$pids" || true
)" || real_rc=$?
assert_eq "rc=$real_rc found=$real_found" "rc=0 found=1" \
  "the real reader run on this box finds the shell running this suite by its command name"

# A Claude or Codex session still working in the lane worktree is not resumed
# beside itself. What the wake reads to find one is this machine's process
# table, and every row below states its own table through lib/process-table.sh
# instead of leaving the answer to whatever else the box is running.
WT_CC1="$TMP_ROOT/wt/CC-1"; mkdir -p "$WT_CC1"
# The claude arm reads CLAUDE_CONFIG_DIR out of the session's own environment
# and falls back to $HOME/.claude when it cannot. A row meaning `not idle` has
# to land that fallback somewhere this fixture owns: the developer's real home
# holds session files named for live pids, and a collision there would decide
# the row.
WAKE_HOME="$TMP_ROOT/wake-home"; mkdir -p "$WAKE_HOME/.claude/sessions"
LIVE_RESUME_claude="claude -n CC-1 --resume $CLAUDE222 -p $WAKE_LINE"
LIVE_RESUME_codex="codex exec resume $CODEX444 $WAKE_LINE"

# table_wake HARNESS [SCRIPT] — a HARNESS wake on CC-1 through SCRIPT, over the
# table the caller staged. Nothing is started and nothing is waited for, so the
# row's precondition holds at the instant the wake reads it.
table_wake() {
  local saved="$OT"
  rm -f -- "${TMP_ROOT:?}/live-wake.cmd"
  OT="${2:-$OT}"
  HOME="$WAKE_HOME" \
    OT_CAPTURE="$TMP_ROOT/live-wake.cmd" LANES_HOME="$SESSION_HOME" \
    CODEX_HOME_OVERRIDE="$SESSION_HOME/.selected-codex" \
    run_case live-wake -- --wake --harness "$1" CC-1
  OT="$saved"
}

# The fake pids the rows below put in the worktree. None of them needs to exist:
# `readlink` answers their cwd off PROC_CWD_FILE, and that is the whole of the
# CWD read. It is not the whole of the reading — a claude pid that reaches the
# idle branch is also read for its environment and for the session file named
# after it — which is what WAKE_HOME above stands under.
#
# Two claude pids, because the producer has two separate arms that answer
# `busy`, and a row answered by both pins neither. CLAUDE_IDLE_PID's session
# file reads idle, so only the shell child under it can say the turn is live;
# CLAUDE_PID has no shell child, so only its session file can.
#
# MACOS_PID is the same fixture seen the way macOS `ps` reports it, its comm the
# whole executable path behind padded pid columns. No Linux process shows that
# shape, and the row is what pins the strip that removes it.
CLAUDE_IDLE_PID=9101; CLAUDE_IDLE_SHELL=9102; CLAUDE_PID=9103; MACOS_PID=9105
CODEX_PID=9201; CODEX_SHELL=9202
printf '{"status":"idle"}\n' >"$WAKE_HOME/.claude/sessions/$CLAUDE_IDLE_PID.json"
printf '{"status":"busy"}\n' >"$WAKE_HOME/.claude/sessions/$CLAUDE_PID.json"

# NAME|TABLE ROWS, comma-separated|THE WAKE'S ANSWER
#
# The refusal names the state the shared judge read, so a harness process in the
# worktree is `working` where the /proc read alone called it `busy`. With no
# pane on this tmux server carrying the item's window name, the process table is
# the whole of the reading here, exactly as it was before the judge existed.
while IFS='|' read -r label rows want; do
  [[ -n "$label" ]] || continue
  IFS=',' read -r -a table_rows <<<"$rows"
  proc_table_write "$PROC_TABLE" ${table_rows[@]+"${table_rows[@]}"}
  proc_cwd_write "$PROC_CWD_FILE" "$CLAUDE_IDLE_PID=$WT_CC1" "$CLAUDE_PID=$WT_CC1" \
    "$MACOS_PID=$WT_CC1" "$CODEX_PID=$WT_CC1"
  proc_table_readable || want=unjudged
  table_wake "${label%% *}"
  assert_eq "RC=$RC resumed=$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "RC=1 resumed=" \
    "a wake beside $label exits 1 and resumes nothing"
  assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=$want" \
    "a wake beside $label is refused as $want"
done <<ROWS
claude with a shell under an idle session file|$CLAUDE_IDLE_PID 1 claude,$CLAUDE_IDLE_SHELL $CLAUDE_IDLE_PID bash|working
claude whose session file does not read idle|$CLAUDE_PID 1 claude|working
claude whose comm is a whole path behind padded columns|  $MACOS_PID     1 /Applications/Claude.app/Contents/MacOS/claude|working
codex with a shell under it|$CODEX_PID 1 codex,$CODEX_SHELL $CODEX_PID bash|working
codex with no shell under it|$CODEX_PID 1 codex|unjudged
ROWS

# The inverse of those rows: a box running no harness in the worktree at all,
# where the wake goes through. The empty table is that precondition, stated.
proc_table_write "$PROC_TABLE"
proc_cwd_write "$PROC_CWD_FILE"
table_wake codex
assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_codex" \
  "a codex wake with no codex process in the worktree resumes it"

# The one row that still needs a REAL process. `/proc/<pid>/environ` is where
# the wake finds the session's CLAUDE_CONFIG_DIR, and no table stands in for it,
# so the idle answer this row asserts is the only one that exercises that read.
# The fixture session is a copy of bash named claude, running in the worktree.
LIVE_BIN="$TMP_ROOT/live-bin"; mkdir -p "$LIVE_BIN"; cp "$BASH" "$LIVE_BIN/claude"
LIVE_CONFIG="$TMP_ROOT/live-config"; mkfifo "$TMP_ROOT/never"
cat >"$TMP_ROOT/live-session.sh" <<'EOF'
printf '{"status":"idle"}\n' >"$CLAUDE_CONFIG_DIR/sessions/$$.json"
: >"$1"
read -r _ <"$2"
EOF
# live_claude_wake [SCRIPT] — the wake beside that session. Its pid comes from
# the shell that started it, so the table is exact the moment the process
# exists; the two assertions are the row's precondition, and they name the
# fixture rather than letting a process that never started read as a verdict.
live_claude_wake() {
  local ready="$TMP_ROOT/live-ready" pid n=0
  rm -rf -- "${LIVE_CONFIG:?}" "${ready:?}"; mkdir -p "$LIVE_CONFIG/sessions"
  (cd "$WT_CC1" && export CLAUDE_CONFIG_DIR="$LIVE_CONFIG" && exec "$LIVE_BIN/claude" "$TMP_ROOT/live-session.sh" "$ready" "$TMP_ROOT/never") &
  pid=$!
  LIVE_PIDS="$pid"
  while [[ ! -e "$ready" && "$n" -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done
  assert_eq "$([[ -s "$LIVE_CONFIG/sessions/$pid.json" ]] && echo wrote || echo missing)" "wrote" \
    "fixture: the live claude session wrote its status file before the wake"
  if proc_table_readable; then
    assert_eq "$(readlink -- "/proc/$pid/cwd" 2>/dev/null)" "$WT_CC1" \
      "fixture: the live claude session runs in the lane worktree"
  fi
  proc_table_write "$PROC_TABLE" "$pid 1 claude"
  proc_cwd_write "$PROC_CWD_FILE"
  table_wake claude "${1:-}"
  kill $LIVE_PIDS 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  LIVE_PIDS=""
}
live_claude_wake
if proc_table_readable; then
  assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_claude" \
    "a wake beside an idle claude session resumes it"
else
  assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=unjudged" \
    "with no /proc that same session is unjudged"
fi

# The rows the pane alone gets wrong. WORKING_RE draws a second or two into a
# turn, so the first moments of one are an input marker with nothing above it —
# byte for byte a finished turn. Read off the pane that is `idle`, and a wake
# acting on `idle` starts a second session on a worktree mid-turn. The harness
# process is what tells them apart, and anything but a process read that says
# idle answers ahead of the pane's idle rung.
WAKE_PANE_BIN="$TMP_ROOT/wake-pane-bin"; mkdir -p "$WAKE_PANE_BIN"
cat >"$WAKE_PANE_BIN/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  list-panes) printf 'CC-1\t%%9\t4242\t%s\n' "\$(cat "$TMP_ROOT/wake-pane.cmd")"; exit 0 ;;
  capture-pane) cat "$TMP_ROOT/wake-pane.txt"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$WAKE_PANE_BIN/tmux"

# HARNESS|TABLE ROWS, comma-separated|COMPOSER LINE|REFUSAL|WHAT THE PROCESS READ SAYS
#
# Both rows put a lane's own idle-looking screen on the tmux server the wake
# reads. The claude row's process has a shell under it, a turn already under
# way. The codex row's has none, which is all a live codex session ever shows,
# since codex publishes no idle signal — and `unjudged` must never buy a resume.
while IFS='|' read -r wharness wrows wcomposer wreason wlabel; do
  [[ -n "$wharness" ]] || continue
  printf '%s\n' "$wharness" >"$TMP_ROOT/wake-pane.cmd"
  printf '%s\n%s\n' '⏺ Done: the PR is merged.' "$wcomposer" >"$TMP_ROOT/wake-pane.txt"
  IFS=',' read -r -a table_rows <<<"$wrows"
  proc_table_write "$PROC_TABLE" ${table_rows[@]+"${table_rows[@]}"}
  proc_cwd_write "$PROC_CWD_FILE" "$CLAUDE_IDLE_PID=$WT_CC1" "$CLAUDE_PID=$WT_CC1" "$CODEX_PID=$WT_CC1"
  proc_table_readable || wreason=unjudged
  PATH="$WAKE_PANE_BIN:$PATH" table_wake "$wharness"
  assert_eq "RC=$RC resumed=$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "RC=1 resumed=" \
    "a $wharness wake over an idle-looking pane whose process read says $wlabel resumes nothing"
  assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=$wreason" \
    "that pane is refused as $wreason, not taken for the idle it looks like"
done <<ROWS
claude|$CLAUDE_IDLE_PID 1 claude,$CLAUDE_IDLE_SHELL $CLAUDE_IDLE_PID bash|$(printf '\xe2\x9d\xaf\xc2\xa0')|working|a live turn under an idle session file
codex|$CODEX_PID 1 codex|$(printf '\xe2\x80\xba')|unjudged|nothing it could tell
ROWS

# The mutant: the refusal gone, the session state still read.
BUSY_MUTANT_REPO="$TMP_ROOT/busy-mutant-repo"
cp -a "$REPO" "$BUSY_MUTANT_REPO"
BUSY_MUTANT="$BUSY_MUTANT_REPO/scripts/open-terminal"
sed -i.bak 's/\[\[ "$wake_state" == idle \]\] ||/true ||/' "$BUSY_MUTANT"
assert_eq "$(cmp -s "$OT" "$BUSY_MUTANT" && echo same || echo changed)" "changed" "control: the busy mutant really drops the refusal"
proc_table_write "$PROC_TABLE" "$CLAUDE_IDLE_PID 1 claude" "$CLAUDE_IDLE_SHELL $CLAUDE_IDLE_PID bash"
proc_cwd_write "$PROC_CWD_FILE" "$CLAUDE_IDLE_PID=$WT_CC1"
table_wake claude "$BUSY_MUTANT"
assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_claude" \
  "control: without the refusal a wake resumes beside a working session"
# The mutant: a codex session with no shell under it read as idle again. With
# no /proc the wake is unjudged before any session is read, so the control has
# nothing to turn.
if proc_table_readable; then
  CODEX_IDLE_MUTANT_REPO="$TMP_ROOT/codex-idle-mutant-repo"
  cp -a "$REPO" "$CODEX_IDLE_MUTANT_REPO"
  CODEX_IDLE_MUTANT="$CODEX_IDLE_MUTANT_REPO/scripts/open-terminal"
  sed -i.bak 's/^    \[\[ "$HARNESS" == claude \]\] || { printf unjudged; return 0; }$/    [[ "$HARNESS" == claude ]] || continue/' "$CODEX_IDLE_MUTANT"
  assert_eq "$(cmp -s "$OT" "$CODEX_IDLE_MUTANT" && echo same || echo changed)" "changed" \
    "control: the codex-idle mutant really reads a shell-less codex session as idle"
  proc_table_write "$PROC_TABLE" "$CODEX_PID 1 codex"
  proc_cwd_write "$PROC_CWD_FILE" "$CODEX_PID=$WT_CC1"
  table_wake codex "$CODEX_IDLE_MUTANT"
  assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_codex" \
    "control: without the codex arm a wake resumes beside a live codex session"
fi
# A live session whose cwd cannot be read is unjudged, never idle. The pid here
# is this test shell's own, the one pid the row can be sure /proc still holds:
# the producer refuses only a process that has NOT exited, and a fake pid would
# be walked past as a session that is over.
proc_table_write "$PROC_TABLE" "$$ 1 claude"
proc_cwd_write "$PROC_CWD_FILE"
PROC_HIDDEN_PIDS="$$"
table_wake claude
assert_eq "RC=$RC resumed=$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "RC=1 resumed=" \
  "a wake beside a session whose cwd cannot be read exits 1 and resumes nothing"
assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=unjudged" \
  "a wake beside a session whose cwd cannot be read is refused as unjudged"
# The mutant: a failed cwd read skips the process again. With no /proc the
# wake is unjudged before any cwd is read, so the control has nothing to turn.
if proc_table_readable; then
  UNREAD_MUTANT_REPO="$TMP_ROOT/unread-mutant-repo"
  cp -a "$REPO" "$UNREAD_MUTANT_REPO"
  UNREAD_MUTANT="$UNREAD_MUTANT_REPO/scripts/open-terminal"
  sed -i.bak 's/^      printf unjudged; return 0$/      continue/' "$UNREAD_MUTANT"
  assert_eq "$(cmp -s "$OT" "$UNREAD_MUTANT" && echo same || echo changed)" "changed" \
    "control: the unread-cwd mutant really skips the process"
  table_wake claude "$UNREAD_MUTANT"
  assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_claude" \
    "control: without the unjudged arm a wake resumes beside a session it never read"
fi
PROC_HIDDEN_PIDS=""

if [[ "${OPEN_TERMINAL_SKIP_CONTROL:-}" != 1 ]]; then
  CLAUDE_MUTANT="$TMP_ROOT/open-terminal-claude-recursive"
  cp "$SRC_OT" "$CLAUDE_MUTANT"
  assert_eq "$(grep -cF 'find -H "$root" -mindepth 2 -maxdepth 2 -type f' "$CLAUDE_MUTANT")" "1" "control finds the Claude lead-only scan"
  sed -i.bak 's/find -H "$root" -mindepth 2 -maxdepth 2 -type f/find -H "$root" -type f/' "$CLAUDE_MUTANT"
  rm -f -- "$CLAUDE_MUTANT.bak"
  assert_eq "$(grep -cF 'find -H "$root" -mindepth 2 -maxdepth 2 -type f' "$CLAUDE_MUTANT")" "0" "control removes the Claude lead-only scan"
  if cmp -s "$SRC_OT" "$CLAUDE_MUTANT"; then FAIL=$((FAIL + 1)); printf '  FAIL  control did not change the Claude scan\n'; else PASS=$((PASS + 1)); printf '  ok    control changed the Claude scan\n'; fi
  set +e
  OPEN_TERMINAL_UNDER_TEST="$CLAUDE_MUTANT" OPEN_TERMINAL_SKIP_CONTROL=1 "$0" >"$TMP_ROOT/claude-control.out" 2>&1
  CLAUDE_CONTROL_RC=$?
  set -e
  assert_eq "$CLAUDE_CONTROL_RC" "1" "control: recursive Claude selection chooses the newer child transcript"

  MUTANT="$TMP_ROOT/open-terminal-pi-default"
  cp "$SRC_OT" "$MUTANT"
  assert_eq "$(grep -cF 'roots="$(pi_relaunch_root "$cwd" "$home")" || return 2' "$MUTANT")" "1" "control finds the Pi settings root"
  sed -i.bak 's@roots="$(pi_relaunch_root "$cwd" "$home")" || return 2@roots="${PI_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$home/.pi/agent}/sessions}"@' "$MUTANT"
  rm -f -- "$MUTANT.bak"
  assert_eq "$(grep -cF 'roots="${PI_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$home/.pi/agent}/sessions}"' "$MUTANT")" "1" "control changes the Pi session root"
  if cmp -s "$SRC_OT" "$MUTANT"; then FAIL=$((FAIL + 1)); printf '  FAIL  control did not change the launcher\n'; else PASS=$((PASS + 1)); printf '  ok    control changed the launcher\n'; fi
  set +e
  OPEN_TERMINAL_UNDER_TEST="$MUTANT" OPEN_TERMINAL_SKIP_CONTROL=1 "$0" >"$TMP_ROOT/control.out" 2>&1
  CONTROL_RC=$?
  set -e
  assert_eq "$CONTROL_RC" "1" "control: the old Pi root misses settings-based sessions"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
