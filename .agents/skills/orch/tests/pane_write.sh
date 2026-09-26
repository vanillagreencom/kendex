#!/usr/bin/env bash
# pane-write, the one writer into a tmux pane: every refusal types nothing, a
# pane running the expected process receives the input, and copy mode is
# cancelled before a keystroke. Every row runs the entry point against a private
# tmux server, whose `lane` window runs `cat` into a file, so what reached the
# program is read back rather than inferred from the tmux calls made.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
REAL_TMUX="$(command -v tmux)" || { echo "pane_write: tmux-missing" >&2; exit 1; }
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SOCK_DIR="$TMP_ROOT/sock"
mkdir -p "$SOCK_DIR"

# The fixture server and every call into it take this environment and no
# other, so the developer's own TMUX never names the server a row writes to.
# LANG names UTF-8 because tmux prints a tab in a format as `_` to a client
# whose environment names no UTF-8 locale, and the resolution splits on tabs.
tm() { env -i PATH="$PATH" HOME="$TMP_ROOT" LANG=C.UTF-8 SHELL=/bin/sh TMUX_TMPDIR="$SOCK_DIR" "$REAL_TMUX" "$@"; }
trap 'tm kill-server 2>/dev/null || true; rm -rf -- "${TMP_ROOT:?}"' EXIT

# copy_scripts DIR — the entry point and the two libraries it sources, so a
# control plants its defect in a copy of its own.
copy_scripts() {
  mkdir -p "$1/lib"
  cp "$SCRIPTS_DIR/pane-write" "$1/"
  cp "$SCRIPTS_DIR/lib/pane-write.sh" "$SCRIPTS_DIR/lib/lane-state.sh" "$1/lib/"
}
REF="$TMP_ROOT/ref"
copy_scripts "$REF"

RECV="$TMP_ROOT/received"
: > "$RECV"
tm -f /dev/null new-session -d -s w -n lane -x 200 -y 50 "exec cat >> '$RECV'"
tm set-option -g default-shell /bin/sh
tm new-window -d -t w -n twin 'exec sleep 100000'
tm new-window -d -t w -n twin 'exec sleep 100000'
# A harness under a shell that does not exec it, the shape a lane started by
# typing its wrapper at a prompt keeps for its whole life.
tm new-window -d -t w -n nest '/bin/sh -c "sleep 100000; :"'
LANE_PANE="$(tm display-message -p -t '=w:lane' '#{pane_id}')"
printf 'hello' > "$TMP_ROOT/hello"
HELLO="$TMP_ROOT/hello"

# pw DIR SELF ARGS... — the entry point under DIR, with TMUX_PANE set to SELF
# where SELF is not empty.
pw() {
  local dir="$1" self="$2"
  shift 2
  env -i PATH="$PATH" HOME="$TMP_ROOT" LANG=C.UTF-8 TMUX_TMPDIR="$SOCK_DIR" ${self:+TMUX_PANE="$self"} "$dir/pane-write" "$@"
}

# received — what the lane's program read since the last call, lines joined by
# `,`. A sentinel line is written after the row through the reference copy and
# waited for, so a row that typed nothing is read as nothing only once input
# written after it has arrived.
SENT=0
received() {
  local n=0 out
  SENT=$((SENT + 1))
  printf 'sentinel-%s' "$SENT" > "$TMP_ROOT/sentinel"
  pw "$REF" "" --pane "$LANE_PANE" --expect cat --file "$TMP_ROOT/sentinel" 2>/dev/null || { echo sentinel-refused; return; }
  until grep -q "sentinel-$SENT\$" "$RECV"; do
    n=$((n + 1))
    [[ "$n" -lt 100 ]] || { echo sentinel-lost; return; }
    sleep 0.1
  done
  # Every line but the sentinel's own ends in `,`; what shares the sentinel's
  # line is input typed with no Enter after it.
  out="$(awk -v s="sentinel-$SENT" '{ sub(s "$", ""); line[NR] = $0 } END { for (i = 1; i < NR; i++) printf "%s,", line[i]; printf "%s", line[NR] }' "$RECV")"
  : > "$RECV"
  printf '%s' "$out"
}

# row DIR NAME SELF ARGS EXPECTED [SETUP] — ARGS is `;`-separated so an empty
# argument survives; EXPECTED is `rc=N key=KEY received=TEXT`, KEY the first
# word after `pane-write:` on stderr, `none` on a quiet run.
observe() { # DIR SELF ARGS [SETUP]
  local dir="$1" self="$2" args rc=0 key
  IFS=';' read -r -a args <<<"$3"
  [[ -z "${4:-}" ]] || eval "$4"
  pw "$dir" "$self" "${args[@]}" 2>"$TMP_ROOT/err" >/dev/null || rc=$?
  key="$(awk '$1 == "pane-write:" { print $2; exit }' "$TMP_ROOT/err")"
  printf 'rc=%s key=%s received=%s' "$rc" "${key:-none}" "$(received)"
}

