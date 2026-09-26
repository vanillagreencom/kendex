#!/usr/bin/env bash
# Terminal-mode selection and the environment a GUI lane receives.
#
# With neither --tmux nor --ghostty, open-terminal picks tmux when $TMUX is set
# and a GUI terminal otherwise. Either flag overrides that. A caller who passes
# --ghostty from inside tmux (the flag inferred from what the screen looked
# like) is warned that the override moved the lane out of the workspace, and the
# GUI window it opens carries neither TMUX nor TMUX_PANE: without that scrub the
# child reads as a Ghostty terminal and a tmux pane at once, and pane-aware
# tools in it act on the controller's tmux server.
#
# Everything external is stubbed: the GUI terminal (argv and the tmux identity
# it inherited, logged) in each of open_gui's three arms, tmux (argv logged,
# then a failure so no lane goes further), gh, and the worktree CLI.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured lane host would turn these local launches into
# hosted ones; the caller environment outranks project settings.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# Stub bin. A GUI terminal stub logs its own name, its argv and the tmux
# identity it was handed (`<unset>` when the variable is absent, which is what a
# scrub must produce and what an empty value would fake). The $TERMINAL stub
# `term` is on every run's PATH and named in $TERMINAL unless a row says
# otherwise, so no case resolves the developer's own terminal; the
# xdg-terminal-exec and ghostty stubs sit in bins of their own, on PATH only for
# the row that exercises that arm.
BIN="$TMP_ROOT/bin"
XDG_BIN="$TMP_ROOT/bin-xdg"
GHOSTTY_BIN="$TMP_ROOT/bin-ghostty"
mkdir -p "$BIN" "$XDG_BIN" "$GHOSTTY_BIN"
gui_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$OT_TERM_LOG"
printf 'env TMUX=%s TMUX_PANE=%s\n' "${TMUX-<unset>}" "${TMUX_PANE-<unset>}" >> "$OT_TERM_LOG"
exit 0
STUB
  chmod +x "$1"
}
gui_stub "$BIN/term"
gui_stub "$XDG_BIN/xdg-terminal-exec"
gui_stub "$GHOSTTY_BIN/ghostty"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$OT_TMUX_LOG"
# The named session exists, so a launch reaches the window calls, which fail.
[[ "${1:-}" != has-session ]] || exit 0
exit 1
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/tmux" "$BIN/gh"

