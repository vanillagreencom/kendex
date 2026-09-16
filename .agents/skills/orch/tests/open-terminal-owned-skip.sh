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
  OUT=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" STUB_CALL_LOG="$CALL_LOG" STUB_EXIT_DIR="$EXIT_DIR" OT_CAPTURE="${OT_CAPTURE:-}" LANES_HOME="${LANES_HOME:-}" CODEX_HOME="${CODEX_HOME_OVERRIDE:-}" CODEX_INVENTORY="${CODEX_INVENTORY:-}" \
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
  out=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" LANES_CLI="$WAKE_LANE_BIN/lanes" \
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

# A Claude or Codex session still working in the lane worktree is not resumed
# beside itself. The fixture session is a copy of bash named for the harness,
# so it carries the harness's command name, running in the worktree with the
# shell child and, for Claude, the session file a row names.
LIVE_BIN="$TMP_ROOT/live-bin"; mkdir -p "$LIVE_BIN"; cp "$BASH" "$LIVE_BIN/claude"; cp "$BASH" "$LIVE_BIN/codex"
LIVE_CONFIG="$TMP_ROOT/live-config"; mkfifo "$TMP_ROOT/never"
cat >"$TMP_ROOT/live-session.sh" <<'EOF'
[ "$1" = - ] || printf '{"status":"%s"}\n' "$1" >"$CLAUDE_CONFIG_DIR/sessions/$$.json"
if [ "$2" = 1 ]; then
  bash -c 'printf "%s\n" "$$" >"$1.shell"; read -r _ <"$2"' shell "$3" "$4" &
  n=0; while [ ! -s "$3.shell" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
fi
: >"$3"
read -r _ <"$4"
EOF
# live_wake HARNESS STATUS SHELL [SCRIPT] — a HARNESS wake on CC-1 through
# SCRIPT, beside a live session whose file reads STATUS (`-` writes none), with
# a shell child when SHELL is 1.
live_wake() {
  local ready="$TMP_ROOT/live-ready" pid n=0 saved="$OT"
  rm -rf -- "$LIVE_CONFIG" "$ready" "$ready.shell" "$TMP_ROOT/live-wake.cmd"; mkdir -p "$LIVE_CONFIG/sessions"
  (cd "$TMP_ROOT/wt/CC-1" && export CLAUDE_CONFIG_DIR="$LIVE_CONFIG" && exec "$LIVE_BIN/$1" "$TMP_ROOT/live-session.sh" "$2" "$3" "$ready" "$TMP_ROOT/never") &
  pid=$!
  LIVE_PIDS="$pid"
  while [[ ! -e "$ready" && "$n" -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done
  [[ ! -s "$ready.shell" ]] || LIVE_PIDS="$LIVE_PIDS $(cat "$ready.shell")"
  OT="${4:-$OT}"
  OT_CAPTURE="$TMP_ROOT/live-wake.cmd" LANES_HOME="$SESSION_HOME" CODEX_HOME_OVERRIDE="$SESSION_HOME/.selected-codex" \
    run_case live-wake -- --wake --harness "$1" CC-1
  OT="$saved"
  kill $LIVE_PIDS 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  LIVE_PIDS=""
}
LIVE_RESUME_claude="claude -n CC-1 --resume $CLAUDE222 -p $WAKE_LINE"
LIVE_RESUME_codex="codex exec resume $CODEX444 $WAKE_LINE"
# The refusal names the state the shared judge read, so a live harness process
# is `working` where the /proc read alone called it `busy`. With no pane on this
# tmux server carrying the item's window name, the harness process is the whole
# of the reading here, exactly as it was before the judge existed.
for row in "claude idle 1 working|a shell under an idle session" "claude busy 0 working|a session file not reading idle" "claude idle 0 idle|an idle session" \
  "codex - 1 working|a shell under a codex session" "codex - 0 unjudged|a codex session with no shell under it"; do
  IFS='|' read -r spec label <<<"$row"
  read -r harness status shell want <<<"$spec"
  # With no /proc the cwd of the live session cannot be read at all.
  [[ -d /proc/self ]] || want=unjudged
  live_wake "$harness" "$status" "$shell"
  if [[ "$want" == idle ]]; then
    resume_var="LIVE_RESUME_$harness"
    assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "${!resume_var}" "a wake beside $label resumes it"
  else
    assert_eq "RC=$RC resumed=$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "RC=1 resumed=" "a wake beside $label exits 1 and resumes nothing"
    assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=$want" "a wake beside $label is refused as $want"
  fi
done
# The row the pane rungs alone get wrong. WORKING_RE draws a second or two into
# a turn, so the first moments of one are a composer with nothing above it —
# byte for byte a finished turn. Read off the pane that is `idle`, and a wake
# acting on `idle` starts a second `claude --resume` on a worktree whose session
# is mid-turn. The harness process is what tells them apart, and the judge lets
# a busy one veto the idle rung, so this screen refuses as `working`.
WAKE_PANE_BIN="$TMP_ROOT/wake-pane-bin"; mkdir -p "$WAKE_PANE_BIN"
printf '%s\n%s\n' '⏺ Done: the PR is merged.' $'\xe2\x9d\xaf\xc2\xa0' >"$TMP_ROOT/wake-pane.txt"
cat >"$WAKE_PANE_BIN/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  list-panes) printf 'CC-1\t%%9\t4242\tclaude\n'; exit 0 ;;
  capture-pane) cat "$TMP_ROOT/wake-pane.txt"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$WAKE_PANE_BIN/tmux"
PATH="$WAKE_PANE_BIN:$PATH" live_wake claude idle 1
assert_eq "RC=$RC resumed=$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "RC=1 resumed=" \
  "a wake beside a busy session whose pane shows a finished turn's composer resumes nothing"
assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=working" \
  "that pane is refused as working, not taken for the idle it looks like"

# The mutant: the refusal gone, the session state still read.
BUSY_MUTANT_REPO="$TMP_ROOT/busy-mutant-repo"
cp -a "$REPO" "$BUSY_MUTANT_REPO"
BUSY_MUTANT="$BUSY_MUTANT_REPO/scripts/open-terminal"
sed -i.bak 's/\[\[ "$wake_state" == idle \]\] ||/true ||/' "$BUSY_MUTANT"
assert_eq "$(cmp -s "$OT" "$BUSY_MUTANT" && echo same || echo changed)" "changed" "control: the busy mutant really drops the refusal"
live_wake claude idle 1 "$BUSY_MUTANT"
assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "claude -n CC-1 --resume $CLAUDE222 -p $WAKE_LINE" \
  "control: without the refusal a wake resumes beside a working session"
# The inverse of the codex rows: with no codex process in the worktree, the wake
# proceeds.
OT_CAPTURE="$TMP_ROOT/live-wake.cmd" LANES_HOME="$SESSION_HOME" CODEX_HOME_OVERRIDE="$SESSION_HOME/.selected-codex" \
  run_case live-wake-none -- --wake --harness codex CC-1
assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_codex" \
  "a codex wake with no codex process in the worktree resumes it"
# The mutant: a codex session with no shell under it read as idle again. With
# no /proc the wake is unjudged before any session is read, so the control has
# nothing to turn.
if [[ -d /proc/self ]]; then
  CODEX_IDLE_MUTANT_REPO="$TMP_ROOT/codex-idle-mutant-repo"
  cp -a "$REPO" "$CODEX_IDLE_MUTANT_REPO"
  CODEX_IDLE_MUTANT="$CODEX_IDLE_MUTANT_REPO/scripts/open-terminal"
  sed -i.bak 's/^    \[\[ "$HARNESS" == claude \]\] || { printf unjudged; return 0; }$/    [[ "$HARNESS" == claude ]] || continue/' "$CODEX_IDLE_MUTANT"
  assert_eq "$(cmp -s "$OT" "$CODEX_IDLE_MUTANT" && echo same || echo changed)" "changed" \
    "control: the codex-idle mutant really reads a shell-less codex session as idle"
  live_wake codex - 0 "$CODEX_IDLE_MUTANT"
  assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "$LIVE_RESUME_codex" \
    "control: without the codex arm a wake resumes beside a live codex session"
fi
# A live session whose cwd cannot be read is unjudged, never idle. The shim
# stands in for the one readlink open-terminal calls and hides only a cwd in
# the fixture worktree.
CWD_SHIM="$TMP_ROOT/cwd-shim"; mkdir -p "$CWD_SHIM"
printf '#!/bin/sh\nt=$("%s" "$@") || exit 1\n[ "$t" != "%s" ] || exit 1\nprintf "%%s\\n" "$t"\n' \
  "$(command -v readlink)" "$TMP_ROOT/wt/CC-1" >"$CWD_SHIM/readlink"
chmod +x "$CWD_SHIM/readlink"
PATH="$CWD_SHIM:$PATH" live_wake claude idle 0
assert_eq "RC=$RC resumed=$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "RC=1 resumed=" \
  "a wake beside a session whose cwd cannot be read exits 1 and resumes nothing"
assert_contains "$ERR" "open-terminal: wake-refused item=CC-1 reason=unjudged" \
  "a wake beside a session whose cwd cannot be read is refused as unjudged"
# The mutant: a failed cwd read skips the process again. With no /proc the
# wake is unjudged before any cwd is read, so the control has nothing to turn.
if [[ -d /proc/self ]]; then
  UNREAD_MUTANT_REPO="$TMP_ROOT/unread-mutant-repo"
  cp -a "$REPO" "$UNREAD_MUTANT_REPO"
  UNREAD_MUTANT="$UNREAD_MUTANT_REPO/scripts/open-terminal"
  sed -i.bak 's/^      printf unjudged; return 0$/      continue/' "$UNREAD_MUTANT"
  assert_eq "$(cmp -s "$OT" "$UNREAD_MUTANT" && echo same || echo changed)" "changed" \
    "control: the unread-cwd mutant really skips the process"
  PATH="$CWD_SHIM:$PATH" live_wake claude idle 0 "$UNREAD_MUTANT"
  assert_eq "$(cat "$TMP_ROOT/live-wake.cmd" 2>/dev/null)" "claude -n CC-1 --resume $CLAUDE222 -p $WAKE_LINE" \
    "control: without the unjudged arm a wake resumes beside a session it never read"
fi

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
