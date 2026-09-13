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
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="${OPEN_TERMINAL_UNDER_TEST:-$SCRIPTS_DIR/open-terminal}"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
[[ -z "${OT_CAPTURE:-}" ]] || printf '%s\n' "${!#}" >"$OT_CAPTURE"
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
# With no exit-code file the call makes and prints a worktree dir (exit 0).
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
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
    STUB_EXISTS_DIR="$EXISTS_DIR" \
    "$OT" --ghostty "${CMD_ARGS[@]}" "$@" 2>"$TMP_ROOT/$name.err")
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
SESSION_HOME="$TMP_ROOT/session-home"; CLAUDE222=22222222-2222-2222-2222-222222222222; CODEX444=44444444-4444-4444-4444-444444444444; mkdir -p "$SESSION_HOME/.claude-shared/projects/repo" "$SESSION_HOME/.selected-codex/sessions/2026" "$SESSION_HOME/.pi/agent/sessions/repo"
printf '%s\n' '{"type":"user","message":{"content":"start CC-1"}}' >"$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"
cp "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl" "$SESSION_HOME/.claude-shared/projects/repo/11111111-1111-1111-1111-111111111111.jsonl"; touch -t 200001010000 "$SESSION_HOME/.claude-shared/projects/repo/11111111-1111-1111-1111-111111111111.jsonl"
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
