#!/usr/bin/env bash
# Tests for the pane side of orch/scripts/oversee-watch: what the watch reads
# off a lane's tmux window. Spent-account banners and their reset clauses are
# oversee_watch_usage_limit.sh; the GitHub side (pr-watch, merged, the
# heartbeat and the process-wide failures) is oversee_watch.sh. All build
# their sandbox from lib/oversee-watch-harness.sh.
#
# Covered here: window absence versus probe failure; shell-exit debounce; live
# versus answered prompts for both harnesses; idle-return debounce; scrollback
# boundaries; and one-capture classification.
#
# One table. A row names a screen (a pane fixture kept whole in `screen`), the
# lane it sits in (the pane's foreground command, its children, the windows
# the server holds), how many passes the watch takes, and the facts the run
# must show; `watch` reads exactly those facts, so a row fails on the fact it
# names. A `cont` row is the next run over the row above it, same state.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

HEARTBEAT1='EVENT+heartbeat+loops=1+interval=0s+since=none'
HEARTBEAT2='EVENT+heartbeat+loops=2+interval=0s+since=none'
COMPOSER='\xe2\x9d\xaf\xc2\xa0'          # Claude's composer: `❯` + U+00A0
DIALOG='Do you want to proceed?\n   ❯ 1. Yes\n     2. No'
IDLE_DONE='⏺ Done: the PR is merged and the worktree is gone.'

# screen NAME [LANE] — writes the pane fixture NAME, whole, as the screen of
# LANE (gh-2 unless named). `codex:<capture>` is one of the byte-exact Codex
# captures under fixtures/, checked for the line the row's reading rests on:
# a predicate reasoned instead of measured is wrong about the screen it
# claims to describe. `-` leaves the harness default, a lane mid-turn.
screen() {
  local pane="$STUB_DIR/pane-${2:-gh-2}.txt"
  case "$1" in
    -) ;;
    exited_banner) printf '%b\n' '⏺ I will keep going.' '' "You've hit your session limit · resets 21:00" '$ ' > "$pane" ;;
    fish_prompt) printf '%b\n' 'method@box ~/dev/kendex (main)>' > "$pane" ;;
    # a pane holding only blank lines: the pane tail is a grep miss there
    blank) printf '%b\n' '   ' '' '\t' > "$pane" ;;
    prompt) printf '%b\n' "$DIALOG" > "$pane" ;;
    question) printf '%b\n' '⏺ I found two ways to do this.' '' "$DIALOG" > "$pane" ;;
    # a dialog the lane already answered, still on the screen above its turn
    answered_dialog) printf '%b\n' '⏺ I found two ways to do this.' "$DIALOG" '❯ go with the first one' "$IDLE_DONE" "$COMPOSER" '  bypass permissions on' > "$pane" ;;
    live_dialog) printf '%b\n' '❯ go ahead and refactor it' '⏺ I found two ways to do this.' "$DIALOG" > "$pane" ;;
    idle) printf '%b\n' "$IDLE_DONE" "$COMPOSER" '  bypass permissions on' > "$pane" ;;
    idle_short) printf '%b\n' '⏺ Done.' "$COMPOSER" > "$pane" ;;
    idle_merged) printf '%b\n' '⏺ Done: the PR is merged.' "$COMPOSER" > "$pane" ;;
    # the streaming token counter of the status line, over the same composer
    working_counter) printf '%b\n' '✶ Germinating… (29m 16s \xc2\xb7 ↓ 58.7k tokens)' "$COMPOSER" > "$pane" ;;
    # the other two working shapes, one per lane
    working_hints)
      printf '%b\n' '⏺ Thinking (esc to interrupt)' "$COMPOSER" > "$STUB_DIR/pane-gh-1.txt"
      printf '%b\n' '⎿  (ctrl+b ctrl+b (twice) to run in background)' "$COMPOSER" > "$pane" ;;
    # one screen per pass: idle, then working again
    idle_then_working)
      printf '%b\n' '⏺ Done.' "$COMPOSER" > "$STUB_DIR/pane-gh-2.1.txt"
      printf '%b\n' '✶ Germinating… (2m 4s \xc2\xb7 ↓ 5.0k tokens)' "$COMPOSER" > "$STUB_DIR/pane-gh-2.2.txt" ;;
    working_above_turn) printf '%b\n' '⏺ Thinking (esc to interrupt)' '❯ actually stop there and write it up' "$IDLE_DONE" "$COMPOSER" '  bypass permissions on' > "$pane" ;;
    working_below_turn) printf '%b\n' '❯ go ahead and refactor it' '⏺ Thinking (esc to interrupt)' "$COMPOSER" > "$pane" ;;
    # a submitted turn opens with the composer's marker, and nothing below it
    prompt_above_turn) printf '%b\n' '❯ run the suite' '⏺ Bash(cargo test)' '  ⎿ Compiling kendex v5.0.0' > "$pane" ;;
    codex:*)
      local capture="$CODEX_PANES/${1#codex:}.txt"
      case "$1" in
        # Codex draws no submit hint at its composer, so the marker alone
        # carries idleness; a busy Codex screen draws that composer too, so
        # the interrupt hint is what keeps a busy lane out
        codex:codex-idle-after-turn) ! grep -qF 'to submit message' "$capture" || { echo "screen: $1 carries a submit hint; the marker-alone reading no longer holds" >&2; exit 1; } ;;
        codex:codex-working) grep -qF '› Ask Codex to do anything' "$capture" && grep -qF 'esc to interrupt' "$capture" || { echo "screen: $1 lost its composer or interrupt hint; the working row would pin nothing" >&2; exit 1; } ;;
      esac
      cat "$capture" > "$pane" ;;
    *) echo "screen: unknown fixture $1" >&2; exit 1 ;;
  esac
}

