#!/usr/bin/env bash
# The payload reader the Bash hooks share, as one table each hook's suite runs
# against its own hook. Every hook inlines the same reader, so the rows are
# the same rows, and a copy that drifts reds in the suite of the hook it
# drifted in.
#
# Usage, from a suite:
#
#   . "$TEST_DIR/lib/payload-rows.sh"
#   payload_table "$HOOK" 'pkill -f x' 'kill 1234'        # [DIR]
#
# HOOK is the script under test, then a command that hook refuses and one it
# passes; DIR is the directory the hook runs in, the caller's working
# directory when absent. The suite defines `assert_eq GOT WANT LABEL`, counts
# PASS and FAIL, and holds TMP_ROOT, a directory it removes at exit; the
# table asserts through them.
#
# A row is `label|payload|command|world|rc|err`:
#   payload  the shape the command is carried in. `harness` is
#            {tool_input:{command}}, what Claude Code, Codex, Gemini CLI and
#            the Pi carrier send; `truncated` is that shape cut before its
#            closing braces; `number` and `false` name a command that is not
#            a string; `input-string` a tool_input that is not an object;
#            `no-command` a tool_input naming none; `top-level` a bare
#            `command` beside no tool_input, and `top-level-false` that
#            field as false; `copilot-object` and `copilot-string` are
#            Copilot's toolArgs, an object or one JSON-encoded string;
#            `copilot-text` a toolArgs string that is not JSON
#   command  what the shape carries: `refusing`, `passing`, `empty`; `-`
#            where the shape carries none
#   world    the PATH the hook runs under. `tools` holds every tool a hook
#            sourcing this table reads (jq, cat, grep, sed, git) and nothing
#            else; `no-jq` and `no-cat` are that set less the one tool;
#            `none` is a directory that does not exist
#   rc       the exit status
#   err      stderr reduced to the arm that wrote it: `parse` is the reader's
#            refusal of a payload it could not read, `tools` its refusal of a
#            PATH that cannot read one, `refusal` the hook's own refusal of a
#            command it read, `-` silence
#
# Every row runs the hook under `env -i` with HOME, PWD and the world's PATH
# and nothing else, so a passing row proves the hook read the payload with
# those tools alone. `tools` is `no-cat` plus cat and `no-jq` plus jq, so the
# passing harness row is the control that the PATH alone decided the tool
# rows. The Copilot shapes carry DIR as their cwd, as Copilot carries the
# directory the command runs in.
#
# HOOKS_TABLE_PROBE=1 renders `label => got` for every row instead of
# asserting; the run is then refused after the loop.

payload_json() { # shape command dir -> the payload text
  local shape="$1" c="$2" d="$3" whole
  case "$shape" in
    harness) jq -nc --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' ;;
    truncated)
      whole=$(jq -nc --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}')
      printf '%s' "${whole%\}\}}"
      ;;
    number) printf '%s' '{"tool_input":{"command":123}}' ;;
    false) printf '%s' '{"tool_input":{"command":false}}' ;;
    input-string) jq -nc --arg c "$c" '{tool_input:$c}' ;;
    no-command) printf '%s' '{"tool_name":"Bash","tool_input":{}}' ;;
    top-level) jq -nc --arg c "$c" '{command:$c}' ;;
    top-level-false) printf '%s' '{"command":false}' ;;
    copilot-object)
      jq -nc --arg c "$c" --arg d "$d" '{sessionId:"s",timestamp:1,cwd:$d,toolName:"bash",toolArgs:{command:$c}}'
      ;;
    copilot-string)
      jq -nc --arg c "$c" --arg d "$d" '{sessionId:"s",timestamp:1,cwd:$d,toolName:"bash",toolArgs:({command:$c}|tojson)}'
      ;;
    copilot-text) printf '%s' '{"toolName":"bash","toolArgs":"not json"}' ;;
    *)
      printf 'payload-rows: no payload shape named %s\n' "$shape" >&2
      exit 1
      ;;
  esac
}

payload_world() { # name tool... -> a directory holding those tools and nothing else
  local dir="$PAYLOAD_ROOT/$1" tool real
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    # type -P, not command -v: cat and friends are shell functions in some
    # interactive environments, and a function name symlinks to nothing.
    if ! real="$(type -P "$tool")"; then
      printf 'payload-rows: %s is not on PATH, so the tool worlds cannot be built\n' "$tool" >&2
      exit 1
    fi
    ln -s "$real" "$dir/$tool"
  done
}

