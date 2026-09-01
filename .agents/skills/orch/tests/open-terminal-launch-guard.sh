#!/usr/bin/env bash
# The last layer before a window opens: a launch whose working directory does
# not exist is refused by name, on every launch path.
#
# The class this closes was reached repeatedly in the real fleet (KEN-1084). A
# suite that drives `open-terminal` with a stubbed worktree CLI gets an empty
# path back the moment the stub exits 0 without printing one — the shape a
# PATH stub leaves when its fixture tree is deleted under it — and open_gui
# then handed that empty path to a real GUI terminal, which opened a window on
# the operator's desktop at a directory that was gone. The same is true of any
# lane whose worktree was removed while it ran. Refusing here closes it
# whatever produced the launch, without asking who did.
#
# Everything external is stubbed: the GUI terminal (invocations logged, so a
# refusal that still launched is visible), tmux, gh, and the worktree CLI.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sealed-bin.sh
. "$TEST_DIR/lib/sealed-bin.sh"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="${OPEN_TERMINAL_UNDER_TEST:-$SCRIPTS_DIR/open-terminal}"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2   got: $1"; }
assert_not_contains() {
  grep -qF -- "$2" <<<"$1" && bad "$3" "forbidden substring: $2
        in: $1" || ok "$3"
}
assert_contains() {
  grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3" "wanted substring: $2
        in: $1"
}

# Stub bin. The GUI terminal APPENDS rather than truncating, so a case that
# expects no launch fails loudly on a stray one instead of overwriting it.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/term" <<'EOF'
#!/usr/bin/env bash
printf 'term %s\n' "$*" >> "$OT_TERM_LOG"
exit 0
EOF
# The desktop's launcher, for the case where $TERMINAL names nothing, and a
# launcher that refuses its arguments the way the GTK family refuses -e bash -lc.
cat > "$BIN/xdg-terminal-exec" <<'EOF'
#!/usr/bin/env bash
printf 'xdg %s\n' "$*" >> "$OT_TERM_LOG"
exit 0
EOF
cat > "$BIN/badterm" <<'EOF'
#!/usr/bin/env bash
echo "badterm: unrecognised option -lc" >&2
exit 3
EOF
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$OT_TMUX_LOG"
exit 1
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/term" "$BIN/xdg-terminal-exec" "$BIN/badterm" "$BIN/tmux" "$BIN/gh"

# $TERMINAL is the terminal open_gui reaches for first — the owner's ruling
# that a GUI launch honours the user's own choice — so each run names a stub
# and pins the branch, $OT_TERMINAL choosing which. A BARE name, never a path
# into this mktemp tree: a path bypasses PATH resolution, and with it the seal
# that answers once the tree is gone. On fallthrough the seal takes the branch
# below instead.

# Stub worktree CLI, one shape per $STUB_MODE:
#   empty    exits 0 printing nothing (a stub that escaped its fixture)
#   missing  prints a path that was never created (a tree removed under a lane)
#   real     makes the directory and prints it
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "create" ]] || { echo "unexpected worktree stub call: \$*" >&2; exit 1; }
case "\$STUB_MODE" in
  empty)   exit 0 ;;
  missing) printf '%s\n' "$TMP_ROOT/gone/\${2:-item}"; exit 0 ;;
  real)    mkdir -p "$TMP_ROOT/wt/\${2:-item}"; printf '%s\n' "$TMP_ROOT/wt/\${2:-item}"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB"