# lane NAME — stages what surrounds the pane: the foreground command tmux
# reports for gh-2 (claude by default), what runs under it, and the windows
# the server holds. WATCHED is the lane list the run names.
WATCHED="gh-1 gh-2"
lane() {
  WATCHED="gh-1 gh-2"
  case "$1" in
    claude) ;;
    codex) printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt" ;;
    bash) printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt" ;;
    # a login shell reports itself as -bash
    login) printf -- '-bash\n' > "$STUB_DIR/cmd-gh-2.txt" ;;
    zsh) printf 'zsh\n' > "$STUB_DIR/cmd-gh-2.txt" ;;
    # a shell on the first pass only, then the live command
    bash_once) printf 'bash\n' > "$STUB_DIR/cmd-gh-2.1.txt" ;;
    # the harness resumed from an interactive prompt: the shell stays the
    # pane process with the harness as its child
    fish_child) printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"; printf '2747883\n' > "$STUB_DIR/kids-9002.txt" ;;
    fish) printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt" ;;
    # a child probe that cannot run: pgrep's syntax-error status, or its fatal one
    fish_probe2) printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"; : > "$STUB_DIR/probe-fail-9002" ;;
    fish_probe3) printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"; printf '3' > "$STUB_DIR/probe-fail-9002" ;;
    # a liveness reply that is not `<pid> <command>`
    obs:*) printf '%s\n' "${1#obs:}" > "$STUB_DIR/obs-gh-2.txt" ;;
    nocmd) rm -f "$STUB_DIR/cmd-gh-2.txt" ;;
    # the caller's session holds gh-1 only
    nowindow) printf 'gh-1\n' > "$STUB_DIR/windows.txt" ;;
    # gh-2 lives in session `arch`, at a bare shell, watched by tmux's target form
    arch)
      printf 'gh-1\n' > "$STUB_DIR/windows.txt"
      printf 'gh-2\n' > "$STUB_DIR/windows-arch.txt"
      printf 'bash\n' > "$STUB_DIR/cmd-arch:gh-2.txt"
      printf '$ \n' > "$STUB_DIR/pane-arch:gh-2.txt"
      WATCHED="gh-1 arch:gh-2" ;;
    # ...the same, looked up unqualified; and after tmux destroyed the session
    arch_bare) WATCHED="gh-1 gh-2" ;;
    arch_gone) rm -f "$STUB_DIR/windows-arch.txt"; WATCHED="gh-1 arch:gh-2" ;;
    # two lanes whose names differ only outside the filename-safe set
    collide)
      printf 'a+b\na@b\n' > "$STUB_DIR/windows.txt"
      printf 'claude\n' > "$STUB_DIR/cmd-a+b.txt"
      printf 'claude\n' > "$STUB_DIR/cmd-a@b.txt"
      printf '%b\n' "$DIALOG" > "$STUB_DIR/pane-a+b.txt"
      printf '⏺ working on it\n' > "$STUB_DIR/pane-a@b.txt"
      WATCHED="a+b a@b" ;;
    *) echo "lane: unknown lane $1" >&2; exit 1 ;;
  esac
}

