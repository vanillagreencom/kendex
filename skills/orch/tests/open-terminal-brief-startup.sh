#!/usr/bin/env bash
# The local --brief-file contract through real terminal input before the pane
# shell finishes startup. Inputs: open-terminal, pane-write and lane-launch,
# plus the shared launcher fixtures. The inline-prompt control loses input at
# that boundary; a ready-shell argv test alone cannot exercise it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/question-off.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
REAL_TMUX="$(command -v tmux)" || { echo 'brief-startup: tmux-missing' >&2; exit 1; }
REAL_FISH="$(command -v fish)" || { echo 'brief-startup: fish-missing' >&2; exit 1; }
REAL_SLEEP="$(command -v sleep)" || exit 1

# Each child holds a private server. The parent deadline bounds FIFO startup,
# launcher execution and readback, including a broken fixture's waits.
if [[ "${1:-}" == --case ]]; then
  ROOT="$2" OT="$3" HARNESS="$4" SHELL_BIN="$5"
  mkdir -p "$ROOT/home/.config/fish" "$ROOT/bin" "$ROOT/real-bin"
  # Fish skips its disowned completion generator when these stores exist.
  # The generator otherwise can keep writing after the pane shell exits.
  mkdir -p "$ROOT/home/.local/share/fish/generated_completions" \
    "$ROOT/home/.cache/fish/generated_completions"
  # macOS temp paths leave too little room for tmux's default socket suffix.
  tm() { env -i PATH="$ROOT/bin:$PATH" HOME="$ROOT/home" LANG=C.UTF-8 SHELL="$BASH" "$REAL_TMUX" -S "$ROOT/s" "$@"; }
  trap 'tm kill-server 2>/dev/null || true' EXIT
  trap 'exit 143' TERM
  ot_stub_bin "$ROOT/bin"
  mkfifo "$ROOT/startup-gate"
  printf 'printf ready > %s\nread --nchars 1 < %s\nprintf ready > %s\n' \
    "$ROOT/startup-entered" "$ROOT/startup-gate" "$ROOT/startup-released" > "$ROOT/home/.config/fish/config.fish"
  printf 'printf ready > %q\nread -r -n 1 < %q\nprintf ready > %q\n' \
    "$ROOT/startup-entered" "$ROOT/startup-gate" "$ROOT/startup-released" > "$ROOT/bashrc"
  # Positive rows must fit macOS's 1024-byte input queue, including Enter.
  # The inline control deliberately exceeds it to prove actual delivery loss.
  check_capacity=false
  [[ "$OT" != "$SCRIPTS_DIR/open-terminal" ]] || check_capacity=true
  {
    printf '#!%s\nroot=%q\nreal_tmux=%q\nreal_sleep=%q\ncheck_capacity=%q\n' \
      "$BASH" "$ROOT" "$REAL_TMUX" "$REAL_SLEEP" "$check_capacity"
    cat <<'WRAPPER'
set -euo pipefail
if [[ "$1" == paste-buffer ]]; then
  for i in {1..100}; do [[ ! -f "$root/startup-entered" ]] || break; "$real_sleep" 0.02; done
  [[ -f "$root/startup-entered" && ! -f "$root/startup-released" ]] || exit 70
fi
if [[ "$1" == load-buffer && "${!#}" == - ]]; then
  cat > "$root/typed-command"
  input_bytes="$(wc -c < "$root/typed-command")"
  if [[ "$check_capacity" == true ]] && (( input_bytes + 1 > 1024 )); then
    printf 'brief-startup: input-bytes=%s limit=1024\n' "$input_bytes" > "$root/input-bound"
    exit 76
  fi
  "$real_tmux" -S "$root/s" "$@" < "$root/typed-command"
else
  "$real_tmux" -S "$root/s" "$@"
fi
if [[ "$1" == send-keys && "${!#}" == Enter ]]; then
  printf x > "$root/startup-gate"
fi
WRAPPER
  } > "$ROOT/real-bin/tmux"
  chmod +x "$ROOT/real-bin/tmux"
  printf '#!%s\nprintf "%%s\\0" "$@" > %q\nprintf "%%s" "${!#}" > %q\nmv -- %q %q\n' \
    "$BASH" "$ROOT/argv" "$ROOT/received.tmp" "$ROOT/received.tmp" "$ROOT/received" > "$ROOT/bin/$HARNESS"
  chmod +x "$ROOT/bin/$HARNESS"
  tm -f /dev/null new-session -d -s fixture -x 200 -y 50
  if [[ "$SHELL_BIN" == "$REAL_FISH" ]]; then
    printf '#!%s\nexec %q -l\n' "$BASH" "$REAL_FISH" > "$ROOT/pane-shell"
    chmod +x "$ROOT/pane-shell"
    tm set-option -g default-shell "$ROOT/pane-shell"
    tm set-option -gu default-command
  else
    tm set-option -g default-shell "$BASH"
    tm set-option -g default-command "$BASH --noprofile --rcfile '$ROOT/bashrc' -i"
  fi
  for n in {1..8}; do
    printf 'paragraph-%s: ' "$n"
    printf '%s ' $'Keep the agent\'s $HOME and `whoami`, "done", a & b, C:\\tmp, 100%s and {brief}.'
    # One physical line exceeds the canonical terminal input bound. Short
    # lines can be drained after the gate opens before the queued paste fills
    # that bound, so their loss depends on the shell's startup speed.
    printf 'scope status instructions %.0s' {1..256}
    printf '\n\n'
  done > "$ROOT/brief"
  printf '%s\n' 'STARTUP_BRIEF_TAIL' >> "$ROOT/brief"
  printf '%s' "$(cat -- "$ROOT/brief")" > "$ROOT/expected"
  case "$HARNESS" in
    codex) flags='-m gpt-6.1-sol -c model_reasoning_effort=high' ;;
    claude) flags='--model opus --effort high' ;;
    pi) flags='--model github-copilot/claude-sonnet-5 --thinking high' ;;
    *) exit 2 ;;
  esac
  env -i PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" LANG=C.UTF-8 LINEAR_TEAM= \
    WORKTREE_CLI="$ROOT/bin/worktree" ORCH_TMUX_SESSION=fixture \
    ORCH_LANE_HOST=local OT_WT_LOG="$ROOT/worktree.log" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    "$OT" --tmux --harness "$HARNESS" --cmd "$HARNESS $flags $QUESTION_OFF_ALL {brief}" \
    --brief-file "$ROOT/brief" KEN-1 > "$ROOT/launch.log" 2>&1
  for i in {1..100}; do [[ ! -f "$ROOT/received" ]] || break; "$REAL_SLEEP" 0.02; done
  [[ -f "$ROOT/startup-entered" && -f "$ROOT/startup-released" ]] || exit 71
  if [[ -f "$ROOT/received" ]]; then
    cmp -s "$ROOT/received" "$ROOT/expected" || exit 1
    # The argv recorder includes every argument, including the full prompt.
    perl -e 'local $/; open my $a,"<",$ARGV[0] or die $!; my @a=split /\0/,<$a>; open my $b,"<",$ARGV[1] or die $!; exit($a[-1] eq <$b> ? 0 : 1)' \
      "$ROOT/argv" "$ROOT/expected"
  else
    exit 1
  fi
  exit
