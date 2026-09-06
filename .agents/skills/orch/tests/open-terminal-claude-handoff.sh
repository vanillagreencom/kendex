#!/usr/bin/env bash
# Tests for the claude handoff lane emitted by open-terminal.
#
# Two constraints the claude arms hold:
#
# 1. A handoff session that boots in default (prompting) mode stalls on its
#    FIRST tool call with nobody attached, so launch-only autonomy needs a
#    permission-mode argument. Model, effort, and permission posture arrive as
#    --launch-flags, chosen per task at launch time rather than stored
#    anywhere, and a lane whose flags carry no permission bypass must warn
#    that handoff autonomy is void.
#
# 2. The brief (initial '/orch start …' prompt) rides as a CLI arg; first-run
#    dialogs (theme/trust/browser-integration) consume it, leaving a healthy
#    TUI at an EMPTY composer. The tmux path must verify the launch took by
#    re-capturing the pane — the brief delivered (on a line other than the
#    echoed launch command, with a response begun), or a turn in flight —
#    re-send the brief once if neither shows, and emit a per-lane failure +
#    nonzero exit if it still does not. A pane running a turn is a launched
#    lane, reported as launched and never typed into. A first-run dialog is
#    not, and animating a spinner does not make it one.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo
# so `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, and
# stubs the worktree CLI, gh, ghostty (captures the composed GUI command), and
# tmux (logs every call; serves scripted capture-pane screens) so no real
# harness is ever launched.
#
# One table: a row names the launch mode, the environment, the --launch-flags
# value, the screens the tmux stub serves in order, and the facts the launch
# must show; `observe` reads exactly those facts, so a row fails on the fact
# it names. The one probe outside the table runs a captured GUI command for
# real to read back the argv claude receives.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The composer's prompt marker is `❯` followed by a NON-BREAKING space; a
# SUBMITTED message is echoed into the transcript as `❯` followed by an
# ordinary one. That invisible character is the whole discriminator between a
# draft the operator is still typing and a prompt the TUI accepted, so both are
# spelled here as escapes rather than typed into the fixture.
NBSP=$'\xc2\xa0'
CARET=$'\xe2\x9d\xaf'
STATUS='  realwd Opus 5 (VG)                    /rc'
RULE='────────────────────────────────────────'
BRIEF='/orch start CC-737'
BRIEFN='/orch+start+CC-737'   # the brief as a needle: `+` reads as a space
RESEND="send-keys -t %7 -l $BRIEF"

# Stub bin: ghostty captures its final argument (the composed `cd ... && claude
# ...` command open_gui hands to `bash -lc`) into $OT_CAPTURE; gh exits 1 so
# resolve_repo yields empty without touching the network (the github row
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
# row can prove open-terminal checks each tmux step instead of falling
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