# run LOOPS — one watch of LOOPS passes over the watched lanes; OUT, RC and
# ERR (a file) are what `watch` reads.
RUN_SEQ=0
run() {
  local lanes
  read -ra lanes <<<"$WATCHED"
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch -- --max-loops "$1" "${lanes[@]}" 2>"$ERR")" && RC=0 || RC=$?
}

# watch EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (in a needle `+` reads as a space):
#   rc              exit status
#   first           the first stdout line, or `none`
#   lines           how many stdout lines the run printed
#   out~<text>      whether stdout carries <text>
#   stderr~<text>   whether stderr carries <text>
#   notes~<text>    how many stderr lines carry <text>
#   probes          how many child probes the run made
#   probed~<pid>    whether a child probe named <pid>
watch() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    needle="${name#*~}"; needle="${needle//+/ }"
    case "$name" in
      rc) value="$RC" ;;
      first) value="$(head -n 1 <<<"$OUT")"; value="${value:-none}"; value="${value// /+}" ;;
      lines) value="$(printf '%s' "$OUT" | grep -c '' || true)" ;;
      out~*) value="$(grep -qF -- "$needle" <<<"$OUT" && echo true || echo false)" ;;
      stderr~*) value="$(grep -qF -- "$needle" "$ERR" && echo true || echo false)" ;;
      notes~*) value="$(grep -cF -- "$needle" "$ERR" || true)" ;;
      probes) value="$([[ -e "$STUB_DIR/pgrep.calls" ]] && grep -c . "$STUB_DIR/pgrep.calls" || echo 0)" ;;
      probed~*) value="$([[ -e "$STUB_DIR/pgrep.calls" ]] && grep -qF -- "$needle" "$STUB_DIR/pgrep.calls" && echo true || echo false)" ;;
      *) echo "watch: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# lane_table ROW... — `label|pass|screen|lane|loops|expect`. `pass` is `new`
# (a fresh sandbox) or `cont` (the next run over the row above, same state,
# fresh captures).
CASE_SEQ=0
lane_table() {
  local row label pass name which loops expect
  for row in "$@"; do
    IFS='|' read -r label pass name which loops expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'lane_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    case "$pass" in
      new) new_case "lane_$((++CASE_SEQ))" ;;
      cont) rm -f "$STUB_DIR"/pane-*.calls "$STUB_DIR"/cmd-*.calls "$STUB_DIR"/pgrep.calls ;;
      *) echo "lane_table: unknown pass $pass in $row" >&2; exit 1 ;;
    esac
    lane "$which"
    screen "$name"
    run "$loops"
    assert_eq "$(watch "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== oversee-watch lanes: the window, and the harness in it ==="
