#!/usr/bin/env bash
# Regression tests for the claude handoff lane emitted by open-terminal.
#
# Bug (kendex#1173), two composing defects observed on a real fleet launch:
#
# 1. The claude arms rendered no permission-mode argument, so handoff sessions
#    booted in default (prompting) mode and stalled on their FIRST tool call
#    with nobody attached — launch-only autonomy was structurally impossible.
#    Model, effort, and permission posture now arrive as --launch-flags, chosen
#    per task at launch time rather than stored anywhere, and a lane whose
#    flags carry no permission bypass must warn that handoff autonomy is void.
#
# 2. The brief (initial '/orch start …' prompt) rides as a CLI arg; first-run
#    dialogs (theme/trust/browser-integration) consume it, leaving a healthy
#    TUI at an EMPTY composer while open-terminal reported success. The tmux
#    path must now verify delivery by re-capturing the pane (the brief visible
#    on a line other than the echoed launch command), re-send the brief once
#    if absent, and emit a per-lane failure + nonzero exit if still absent.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo
# so `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, and
# stubs the worktree CLI, gh, ghostty (captures the composed GUI command), and
# tmux (logs every call; serves scripted capture-pane screens) so no real
# harness is ever launched.
set -euo pipefail

# The terminal-condition tail every rendered brief carries (open-terminal start_cmd).
TC=" — complete means the PR is MERGED and the worktree cleaned up, not merely opened"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
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

# Stub bin: ghostty captures its final argument (the composed `cd ... && claude
# ...` command open_gui hands to `bash -lc`) into $OT_CAPTURE; gh exits 1 so
# resolve_repo yields empty without touching the network (the github case
# passes --repo explicitly); tmux logs every invocation into $OT_TMUX_LOG and
# serves capture-pane from numbered screen files in $OT_TMUX_CAPTURES (the
# highest-numbered file repeats for later calls).
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" > "$OT_CAPTURE"
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OT_TMUX_LOG"
# $OT_TMUX_FAIL names one tmux subcommand that fails (after logging), so a
# case can prove open-terminal checks each tmux step instead of falling
# through to a success return.
if [[ -n "${OT_TMUX_FAIL:-}" && "${1:-}" == "$OT_TMUX_FAIL" ]]; then
  exit 1