# A temp git repo containing a copy of open-terminal + its libs, so the
# script's PROJECT_ROOT resolves to this repo.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SRC_OT" "$REPO/scripts/open-terminal"
cp "$SRC_LIB_DIR"/*.sh "$REPO/scripts/lib/"
chmod +x "$REPO/scripts/open-terminal"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"
# Every row runs whatever binary this names; `mutant` repoints it at a copy
# with the working predicate rewritten, and `unmutate` puts it back.
OT_UNDER_TEST="$OT"

# screen NAME — prints one pane capture, by name.
#   echo       the brief appears ONLY inside the echoed launch command, which
#              is exactly what a first-run dialog leaves behind: UNDELIVERED.
#              The response marker under it is deliberate: this screen fails
#              delivery on the launch-line filter alone
#   delivered  the brief on its own transcript line, distinct from the echoed
#              launch command, and the response begun (● transcript marker)
#   composer   the brief sitting UNSENT in the │-bordered input box an older
#              TUI drew: delivery means SUBMITTED, so this is UNDELIVERED. Its
#              response marker is deliberate too: this screen fails delivery
#              on the composer-box filter alone
#   draft      the same, in the shape v2.1.261 actually draws: two rules
#              around the prompt line, no │ anywhere, and a status bar that
#              already carries ●. UNDELIVERED, and the only thing separating
#              it from `delivered` is the non-breaking space after the caret.
#              Not somewhere to type either: the composer is OCCUPIED, and
#              `send-keys -l` would append a second copy of the brief
#   earlyturn  a turn in its FIRST FRAMES: the brief submitted into the
#              transcript, a spinner frame this script deliberately does not
#              read, no token counter yet, and the composer already empty
#              again. LAUNCHED — and the screen that must never be typed into,
#              since readiness alone would send a second brief into the turn
#   working    a turn in flight: the verb, the elapsed time and the streaming
#              token counter the harness draws only while one runs. The brief
#              is nowhere but the echoed launch command, the screen a long
#              brief leaves once the TUI has redrawn its transcript line
#              beyond recognition. LAUNCHED
#   signin     a first-run sign-in step, animating the same spinner frame a
#              running turn does and carrying no token counter, no interrupt
#              hint, no brief and no composer. STUCK: the launcher's failure
#              exit is what this pane needs, and a predicate keyed on the
#              spinner would call it launched
#   ready      the main TUI at a ready, EMPTY composer in the shape v2.1.261
#              draws it, where a re-send must land. Its readiness marker is
#              the composer's own prompt line: the '? for shortcuts' footer
#              appeared on 0 of 146 captures of that build
#   ready-legacy  the same state as an older TUI drew it, on the footer alone
#   huge       delivered, then a pane larger than a pipe buffer: a
#              short-circuiting scan would SIGPIPE its upstream under pipefail
#              and misread the submitted prompt as missing
screen() {
  case "$1" in
    echo) printf '%s\n' "\$ claude -n CC-737 --dangerously-skip-permissions '$BRIEF'" '● Reading workflows/start.md' '╭─ Enable browser integration? ─╮' '> ' ;;
    delivered) printf '%s\n' "$CARET $BRIEF" '● Reading workflows/start.md' ;;
    composer) printf '%s\n' '● Reading workflows/start.md' '╭──────────────────────────────────────────╮' "│ > $BRIEF │" '╰──────────────────────────────────────────╯' '  ? for shortcuts' ;;
    earlyturn) printf '%s\n' "$CARET $BRIEF" '✶ Orchestrating…' "$RULE" "$CARET$NBSP" "$RULE" "$STATUS" ;;
    draft) printf '%s\n' '● Reading workflows/start.md' "$RULE" "$CARET$NBSP$BRIEF" "$RULE" "$STATUS" ;;
    working) printf '%s\n' "\$ claude -n CC-737 '$BRIEF'" '✻ Orchestrating… (3s · ↓ 79 tokens · thinking with high effort)' ;;
    signin) printf '%s\n' '  Select login method' '✻ Opening browser to sign in…' ;;
    ready) printf '%s\n' "$RULE" "$CARET$NBSP" "$RULE" "$STATUS" ;;
    ready-legacy) printf '%s\n' '╭──────────────────────────────────────────╮' '│ >                                         │' '╰──────────────────────────────────────────╯' '  ? for shortcuts' ;;
    huge) screen delivered; awk 'BEGIN { for (i = 0; i < 20000; i++) print "transcript filler line" }' ;;
    *) echo "screen: unknown capture $1" >&2; exit 1 ;;
  esac
}

# --- harness -----------------------------------------------------------------

# run MODE ENV FLAGS SCREENS — one launch. MODE is gui, github (gui, the
# github tracker), tmux or tmux-codex; the GUI modes clear TMUX so the suite
# reads the same inside and outside a tmux session; ENV a comma-separated list of
# VAR=value pairs or `-`; FLAGS the --launch-flags value or `-` for none;
# SCREENS the comma-separated captures the tmux stub serves in order, or `-`.
# OUT, RC, ERR (a file), CAP (the GUI command's capture file) and the tmux
# log are what `observe` reads.
RUN_SEQ=0
run() {
  local mode="$1" envspec="$2" flags="$3" screens="$4" args=() envs=() pair i=0 name
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN/screens"
  ERR="$RUN/stderr"
  CAP="$RUN/capture"
  OT_TMUX_LOG="$RUN/tmux-log"
  OT_TMUX_COUNT="$RUN/tmux-count"
  OT_TMUX_CAPTURES="$RUN/screens"
  : > "$OT_TMUX_LOG"
  export OT_TMUX_LOG OT_TMUX_COUNT OT_TMUX_CAPTURES
  if [[ "$screens" != - ]]; then
    IFS=',' read -ra names <<<"$screens"
    for name in "${names[@]}"; do screen "$name" > "$RUN/screens/$((++i))"; done
  fi
  case "$mode" in
    gui) envs=(TMUX=); args=(--ghostty --harness claude) ;;
    github) envs=(TMUX=); args=(--tracker github --repo acme/widgets --ghostty --harness claude) ;;
    tmux) envs=(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1); args=(--tmux --harness claude) ;;
    tmux-codex) envs=(TMUX=stub,1,0 ORCH_TMUX_VERIFY_SECS=1); args=(--tmux --harness codex) ;;
    *) echo "run: unknown mode $mode" >&2; exit 1 ;;
  esac
  if [[ "$envspec" != - ]]; then
    IFS=',' read -ra pairs <<<"$envspec"
    for pair in "${pairs[@]}"; do envs+=("$pair"); done
  fi
  [[ "$flags" == - ]] || args+=(--launch-flags "$flags")
  if [[ "$mode" == github ]]; then args+=(42); else args+=(cc-737); fi
  set +e
  OUT=$(env ${envs[@]+"${envs[@]}"} OT_CAPTURE="$CAP" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_UNDER_TEST" "${args[@]}" 2>"$ERR")
  RC=$?
  set -e
}

# open_gui launches the (stubbed) terminal via `setsid ... &`, so the capture
# file lands asynchronously after open-terminal itself has exited.
wait_capture() {
  local i
  for i in $(seq 1 50); do
    [[ -s "$CAP" ]] && return 0
    sleep 0.1
  done
  return 1
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (in a needle `+` reads as a space):
#   rc              exit status
#   out~<text>      whether stdout carries <text>
#   stderr~<text>   whether stderr carries <text>
#   launched        whether the GUI terminal stub was invoked
#   cmd~<text>      whether the captured GUI command carries <text>, or
#                   `nocapture` when the stub was never invoked
#   tail            the captured GUI command after its last `&& `
#   log~<text>      whether the tmux log carries <text>
#   resends         how many tmux calls re-sent the brief
#   fullresends     how many of those were exactly the brief, nothing more
#   enters          how many bare Enters were sent
observe() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    needle="${name#*~}"; needle="${needle//+/ }"
    case "$name" in
      rc) value="$RC" ;;
      out~*) value="$(grep -qF -- "$needle" <<<"$OUT" && echo true || echo false)" ;;
      stderr~*) value="$(grep -qF -- "$needle" "$ERR" && echo true || echo false)" ;;
      launched) value="$(wait_capture && echo true || echo false)" ;;
      cmd~*) if wait_capture; then value="$(grep -qF -- "$needle" "$CAP" && echo true || echo false)"; else value=nocapture; fi ;;
      tail) if wait_capture; then value="$(cat "$CAP")"; value="${value##*&& }"; value="${value// /+}"; else value=nocapture; fi ;;
      log~*) value="$(grep -qF -- "$needle" "$OT_TMUX_LOG" && echo true || echo false)" ;;
      resends) value="$(grep -cF -- "$RESEND" "$OT_TMUX_LOG" || true)" ;;
      fullresends) value="$(grep -cFx -- "$RESEND" "$OT_TMUX_LOG" || true)" ;;
      enters) value="$(grep -c 'send-keys -t %7 Enter$' "$OT_TMUX_LOG" || true)" ;;
      *) echo "observe: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# mutant NAME FILE SED WHAT — stage open-terminal and its libs in a git repo of
# its own, so PROJECT_ROOT still resolves hermetically, with SED applied to
# FILE (a path under scripts/), and point every following row at it. The copy
# is proven to differ from the original first, so a mutation whose anchor moved
# cannot pass as a silent no-op.
mutant() {
  local name="$1" file="$2" expr="$3" what="$4" dir src
  dir="$TMP_ROOT/mutants/$name"
  src="$SCRIPTS_DIR/$file"
  mkdir -p "$dir/scripts/lib"
  cp "$SRC_OT" "$dir/scripts/open-terminal"
  cp "$SRC_LIB_DIR"/*.sh "$dir/scripts/lib/"
  sed "$expr" "$src" > "$dir/scripts/$file"
  if cmp -s "$src" "$dir/scripts/$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  control: the %s mutant is byte-identical to %s\n' "$name" "$file"
  else
    pass "control: the $name mutant really rewrites $what"
  fi
  chmod +x "$dir/scripts/open-terminal"
  git -C "$dir" init -q
  OT_UNDER_TEST="$dir/scripts/open-terminal"
}

unmutate() { OT_UNDER_TEST="$OT"; }

# launch_table ROW... — `label|mode|env|flags|screens|expect`, one launch and
# one assertion per row.
launch_table() {
  local row label mode envspec flags screens expect
  for row in "$@"; do
    IFS='|' read -r label mode envspec flags screens expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'launch_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    run "$mode" "$envspec" "$flags" "$screens"
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== open-terminal claude handoff: per-task launch flags ==="
# The flags this launch passed are the flags rendered, before the brief, and
# nothing is carried over from another launch or a stored default: with no
# --launch-flags the command is exactly what a human would type. A lane whose
# flags carry no permission bypass warns that handoff autonomy is void; a
# prompting override still launches. Flags carrying shell metacharacters are
# rejected before anything launches, since the string is interpolated into a
# shell-executed launch command; a bracketed model id is an ordinary value.
# The tmux-only verify timeout is never validated on a GUI launch.
launch_table \
  "linear:claude renders the caller's launch flags before the brief, no warning|gui|-|--model opus[1m] --effort max --dangerously-skip-permissions|-|rc=0 cmd~'--model'+'opus[1m]'+'--effort'+'max'+'--dangerously-skip-permissions'+'$BRIEFN'=true stderr~WARNING=false" \
  "github:claude renders the same|github|-|--effort max --dangerously-skip-permissions|-|rc=0 cmd~'--effort'+'max'+'--dangerously-skip-permissions'+'/orch+start+github+acme/widgets#42'=true" \
  "a second launch renders its own flags, nothing leaking from another launch or a stored default|gui|-|--model sonnet --permission-mode bypassPermissions|-|rc=0 cmd~'--model'+'sonnet'+'--permission-mode'+'bypassPermissions'+'$BRIEFN'=true cmd~'--effort'+'max'=false stderr~WARNING=false" \
  "an unflagged launch renders no model, effort or permission default, and warns it will stall unattended|gui|-|-|-|tail=claude+-n+CC-737+'$BRIEFN' stderr~handoff+autonomy+is+void=true" \
  "a prompting override still launches, rendered as given, and warns loudly|gui|-|--permission-mode plan|-|rc=0 cmd~'--permission-mode'+'plan'+'$BRIEFN'=true stderr~WARNING=true stderr~handoff+autonomy+is+void=true" \
  "metacharacter launch flags refuse to launch, naming the option, and nothing runs|gui|-|--flag; touch $TMP_ROOT/pwned|-|rc=1 stderr~--launch-flags=true launched=false" \
  "a broken tmux-only verify setting does not abort a GUI launch, which never reads it|gui|ORCH_TMUX_VERIFY_SECS=abc|-|-|rc=0 stderr~ORCH_TMUX_VERIFY_SECS=false"

# The rendered line is executed by a shell in the launch directory, so a
# bracketed model id is glob syntax there. With the tokens unquoted, a single
# same-named file in the worktree rewrites `opus[1m]` to `opus1` and the lane
# starts on a model nobody chose. Launch with a bracketed model id, run the
# captured command for real with the decoy planted, and read back the argv
# claude receives.
run gui - "--model opus[1m] --dangerously-skip-permissions" -
if wait_capture; then
  globbait="$TMP_ROOT/globbait"
  mkdir -p "$globbait"
  : > "$globbait/opus1"
  printf '#!/usr/bin/env bash\nprintf '"'"'%%s\\n'"'"' "$@" > "$OT_ARGV_CAPTURE"\n' > "$BIN/claude"
  chmod +x "$BIN/claude"
  cmd="$(cat "$CAP")"
  (cd "$globbait" && OT_ARGV_CAPTURE="$TMP_ROOT/argv" PATH="$BIN:$PATH" bash -lc "${cmd##*&& }") >/dev/null 2>&1 || true
  rm -f "$BIN/claude"
  assert_eq "$(tr '\n' ' ' < "$TMP_ROOT/argv" 2>/dev/null || echo unrun)" "-n CC-737 --model opus[1m] --dangerously-skip-permissions $BRIEF " \
    "the argv claude receives is the flags as given: a same-named file cannot rewrite the model id"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  the bracketed model id row never invoked the terminal stub, so its argv cannot be read\n'
fi

echo "=== open-terminal claude handoff: tmux brief delivery ==="
# The brief visible in the transcript on the first verification pass is
# delivery: no re-send, and the capture includes scrollback (-S -), since a
# fast response scrolling the prompt out of the viewport must not read as
# undelivered. A turn in flight is the other, independent proof, whether it
# was running from the first pass or starts while the launcher waits for a
# composer: launched, no re-send, and no further keystroke into a session that
# would take it mid-turn. A first-run dialog is not a turn, however it
# animates. The brief only inside the echoed launch command is what a
# dialog leaves: the launcher waits for a ready composer, sending one
# dismissing Enter per dialog pass, types the brief once after readiness
# (bare Enters: one at launch, one per dialog nudge, one submitting the
# re-send; the verify loop consumes one screen per second before the
# composer wait begins, so two dialog passes take five echo screens), and fails the lane loudly if the re-sent brief never shows as
# submitted, or the composer never becomes ready. Unsent composer text is
# not delivery either, nor a brief with no response begun. Each tmux step is
# checked, and each failure names its own cause: a window never created, or launch keystrokes that failed on a
# briefless lane, is a failed lane, never a launched one.
launch_table \
  "the brief visible on the first pass is delivery: no re-send, the flags sent, scrollback captured|tmux|-|--dangerously-skip-permissions|delivered|rc=0 out~Opened+tmux+window+'CC-737'=true out~Re-delivered=false log~'--dangerously-skip-permissions'+'$BRIEFN'=true log~capture-pane+-pJ+-S+-+-t+%7=true resends=0" \
  "a dialog ate the brief: the launcher waits for a ready composer and re-sends exactly the start command once|tmux|-|-|echo,ready,delivered|rc=0 out~Re-delivered+brief+to+'CC-737'=true resends=1 fullresends=1" \
  "two dialog passes before readiness: one dismissing Enter per pass, the brief typed once after|tmux|ORCH_TMUX_VERIFY_SECS=3|-|echo,echo,echo,echo,echo,ready,delivered|rc=0 out~Re-delivered+brief+to+'CC-737'=true enters=4 resends=1" \
  "the echoed command alone is not delivery: one re-send, then a loud per-lane failure|tmux|-|-|echo,ready,ready|rc=1 stderr~brief+undelivered+to+'CC-737'=true stderr~handoff+lane(s)+failed=true out~Done:+launched+1=false resends=1" \
  "unsent composer text is not delivery: one re-send, then the failure|tmux|-|-|composer|rc=1 stderr~brief+undelivered+to+'CC-737'=true resends=1" \
  "a brief left sitting in the composer is submitted by the nudge, not typed a second time|tmux|ORCH_TMUX_VERIFY_SECS=2|-|draft,draft,draft,delivered|rc=0 out~Done:+launched+1=true resends=0 enters=2" \
  "a composer that stays occupied is a failed lane, and never has a second brief typed into it|tmux|-|-|draft|rc=1 stderr~never+reached+a+ready+composer=true resends=0" \
  "a lane that comes up on the very last nudge is seen, not reported stuck|tmux|-|-|echo,echo,delivered|rc=0 out~Confirmed+'CC-737'+launched=true resends=0 enters=2" \
  "an older TUI's shortcuts footer is still read as ready|tmux|-|-|echo,ready-legacy,delivered|rc=0 out~Re-delivered+brief+to+'CC-737'=true resends=1" \
  "a turn in its first frames is launched and never typed into, before any counter or marker shows|tmux|-|-|earlyturn|rc=0 out~Done:+launched+1=true resends=0 enters=1" \
  "a turn in flight is a launched lane whatever its transcript line reads as: no re-send|tmux|-|-|working|rc=0 out~Done:+launched+1=true resends=0 enters=1" \
  "a lane that starts working while the launcher waits for a composer ends the wait launched, nothing typed into it|tmux|-|-|echo,working|rc=0 out~Confirmed+'CC-737'+launched=true resends=0 enters=1" \
  "a composer that never becomes ready is a failed lane, named as stuck|tmux|-|-|echo,echo|rc=1 stderr~never+reached+a+ready+composer=true out~Done:+launched+1=false" \
  "a sign-in step animating a spinner is still a stuck lane, not a working one|tmux|-|-|signin|rc=1 stderr~never+reached+a+ready+composer=true out~Done:+launched+1=false" \
  "a huge scrollback with the delivered brief near its start is delivery: no duplicate brief|tmux|-|-|huge|rc=0 resends=0" \
  "a window that was never created is a failed lane, not a launched one|tmux|OT_TMUX_FAIL=new-window|-|delivered|rc=1 stderr~new-window+failed=true stderr~handoff+lane(s)+failed=true out~Done:+launched+1=false" \
  "launch keystrokes failing on a briefless lane is a failed lane too|tmux-codex|OT_TMUX_FAIL=send-keys|-|-|rc=1 stderr~send-keys+failed+launching=true out~Done:+launched+1=false"

echo "=== the turn-in-flight reading can fail, both ways ==="
# `pane_working` is the whole of it, so it is the mutation both controls take.
# Cut it to always-false and the two working rows go back to the false alarm
# this closed: a healthy mid-turn lane reported as a stuck composer, exit 1.
mutant working-blind lib/pane-working.sh 's/^pane_working() {/pane_working() { return 1;/' pane_working
launch_table \
  "control: with the turn reading gone, a turn in flight fails as a stuck composer|tmux|-|-|working|rc=1 stderr~never+reached+a+ready+composer=true out~Done:+launched+1=false" \
  "control: and so does a lane that starts working during the composer wait|tmux|-|-|echo,working|rc=1 stderr~never+reached+a+ready+composer=true"
# Widen it to the spinner frames — the shape this fix was first written with —
# and the failure exit stops covering the pane it is for: Claude Code animates
# one frame set across every long-running screen, sign-in included, so the
# stuck lane above reports launched and an unattended login prompt is called a
# success.
mutant working-spinner lib/pane-working.sh "s/^pane_working() {/pane_working() { grep -q '\xe2\x9c\xbb' <<<\"\$1\" \&\& return 0;/" pane_working
launch_table \
  "control: keyed on the spinner instead, the sign-in step reports launched|tmux|-|-|signin|rc=0 out~Done:+launched+1=true stderr~never+reached+a+ready+composer=false"
# The composer read can fail the same two ways. Drop the composer filter and
# the draft above passes as a submitted prompt: the │ the old filter looks for
# is on none of the 146 captures of v2.1.261, so nothing else stands between a
# half-typed brief and a lane called launched.
mutant composer-blind open-terminal 's/ | grep -Ev -- "\$COMPOSER_RE"//' 'the composer filter'
launch_table \
  "control: without the composer filter, a draft the operator is still typing reports launched|tmux|-|-|draft|rc=0 out~Done:+launched+1=true resends=0"
# Key readiness on the old footer alone and the re-send path goes unreachable:
# v2.1.261 never draws it, so a dialog that ate the brief can only ever reach
# the failure exit, never the recovery the launcher exists to perform.
mutant ready-legacy-only open-terminal 's/^READY_RE=.*/READY_RE="\\? for shortcuts"/' 'the readiness marker'
launch_table \
  "control: keyed on the old footer alone, a dialog that ate the brief can never be recovered|tmux|-|-|echo,ready,ready|rc=1 stderr~never+reached+a+ready+composer=true resends=0"