# A missing window is the event; a window in another session is watched under
# tmux's `session:window` form and reported under the name given, and tmux
# destroying a session with its last window is that window gone, not a
# failure of the pass. A live window whose pane is a bare shell is
# lane-exited, on two consecutive passes: a live harness can hold a shell in
# the foreground for one poll, and relaunching a working lane costs more than
# a wait. A shell with a child under it is the harness resumed from a prompt,
# probed once per bare-shell lane per pass; a probe that cannot run at all is
# not an answer, and its note carries the status that occurred (pgrep's 2 for
# a syntax error, 3 for a fatal one, 127 for a missing binary).
lane_table \
  "a missing lane window is the event|new|-|nowindow|2|rc=0 first=EVENT+window-gone+gh-2 lines=1" \
  "a window in another session is watched under the name given|new|-|arch|2|rc=0 first=EVENT+lane-exited+arch:gh-2" \
  "the bare name still means the caller's session, where it does not exist|cont|-|arch_bare|2|first=EVENT+window-gone+gh-2 lines=1" \
  "a lane whose session is gone is reported gone, not a failed pass|cont|-|arch_gone|2|rc=0 first=EVENT+window-gone+arch:gh-2 lines=1" \
  "a bare shell on two consecutive passes is lane-exited, the pane tail carrying the reason, never window-gone, usage-limit or idle|new|exited_banner|bash|2|rc=0 first=EVENT+lane-exited+gh-2 out~session+limit=true out~EVENT+window-gone=false out~EVENT+usage-limit=false out~EVENT+idle-after-return=false" \
  "one pass of shell is not the event|new|-|bash|1|first=$HEARTBEAT1 out~EVENT+lane-exited=false" \
  "a shell then a live command is a transient, not an exit|new|-|bash_once|2|first=$HEARTBEAT2 out~EVENT+lane-exited=false" \
  "a login shell (-bash) counts as a bare shell|new|-|login|2|first=EVENT+lane-exited+gh-2" \
  "a shell pane with a child is a live lane, probed once per pass, the harness pane never probed|new|-|fish_child|2|first=$HEARTBEAT2 out~EVENT+lane-exited=false probes=2 probed~9001=false" \
  "a lane whose child probe cannot run stays watched, the note naming the status once per run|new|-|fish_probe2|2|first=$HEARTBEAT2 out~EVENT+lane-exited=false stderr~could+not+list+the+children+of+the+pane+behind+'gh-2'=true stderr~pgrep+-P+exited+2=true notes~could+not+list+the+children=1" \
  "the note names the fatal status that occurred, never a fixed one|new|-|fish_probe3|2|first=$HEARTBEAT2 out~EVENT+lane-exited=false stderr~pgrep+-P+exited+3=true stderr~pgrep+-P+exited+2=false" \
  "control: a bare fish prompt with no child is the event on the second pass|new|fish_prompt|fish|2|first=EVENT+lane-exited+gh-2" \
  "control: a live pane command is not an exit|new|-|codex|2|first=$HEARTBEAT2 out~EVENT+lane-exited=false" \
  "a blank pane does not swallow the event|new|blank|zsh|2|rc=0 first=EVENT+lane-exited+gh-2" \
  "a liveness reply with no command exits 2, emits nothing, and is preserved|new|-|obs:9002|2|rc=2 lines=0 stderr~malformed+result+for+'gh-2':+9002=true" \
  "a liveness reply with a non-pid exits 2, emits nothing, and is preserved|new|-|obs:fish fish|2|rc=2 lines=0 stderr~malformed+result+for+'gh-2':+fish+fish=true" \
  "an unreadable pane command is a fail-closed probe error, never window-gone|new|-|nocmd|2|rc=2 lines=0 stderr~pane+command+probe+failed+for+'gh-2':+can't+find+window:+gh-2=true"