fi
case "${1:-}" in
  list-windows) echo "1" ;;
  new-window) echo "%7" ;;
  capture-pane)
    n=$(cat "$OT_TMUX_COUNT" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$OT_TMUX_COUNT"
    if [[ -f "$OT_TMUX_CAPTURES/$n" ]]; then
      cat "$OT_TMUX_CAPTURES/$n"
    else
      last="$(ls "$OT_TMUX_CAPTURES" 2>/dev/null | sort -n | tail -1)"
      [[ -n "$last" ]] && cat "$OT_TMUX_CAPTURES/$last"
    fi
    ;;
esac
exit 0
EOF
chmod +x "$BIN/ghostty" "$BIN/gh" "$BIN/tmux"

# $TERMINAL is what open_gui reaches for first, so it is PINNED to the stub on
# PATH here: unset, the branch below it would resolve whatever terminal the
# developer's desktop provides and this suite would open real windows.
export TERMINAL=ghostty

# Stub worktree CLI: `create <item>` makes and prints a temp dir.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "create" ]]; then
  d="$TMP_ROOT/wt/\${2:-unknown}"
  mkdir -p "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

# Build a temp git repo containing a copy of open-terminal + its libs, so the
# script's PROJECT_ROOT resolves to this repo. $2 optional settings body.
make_ot_repo() {
  local repo="$1" settings="${2:-}"
  mkdir -p "$repo/scripts/lib"
  cp "$SRC_OT" "$repo/scripts/open-terminal"
  cp "$SRC_LIB_DIR"/*.sh "$repo/scripts/lib/"
  chmod +x "$repo/scripts/open-terminal"
  git -C "$repo" init -q
  if [[ -n "$settings" ]]; then
    printf '%s\n' "$settings" > "$repo/kendex.settings.toml"
  fi
  printf '%s\n' "$repo/scripts/open-terminal"
}

# open_gui launches the (stubbed) terminal via `setsid ... &`, so the capture
# file lands asynchronously after open-terminal itself has exited.
wait_capture() {
  local f="$1" i
  for i in $(seq 1 50); do
    [[ -s "$f" ]] && return 0
    sleep 0.1
  done
  return 1
}

# Fresh tmux stub state (log + capture-call counter + screen dir) per case.
new_tmux_state() {
  local name="$1"
  OT_TMUX_LOG="$TMP_ROOT/$name.tmux-log"
  OT_TMUX_COUNT="$TMP_ROOT/$name.tmux-count"
  OT_TMUX_CAPTURES="$TMP_ROOT/$name.screens"
  : > "$OT_TMUX_LOG"
  rm -rf "$OT_TMUX_CAPTURES"
  mkdir -p "$OT_TMUX_CAPTURES"
  export OT_TMUX_LOG OT_TMUX_COUNT OT_TMUX_CAPTURES
}

REPO="$TMP_ROOT/repo"
OT="$(make_ot_repo "$REPO")"

# Pane screen where the brief appears ONLY inside the echoed launch command —
# exactly what a first-run dialog leaves behind. The delivery check must treat
# this as UNDELIVERED (the filter's failing input).
ECHO_SCREEN="\$ claude -n CC-737 --dangerously-skip-permissions '/orch start CC-737${TC}'
╭─ Enable browser integration? ─╮
> "
# Pane screen after the brief reached the TUI: the brief is visible on its own
# transcript line, distinct from the echoed launch command, and the response
# has begun (● transcript marker).
DELIVERED_SCREEN="> /orch start CC-737${TC}
● Reading workflows/start.md"
# Pane screen where the brief sits UNSENT in the composer's │-bordered input
# box — visible outside the echoed launch command, but with no transcript
# activity anywhere. Delivery means SUBMITTED, so this must count as
# UNDELIVERED.
COMPOSER_SCREEN="╭──────────────────────────────────────────╮
│ > /orch start CC-737${TC} │
╰──────────────────────────────────────────╯
  ? for shortcuts"
# Main TUI at a ready, EMPTY composer (the '? for shortcuts' footer is the
# readiness marker) — where the re-send must land, never in a dialog.
READY_SCREEN="╭──────────────────────────────────────────╮
│ >                                         │
╰──────────────────────────────────────────╯
  ? for shortcuts"

echo "=== open-terminal claude handoff: per-task launch flags ==="

# Case 1: linear:claude renders the autonomy flag by default.
CAP1="$TMP_ROOT/cap1"
set +e
c1_out=$(OT_CAPTURE="$CAP1" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude --launch-flags "--model opus[1m] --effort max --dangerously-skip-permissions" cc-737 2>"$TMP_ROOT/c1.err")
c1_code=$?
set -e
assert_eq "$c1_code" "0" "linear:claude launch succeeds"
if wait_capture "$CAP1"; then
  c1_cmd="$(cat "$CAP1")"
  assert_contains "$c1_cmd" "'--model' 'opus[1m]' '--effort' 'max' '--dangerously-skip-permissions' '/orch start CC-737${TC}'" \
    "linear:claude renders the caller's launch flags before the brief"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  linear:claude never invoked the terminal stub\n'
fi
assert_not_contains "$(cat "$TMP_ROOT/c1.err")" "WARNING" \
  "flags carrying a permission bypass emit no warning"

# Case 2: github:claude renders the same flag.
CAP2="$TMP_ROOT/cap2"
set +e
c2_out=$(OT_CAPTURE="$CAP2" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tracker github --repo acme/widgets --ghostty --harness claude --launch-flags "--effort max --dangerously-skip-permissions" 42 2>"$TMP_ROOT/c2.err")
c2_code=$?
set -e
assert_eq "$c2_code" "0" "github:claude launch succeeds"
if wait_capture "$CAP2"; then
  c2_cmd="$(cat "$CAP2")"
  assert_contains "$c2_cmd" "'--effort' 'max' '--dangerously-skip-permissions' '/orch start github acme/widgets#42${TC}'" \
    "github:claude renders the caller's launch flags before the brief"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  github:claude never invoked the terminal stub\n'
fi

# Case 3: a different task gets different flags on the same machine — the
# decision is per launch, so nothing is carried over from case 1 and no
# settings file participates.
CAP3="$TMP_ROOT/cap3"
set +e
c3_out=$(OT_CAPTURE="$CAP3" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude --launch-flags "--model sonnet --permission-mode bypassPermissions" cc-737 2>"$TMP_ROOT/c3.err")
c3_code=$?
set -e
assert_eq "$c3_code" "0" "a second launch with different flags succeeds"
if wait_capture "$CAP3"; then
  c3_cmd="$(cat "$CAP3")"
  assert_contains "$c3_cmd" "'--model' 'sonnet' '--permission-mode' 'bypassPermissions' '/orch start CC-737${TC}'" \
    "the flags this launch passed are the flags rendered"
  assert_not_contains "$c3_cmd" "'--effort' 'max'" \
    "no flag leaks in from another launch or a stored default"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  per-task flags case never invoked the terminal stub\n'
fi
assert_not_contains "$(cat "$TMP_ROOT/c3.err")" "WARNING" \
  "a bypassing permission mode emits no warning"

# Case 3b: with no --launch-flags at all the command is exactly what a human
# would type — no stored model, effort, or permission default appears.
CAP3B="$TMP_ROOT/cap3b"
set +e
OT_CAPTURE="$CAP3B" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude cc-737 2>"$TMP_ROOT/c3b.err"
set -e
if wait_capture "$CAP3B"; then
  c3b_cmd="$(cat "$CAP3B")"
  # The launch command must end exactly at the brief: no model, effort, or
  # permission flag may appear from anywhere but --launch-flags.
  assert_eq "${c3b_cmd##*&& }" "claude -n CC-737 '/orch start CC-737${TC}'" \
    "an unflagged launch renders no model, effort, or permission default"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  unflagged case never invoked the terminal stub\n'
fi
assert_contains "$(cat "$TMP_ROOT/c3b.err")" "handoff autonomy is void" \
  "an unflagged claude lane warns that it will stall unattended"

# Case 4: a prompting override still launches but warns loudly that handoff
# autonomy is void.
CAP4="$TMP_ROOT/cap4"
set +e
c4_out=$(OT_CAPTURE="$CAP4" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude --launch-flags "--permission-mode plan" cc-737 2>"$TMP_ROOT/c4.err")
c4_code=$?
set -e
assert_eq "$c4_code" "0" "prompting flags still launch"
if wait_capture "$CAP4"; then
  assert_contains "$(cat "$CAP4")" "'--permission-mode' 'plan' '/orch start CC-737${TC}'" \
    "prompting flags are rendered as given"
fi
c4_err="$(cat "$TMP_ROOT/c4.err")"
assert_contains "$c4_err" "WARNING" "prompting flags warn"
assert_contains "$c4_err" "handoff autonomy is void" "warning names the voided contract"

echo
echo "=== open-terminal claude handoff: tmux brief delivery ==="

# Case 5: brief visible in the pane transcript on the first verification pass —
# no re-send, success.
new_tmux_state c5
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c5_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude --launch-flags "--dangerously-skip-permissions" cc-737 2>"$TMP_ROOT/c5.err")
c5_code=$?
set -e
assert_eq "$c5_code" "0" "tmux delivered-first-pass exits 0"
assert_contains "$c5_out" "Opened tmux window 'CC-737'" "tmux window opened"
assert_not_contains "$c5_out" "Re-delivered" "no re-send when the brief is visible"
c5_log="$(cat "$OT_TMUX_LOG")"
assert_contains "$c5_log" "'--dangerously-skip-permissions' '/orch start CC-737${TC}'" \
  "tmux-sent launch command carries the flags the caller chose"
assert_contains "$c5_log" "capture-pane" "delivery was verified via capture-pane"
assert_contains "$c5_log" "capture-pane -pJ -S - -t %7" \
  "capture includes scrollback (-S -): a fast response scrolling the prompt out of the viewport must not read as undelivered"
assert_not_contains "$c5_log" "send-keys -t %7 -l /orch start CC-737" \
  "brief is not re-sent when already delivered"

# Case 6: first capture shows the brief only inside the echoed launch command
# (dialog ate the arg); the launcher waits for a ready composer, re-sends the
# brief once, and the next capture shows it in the transcript.
new_tmux_state c6
printf '%s\n' "$ECHO_SCREEN" > "$OT_TMUX_CAPTURES/1"
printf '%s\n' "$READY_SCREEN" > "$OT_TMUX_CAPTURES/2"
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/3"
set +e
c6_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c6.err")
c6_code=$?
set -e
assert_eq "$c6_code" "0" "tmux re-delivery path exits 0"
assert_contains "$c6_out" "Re-delivered brief to 'CC-737'" "re-delivery is reported"
c6_log="$(cat "$OT_TMUX_LOG")"
c6_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737" -- "$OT_TMUX_LOG")"
assert_eq "$c6_resends" "1" "brief is re-sent exactly once"
c6_full_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737${TC}" -- "$OT_TMUX_LOG")"
assert_eq "$c6_full_resends" "1" "the re-sent brief carries the terminal condition"

# Case 6b: TWO dialog screens before the composer is ready — each
# wait-composer pass sends one dismissing Enter, and the brief goes in only
# once the '? for shortcuts' footer appears. Proves brief characters are
# never typed into a dialog.
new_tmux_state c6b
printf '%s\n' "$ECHO_SCREEN" > "$OT_TMUX_CAPTURES/1"
printf '%s\n' "$ECHO_SCREEN" > "$OT_TMUX_CAPTURES/2"
printf '%s\n' "$ECHO_SCREEN" > "$OT_TMUX_CAPTURES/3"
printf '%s\n' "$READY_SCREEN" > "$OT_TMUX_CAPTURES/4"
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/5"
set +e
c6b_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=2 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c6b.err")
c6b_code=$?
set -e
assert_eq "$c6b_code" "0" "dialog-then-ready path exits 0"
assert_contains "$c6b_out" "Re-delivered brief to 'CC-737'" "re-delivery after dialog dismissal is reported"
# Bare Enters: 1 at launch + 1 dialog dismissal nudge + 1 submitting the
# re-sent brief. The brief itself is typed exactly once, after readiness.
c6b_enters="$(grep -c "send-keys -t %7 Enter$" -- "$OT_TMUX_LOG" || true)"
assert_eq "$c6b_enters" "3" "one dismissing Enter per dialog pass, none extra"
c6b_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737" -- "$OT_TMUX_LOG")"
assert_eq "$c6b_resends" "1" "brief typed exactly once, after the composer is ready"

# Case 7: the brief never leaves the echoed launch line (the TUI reaches a
# ready composer but the re-sent brief never shows as submitted) — proves
# the echoed command alone is NOT delivery evidence, and the lane fails
# loudly with a nonzero exit.
new_tmux_state c7
printf '%s\n' "$ECHO_SCREEN" > "$OT_TMUX_CAPTURES/1"
printf '%s\n' "$READY_SCREEN" > "$OT_TMUX_CAPTURES/2"
printf '%s\n' "$READY_SCREEN" > "$OT_TMUX_CAPTURES/3"
set +e
c7_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c7.err")
c7_code=$?
set -e
assert_eq "$c7_code" "1" "undelivered brief exits nonzero"
c7_err="$(cat "$TMP_ROOT/c7.err")"
assert_contains "$c7_err" "brief undelivered to 'CC-737'" "per-lane failure line names the lane"
assert_contains "$c7_err" "handoff lane(s) failed" "summary reports the failed lane count"
assert_not_contains "$c7_out" "Done: launched 1" "a failed lane is not counted as launched"
c7_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737" -- "$OT_TMUX_LOG")"
assert_eq "$c7_resends" "1" "re-send is attempted exactly once before failing"

# Case 8: the brief sitting unsent in the composer box is NOT delivery —
# submission evidence (transcript activity) is required, so the lane re-sends
# once and then fails when the screen never advances past the composer.
new_tmux_state c8
printf '%s\n' "$COMPOSER_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c8_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c8.err")
c8_code=$?
set -e
assert_eq "$c8_code" "1" "composer-only screen exits nonzero"
assert_contains "$(cat "$TMP_ROOT/c8.err")" "brief undelivered to 'CC-737'" \
  "unsubmitted composer text is reported undelivered"
# `|| true` keeps set -e alive when the buggy no-re-send path yields count 0
# (grep -c still prints the 0 but exits 1).
c8_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737" -- "$OT_TMUX_LOG" || true)"
assert_eq "$c8_resends" "1" "composer-only screen still gets exactly one re-send"

# Case 8b: a huge retained pane (larger than a pipe buffer) with the
# delivered brief near the START of history — a short-circuiting `grep -q`
# scan would SIGPIPE its upstream under pipefail (exit 141) and misread the
# submitted prompt as missing, duplicating the brief into a running session.
new_tmux_state c8b
{ printf '%s\n' "$DELIVERED_SCREEN"; awk 'BEGIN { for (i = 0; i < 20000; i++) print "transcript filler line" }'; } > "$OT_TMUX_CAPTURES/1"
set +e
c8b_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c8b.err")
c8b_code=$?
set -e
assert_eq "$c8b_code" "0" "huge scrollback with an early delivered brief exits 0"
c8b_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737" -- "$OT_TMUX_LOG" || true)"
assert_eq "$c8b_resends" "0" "no duplicate brief is sent into a running session"

echo
echo "=== open-terminal claude handoff: tmux failure detection ==="

# Case 9: new-window fails — the lane must fail instead of verifying (and
# counting) a pane that was never created.
new_tmux_state c9
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c9_out=$(TMUX=stub,1,0 OT_TMUX_FAIL=new-window ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c9.err")
c9_code=$?
set -e
assert_eq "$c9_code" "1" "new-window failure exits nonzero"
assert_contains "$(cat "$TMP_ROOT/c9.err")" "handoff lane(s) failed" \
  "new-window failure counts the lane as failed"
assert_not_contains "$c9_out" "Done: launched 1" \
  "a window that was never created is not counted as launched"

# Case 10: send-keys fails on a briefless (codex) lane — the empty-brief
# early return must not count a window whose launch keystrokes failed.
new_tmux_state c10
set +e
c10_out=$(TMUX=stub,1,0 OT_TMUX_FAIL=send-keys ORCH_TMUX_VERIFY_SECS=1 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness codex cc-737 2>"$TMP_ROOT/c10.err")
c10_code=$?
set -e
assert_eq "$c10_code" "1" "send-keys failure exits nonzero on a briefless lane"
assert_not_contains "$c10_out" "Done: launched 1" \
  "a lane whose launch keystrokes failed is not counted as launched"

echo
echo "=== open-terminal claude handoff: config validation ==="

# Case 11: launch flags carrying shell metacharacters are rejected before
# anything launches — the string is interpolated into a shell-executed launch
# command, so it must never pass through unvalidated.
CAP11="$TMP_ROOT/cap11"
set +e
c11_out=$(OT_CAPTURE="$CAP11" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude --launch-flags "--flag; touch $TMP_ROOT/pwned" cc-737 2>"$TMP_ROOT/c11.err")
c11_code=$?
set -e
assert_eq "$c11_code" "1" "metacharacter launch flags refuse to launch"
assert_contains "$(cat "$TMP_ROOT/c11.err")" "--launch-flags" \
  "rejection names the offending option"
if [[ -e "$TMP_ROOT/pwned" || -s "$CAP11" ]]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  rejected launch flags still reached a shell or terminal launch\n'
else
  PASS=$((PASS + 1))
  printf '  ok    nothing was launched with the rejected value\n'
fi

# Case 11b: a bracketed model id is an ordinary flag value, not a shell hazard.
CAP11B="$TMP_ROOT/cap11b"
set +e
OT_CAPTURE="$CAP11B" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude --launch-flags "--model opus[1m] --dangerously-skip-permissions" cc-737 2>"$TMP_ROOT/c11b.err"
c11b_code=$?
set -e
assert_eq "$c11b_code" "0" "a bracketed model id is accepted"

# Case 11c: the rendered line is executed by a shell in the launch directory,
# so a bracketed model id is glob syntax there. With the tokens unquoted, a
# single same-named file in the worktree rewrote `opus[1m]` to `opus1` and the
# lane started on a model nobody chose. Run the captured command for real, with
# the decoy planted, and read back the argv claude actually receives.
if wait_capture "$CAP11B"; then
  c11c_cmd="$(cat "$CAP11B")"
  c11c_dir="$TMP_ROOT/globbait"
  mkdir -p "$c11c_dir"
  : > "$c11c_dir/opus1"
  cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$OT_ARGV_CAPTURE"
EOF
  chmod +x "$BIN/claude"
  c11c_argv="$TMP_ROOT/c11c.argv"
  (cd "$c11c_dir" && OT_ARGV_CAPTURE="$c11c_argv" PATH="$BIN:$PATH" bash -lc "${c11c_cmd##*&& }") >/dev/null 2>&1 || true
  assert_contains "$(cat "$c11c_argv" 2>/dev/null || true)" "opus[1m]" \
    "the bracketed model id survives the shell that runs the launch command"
  assert_not_contains "$(cat "$c11c_argv" 2>/dev/null || true)" "opus1" \
    "a same-named file in the launch directory cannot rewrite the model id"
  rm -f "$BIN/claude"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  bracketed model id case never invoked the terminal stub\n'
fi

# Case 12: non-integer ORCH_TMUX_VERIFY_SECS is a clear config error, not a
# zero-pass verify loop misreported as a delivery failure.
new_tmux_state c12
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c12_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=abc PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c12.err")
c12_code=$?
set -e
assert_eq "$c12_code" "1" "non-integer verify secs exits nonzero"
assert_contains "$(cat "$TMP_ROOT/c12.err")" "ORCH_TMUX_VERIFY_SECS" \
  "verify-secs rejection names the setting"
assert_not_contains "$(cat "$TMP_ROOT/c12.err")" "brief undelivered" \
  "config error is not misreported as a delivery failure"

# Case 13: zero is rejected the same way (a zero-second loop never verifies).
new_tmux_state c13
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c13_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=0 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c13.err")
c13_code=$?
set -e
assert_eq "$c13_code" "1" "zero verify secs exits nonzero"
assert_contains "$(cat "$TMP_ROOT/c13.err")" "ORCH_TMUX_VERIFY_SECS" \
  "zero rejection names the setting"

# Case 13b: leading-zero values are base-10, not octal — '08' errored the
# arithmetic ("value too great for base") and failed a healthy lane.
new_tmux_state c13b
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c13b_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=08 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c13b.err")
c13b_code=$?
set -e
assert_eq "$c13b_code" "0" "leading-zero verify secs is base-10 and launches"
assert_not_contains "$(cat "$TMP_ROOT/c13b.err")" "value too great" \
  "no octal arithmetic error for '08'"

# Case 13c: an overflow-sized value cannot dodge the clamp into negative
# arithmetic (zero-pass loops + instant resend).
new_tmux_state c13c
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c13c_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=10000000000000000000 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c13c.err")
c13c_code=$?
set -e
assert_eq "$c13c_code" "0" "overflow-sized verify secs still launches (clamped)"
assert_contains "$(cat "$TMP_ROOT/c13c.err")" "clamped to 120" \
  "overflow-sized value is clamped loudly"
c13c_resends="$(grep -cF "send-keys -t %7 -l /orch start CC-737" -- "$OT_TMUX_LOG" || true)"
assert_eq "$c13c_resends" "0" "no instant resend from a zero-pass verify loop"

# Case 13d: a broken tmux-only setting must not abort a GUI launch that
# never reads it.
CAP13D="$TMP_ROOT/cap13d"
set +e
c13d_out=$(ORCH_TMUX_VERIFY_SECS=abc OT_CAPTURE="$CAP13D" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness claude cc-737 2>"$TMP_ROOT/c13d.err")
c13d_code=$?
set -e
assert_eq "$c13d_code" "0" "invalid verify secs does not abort a GUI launch"
assert_not_contains "$(cat "$TMP_ROOT/c13d.err")" "ORCH_TMUX_VERIFY_SECS" \
  "GUI launches never validate the tmux-only setting"

# Case 13e: a broken tmux-only setting must not abort a tmux CODEX lane —
# only Claude verification lanes read the timeout.
new_tmux_state c13e
set +e
c13e_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=abc PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness codex cc-737 2>"$TMP_ROOT/c13e.err")
c13e_code=$?
set -e
assert_eq "$c13e_code" "0" "invalid verify secs does not abort a tmux codex launch"
assert_not_contains "$(cat "$TMP_ROOT/c13e.err")" "ORCH_TMUX_VERIFY_SECS" \
  "non-claude tmux launches never validate the claude-verification timeout"

# Case 14: a runaway value is clamped loudly (the lane still verifies)
# instead of hanging the launch for hours.
new_tmux_state c14
printf '%s\n' "$DELIVERED_SCREEN" > "$OT_TMUX_CAPTURES/1"
set +e
c14_out=$(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=99999 PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tmux --harness claude cc-737 2>"$TMP_ROOT/c14.err")
c14_code=$?
set -e
assert_eq "$c14_code" "0" "clamped verify secs still launches"
assert_contains "$(cat "$TMP_ROOT/c14.err")" "clamped to 120" \
  "runaway verify secs is clamped loudly"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
