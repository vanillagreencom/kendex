#!/usr/bin/env bash
# The session-start-row, session-end-row and stop-failure-row hooks: each
# runs the lane-mail-check entry beside it with the argument `row` and the
# event. What the turn end writes for a row is the runtime's rows' subject;
# these rows hold the hooks' own lines. Every case builds a main checkout
# under TMP_ROOT with the install a kendex project renders and runs a wrapper
# with a payload in the shape Claude Code 2.1.283 emits. HOOK_UNDER_TEST
# overrides the lane-mail-check copy every case installs.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$TEST_DIR/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "session-rows: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "session-rows: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "session-rows: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
PASS=0
FAIL=0

assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# `display-message -p -t <pane> FORMAT`, the two tmux reads a row takes:
# `#{pid}`, the server's pid TMUX_SERVER_ID names, and `#{pane_pid}`, the
# pane's shell, which TMUX_PANE_PID names; and `#{pid} #{start_time}`, the
# server's start the turn-end hook binds the fleet record by, 1790000000.
TMUX_BIN="$TMP_ROOT/tmux-bin"
mkdir -p "$TMUX_BIN"
cat > "$TMUX_BIN/tmux" <<'TMUXSTUB'
#!/bin/sh
[ -n "${TMUX_SERVER_ID:-}" ] || { echo "can't find pane" >&2; exit 1; }
for format in "$@"; do :; done
case "$format" in
  '#{pane_pid}') printf '%s\n' "${TMUX_PANE_PID:-}" ;;
  '#{pid} #{start_time}') printf '%s 1790000000\n' "$TMUX_SERVER_ID" ;;
  *) printf '%s\n' "$TMUX_SERVER_ID" ;;
esac
TMUXSTUB
chmod +x "$TMUX_BIN/tmux"

# Synthetic process identities exercise ancestry, never process liveness.
# All other cases use the host's process table and owned Perl children.
PS_BIN="$(command -v ps)"
export PS_BIN
cat > "$TMUX_BIN/ps" <<'PSSTUB'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${SESSION_ROWS_ANCESTRY:-}" ] || exec "$PS_BIN" "$@"
pid="${!#}"
while IFS='|' read -r id parent comm args; do
  [ "$id" = "$pid" ] || continue
  [ "$comm" != unreadable ] || exit 1
  case "$*" in *args=*) printf '%s\n' "$args" ;; *) printf '%s %s\n' "$parent" "$comm" ;; esac
  exit 0
done < "$SESSION_ROWS_ANCESTRY"
# The hook shell begins the walk at its real $$, before the synthetic ids.
printf '9101 bash\n'
PSSTUB
chmod +x "$TMUX_BIN/ps"

# A main checkout on `main`, with the orch install and the hooks under
# .claude, and the overseer mailbox directory the fleet makes. CHECKOUT is the
# repository, ROWS the file the session in pane %9 on server 7000 writes.
CHECKOUT=""
ROWS=""
HOOK_HOME=.claude/hooks
new_checkout() { # NAME [HOOK_HOME]
  local hook
  HOOK_HOME="${2:-.claude/hooks}"
  CHECKOUT="$TMP_ROOT/$1"
  mkdir -p "$CHECKOUT"
  git -C "$CHECKOUT" init -q
  git -C "$CHECKOUT" checkout -q -b main
  git -C "$CHECKOUT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  mkdir -p "$CHECKOUT/.agents/skills/orch" "$CHECKOUT/$HOOK_HOME" "$CHECKOUT/.claude/skills" \
    "$CHECKOUT/tmp/lane-mail/overseer"
  ln -s "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
  mkdir -p "$CHECKOUT/.agents/skills/mailbox"
  ln -s "$REPO_ROOT/skills/mailbox/scripts" "$CHECKOUT/.agents/skills/mailbox/scripts"
  ln -s ../../.agents/skills/orch "$CHECKOUT/.claude/skills/orch"
  ln -s ../../.agents/skills/mailbox "$CHECKOUT/.claude/skills/mailbox"
  cp "$HOOK" "$CHECKOUT/$HOOK_HOME/lane-mail-check.sh"
  # Each hook by its own path, which is how tools/guard --range finds this
  # suite for a change to one of them.
  for hook in "$HOOKS/session-start-row.sh" "$HOOKS/session-end-row.sh" "$HOOKS/stop-failure-row.sh" \
    "$HOOKS/lane-mail-halt.sh"; do
    cp "$hook" "$CHECKOUT/$HOOK_HOME/${hook##*/}"
  done
  ROWS="$CHECKOUT/tmp/lane-mail/overseer/session-7000-9.jsonl"
}