echo "=== lane-asking: a question nobody has answered ==="
# A selection prompt is a question, never an idle prompt; the check reads the
# same liveness answer as the exit check, so a wrapped lane's prompt is seen.
# Codex marks its selected row with `›`, not `❯`, and words its hints its own
# way, so the marker is the whole signature. Two lanes whose names flatten to
# one slug keep separate pane snapshots. Only the slice below the last user
# turn is a question still waiting: an answered list re-fires every pass and
# masks the event the lane is really at. A stale prompt under a bare shell is
# not a question anyone can answer, and firing it every pass would starve the
# lane-exited that the second pass earns.
lane_table \
  "a question prompt is the event, the pane tail following, the working lane unreported|new|question|claude|2|rc=0 first=EVENT+lane-asking+gh-2 out~+++❯+1.+Yes=true out~gh-1=false out~EVENT+idle-after-return=false" \
  "a wrapped lane's question is still the event|new|prompt|fish_child|1|first=EVENT+lane-asking+gh-2" \
  "a codex directory-trust dialog is a question|new|codex:codex-dialog-trust|codex|1|first=EVENT+lane-asking+gh-2 out~Do+you+trust+the+contents+of+this+directory?=true" \
  "a codex model picker is a question|new|codex:codex-dialog-model|codex|1|first=EVENT+lane-asking+gh-2 out~Select+Model+and+Effort=true" \
  "lanes whose names flatten to one slug keep separate pane snapshots|new|-|collide|1|rc=0 first=EVENT+lane-asking+a+b" \
  "a selection list above the last user turn is answered: the lane reaches the idle event it was masking|new|answered_dialog|claude|2|rc=0 first=EVENT+idle-after-return+gh-2 out~EVENT+lane-asking=false" \
  "control: the same list below the last user turn is still the event|new|live_dialog|claude|1|first=EVENT+lane-asking+gh-2 out~+++❯+1.+Yes=true" \
  "a stale prompt under an exited harness is not a question|new|prompt|bash|1|first=$HEARTBEAT1 out~EVENT+lane-asking=false" \
  "...and the second pass reports the lane as exited rather than starved|cont|prompt|bash|2|first=EVENT+lane-exited+gh-2"

echo "=== idle-after-return: the round is over and nobody is driving ==="
# An idle prompt on two consecutive passes is the event: the screen between
# two tool calls reads the same for one pass, and idle then working is a lane
# that picked itself back up. A working lane shows the same composer, so the
# prompt alone never decides: the token counter, the interrupt hint and the
# background-shell hint all mean busy. Codex draws its composer below the
# working indicator for the whole turn, so WORKING_RE is what keeps its
# marker from waking a busy lane. Scrollback never goes away: only the slice
# below the last user turn is work in flight now, and a submitted turn's
# marker above it is not the composer the lane is sitting at.
lane_table \
  "an idle prompt on two consecutive passes is the event, the pane tail following|new|idle|claude|2|rc=0 first=EVENT+idle-after-return+gh-2 out~the+PR+is+merged=true" \
  "a codex lane that finished its turn is idle too, the marker alone deciding|new|codex:codex-idle-after-turn|codex|2|first=EVENT+idle-after-return+gh-2" \
  "a codex lane at a fresh composer is idle too|new|codex:codex-composer-idle|codex|2|first=EVENT+idle-after-return+gh-2" \
  "a codex composer holding a draft is idle too|new|codex:codex-composer-draft|codex|2|first=EVENT+idle-after-return+gh-2" \
  "a working codex lane is not idle, its composer notwithstanding|new|codex:codex-working|codex|2|first=$HEARTBEAT2 out~EVENT+idle-after-return=false" \
  "a wrapped lane at its composer is idle, not exited|new|idle_merged|fish_child|2|first=EVENT+idle-after-return+gh-2" \
  "one idle pass is not the event|new|idle_short|claude|1|first=$HEARTBEAT1 out~EVENT+idle-after-return=false" \
  "control: a working lane showing its composer is not idle, the token counter keeping it out|new|working_counter|claude|2|first=$HEARTBEAT2 out~EVENT+idle-after-return=false" \
  "the interrupt hint and the background-shell hint both mean busy|new|working_hints|claude|2|first=$HEARTBEAT2 out~EVENT+idle-after-return=false" \
  "an idle pass followed by a working one is not the event|new|idle_then_working|claude|2|first=$HEARTBEAT2 out~EVENT+idle-after-return=false" \
  "an interrupt hint above the last user turn is scrollback, not work in flight|new|working_above_turn|claude|2|rc=0 first=EVENT+idle-after-return+gh-2" \
  "control: the same hint below the last user turn still means busy|new|working_below_turn|claude|2|first=$HEARTBEAT2 out~EVENT+idle-after-return=false" \
  "a scrollback user turn is not the composer the lane is sitting at|new|prompt_above_turn|claude|2|first=$HEARTBEAT2 out~EVENT+idle-after-return=false"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
