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
# it inherited, logged), tmux (argv logged, then a failure so no lane goes
# further), gh, and the worktree CLI.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
assert_contains() {
  grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3" "wanted substring: $2
        in: $1"
}
assert_not_contains() {
  grep -qF -- "$2" <<<"$1" && bad "$3" "unwanted substring: $2
        in: $1" || ok "$3"
}

# Stub bin. The GUI terminal logs its argv and the tmux identity it was handed
# (`<unset>` when the variable is absent, which is what a scrub must produce and
# what an empty value would fake). Every run names this stub in $TERMINAL, which
# open_gui reaches for first, so no case resolves the developer's own terminal.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/term" <<'STUB'
#!/usr/bin/env bash
printf 'term %s\n' "$*" >> "$OT_TERM_LOG"
printf 'env TMUX=%s TMUX_PANE=%s\n' "${TMUX-<unset>}" "${TMUX_PANE-<unset>}" >> "$OT_TERM_LOG"
exit 0
STUB
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$OT_TMUX_LOG"
exit 1
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/term" "$BIN/tmux" "$BIN/gh"

# Stub worktree CLI: `create <item>` makes and prints a directory, so the
# launch reaches the terminal instead of the missing-directory refusal.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "create" ]] || { echo "unexpected worktree stub call: \$*" >&2; exit 1; }
d="$TMP_ROOT/wt/\${2:-item}"
mkdir -p "\$d"
printf '%s\n' "\$d"
EOS
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

# run NAME OT WHERE ARGS... — WHERE is `in` (a tmux controller: TMUX and
# TMUX_PANE set) or `out` (neither present, whatever this suite itself runs
# under). Sets RC, ERR, TERM_LOG_TEXT and TMUX_LOG_TEXT.
run() {
  local name="$1" ot="$2" where="$3"
  shift 3
  local term_log="$TMP_ROOT/$name.term" tmux_log="$TMP_ROOT/$name.tmux"
  : > "$term_log"
  : > "$tmux_log"
  local -a tmux_env
  case "$where" in
    in)  tmux_env=(env TMUX=stub,1,0 TMUX_PANE=%7) ;;
    out) tmux_env=(env -u TMUX -u TMUX_PANE) ;;
    *) echo "run: WHERE must be in or out, got '$where'" >&2; exit 2 ;;
  esac
  set +e
  "${tmux_env[@]}" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" \
    OT_TERM_LOG="$term_log" OT_TMUX_LOG="$tmux_log" TERMINAL=term \
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

WARNING="Warning: --ghostty overrides tmux auto-detection"

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
        assert_contains "$ERR" "Error: not inside tmux" "$desc -> named as not inside tmux"
        assert_eq "$TERM_LOG_TEXT" "" "$desc -> no GUI terminal opens in its place"
        ;;
    esac
    if [[ "$warn" == "warn" ]]; then
      assert_contains "$ERR" "$WARNING" "$desc -> warns that the flag overrides auto-detection"
    else
      assert_not_contains "$ERR" "$WARNING" "$desc -> no override warning"
    fi
  done <<<"$MODE_ROWS"
}

echo "=== open-terminal: mode is auto-detected from \$TMUX and a flag overrides it ==="
check_mode_rows main "$REPO/scripts/open-terminal"

echo
echo "=== a GUI terminal opened from inside tmux inherits no tmux identity ==="
run scrub "$REPO/scripts/open-terminal" in --ghostty CC-1
assert_eq "$RC" "0" "the override launch succeeds"
assert_contains "$TERM_LOG_TEXT" "env TMUX=<unset> TMUX_PANE=<unset>" \
  "the GUI terminal receives neither TMUX nor TMUX_PANE"

echo
echo "=== each rule can fail ==="

# mutate NAME SED_EXPR — a copy of open-terminal with SED_EXPR applied, staged
# in its own repo; the copy must differ from the source or the control proves
# nothing. Sets MUTANT_OT to the staged script (no subshell, so the tally
# above keeps counting).
mutate() {
  local name="$1" expr="$2"
  local dir="$TMP_ROOT/mutant-$name"
  mkdir -p "$dir"
  sed "$expr" "$SRC_OT" > "$dir/open-terminal"
  if cmp -s "$SRC_OT" "$dir/open-terminal"; then
    bad "control: the $name mutant really changes open-terminal" "the copy is byte-identical to open-terminal"
  else
    ok "control: the $name mutant really changes open-terminal"
  fi
  stage "$dir/repo" "$dir/open-terminal"
  MUTANT_OT="$dir/repo/scripts/open-terminal"
}

# Auto-detection gone: with no flag every launch is a GUI launch, so the
# inside-tmux default row reds while the flagged rows still hold.
mutate default 's/then TERMINAL_MODE="tmux"; else TERMINAL_MODE="gui"/then TERMINAL_MODE="gui"; else TERMINAL_MODE="gui"/'
run mut_default "$MUTANT_OT" in CC-1
assert_eq "$TMUX_LOG_TEXT" "" "control: without auto-detection tmux is never reached from inside tmux"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" "control: and a GUI terminal opens instead"

# The warning's branch never taken: the override still launches, silently.
mutate warning 's/^elif \[\[ "$TERMINAL_MODE" == "ghostty" \&\& -n "${TMUX:-}" \]\]; then$/elif false; then/'
run mut_warn "$MUTANT_OT" in --ghostty CC-1
assert_eq "$RC" "0" "control: without the warning the override still launches"
assert_not_contains "$ERR" "$WARNING" "control: and says nothing about overriding tmux"

# The scrub gone: the GUI terminal inherits the controller's tmux identity.
mutate scrub 's/ -u TMUX -u TMUX_PANE//'
run mut_scrub "$MUTANT_OT" in --ghostty CC-1
assert_eq "$RC" "0" "control: without the scrub the launch still succeeds"
assert_contains "$TERM_LOG_TEXT" "env TMUX=stub,1,0 TMUX_PANE=%7" \
  "control: and the GUI terminal really does inherit TMUX and TMUX_PANE"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