# Readiness that does not insist on an EMPTY composer types into an occupied
# one, and `send-keys -l` appends: the lane is handed
# `/orch start CC-737/orch start CC-737` and submits it.
mutant ready-occupied open-terminal 's/^READY_RE=.*/READY_RE="$COMPOSER_RE"/' 'the empty-composer requirement'
launch_table \
  "control: readiness without the empty test types a second brief into an occupied composer|tmux|-|-|draft|resends=1"
# Test the nudge budget BEFORE the capture and the last Enter's result is
# never looked at: the lane that came up on it is reported stuck.
mutant last-pass-blind open-terminal 's@^    screen="$(tmux capture-pane -pJ -t "$pane" 2>/dev/null)" || return 1$@    (( waited < TMUX_VERIFY_SECS )) || return 1; screen="$(tmux capture-pane -pJ -t "$pane" 2>/dev/null)" || return 1@;/^    (( waited < TMUX_VERIFY_SECS )) || return 1$/d' 'the read-before-budget order'
launch_table \
  "control: deciding before the capture reports a lane that came up on the last nudge as stuck|tmux|-|-|echo,echo,delivered|rc=1 stderr~never+reached+a+ready+composer=true"
# Require a transcript-activity marker on top of the brief and the first
# frames of a turn read as an idle, ready composer: the counter is not drawn
# yet, the spinner frame is one this script does not read, and the composer is
# already empty — so a second brief goes into the turn.
mutant activity-required open-terminal 's@^  \[\[ "$filtered" == \*"$brief"\* \]\]$@  [[ "$filtered" == *"$brief"* ]] || return 1; [[ "$screen" == *"\xe2\x97\x8f"* ]]@' 'the delivery read'
launch_table \
  "control: with a marker required on top, a turn in its first frames takes a second brief|tmux|-|-|earlyturn|resends=1"