fi

TMP_ROOT="$(mktemp -d)" || { echo 'brief-startup: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
OLD="$(mutant_scripts inline-brief open-terminal)"
orch_fixture_shared_libs "${OLD%/scripts}"
git -C "${OLD%/scripts}" init -q
git -C "${OLD%/scripts}" config gc.auto 0
git -C "${OLD%/scripts}" config maintenance.auto false
mutate_file "$OLD/open-terminal" 'brief_path="${6:-}"' 'brief_path=""'

run_case() { # NAME SCRIPT HARNESS SHELL
  local name="$1" ot="$2" harness="$3" shell="$4"
  RUN="$TMP_ROOT/$name"
  mkdir -p "$RUN"
  RC=0
  env -i PATH="$PATH" HOME="$TMP_ROOT" LANG=C.UTF-8 timeout 20 "$BASH" "$TEST_DIR/open-terminal-brief-startup.sh" \
    --case "$RUN" "$ot" "$harness" "$shell" > "$RUN/log" 2>&1 || RC=$?
  [[ ! -f "$RUN/input-bound" ]] || cat "$RUN/input-bound" >> "$RUN/log"
}

while IFS='|' read -r harness shell; do
  run_case "$harness-${shell##*/}" "$SCRIPTS_DIR/open-terminal" "$harness" "$shell"
  assert_eq "$RC" 0 "the complete $harness brief reaches argv and the first message before ${shell##*/} startup finishes" "$RUN/log"
done <<ROWS
codex|$REAL_FISH
claude|$REAL_FISH
pi|$REAL_FISH
codex|$BASH
claude|$BASH
pi|$BASH
ROWS

run_case old-inline "$OLD/open-terminal" codex "$REAL_FISH"
assert_eq "$RC" 1 'control: the original inline brief fails the same full-message readback' "$RUN/log"
if [[ -f "$RUN/startup-released" ]] \
  && { [[ ! -f "$RUN/argv" && ! -f "$RUN/received" ]] \
    || { [[ -f "$RUN/argv" && -f "$RUN/received" ]] && ! cmp -s "$RUN/received" "$RUN/expected"; }; }; then
  # The launch command clears the screen even after successful delivery.
  # The tail can survive an earlier lost paragraph, so compare the full brief.
  pass 'control: startup completed after paste without complete brief delivery'
else
  fail 'control: startup completed after paste without complete brief delivery'
fi
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
