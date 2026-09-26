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
# A shell is_bare_shell does not name, started as tmux's default-shell: a copy
# of bash under a name of its own. It stays the default from here on, which
# the rows that expect a shell read at write time.
cp "$(command -v bash)" "$TMP_ROOT/ownsh"
tm set-option -g default-shell "$TMP_ROOT/ownsh"
tm new-window -d -t w -n own
# A second program reading its own input, for the rows that write two panes.
RECV2="$TMP_ROOT/received-pair"
: > "$RECV2"
tm new-window -d -t w -n pair "exec cat >> '$RECV2'"
LANE_PANE="$(tm display-message -p -t '=w:lane' '#{pane_id}')"
PAIR_PANE="$(tm display-message -p -t '=w:pair' '#{pane_id}')"
printf 'hello' > "$TMP_ROOT/hello"
HELLO="$TMP_ROOT/hello"

# Directories a row puts ahead of PATH: a ps that fails, a tmux whose
# paste-buffer fails, and a tmux that holds every paste-buffer for two seconds
# before making it, so writers started together have all loaded their buffers
# before any of them pastes.
FAILPS="$TMP_ROOT/failps"
FAILPASTE="$TMP_ROOT/failpaste"
SLOWPASTE="$TMP_ROOT/slowpaste"
mkdir -p "$FAILPS" "$FAILPASTE" "$SLOWPASTE"
printf '#!/bin/sh\nexit 1\n' > "$FAILPS/ps"
printf '#!/bin/sh\n[ "$1" = paste-buffer ] && exit 1\nexec "%s" "$@"\n' "$REAL_TMUX" > "$FAILPASTE/tmux"
printf '#!/bin/sh\n[ "$1" = paste-buffer ] && sleep 2\nexec "%s" "$@"\n' "$REAL_TMUX" > "$SLOWPASTE/tmux"
chmod +x "$FAILPS/ps" "$FAILPASTE/tmux" "$SLOWPASTE/tmux"
# A tmux whose pane list names systemd-run as every pane's command for the
# first reads, as many as WRAP_LIMIT holds, the window a fleet-confine
# default-command holds before its shell takes the foreground. A row writes
# both files first.
WRAPPED="$TMP_ROOT/wrapped"
WRAP_COUNT="$TMP_ROOT/wrap-count"
WRAP_LIMIT="$TMP_ROOT/wrap-limit"
mkdir -p "$WRAPPED"
cat > "$WRAPPED/tmux" <<EOF
#!/bin/sh
if [ "\$1" = list-panes ]; then
  n=\$((\$(cat '$WRAP_COUNT') + 1))
  echo "\$n" > '$WRAP_COUNT'
  if [ "\$n" -le "\$(cat '$WRAP_LIMIT')" ]; then
    "$REAL_TMUX" "\$@" | awk -F'\t' -v OFS='\t' '{ \$NF = "systemd-run" } 1'
    exit
  fi
fi
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$WRAPPED/tmux"

# pw DIR SELF ARGS... — the entry point under DIR, with TMUX_PANE set to SELF
# where SELF is not empty, $PW_PREFIX ahead of PATH where it is set, and
# $PW_SETTLE as the settle time, one second so a refused shell costs little.
PW_PREFIX=""
PW_SETTLE=1
pw() {
  local dir="$1" self="$2"
  shift 2
  env -i PATH="${PW_PREFIX:+$PW_PREFIX:}$PATH" HOME="$TMP_ROOT" LANG=C.UTF-8 TMUX_TMPDIR="$SOCK_DIR" PANE_WRITE_SETTLE_SECS="$PW_SETTLE" ${self:+TMUX_PANE="$self"} "$dir/pane-write" "$@"
}