# The ghostty arm sits below `command -v xdg-terminal-exec`, so on a machine
# that has xdg-terminal-exec installed it is unreachable through PATH order
# alone. This PATH is a farm of symlinks to every executable on the suite's own
# PATH except xdg-terminal-exec, so that probe fails there and the arm is
# reached hermetically.
NO_XDG_PATH="$TMP_ROOT/path-without-xdg"
mkdir -p "$NO_XDG_PATH"
(
  IFS=:
  for d in $PATH; do
    [[ -d "$d" ]] || continue
    ln -s "$d"/* "$NO_XDG_PATH"/ 2>/dev/null || true
  done
)
rm -f -- "$NO_XDG_PATH/xdg-terminal-exec"
if command -v xdg-terminal-exec >/dev/null 2>&1 && PATH="$NO_XDG_PATH" command -v xdg-terminal-exec >/dev/null 2>&1; then
  echo "fixture: xdg-terminal-exec still resolves on the farm PATH" >&2
  exit 2
fi

# Stub worktree CLI: `create <item>` makes and prints a directory, so the
# launch reaches the terminal instead of the missing-directory refusal.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "create" ]] || { echo "unexpected worktree stub call: \$*" >&2; exit 1; }
d="$TMP_ROOT/wt/\${2:-item}"
mkdir -p "\$d"
git init -q "\$d"
printf '%s\n' "\$d"
EOS
chmod +x "$STUB"

# stage DIR SRC — a copy of open-terminal in a git repo of its own, so
# PROJECT_ROOT resolves hermetically.
stage() {
  mkdir -p "$1/scripts/lib"
  cp "$2" "$1/scripts/open-terminal"
  cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$1/scripts/"
  cp -R "$SRC_LIB_DIR/." "$1/scripts/lib/"
  orch_fixture_shared_libs "$1"
  chmod +x "$1/scripts/open-terminal"
  git -C "$1" init -q
}

REPO="$TMP_ROOT/repo"
stage "$REPO" "$SRC_OT"

# run NAME OT WHERE ARGS... — WHERE is `in` (a tmux controller: TMUX and
# TMUX_PANE set) or `out` (neither present, whatever this suite itself runs
# under). $RUN_PATH is the launch PATH and $RUN_TERMINAL the $TERMINAL value
# (empty: unset), both defaulting to the `term` arm. Sets RC, ERR,
# TERM_LOG_TEXT and TMUX_LOG_TEXT.
RUN_PATH=""
RUN_TERMINAL="term"
run() {
  local name="$1" ot="$2" where="$3"
  shift 3
  local term_log="$TMP_ROOT/$name.term" tmux_log="$TMP_ROOT/$name.tmux"
  : > "$term_log"
  : > "$tmux_log"
  # env reads its -u options only ahead of the first assignment.
  local -a launch_env=(env)
  [[ -n "$RUN_TERMINAL" ]] || launch_env+=(-u TERMINAL)
  case "$where" in
    in)  launch_env+=(TMUX=stub,1,0 TMUX_PANE=%7 ORCH_TMUX_SESSION=stub) ;;
    out) launch_env+=(-u TMUX -u TMUX_PANE) ;;
    *) echo "run: WHERE must be in or out, got '$where'" >&2; exit 2 ;;
  esac
  [[ -z "$RUN_TERMINAL" ]] || launch_env+=("TERMINAL=$RUN_TERMINAL")
  set +e
  "${launch_env[@]}" PATH="${RUN_PATH:-$BIN:$PATH}" ORCH_STATE_DIR="$TMP_ROOT/$name.state" WORKTREE_CLI="$STUB" \
    OT_TERM_LOG="$term_log" OT_TMUX_LOG="$tmux_log" \
    "$ot" --cmd 'echo {item}' "$@" >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/$name.err")"
  # open_gui detaches the launch (`setsid ... &`), so the stub's lines can land
  # after open-terminal has exited. An exit 0 says a GUI launch was started, so
  # wait for both of its lines; any other status says none was, so watch a real
  # interval and prove none appears. tmux calls are synchronous.
  local i=0
  if [[ "$RC" -eq 0 ]]; then
    while [ "$i" -lt 100 ] && [ "$(grep -c '' "$term_log")" -lt 2 ]; do
      sleep 0.1
      i=$((i + 1))
    done
  else
    sleep 1
  fi
  TERM_LOG_TEXT="$(cat "$term_log")"
  TMUX_LOG_TEXT="$(cat "$tmux_log")"
}

WARNING='open-terminal: mode-override option=--ghostty detected=tmux'

# One row per (where, flag) pair: the launcher it must reach and whether the
# override warning is due. `refused` is --tmux outside tmux, which open_tmux
# rejects before its first tmux call; the flag still won, since no GUI opened.
MODE_ROWS='in||tmux|nowarn
out||gui|nowarn
in|--ghostty|gui|warn
out|--ghostty|gui|nowarn
in|--tmux|tmux|nowarn
out|--tmux|refused|nowarn'

# check_mode_rows LABEL OT — runs every row against OT and asserts it.
check_mode_rows() {
  local label="$1" ot="$2" where flag expect warn desc
  local n=0
  while IFS='|' read -r where flag expect warn; do
    [[ -n "$where" ]] || continue
    n=$((n + 1))
    desc="$label: $where tmux, flag '${flag:-none}'"
    if [[ -n "$flag" ]]; then
      run "$label-$n" "$ot" "$where" "$flag" CC-1
    else
      run "$label-$n" "$ot" "$where" CC-1
    fi
    case "$expect" in
      tmux)
        assert_contains "$TMUX_LOG_TEXT" "tmux list-windows" "$desc -> tmux is reached"
        assert_eq "$TERM_LOG_TEXT" "" "$desc -> no GUI terminal opens"
        ;;
      gui)
        assert_eq "$RC" "0" "$desc -> the GUI launch is reported as successful"
        assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" "$desc -> a GUI terminal opens"
        assert_eq "$TMUX_LOG_TEXT" "" "$desc -> tmux is never called"
        ;;
      refused)
        assert_eq "$RC" "1" "$desc -> the item fails"
        assert_contains "$ERR" "open-terminal: tmux-missing item=CC-1" "$desc -> named as not inside tmux"
        assert_eq "$TERM_LOG_TEXT" "" "$desc -> no GUI terminal opens in its place"
        ;;
    esac
    if [[ "$warn" == "warn" ]]; then
      assert_eq "${ERR%%$'\n'*}" "$WARNING" "$desc -> warns that the flag overrides auto-detection"
    else
      assert_not_contains "$ERR" "$WARNING" "$desc -> no override warning"
    fi
  done <<<"$MODE_ROWS"
}

echo "=== open-terminal: mode is auto-detected from \$TMUX and a flag overrides it ==="
check_mode_rows main "$REPO/scripts/open-terminal"

echo
echo "=== the rule can fail ==="

# The suite's one must-fail control. Auto-detection gone: with no flag every
# launch is a GUI launch, so the inside-tmux default row reds while the flagged
# rows still hold.
MUTANT_REPO="$TMP_ROOT/mutant-default"
MUTANT_OT="$(mutant_scripts mutant-default open-terminal)/open-terminal" || exit 1
git -C "$MUTANT_REPO" init -q
orch_fixture_shared_libs "$MUTANT_REPO"
mutate_file "$MUTANT_OT" 'then TERMINAL_MODE="tmux"; else TERMINAL_MODE="gui"' 'then TERMINAL_MODE="gui"; else TERMINAL_MODE="gui"'
run mut_default "$MUTANT_OT" in CC-1
assert_eq "$TMUX_LOG_TEXT" "" "control: without auto-detection tmux is never reached from inside tmux"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" "control: and a GUI terminal opens instead"

echo
echo "=== a GUI terminal opened from inside tmux inherits no tmux identity, on every launcher arm ==="

# One row per open_gui arm: the PATH and $TERMINAL that reach it, and the argv
# the stub must log. Every arm detaches through run_detached, which owns the
# scrub.
ARM_ROWS="terminal|$BIN:$PATH|term|term -e bash -lc
xdg|$XDG_BIN:$BIN:$PATH|-|xdg-terminal-exec bash -lc
ghostty|$GHOSTTY_BIN:$BIN:$NO_XDG_PATH|-|ghostty --working-directory="
while IFS='|' read -r arm path terminal argv; do
  [[ -n "$arm" ]] || continue
  RUN_PATH="$path"
  RUN_TERMINAL="${terminal#-}"
  run "scrub-$arm" "$REPO/scripts/open-terminal" in --ghostty CC-1
  assert_eq "$RC" "0" "$arm arm: the override launch succeeds"
  assert_contains "$TERM_LOG_TEXT" "$argv" "$arm arm: the launch went through this arm"
  assert_contains "$TERM_LOG_TEXT" "env TMUX=<unset> TMUX_PANE=<unset>" \
    "$arm arm: the GUI terminal receives neither TMUX nor TMUX_PANE"
done <<<"$ARM_ROWS"
RUN_PATH=""
RUN_TERMINAL="term"

echo "=== the GUI launch happens on a host with no setsid ==="

# run_detached detaches the window so it outlives this script, through
# lib/lane-launch.sh's lane_run_detached. setsid is util-linux
# and stock macOS has none, and the launch line sends its own stderr to
# /dev/null — so a `setsid: command not found` was swallowed there, nothing
# opened, and open-terminal still printed "Opened terminal". nohup is the arm
# every platform has. The probe PATH is the real one minus setsid rather than a
# list of the tools open_gui uses, so it stays true as open_gui changes.
NO_SETSID_PATH="$TMP_ROOT/path-without-setsid"
mkdir -p "$NO_SETSID_PATH"
(
  IFS=:
  for d in $PATH; do
    [[ -d "$d" ]] || continue
    ln -s "$d"/* "$NO_SETSID_PATH"/ 2>/dev/null || true
  done
)
rm -f -- "$NO_SETSID_PATH/setsid"
# Without this the case passes vacuously through the setsid branch.
if PATH="$NO_SETSID_PATH" command -v setsid >/dev/null 2>&1; then
  fail "the probe PATH resolves no setsid" "setsid is still reachable"
else
  pass "the probe PATH resolves no setsid"
fi

RUN_PATH="$BIN:$NO_SETSID_PATH"
run "nosetsid" "$REPO/scripts/open-terminal" out CC-1
assert_eq "$RC" "0" "no setsid: the GUI launch is reported as successful"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" "no setsid: a GUI terminal really opens"

RUN_PATH=""
RUN_TERMINAL="term"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