echo "=== pane-write: refusals type nothing, a proven pane receives ==="
ROWS=(
  "an empty window names no pane|-|--window;;--expect;cat;--file;$HELLO|rc=1 key=pane-unresolved received="
  "an empty pane names no pane|-|--pane;;--expect;cat;--file;$HELLO|rc=1 key=pane-unresolved received="
  "a window name passed as a pane id is not resolved|-|--pane;lane;--expect;cat;--file;$HELLO|rc=1 key=pane-unresolved received="
  "the caller's own pane is refused|$LANE_PANE|--window;lane;--expect;cat;--file;$HELLO|rc=1 key=pane-self received="
  "a window no pane carries is refused|-|--window;gone;--expect;cat;--file;$HELLO|rc=1 key=pane-missing received="
  "a pane id the server does not list is refused|-|--pane;%9999;--expect;cat;--file;$HELLO|rc=1 key=pane-missing received="
  "a name two windows share is refused|-|--window;twin;--expect;sleep;--file;$HELLO|rc=1 key=pane-ambiguous received="
  "a pane running another process is refused|-|--window;lane;--expect;claude;--file;$HELLO|rc=1 key=process-mismatch received="
  "a pane running a program is not a shell|-|--window;lane;--expect;shell;--file;$HELLO|rc=1 key=process-mismatch received="
  "a key outside the list is refused|-|--window;lane;--expect;cat;--key;Escape|rc=1 key=key-invalid received="
  "the expected process receives the paste and its Enter|-|--window;lane;--expect;cat;--file;$HELLO|rc=0 key=none received=hello,"
  "a session-qualified window resolves to the same pane|-|--window;w:lane;--expect;cat;--file;$HELLO|rc=0 key=none received=hello,"
  "a proven pane id receives the paste|-|--pane;$LANE_PANE;--expect;cat;--file;$HELLO|rc=0 key=none received=hello,"
  "a key is pressed in the pane|-|--window;lane;--expect;cat;--key;Enter|rc=0 key=none received=,"
  "a process below the pane's shell is the expected one|-|--window;nest;--expect;sleep;--key;Enter|rc=0 key=none received="
)
for r in "${ROWS[@]}"; do
  IFS='|' read -r name self args want <<<"$r"
  [[ "$self" != - ]] || self=""
  assert_eq "$(observe "$REF" "$self" "$args")" "$want" "$name"
done
# Copy mode is entered by the row itself, so the keystroke that follows would
# drive the copy-mode cursor were it not cancelled first.
assert_eq "$(observe "$REF" "" "--window;lane;--expect;cat;--file;$HELLO" 'tm copy-mode -t "$LANE_PANE"')" \
  "rc=0 key=none received=hello," "a pane in copy mode is returned to its program before the Enter"

echo "=== pane-write: each rule's control ==="
# mutant NAME OLD NEW — a copy of the scripts with OLD replaced by NEW in
# lib/pane-write.sh, once, or the control fails before it runs.
mutant() {
  local dir="$TMP_ROOT/mutant-$1" file
  copy_scripts "$dir"
  file="$dir/lib/pane-write.sh"
  assert_eq "$(grep -c -F -e "$2" "$file" || true)" 1 "control $1 finds its one site"
  OLD="$2" NEW="$3" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$file"
  assert_eq "$(grep -c -F -e "$3" "$file" || true)" 1 "control $1 applied its mutation"
  MUTANT="$dir"
}
# One row per rule: NAME@OLD@NEW@SELF@ARGS@EXPECTED, `@`-separated because the
# sites carry `|`. Each row is its rule's own refusal row above, run against a
# copy with that rule taken out.
CONTROLS=(
  "unresolved@  [[ -n \"\$2\" ]] ||@  [[ -n \"\$2\" ]] || true ||@-@--window;;--expect;cat;--file;$HELLO@rc=1 key=pane-missing received="
  "self@\"\$PANE_WRITE_ID\" == \"\$TMUX_PANE\"@\"\$PANE_WRITE_ID\" == never@$LANE_PANE@--window;lane;--expect;cat;--file;$HELLO@rc=0 key=none received=hello,"
  "missing@if [[ \"\$LANE_PANE_COUNT\" == 0 ]]; then@if false; then@-@--window;gone;--expect;cat;--file;$HELLO@rc=1 key=pane-ambiguous received="
  "ambiguous@            pane_write_refuse 1 pane-ambiguous@            : pane_write_refuse 1 pane-ambiguous@-@--window;twin;--expect;sleep;--file;$HELLO@rc=1 key=process-mismatch received="
  "mismatch@  pane_write_expect \"\$expect\" || return@  : || return@-@--window;lane;--expect;claude;--file;$HELLO@rc=0 key=none received=hello,"
  "child@if (q == root) { print \"found\"; exit }@if (q == root) { print \"none\"; exit }@-@--window;nest;--expect;sleep;--key;Enter@rc=1 key=process-mismatch received="
)
for r in "${CONTROLS[@]}"; do
  IFS='@' read -r name old new self args want <<<"$r"
  [[ "$self" != - ]] || self=""
  mutant "$name" "$old" "$new"
  assert_eq "$(observe "$MUTANT" "$self" "$args")" "$want" "control: without the $name rule the row reads otherwise"
done
mutant copy-mode 'pane_write_mode_clear() {' 'pane_write_mode_clear() { return 0;'
assert_eq "$(observe "$MUTANT" "" "--window;lane;--expect;cat;--file;$HELLO" 'tm copy-mode -t "$LANE_PANE"')" \
  "rc=0 key=none received=hello" "control: without the copy-mode cancel the Enter never reaches the program"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