# received [PANE RECV] — what the program in PANE, the lane's by default, read
# since the last call into RECV, lines joined by `,`. A sentinel line is written
# after the row through the reference copy and waited for, so a row that typed
# nothing is read as nothing only once input written after it has arrived.
SENT=0
received() {
  local pane="${1:-$LANE_PANE}" recv="${2:-$RECV}" n=0 out
  SENT=$((SENT + 1))
  printf 'sentinel-%s' "$SENT" > "$TMP_ROOT/sentinel"
  pw "$REF" "" --pane "$pane" --expect cat --file "$TMP_ROOT/sentinel" 2>/dev/null || { echo sentinel-refused; return; }
  until grep -q "sentinel-$SENT\$" "$recv"; do
    n=$((n + 1))
    [[ "$n" -lt 100 ]] || { echo sentinel-lost; return; }
    sleep 0.1
  done
  # Every line but the sentinel's own ends in `,`; what shares the sentinel's
  # line is input typed with no Enter after it.
  out="$(awk -v s="sentinel-$SENT" '{ sub(s "$", ""); line[NR] = $0 } END { for (i = 1; i < NR; i++) printf "%s,", line[i]; printf "%s", line[NR] }' "$recv")"
  : > "$recv"
  printf '%s' "$out"
}

# observe DIR SELF ARGS [SETUP] [PREFIX] — ARGS is `;`-separated so an empty
# argument survives; the output is `rc=N key=KEY received=TEXT`, KEY the first
# word after `pane-write:` on stderr, `none` on a quiet run. PREFIX goes ahead
# of PATH for the row's own write only, never the sentinel's.
observe() {
  local dir="$1" self="$2" args rc=0 key
  IFS=';' read -r -a args <<<"$3"
  [[ -z "${4:-}" ]] || eval "$4"
  PW_PREFIX="${5:-}"
  pw "$dir" "$self" "${args[@]}" 2>"$TMP_ROOT/err" >/dev/null || rc=$?
  PW_PREFIX=""
  key="$(awk '$1 == "pane-write:" { print $2; exit }' "$TMP_ROOT/err")"
  printf 'rc=%s key=%s received=%s' "$rc" "${key:-none}" "$(received)"
}

echo "=== pane-write: refusals type nothing, a proven pane receives ==="
# NAME|SELF|ARGS|EXPECTED[|PREFIX], PREFIX a stub directory ahead of PATH.
ROWS=(
  "an empty window names no pane|-|--window;;--expect;cat;--file;$HELLO|rc=1 key=pane-unresolved received="
  "an empty pane names no pane|-|--pane;;--expect;cat;--file;$HELLO|rc=1 key=pane-unresolved received="
  "a window name passed as a pane id is not resolved|-|--pane;lane;--expect;cat;--file;$HELLO|rc=1 key=pane-unresolved received="
  "the caller's own pane is refused|$LANE_PANE|--window;lane;--expect;cat;--file;$HELLO|rc=1 key=pane-self received="
  "a window no pane carries is refused|-|--window;gone;--expect;cat;--file;$HELLO|rc=1 key=pane-missing received="
  "a pane id the server does not list is refused|-|--pane;%9999;--expect;cat;--file;$HELLO|rc=1 key=pane-missing received="
  "a name two windows share is refused|-|--window;twin;--expect;sleep;--file;$HELLO|rc=1 key=pane-ambiguous received="
  "a pane running another process is refused|-|--window;lane;--expect;claude;--file;$HELLO|rc=1 key=process-mismatch received="
  "a process of that name outside the pane's own tree is not the pane's|-|--window;lane;--expect;sleep;--file;$HELLO|rc=1 key=process-mismatch received="
  "a file that is not there is refused before the pane is touched|-|--window;lane;--expect;cat;--file;$TMP_ROOT/absent|rc=1 key=file-unreadable received="
  "an empty expect names no process|-|--window;lane;--expect;;--file;$HELLO|rc=1 key=expect-missing received="
  "a second target option is refused|-|--window;lane;--window;lane;--expect;cat;--file;$HELLO|rc=1 key=argument-invalid received="
  "a process table that cannot be read is refused as such|-|--window;lane;--expect;claude;--file;$HELLO|rc=1 key=pane-read-failed received=|$FAILPS"
  "a pane running a program is not a shell|-|--window;lane;--expect;shell;--file;$HELLO|rc=1 key=process-mismatch received="
  "a key outside the list is refused|-|--window;lane;--expect;cat;--key;Escape|rc=1 key=key-invalid received="
  "the expected process receives the paste and its Enter|-|--window;lane;--expect;cat;--file;$HELLO|rc=0 key=none received=hello,"
  "a session-qualified window resolves to the same pane|-|--window;w:lane;--expect;cat;--file;$HELLO|rc=0 key=none received=hello,"
  "a proven pane id receives the paste|-|--pane;$LANE_PANE;--expect;cat;--file;$HELLO|rc=0 key=none received=hello,"
  "a key is pressed in the pane|-|--window;lane;--expect;cat;--key;Enter|rc=0 key=none received=,"
  "a process below the pane's shell is the expected one|-|--window;nest;--expect;sleep;--key;Enter|rc=0 key=none received="
  "a shell named only by tmux's default-shell is a window's own shell|-|--window;own;--expect;shell;--key;Enter|rc=0 key=none received="
)
for r in "${ROWS[@]}"; do
  IFS='|' read -r name self args want prefix <<<"$r"
  [[ "$self" != - ]] || self=""
  assert_eq "$(observe "$REF" "$self" "$args" "" "$prefix")" "$want" "$name"
