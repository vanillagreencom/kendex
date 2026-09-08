#!/usr/bin/env bash
# The keyed-line contract, as one table each suite runs against its own hook.
# Every refusal and notice carries a line `<hook-name>: <key>=<value>`, and that
# line is what a reader parses; a row pins it beside the exit status, and the
# English below it is pinned nowhere.
#
# The first line is the contract, at position 1: a hook captures what a command
# it runs wrote and replays it under the keyed line, so nothing precedes the
# key. `first_line` reads line 1 strictly, and `cause_below` says whether the
# captured cause is there under it — the two halves a row asserts together.
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

# FILE defaults to the suite's own stderr; a suite whose fixture writes
# somewhere else passes it instead.
first_line() { # [FILE] -> line 1, `-` when nothing was written
  local line="" file="${1:-$ERR_FILE}"
  # One line, read in the shell: a `head` here stops reading while the hook
  # still writes, and its SIGPIPE would read as an empty stderr.
  IFS= read -r line <"$file" || :
  printf '%s' "${line:--}"
}

cause_below() { # [FILE] -> `present` when anything stands under line 1
  local file="${1:-$ERR_FILE}" n
  n=$(awk 'NR > 1 && NF { found = 1 } END { print found + 0 }' <"$file")
  [ "$n" = 1 ] && printf 'present' || printf 'absent'
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