RC=0
# in_pane COMMAND... — COMMAND as a harness in pane %9 runs its hook: a pane
# shell, whose pid is the pane's, then one process that is no shell, perl
# standing in for the harness, forking COMMAND. NESTED=1 puts a second such
# process between them, a harness another harness started in the same pane.
in_pane() { # COMMAND...
  if [ -n "${SESSION_ROWS_ANCESTRY:-}" ]; then
    TMUX_PANE_PID=9000 "$@"
    return
  fi
  local harness=(perl -e 'exit(system(@ARGV) >> 8)' --)
  [ "${NESTED:-0}" -eq 0 ] || harness+=(perl -e 'exit(system(@ARGV) >> 8)' --)
  bash -c 'TMUX_PANE_PID=$$ "$@"; exit $?' pane-shell "${harness[@]}" "$@"
}
# run WRAPPER PAYLOAD [ENV=VAL...] — the wrapper as the harness runs it, from
# the checkout, inside pane %9 of server 7000 on the account /accounts/one.
run() { # WRAPPER PAYLOAD [ENV=VAL...]
  local wrapper="$1" payload="$2"
  shift 2
  RC=0
  printf '%s' "$payload" |
    (cd "$CHECKOUT" && env -u CLAUDE_PROJECT_DIR -u CODEX_HOME -u LANE_MAIL_ITEM \
      "PATH=$TMUX_BIN:$PATH" TMUX=fake TMUX_PANE=%9 TMUX_SERVER_ID=7000 \
      CLAUDE_CONFIG_DIR=/accounts/one "$@" bash -c "$(declare -f in_pane); in_pane \"\$@\"" _ \
      bash "$CHECKOUT/$HOOK_HOME/$wrapper.sh") \
    >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

# Payloads as Claude Code 2.1.283 builds them: every hook input carries
# session_id, transcript_path, cwd and permission_mode; SessionStart adds
# source and model, SessionEnd reason, StopFailure error, error_details and
# last_assistant_message, and a subagent's turn its agent_id.
BASE='"session_id":"5f0c","transcript_path":"/t/5f0c.jsonl","cwd":"/work","permission_mode":"default"'
START="{\"hook_event_name\":\"SessionStart\",$BASE,\"source\":\"startup\",\"model\":\"claude-fable-5-1\"}"
END="{\"hook_event_name\":\"SessionEnd\",$BASE,\"reason\":\"prompt_input_exit\"}"
WALL="{\"hook_event_name\":\"StopFailure\",$BASE,\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your limit · resets 9:50am\"}"
SUB_WALL="{\"hook_event_name\":\"StopFailure\",$BASE,\"agent_id\":\"a1\",\"error\":\"rate_limit\"}"
STOP="{\"hook_event_name\":\"Stop\",$BASE,\"stop_hook_active\":false}"

last_row() { # JQ
  [ -f "$ROWS" ] || { echo absent; return 0; }
  tail -n 1 "$ROWS" | jq -r "$1"
}
row_count() { [ -f "$ROWS" ] && wc -l < "$ROWS" | tr -d ' ' || echo 0; }

echo "=== the row hooks ==="
new_checkout no_judge
rm -f -- "$CHECKOUT/.claude/hooks/lane-mail-check.sh"
for wrapper in session-start-row session-end-row stop-failure-row; do
  run "$wrapper" "$START"
  assert_eq "RC=$RC first=$(first_line)" "RC=0 first=$wrapper: judge=$CHECKOUT/.claude/hooks/lane-mail-check.sh" \
    "$wrapper with no judge beside it is reported and passed"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