done
# Copy mode is entered by the row itself, so the keystroke that follows would
# drive the copy-mode cursor were it not cancelled first.
assert_eq "$(observe "$REF" "" "--window;lane;--expect;cat;--file;$HELLO" 'tm copy-mode -t "$LANE_PANE"')" \
  "rc=0 key=none received=hello," "a pane in copy mode is returned to its program before the Enter"

# wrapped DIR READS — a shell write into the `own` window while the pane list
# names systemd-run for READS reads, with the running= the refusal names.
wrapped() {
  local seen
  seen="$(observe "$1" "" "--window;own;--expect;shell;--key;Enter" "echo 0 > '$WRAP_COUNT'; echo $2 > '$WRAP_LIMIT'" "$WRAPPED")"
  printf '%s %s' "$seen" "$(awk '$1 == "pane-write:" { for (i = 3; i <= NF; i++) if ($i ~ /^running=/) print $i }' "$TMP_ROOT/err")"
}
# At a one-second settle the resolution reads the pane once and the settle ten
# times more, so the eleventh list-panes call is the last reading: a wrapper
# held for ten reads is gone by it, one held for eleven is not.
assert_eq "$(wrapped "$REF" 10)" "rc=0 key=none received= " \
  "a window a default-command wrapper holds until the last reading passes once its shell is in the foreground"
assert_eq "$(wrapped "$REF" 11)" "rc=1 key=process-mismatch received= running=systemd-run" \
  "a window the wrapper holds past the settle time is refused on the last reading"
# SETTLE|EXPECTED — the setting's two sides: two digits at most, and digits only.
SETTLES=(
  "99|rc=0 key=none received="
  "100|rc=1 key=settle-invalid received="
  "abc|rc=1 key=settle-invalid received="
)
for r in "${SETTLES[@]}"; do
  IFS='|' read -r settle want <<<"$r"
  assert_eq "$(observe "$REF" "" "--window;own;--expect;shell;--key;Enter" "PW_SETTLE=$settle")" \
    "$want" "a settle time of $settle reads as the 0-99 whole seconds the setting allows"
done

# buffers_left — how many pane-write buffers the fixture server holds, each
# deleted once counted so the next count starts from none.
buffers_left() {
  local names name n=0
  names="$(tm list-buffers -F '#{buffer_name}')" || { printf list-failed; return; }
  while IFS= read -r name; do
    [[ "$name" == pane-write-* ]] || continue
    n=$((n + 1))
    tm delete-buffer -b "$name"
  done <<<"$names"
  printf '%s' "$n"
}
# A paste that fails after its buffer loaded is exit 2, and takes the buffer
# with it: left on the server, a later paste could type that text into
# another pane.
failed_paste() { # DIR
  local seen
  seen="$(observe "$1" "" "--window;lane;--expect;cat;--file;$HELLO" "" "$FAILPASTE")"
  printf '%s buffers=%s' "$seen" "$(buffers_left)"
}
assert_eq "$(failed_paste "$REF")" "rc=2 key=write-failed received= buffers=0" \
  "a paste that fails after the checks passed is exit 2 and leaves no buffer behind"

