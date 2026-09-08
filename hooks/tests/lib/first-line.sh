#!/usr/bin/env bash
# The keyed-line contract, as one table each suite runs against its own hook.
# Every refusal and notice carries a line `<hook-name>: <key>=<value>`, and that
# line is what a reader parses; a row pins it beside the exit status, and the
# English below it is pinned nowhere.
#
# A reader matches the prefix `^<hook-name>: `, not line 1, and so does this
# library: a command the hook runs may write its own diagnostic to the same
# stream first — cat on a directory, the settings loader on a malformed file —
# and that line names a cause the keyed one does not carry. Reading line 1
# strictly would pin the absence of those diagnostics, which is not the
# contract and costs the reader the cause.
#
# Usage, from a suite that defines ERR_FILE, `run_hook COMMAND` and
# `run_payload RAW-JSON` (each leaving the status in `rc` and stderr in
# ERR_FILE), `assert_eq GOT WANT LABEL`, PASS and FAIL:
#
#   . "$TEST_DIR/lib/first-line.sh"
#   first_table "\
#   the verb is the value|command|2|block-argv-kill: refused=pkill|pkill -f x
#   "
#
# A row is `label|mode|rc|first|text`:
#   mode   `command` sends the text as the harness's command, `payload` sends
#          it as the whole payload
#   rc     the exit status
#   first  the whole first line of stderr, or `-` for silence
#   text   what the mode sends; `-` is empty, and `printf %b` decodes the
#          escapes a row spells. It stands last, so a row may hold a pipe
#
# `tools_table TOOLS` is the other half: one world per tool, each holding every
# other one, and then a world holding none of them. The last row is what tells
# an accumulator that appends from one that overwrites — a row per tool passes
# either way, since only one name is ever missing.

# NAME and FILE default to the suite's own hook and stderr; a suite whose
# fixture runs a copy of the hook under another path passes them instead.
first_line() { # [NAME] [FILE] -> the hook's own keyed line, `-` when it wrote none
  local prefix line="" file
  prefix="${1:-$(basename "${HOOK:?}" .sh)}: "
  file="${2:-$ERR_FILE}"
  # Read to the end in the shell: a `head` here stops reading while the hook
  # still writes, and its SIGPIPE would read as an empty stderr.
  while IFS= read -r line; do
    case "$line" in "$prefix"*) printf '%s' "$line"; return ;; esac
  done <"$file"
  printf -- '-'
}

first_table() { # ROWS
  local row label mode rc_want first_want text field got before=$((PASS + FAIL))
  while IFS= read -r row; do
    [ "$row" != "" ] || continue
    IFS='|' read -r label mode rc_want first_want text <<<"$row"
    for field in "$label" "$mode" "$rc_want" "$first_want" "$text"; do
      [ "$field" != "" ] || { printf 'first-line: a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    [ "$text" != - ] || text=""
    text=$(printf '%b' "$text")
    case "$mode" in
      command) run_hook "$text" ;;
      payload) run_payload "$text" ;;
      *) printf 'first-line: no mode named %s: %s\n' "$mode" "$row" >&2; exit 1 ;;
    esac
    got="rc=$rc first=$(first_line)"
    assert_eq "$got" "rc=$rc_want first=$first_want" "$label"
  done <<<"$1"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo 'first-line: no row was asserted' >&2; exit 2; }
}