# stage DIR SRC — a copy of open-terminal in a git repo of its own, so
# PROJECT_ROOT resolves hermetically.
stage() {
  mkdir -p "$1/scripts/lib"
  cp "$2" "$1/scripts/open-terminal"
  cp "$SRC_LIB_DIR"/*.sh "$1/scripts/lib/"
  chmod +x "$1/scripts/open-terminal"
  git -C "$1" init -q
}

REPO="$TMP_ROOT/repo"
stage "$REPO" "$SRC_OT"

# run NAME OT MODE ARGS... — sets RC, ERR, TERM_LOG_TEXT and TMUX_LOG_TEXT.
run() {
  local name="$1" ot="$2" mode="$3"
  shift 3
  local term_log="$TMP_ROOT/$name.term" tmux_log="$TMP_ROOT/$name.tmux"
  : > "$term_log"
  : > "$tmux_log"
  set +e
  PATH="$BIN:$SEALED:$PATH" WORKTREE_CLI="$STUB" STUB_MODE="$mode" \
    OT_TERM_LOG="$term_log" OT_TMUX_LOG="$tmux_log" TMUX="${OT_TMUX_VALUE:-}" \
    TERMINAL="${OT_TERMINAL:-term}" \
    "$ot" --cmd 'echo {item}' "$@" >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/$name.err")"
  OUT_TEXT="$(cat "$TMP_ROOT/$name.out")"
  # open_gui detaches the launch (`setsid ... &`), so the stub's line can land
  # after open-terminal has already exited — on a loaded box it did, and the
  # case read an empty log. Which wait to take is DERIVED from the script's own
  # report rather than from a flag each call site remembers: an exit 0 says a
  # launch was started, so wait for its line; any other status says none was, so
  # watch a real interval and prove none appears.
  local i=0
  if [[ "$RC" -eq 0 ]]; then
    while [ "$i" -lt 100 ] && [ ! -s "$term_log" ]; do
      sleep 0.1
      i=$((i + 1))
    done
  else
    sleep 1
  fi
  TERM_LOG_TEXT="$(cat "$term_log")"
  TMUX_LOG_TEXT="$(cat "$tmux_log")"
}

echo "=== open-terminal: a launch at a working directory that is gone is refused ==="

run empty "$REPO/scripts/open-terminal" empty --ghostty CC-1
assert_eq "$RC" "1" "a GUI launch with no worktree path fails the item"
assert_contains "$ERR" "Error: refusing to launch 'CC-1': working directory '' does not exist" \
  "the refusal names the item and the empty directory"
assert_eq "$TERM_LOG_TEXT" "" "no terminal was launched for the empty path"

run missing "$REPO/scripts/open-terminal" missing --ghostty CC-1
assert_eq "$RC" "1" "a GUI launch at a deleted worktree fails the item"
assert_contains "$ERR" "Error: refusing to launch 'CC-1': working directory '$TMP_ROOT/gone/CC-1' does not exist" \
  "the refusal names the directory that is gone"
assert_eq "$TERM_LOG_TEXT" "" "no terminal was launched at the deleted directory"

# The tmux path refuses at the same layer, before the first tmux call: a window
# created with `-c` at a missing directory is the same broken lane.
# TMUX travels through the run helper, never as an assignment prefixed onto a
# function call: bash keeps such an assignment in the shell after the call, and
# it would then decide the mode of every case below.
OT_TMUX_VALUE=stub,1,0
run tmux_missing "$REPO/scripts/open-terminal" missing --tmux CC-1
OT_TMUX_VALUE=""
assert_eq "$RC" "1" "a tmux launch at a deleted worktree fails the item"
assert_contains "$ERR" "Error: refusing to launch 'CC-1': working directory '$TMP_ROOT/gone/CC-1' does not exist" \
  "the tmux path refuses in the same words"
assert_eq "$TMUX_LOG_TEXT" "" "tmux was never called for the deleted directory"

# The premise: with a directory that IS there the same harness launches, and it
# launches $TERMINAL. Without this the refusals above would pass on a harness
# that could not launch anything at all.
run real "$REPO/scripts/open-terminal" real --ghostty CC-1
assert_eq "$RC" "0" "premise: a launch at a real directory succeeds"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" "premise: and \$TERMINAL is the terminal it launched"
# Only the ghostty arm has a --title flag and it is the last one tried, so the
# title is written from inside the launched shell or it is not written at all.
assert_contains "$TERM_LOG_TEXT" "printf '\033]0;%s\007' 'CC-1'" \
  "the launched shell sets the window title to the item"

echo
echo "=== a launcher nothing observed is not a launch to report ==="

# The exit code is the orchestrator's only signal that a lane started, so a
# launcher that refuses its arguments must fail the item rather than be counted.
OT_TERMINAL=badterm
run badterm "$REPO/scripts/open-terminal" real --ghostty CC-1
OT_TERMINAL=""
assert_eq "$RC" "1" "a launcher that exits non-zero fails the item"
assert_contains "$ERR" "Error: badterm exited 3 launching 'CC-1'" \
  "the failure names the launcher and its status"
assert_contains "$ERR" "unrecognised option -lc" "and carries the launcher's own words"
assert_contains "$ERR" "1 handoff lane(s) failed" "the batch summary counts it as failed"
assert_not_contains "$OUT_TEXT" "Opened terminal" "and no success line is printed for it"

# A $TERMINAL naming nothing on PATH is substituted; saying so is the difference
# between an operator's choice being honoured and being quietly overridden.
OT_TERMINAL=no-such-terminal-anywhere
run unresolved "$REPO/scripts/open-terminal" real --ghostty CC-1
OT_TERMINAL=""
assert_eq "$RC" "0" "an unresolvable \$TERMINAL still launches through the fallback"
assert_contains "$ERR" "Warning: \$TERMINAL 'no-such-terminal-anywhere' does not resolve to an executable; launching 'CC-1' with xdg-terminal-exec instead" \
  "the substitution names the value and the terminal used instead"
assert_contains "$TERM_LOG_TEXT" "xdg bash -lc" "and the fallback launcher is the one that ran"
assert_contains "$TERM_LOG_TEXT" "printf '\033]0;%s\007' 'CC-1'" \
  "the title survives the fallback branch too"

echo
echo "=== the refusal can fail: with the guard gone the window opens ==="

# The must-fail control, run over BOTH shapes the guard refuses. `launchable_dir`
# is the whole protection, so the mutation is its one test — with that gone the
# function returns 0 for every path and each launch proceeds exactly as it did
# before this guard existed.
MUTANT="$TMP_ROOT/mutant"
mkdir -p "$MUTANT"
sed 's/\[\[ -d "$1" \]\] && return 0/return 0/' "$SRC_OT" > "$MUTANT/open-terminal"
if cmp -s "$SRC_OT" "$MUTANT/open-terminal"; then
  bad "control: the mutant really drops the directory test" "the copy is byte-identical to open-terminal"
else
  ok "control: the mutant really drops the directory test"
fi
MUTANT_REPO="$TMP_ROOT/mutant-repo"
stage "$MUTANT_REPO" "$MUTANT/open-terminal"

run mutant "$MUTANT_REPO/scripts/open-terminal" missing --ghostty CC-1
assert_eq "$RC" "0" "control: without the guard the deleted-path launch is reported as successful"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" \
  "control: and a terminal really is opened at the directory that is gone"

# The empty path is the shape the leak actually took, so it carries its own
# control rather than riding on the deleted one: a guard written as a stat of a
# non-empty path would refuse the case above and still launch this one.
run mutant_empty "$MUTANT_REPO/scripts/open-terminal" empty --ghostty CC-1
assert_eq "$RC" "0" "control: without the guard the empty-path launch is reported as successful"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" \
  "control: and a terminal really is opened for the empty working directory"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