# Two background jobs of one shell, the shape open-terminal's background
# launches take, write two panes at once. Every job of a script shares its $$,
# so this is what the buffer name has to tell apart. The second job starts half
# a second after the first, so the first loads its buffer first and pastes
# first: a shared name then reads the same way on every run.
concurrent() { # DIR
  local out
  out="$(env -i PATH="$SLOWPASTE:$PATH" HOME="$TMP_ROOT" LANG=C.UTF-8 TMUX_TMPDIR="$SOCK_DIR" bash -c '
    source "$1/lib/lane-state.sh"
    source "$1/lib/pane-write.sh"
    pane_write pane "$2" cat text one 2>/dev/null & a=$!
    sleep 0.5
    pane_write pane "$3" cat text two 2>/dev/null & b=$!
    ra=0; wait "$a" || ra=$?
    rb=0; wait "$b" || rb=$?
    printf "rc=%s,%s" "$ra" "$rb"' _ "$1" "$LANE_PANE" "$PAIR_PANE")"
  printf '%s lane=%s pair=%s' "$out" "$(received)" "$(received "$PAIR_PANE" "$RECV2")"
}
assert_eq "$(concurrent "$REF")" "rc=0,0 lane=one, pair=two," \
  "two writers of one shell writing two panes at once each land only their own text"

echo "=== pane-write: each rule's control ==="
# mutant NAME OLD NEW [FILE] — a copy of the scripts with OLD replaced by NEW in
# FILE, a path under the copy, lib/pane-write.sh by default, once, or the
# control fails before it runs.
mutant() {
  local dir="$TMP_ROOT/mutant-$1" file
  copy_scripts "$dir"
  file="$dir/${4:-lib/pane-write.sh}"
  assert_eq "$(grep -c -F -e "$2" "$file" || true)" 1 "control $1 finds its one site"
  OLD="$2" NEW="$3" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$file"
  assert_eq "$(grep -c -F -e "$3" "$file" || true)" 1 "control $1 applied its mutation"
  MUTANT="$dir"
}
# One row per rule: FILE@NAME@OLD@NEW@SELF@ARGS@EXPECTED[@PREFIX], `@`-separated
# because the sites carry `|`. Each row is its rule's own row above, run
# against a copy with that rule taken out of FILE.
CONTROLS=(
  "lib/pane-write.sh@unresolved@  [[ -n \"\$2\" ]] ||@  [[ -n \"\$2\" ]] || true ||@-@--window;;--expect;cat;--file;$HELLO@rc=1 key=pane-missing received="
  "lib/pane-write.sh@self@\"\$PANE_WRITE_ID\" == \"\$TMUX_PANE\"@\"\$PANE_WRITE_ID\" == never@$LANE_PANE@--window;lane;--expect;cat;--file;$HELLO@rc=0 key=none received=hello,"
  "lib/pane-write.sh@missing@if [[ \"\$LANE_PANE_COUNT\" == 0 ]]; then@if false; then@-@--window;gone;--expect;cat;--file;$HELLO@rc=1 key=pane-ambiguous received="
  "lib/pane-write.sh@ambiguous@            pane_write_refuse 1 pane-ambiguous@            : pane_write_refuse 1 pane-ambiguous@-@--window;twin;--expect;sleep;--file;$HELLO@rc=1 key=process-mismatch received="
  "lib/pane-write.sh@mismatch@  pane_write_expect \"\$expect\" || return@  : || return@-@--window;lane;--expect;claude;--file;$HELLO@rc=0 key=none received=hello,"
  "lib/lane-state.sh@child@if (q == root) { print \"found\"; exit }@if (q == root) { print \"none\"; exit }@-@--window;nest;--expect;sleep;--key;Enter@rc=1 key=process-mismatch received="
  "lib/pane-write.sh@default-shell@\"\$default\" ]] || return 0@\"\$default\" ]] || :@-@--window;own;--expect;shell;--key;Enter@rc=1 key=process-mismatch received="
  "lib/lane-state.sh@anchor@        if (name[pid[i]] !~ re) continue@        if (name[pid[i]] !~ re) continue; else { print \"found\"; exit }@-@--window;lane;--expect;sleep;--file;$HELLO@rc=0 key=none received=hello,"
  "lib/pane-write.sh@file-unreadable@    file) [[ -f \"\$value\" && -r \"\$value\" ]] ||@    file) [[ -f \"\$value\" && -r \"\$value\" ]] || true ||@-@--window;lane;--expect;cat;--file;$TMP_ROOT/absent@rc=2 key=write-failed received="
  "lib/pane-write.sh@expect-missing@  [[ -n \"\$1\" ]] || { pane_write_refuse 1 expect-missing@  [[ -n \"\$1\" ]] || true || { pane_write_refuse 1 expect-missing@-@--window;lane;--expect;;--file;$HELLO@rc=1 key=process-mismatch received="
  "pane-write@repeated-target@      [[ -z \"\$kind\" ]] || refuse_args@      [[ -z \"\$kind\" ]] || true || refuse_args@-@--window;lane;--window;lane;--expect;cat;--file;$HELLO@rc=0 key=none received=hello,"
  "lib/pane-write.sh@table-read@    table=\"\$(lane_process_table)\"@    table=\"\$(lane_process_table || true)\"@-@--window;lane;--expect;claude;--file;$HELLO@rc=1 key=process-mismatch received=@$FAILPS"
)
for r in "${CONTROLS[@]}"; do
  IFS='@' read -r file name old new self args want prefix <<<"$r"
  [[ "$self" != - ]] || self=""
  mutant "$name" "$old" "$new" "$file"
  assert_eq "$(observe "$MUTANT" "$self" "$args" "" "$prefix")" "$want" "control: without the $name rule the row reads otherwise"