payload_err_kind() { # -> the arm that wrote stderr
  local text
  text="$(cat "$PAYLOAD_ROOT/stderr")"
  case "$text" in
    "") printf -- '-' ;;
    *"not valid JSON"*) printf 'parse' ;;
    *"required to read the hook payload"*) printf 'tools' ;;
    *) printf 'refusal' ;;
  esac
}

payload_run() { # hook dir path payload -> "rc=N err=KIND"
  local hook="$1" dir="$2" path="$3" payload="$4" rc=0
  printf '%s' "$payload" | (
    cd "$dir" && env -i HOME="$HOME" PWD="$dir" PATH="$path" "$PAYLOAD_BASH" "$hook" \
      >/dev/null 2>"$PAYLOAD_ROOT/stderr"
  ) || rc=$?
  printf 'rc=%s err=%s' "$rc" "$(payload_err_kind)"
}

PAYLOAD_ROWS="\
the refusing command under the harness shape is refused, so the shape is read|harness|refusing|tools|2|refusal
the passing command under the harness shape passes|harness|passing|tools|0|-
a truncated payload is refused unread rather than skipping the guard|truncated|refusing|tools|2|parse
a command that is not a string is refused unread|number|-|tools|2|parse
a command of false is refused unread, not read as an absent one|false|-|tools|2|parse
a tool_input that is not an object is refused unread|input-string|refusing|tools|2|parse
an empty command is read and passes, not a read failure|harness|empty|tools|0|-
a payload naming no command passes|no-command|-|tools|0|-
a top-level command field is read like a nested one|top-level|refusing|tools|2|refusal
a top-level false is refused unread, not read as an absent one|top-level-false|-|tools|2|parse
a Copilot toolArgs object is read|copilot-object|refusing|tools|2|refusal
a Copilot toolArgs JSON string is read|copilot-string|refusing|tools|2|refusal
the passing command under toolArgs passes, so the shape is read rather than refused|copilot-object|passing|tools|0|-
a toolArgs string that is not JSON is refused unread rather than skipping the guard|copilot-text|-|tools|2|parse
without jq the refusing command is refused unread rather than guessed at|harness|refusing|no-jq|2|tools
without jq even the passing command is refused: nothing was read|harness|passing|no-jq|2|tools
without cat the passing command is refused unread rather than dying at the read|harness|passing|no-cat|2|tools
with no tools at all the passing command is refused unread|harness|passing|none|2|tools
"

payload_table() { # hook refusing passing [dir]
  local hook="$1" refusing="$2" passing="$3" dir="${4:-$PWD}"
  local label shape command world rc err row field text path got before=$((PASS + FAIL))
  PAYLOAD_BASH="$(command -v bash)"
  PAYLOAD_ROOT="${TMP_ROOT:?}/payload-rows"
  rm -rf -- "${TMP_ROOT:?}/payload-rows"
  mkdir -p "$PAYLOAD_ROOT"
  # cat is the other half of the reader: jq reads the payload, cat is what
  # hands it over, and a hook that reaches `INPUT=$(cat)` without it dies
  # with a status that is not 2, which the harness runs the command past.
  payload_world tools jq cat grep sed git
  payload_world no-jq cat grep sed git
  payload_world no-cat jq grep sed git
  echo "=== $(basename "$hook" .sh): the payload reader ==="
  while IFS= read -r row; do
    [ "$row" != "" ] || continue
    IFS='|' read -r label shape command world rc err <<<"$row"
    for field in "$label" "$shape" "$command" "$world" "$rc" "$err"; do
      [ "$field" != "" ] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    case "$command" in
      refusing) text="$refusing" ;;
      passing) text="$passing" ;;
      empty | -) text="" ;;
      *)
        printf 'payload-rows: no command named %s: %s\n' "$command" "$row" >&2
        exit 1
        ;;
    esac
    case "$world" in
      tools | no-jq | no-cat) path="$PAYLOAD_ROOT/$world" ;;
      none) path="$PAYLOAD_ROOT/none" ;;
      *)
        printf 'payload-rows: no world named %s: %s\n' "$world" "$row" >&2
        exit 1
        ;;
    esac
    got="$(payload_run "$hook" "$dir" "$path" "$(payload_json "$shape" "$text" "$dir")")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [ "${HOOKS_TABLE_PROBE:-}" = 1 ]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc err=$err" "$label"
  done <<<"$PAYLOAD_ROWS"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}