unmutate

echo "=== open-terminal claude handoff: the verify timeout ==="
# ORCH_TMUX_VERIFY_SECS is validated where it is read, and only there: a
# non-integer or zero is a config error naming the setting, never a
# zero-pass loop misreported as a delivery failure; leading zeros are base
# 10, not octal, and never inflate the digit count into the clamp; a runaway or overflow-sized value is clamped loudly rather
# than hanging the launch or wrapping into negative arithmetic and an
# instant resend. A codex tmux lane never reads it.
launch_table \
  "a non-integer is a config error naming the setting, not a delivery failure|tmux|ORCH_TMUX_VERIFY_SECS=abc|-|delivered|rc=1 stderr~ORCH_TMUX_VERIFY_SECS=true stderr~brief+undelivered=false" \
  "zero is rejected the same way|tmux|ORCH_TMUX_VERIFY_SECS=0|-|delivered|rc=1 stderr~ORCH_TMUX_VERIFY_SECS=true" \
  "leading zeros are base 10, not octal, and do not count toward the clamp|tmux|ORCH_TMUX_VERIFY_SECS=0000000000000000008|-|delivered|rc=0 stderr~value+too+great=false stderr~clamped=false" \
  "an overflow-sized value is clamped loudly, with no instant resend|tmux|ORCH_TMUX_VERIFY_SECS=10000000000000000000|-|delivered|rc=0 stderr~clamped+to+120=true resends=0" \
  "a runaway value is clamped loudly and still verifies|tmux|ORCH_TMUX_VERIFY_SECS=99999|-|delivered|rc=0 stderr~clamped+to+120=true" \
  "a codex tmux lane never validates the claude-verification timeout|tmux-codex|ORCH_TMUX_VERIFY_SECS=abc|-|-|rc=0 stderr~ORCH_TMUX_VERIFY_SECS=false"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