done
mutant paste-failed '    pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=paste-buffer' \
  '    : pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=paste-buffer'
assert_eq "$(failed_paste "$MUTANT")" "rc=0 key=none received= buffers=0" \
  "control: without the paste-failed refusal a paste that never landed reads as written"
mutant buffer-delete '    tmux delete-buffer -b "$buffer" 2>/dev/null || :' '    : tmux delete-buffer -b "$buffer" 2>/dev/null || :'
assert_eq "$(failed_paste "$MUTANT")" "rc=2 key=write-failed received= buffers=1" \
  "control: without the delete a failed paste leaves its text in a buffer on the server"
mutant shared-buffer 'buffer="pane-write-$$-${PANE_WRITE_ID#%}"' 'buffer="pane-write-$$"'
assert_eq "$(concurrent "$MUTANT")" "rc=0,2 lane=two, pair=" \
  "control: a buffer named for the script alone hands one job's text to the other's pane"
mutant settle '[[ "$reads" -lt $((10#$settle * 10)) ]] || break' 'break'
assert_eq "$(wrapped "$MUTANT" 10)" "rc=1 key=process-mismatch received= running=systemd-run" \
  "control: without the settle the wrapper's first reading refuses the window"
mutant settle-invalid '[[ "$settle" =~ ^[0-9]{1,2}$ ]]' '[[ "$settle" =~ ^.*$ ]]'
assert_eq "$(observe "$MUTANT" "" "--window;own;--expect;shell;--key;Enter" "PW_SETTLE=abc")" \
  "rc=0 key=none received=" "control: without the settle check a word for the settle time is never judged"
mutant settle-digits '^[0-9]{1,2}$' '^[0-9]+$'
assert_eq "$(observe "$MUTANT" "" "--window;own;--expect;shell;--key;Enter" "PW_SETTLE=100")" \
  "rc=0 key=none received=" "control: without the two-digit bound a three-digit settle time is never judged"
mutant copy-mode 'pane_write_mode_clear() {' 'pane_write_mode_clear() { return 0;'
assert_eq "$(observe "$MUTANT" "" "--window;lane;--expect;cat;--file;$HELLO" 'tm copy-mode -t "$LANE_PANE"')" \
  "rc=0 key=none received=hello" "control: without the copy-mode cancel the Enter never reaches the program"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
