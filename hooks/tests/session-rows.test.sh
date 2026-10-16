#!/usr/bin/env bash
# The session rows the session-start-row, session-end-row and stop-failure-row
# hooks write: each runs the lane-mail-check hook beside it with the argument
# `row`, which appends the payload's event as one JSON row through the orch
# skill's lib/session-rows.sh to the session's file in the overseer mailbox
# directory, and refuses nothing. Every case builds a main checkout under
# TMP_ROOT with the install a kendex project renders, runs a wrapper with a
# payload in the shape Claude Code 2.1.283 emits, and asserts the exit status,
# the keyed first line of stderr and the row. HOOK_UNDER_TEST overrides the
# lane-mail-check copy the control at the end runs against.
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

echo "=== session rows ==="

# One table: each wrapper and payload, and the row it leaves. `-` is no row.
while IFS='|' read -r label wrapper payload want; do
  new_checkout "$label"
  run "$wrapper" "$payload"
  got="$(last_row '[.event, .harness, .session_id, .transcript_path, .cwd, .account, (.source // .reason // .error // "-")] | join(",")')"
  assert_eq "RC=$RC first=$(first_line) row=$got" "RC=0 first=- row=$want" "$label"
done <<ROWSTABLE
start|session-start-row|$START|SessionStart,claude,5f0c,/t/5f0c.jsonl,/work,/accounts/one,startup
end|session-end-row|$END|SessionEnd,claude,5f0c,/t/5f0c.jsonl,/work,/accounts/one,prompt_input_exit
wall|stop-failure-row|$WALL|StopFailure,claude,5f0c,/t/5f0c.jsonl,/work,/accounts/one,rate_limit
ROWSTABLE

new_checkout wall_message
run stop-failure-row "$WALL"
assert_eq "$(last_row '.message')|$(last_row '.at | type')" "You've hit your limit · resets 9:50am|number" \
  "a StopFailure row keeps the harness's own message, and every row its time"

# What writes nothing, silently: a subagent's failure, a checkout the fleet
# never made a mailbox directory in, a session outside tmux, and a lane's own
# session.
new_checkout subagent
run stop-failure-row "$SUB_WALL"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a subagent's failure is no row of the session's"
# A Stop is written at every turn end, compact, its time, event, harness and
# session alone, so the file takes one per turn; over a standing StopFailure it
# is written whole, and lifts it.
new_checkout stop_alone
run session-start-row "$START"
run session-start-row "$STOP"
assert_eq "RC=$RC rows=$(row_count) row=$(last_row '[keys[]] | join(",")')" "RC=0 rows=2 row=at,event,harness,session_id" \
  "a Stop with no StopFailure standing writes a compact Stop row"
run stop-failure-row "$WALL"
run session-start-row "$STOP"
assert_eq "RC=$RC rows=$(row_count) last=$(last_row .event) path=$(last_row .transcript_path)" "RC=0 rows=4 last=Stop path=/t/5f0c.jsonl" \
  "a Stop over a StopFailure row is written whole and lifts it"
# A start many turns back is still the session's start: its readers look for
# the last row of an event among the rows naming it, not in the last lines.
for _ in $(seq 70); do run session-start-row "$STOP"; done
start_found() { # LIBRARY
  bash -c 'set -euo pipefail; . "$1"; session_rows_start "$2" && printf "%s\n" "$SR_MODEL"' _ "$1" "$ROWS" 2>/dev/null || echo none
}
assert_eq "$(start_found "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh")" "claude-fable-5-1" \
  "a SessionStart seventy Stop rows back is still read"
# A consumer with orch installed and no overseer: the fleet never made the
# mailbox directory, so each wrapper exits 0, says nothing on either stream and
# adds no file anywhere in the checkout.
tree_of() { (cd "$CHECKOUT" && find . -path ./.git -prune -o -print) | LC_ALL=C sort; }
quiet_run() { # WRAPPER PAYLOAD — its status, both streams' bytes, the paths it added
  local before after added
  before="$(tree_of)" || return 1
  run "$1" "$2"
  after="$(tree_of)" || return 1
  added="$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | paste -s -d, -)" || return 1
  printf 'RC=%s out=%s err=%s added=%s' "$RC" "$(wc -c < "$TMP_ROOT/stdout" | tr -d ' ')" \
    "$(wc -c < "$ERR_FILE" | tr -d ' ')" "$added"
}
QUIET_ROWS="session-start-row|$START
session-end-row|$END
stop-failure-row|$WALL"
while IFS='|' read -r wrapper payload; do
  new_checkout "no_fleet_$wrapper"
  rm -rf -- "${CHECKOUT:?}/tmp"
  got="$(quiet_run "$wrapper" "$payload")" || { echo "session-rows: tree=unreadable value=[$CHECKOUT]" >&2; exit 1; }
  assert_eq "$got" "RC=0 out=0 err=0 added=" \
    "$wrapper with no overseer mailbox directory exits 0, silent, adding no file"
done <<<"$QUIET_ROWS"
new_checkout outside_tmux
run session-start-row "$START" TMUX= TMUX_PANE=
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a session outside tmux has no pane to key a row by"
new_checkout lane
git -C "$CHECKOUT" checkout -q -b ken-9
mkdir -p "$CHECKOUT/tmp/lane-mail/KEN-9"
run session-start-row "$START"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a lane's session writes no overseer row"

# A harness the overseer started in its own pane, second-opinion's
# `claude -p` or a `codex exec`, inherits TMUX_PANE: its hook is two
# harnesses from the pane shell and writes no row, so no reader meets another
# session's facts in this pane's file.
new_checkout nested
NESTED=1 run session-end-row "$END"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a harness nested in the pane's own harness writes no row"

# The installed npm command is a symlink to @openai/codex/bin/codex.js.
# These fixtures provide that path identity only. They execute no launcher.
LAUNCHER="$TMP_ROOT/install/lib/node_modules/@openai/codex/bin/codex.js"
mkdir -p "${LAUNCHER%/*}" "$TMP_ROOT/install/bin"
: > "$LAUNCHER"
ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$TMP_ROOT/install/bin/codex"
ANCESTRY_START='{"hook_event_name":"SessionStart","session_id":"lead-native","cwd":"/native/work","model":"native-model"}'
ANCESTRY_NESTED='{"hook_event_name":"SessionStart","session_id":"nested-native","cwd":"/nested/work","model":"nested-model"}'
ancestry_cases() { # [LIBRARY_COPY]
  local mutant="${1:-}" label chain accepted id parent kind rest comm args before
  while IFS='|' read -r label chain accepted; do
    new_checkout "ancestry_${mutant:+control_}$label" .codex/hooks
    if [ -n "$mutant" ]; then
      rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
      cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
      cp -- "$mutant" "$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
    fi
    # Every rejection starts with a lead identity written by the real owner.
    run session-start-row "$ANCESTRY_START" CODEX_HOME=/accounts/native
    before="$(cat -- "$ROWS")"
    ANCESTRY_FILE="$TMP_ROOT/ancestry"
    : > "$ANCESTRY_FILE"
    id=9101
    rest="$chain,"
    while [ -n "$rest" ]; do
      kind="${rest%%,*}"; rest="${rest#*,}"
      parent=$((id + 1))
      [ -n "$rest" ] || parent=9000
      case "$kind" in
        native) comm=codex; args=/native/codex ;;
        launcher) comm=node; args="node $LAUNCHER" ;;
        mainthread) comm=node-MainThread; args="node $LAUNCHER" ;;
        command) comm=node; args="node $TMP_ROOT/install/bin/codex exec" ;;
        unrelated) comm=node; args="node $TMP_ROOT/unrelated.js" ;;
        nonnode) comm=perl; args="perl $LAUNCHER" ;;
        missing) comm=node; args="node $TMP_ROOT/absent/@openai/codex/bin/codex.js" ;;
        shell) comm=bash; args=bash ;;
        other) comm=perl; args=perl ;;
        unreadable) comm=unreadable; args= ;;
        *) return 1 ;;
      esac
      printf '%s|%s|%s|%s\n' "$id" "$parent" "$comm" "$args" >> "$ANCESTRY_FILE"
      id="$parent"
    done
    run session-start-row "$ANCESTRY_NESTED" "SESSION_ROWS_ANCESTRY=$ANCESTRY_FILE" CODEX_HOME=/accounts/native
    assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=$accepted" "ancestry $label writer outcome"
    if [ "$accepted" -eq 2 ]; then
      assert_eq "$(last_row '[.session_id, .harness, .account, .model, .cwd] | join(",")')" \
        "nested-native,codex,/accounts/native,nested-model,/nested/work" "ancestry $label native identity"
    else
      assert_eq "$(cat -- "$ROWS")" "$before" "ancestry $label preserves lead"
    fi
  done <<'ANCESTRY'
native|native|2
installed_script|native,launcher,shell|2
installed_node_main_thread|native,mainthread,shell|2
installed_command|native,command,shell|2
nested_native|native,shell,native,launcher|1
second_launcher_pair|native,launcher,shell,native,launcher|1
under_other_harness|native,launcher,shell,other|1
unrelated_node|native,unrelated,shell|1
other_script_runner|native,nonnode,shell|1
missing_launcher|native,missing,shell|1
indirect_launcher|native,shell,launcher|1
unreadable_parent|native,unreadable|1
other_lead|other,shell|2
other_nested|other,shell,other|1
ANCESTRY
}
ancestry_cases

# Broadly admitting another non-shell ancestor must fail the same writer
# assertions. The mutant retains the original condition as its first arm.
ANCESTRY_MUTANT="$TMP_ROOT/ancestry-mutant.sh"
cp "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" "$ANCESTRY_MUTANT"
ANCESTRY_RULE='  [ "$harnesses" -eq 1 ]'
assert_eq "$(grep -c -x -F -- "$ANCESTRY_RULE" "$ANCESTRY_MUTANT")" 1 "ancestry control finds the harness bound"
ANCESTRY_RULE="$ANCESTRY_RULE" perl -i -pe 's/^\Q$ENV{ANCESTRY_RULE}\E$/  [ "\$harnesses" -eq 1 ] || [ "\$harnesses" -eq 2 ]/' "$ANCESTRY_MUTANT"
assert_eq "$(grep -c -x -F -- "$ANCESTRY_RULE" "$ANCESTRY_MUTANT" || true)" 0 "ancestry control changed the harness bound"
CONTROL_RC=0
CONTROL_OUT="$(PASS=0; FAIL=0; ancestry_cases "$ANCESTRY_MUTANT"; [ "$FAIL" -eq 0 ])" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 "ancestry control fails the writer contract"
assert_eq "$(grep -c '^  FAIL  ancestry unrelated_node preserves lead$' <<<"$CONTROL_OUT")" 1 \
  "ancestry control detects the unrelated Node overwriting the lead"

# The harness a row names is the one the hook's install directory names.
new_checkout codex_install .codex/hooks
run session-start-row "$START"
assert_eq "RC=$RC harness=$(last_row .harness)" "RC=0 harness=codex" \
  "a hook installed under .codex/hooks writes a codex row"
# Codex 0.160.0's SessionEnd payload: the main thread's session_id,
# transcript_path, cwd and permission_mode, and a reason that is always
# `other` (Codex hooks reference).
CODEX_END='{"session_id":"019a","transcript_path":"/r/rollout-019a.jsonl","cwd":"/work","hook_event_name":"SessionEnd","reason":"other","permission_mode":"default"}'
new_checkout codex_end .codex/hooks
run session-end-row "$CODEX_END"
assert_eq "RC=$RC first=$(first_line) row=$(last_row '[.event, .harness, .session_id, .transcript_path, .cwd, .reason] | join(",")')" \
  "RC=0 first=- row=SessionEnd,codex,019a,/r/rollout-019a.jsonl,/work,other" \
  "a Codex SessionEnd writes a codex row"

# Copilot, from .github/hooks, with payloads in the camelCase shape Copilot
# CLI 1.0.91 sent tools/harness-smoke's event rows: no hook_event_name, the
# session as sessionId, sessionStart and sessionEnd for the lead alone.
COP_HOME_DIR="$TMP_ROOT/cop-home"
mkdir -p "$COP_HOME_DIR"
COP_BASE='"sessionId":"l1","timestamp":1790975267602,"cwd":"/work"'
COP_START="{$COP_BASE,\"source\":\"new\",\"initialPrompt\":\"Reply with ok.\"}"
COP_END="{$COP_BASE,\"reason\":\"error\"}"
COP_ENV=("HOME=$COP_HOME_DIR" COPILOT_HOME=/accounts/cop)
while IFS='|' read -r label wrapper payload want; do
  new_checkout "$label" .github/hooks
  run "$wrapper" "$payload" "${COP_ENV[@]}"
  got="$(last_row '[.event, .harness, .session_id, .cwd, .account, (.source // .reason // "-")] | join(",")')"
  assert_eq "RC=$RC first=$(first_line) row=$got" "RC=0 first=- row=$want" "$label"
done <<ROWSTABLE
copilot start|session-start-row|$COP_START|SessionStart,copilot,l1,/work,/accounts/cop,new
copilot end|session-end-row|$COP_END|SessionEnd,copilot,l1,/work,/accounts/cop,error
ROWSTABLE

# What is reported and passed: an install whose orch scripts lack the row
# library, a key tmux cannot answer, and a wrapper with no judge beside it.
new_checkout no_library
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
mkdir -p "$CHECKOUT/.agents/skills/orch/scripts/lib"
run session-start-row "$START"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" \
  "RC=0 first=lane-mail-check: rows-skipped=$CHECKOUT/.claude/skills/orch/scripts/lib/session-rows.sh rows=0" \
  "an install with no row library is reported and the session starts"
new_checkout no_key
run session-start-row "$START" TMUX_SERVER_ID=
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=lane-mail-check: rows-unwritten=$CHECKOUT rows=0" \
  "a pane tmux cannot key is reported and the session starts"
new_checkout no_judge
rm -f -- "$CHECKOUT/.claude/hooks/lane-mail-check.sh"
for wrapper in session-start-row session-end-row stop-failure-row; do
  run "$wrapper" "$START"
  assert_eq "RC=$RC first=$(first_line)" "RC=0 first=$wrapper: judge=$CHECKOUT/.claude/hooks/lane-mail-check.sh" \
    "$wrapper with no judge beside it is reported and passed"
done

# The overseer's own turn end writes the Stop that lifts its wall. The fleet
# state names pane %9 on server 7000 as the overseer, and a judge stub puts it
# under both marks, so the turn ends; what it judges is lane-mail-check.test.sh's.
new_checkout overseer_stop
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
printf '#!/bin/sh\necho "oversee-succeed: context-below-mark tokens=1 mark=500000 headroom=80"\n' \
  > "$CHECKOUT/.agents/skills/orch/scripts/oversee-succeed"
(cd "$CHECKOUT" && .agents/skills/orch/scripts/workflow-state init oversee >/dev/null \
  && .agents/skills/orch/scripts/workflow-state set oversee overseer '{"server":"7000","server_start":1790000000,"pane":"%9"}' >/dev/null)
run stop-failure-row "$WALL"
RC=0
printf '%s' '{"session_id":"5f0c","stop_hook_active":false}' |
  (cd "$CHECKOUT" && env -u CLAUDE_PROJECT_DIR -u CODEX_HOME "PATH=$TMUX_BIN:$PATH" TMUX=fake TMUX_PANE=%9 \
    TMUX_SERVER_ID=7000 CLAUDE_CONFIG_DIR=/accounts/one bash -c "$(declare -f in_pane); in_pane \"\$@\"" _ \
    bash "$CHECKOUT/.claude/hooks/lane-mail-check.sh") \
  >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
assert_eq "RC=$RC rows=$(row_count) last=$(last_row .event)" "RC=0 rows=2 last=Stop" \
  "the overseer's turn end, whose payload names no event, writes the Stop over its wall"

# The lock wait against the hooks that write rows. A writer is a hook under
# ROOT/hooks whose body runs a session_rows writer or lane-mail-check's row
# arm; each copy of it git tracks under ROOT, the source and every harness
# render, declares a `timeout:` the harness kills it at, which must sit above
# the library's SESSION_ROWS_WAIT so a writer losing the lock says so before
# it is killed. Prints one `copy=<path> timeout=<n> wait=<n>` line per copy
# past the bound, then `writers=<name,...>` and `copies=<n>`. A non-writer
# taken in only adds a copy to judge, so over-inclusion stays open.
wait_bound() { # LIB ROOT
  local wait writer name copies copy timeout names="" count=0
  wait="$(sed -n 's/^SESSION_ROWS_WAIT=\([0-9][0-9]*\)$/\1/p' "$1")" || return 2
  [[ $wait =~ ^[0-9]+$ ]] || { echo "wait=unreadable value=[$wait]"; return 0; }
  for writer in "$2"/hooks/*.sh; do
    grep -q -E 'session_rows_(lane_)?write |"\$JUDGE" row ' "$writer" || continue
    name="${writer##*/}"
    names="$names${names:+,}${name%.sh}"
    copies="$(git -C "$2" ls-files -- ":(glob)**/hooks/$name")" || return 2
    while IFS= read -r copy; do
      [ -n "$copy" ] || continue
      count=$((count + 1))
      timeout="$(awk '/^# ---$/ { n++; next } n == 1 && sub(/^# timeout: */, "") { print; exit }' "$2/$copy")" || return 2
      [[ $timeout =~ ^[0-9]+$ ]] && [ "$wait" -lt "$timeout" ] ||
        echo "copy=$copy timeout=${timeout:-absent} wait=$wait"
    done <<<"$copies"
  done
  echo "writers=$names"
  echo "copies=$count"
}
BOUND="$(wait_bound "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" "$REPO_ROOT")" ||
  { echo "session-rows: wait-bound=unreadable" >&2; exit 1; }
assert_eq "$(grep -c -E '^(copy|wait)=' <<<"$BOUND" || true)" "0" \
  "every tracked copy of a row-writing hook times out above the row lock wait: $BOUND"
# Floor and required members: the extractor finds the wrappers and the writer,
# and each one's source copy at least.
assert_eq "$(grep -c -E '^writers=(.*,)?lane-mail-check,(.*,)?session-end-row(,|$)' <<<"$BOUND" || true)" "1" \
  "the writer extractor finds lane-mail-check and session-end-row"
assert_eq "$(sed -n 's/^copies=\([0-9]*\)$/\1/p' <<<"$BOUND" | awk '{ print ($1 >= 4) }')" "1" \
  "the copy extractor finds each writer's source"

# --- control ------------------------------------------------------------------
# The quiet runs again with the mailbox directory standing: each wrapper adds
# its row file, so the no-file assertion above reaches what a write leaves.
while IFS='|' read -r wrapper payload; do
  new_checkout "fleet_control_$wrapper"
  got="$(quiet_run "$wrapper" "$payload")" || { echo "session-rows: tree=unreadable value=[$CHECKOUT]" >&2; exit 1; }
  assert_eq "$got" "RC=0 out=0 err=0 added=./tmp/lane-mail/overseer/session-7000-9.jsonl" \
    "control: $wrapper with the mailbox directory standing adds its row file"
done <<<"$QUIET_ROWS"
# SESSION_ROWS_WAIT raised to session-end-row's own 3 s in a copy of the
# library: its source copy is past the bound.
WAIT_LIB="$TMP_ROOT/wait-session-rows.sh"
cp "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" "$WAIT_LIB"
assert_eq "$(grep -c -x 'SESSION_ROWS_WAIT=[0-9]*' "$WAIT_LIB" || true)" "1" "control finds the lock wait"
sed -i.bak 's/^SESSION_ROWS_WAIT=[0-9]*$/SESSION_ROWS_WAIT=3/' "$WAIT_LIB"
assert_eq "$(grep -c -x 'SESSION_ROWS_WAIT=3' "$WAIT_LIB" || true)" "1" "control set it to 3"
BOUND="$(wait_bound "$WAIT_LIB" "$REPO_ROOT")" || { echo "session-rows: wait-bound=unreadable" >&2; exit 1; }
assert_eq "$(grep -c -x 'copy=hooks/session-end-row.sh timeout=3 wait=3' <<<"$BOUND" || true)" "1" \
  "control: a lock wait of 3 s puts session-end-row past the bound"
# The row arm's write removed from a copy of the hook: the start row is gone.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  MUTANT="$TMP_ROOT/mutant-lane-mail-check.sh"
  cp "$HOOK" "$MUTANT"
  assert_eq "$(grep -c -F '  [ -n "$ITEM" ] || session_row' "$MUTANT")" "1" "control finds the row arm's write"
  sed -i.bak 's/  \[ -n "\$ITEM" \] || session_row/  :/' "$MUTANT"
  assert_eq "$(grep -c -F '  [ -n "$ITEM" ] || session_row' "$MUTANT")" "0" "control removed it"
  CONTROL_OUT="$(HOOK_UNDER_TEST="$MUTANT" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
  assert_eq "$(grep -c '^  FAIL  start$' <<<"$CONTROL_OUT")" "1" \
    "control: without the row arm's write the start row is not written"
fi
# The library's compact Stop rule removed from a copy of the orch scripts: a
# Stop with no wall standing then lands whole.
new_checkout stop_control
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
STOP_RULE='!= StopFailure ]; then'
assert_eq "$(grep -c -F -- "$STOP_RULE" "$LIB")" "1" "control finds the Stop rule"
sed -i.bak 's/!= StopFailure \]; then/= Never ]; then/' "$LIB"
assert_eq "$(grep -c -F -- "$STOP_RULE" "$LIB")" "0" "control removed it"
run session-start-row "$STOP"
assert_eq "path=$(last_row .transcript_path)" "path=/t/5f0c.jsonl" "control: without the compact Stop rule a turn's Stop lands whole"
# Each camelCase read removed from a copy of the orch scripts: a Copilot
# session end's row then lacks what that read carries.
n=0
while IFS='@' read -r old new field label; do
  n=$((n + 1))
  new_checkout "camel_control_$n" .github/hooks
  rm -f -- "${CHECKOUT:?}/.agents/skills/orch/scripts"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
  CAMEL_LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
  assert_eq "$(grep -c -F -- "$old" "$CAMEL_LIB")" "1" "control finds: $old"
  OLD="$old" NEW="$new" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$CAMEL_LIB"
  assert_eq "$(grep -c -F -- "$old" "$CAMEL_LIB")" "0" "control removed: $old"
  run session-end-row "$COP_END" "${COP_ENV[@]}"
  assert_eq "RC=$RC $field=$(last_row ".$field // \"-\"")" "RC=0 $field=-" "control: $label"
done <<'CAMEL'
({session_id: (.session_id // .sessionId), transcript_path@({session_id, transcript_path@session_id@without the sessionId read a Copilot session end's row names no session
CAMEL
# The event list removed from the reader: a start seventy Stops back is lost.
READ_RULE='    lines="$(grep -F -- "\"event\":\"$2\"" "$1")" || rc=$?'
assert_eq "$(grep -c -F -- "$READ_RULE" "$LIB")" "1" "control finds the event list"
READ_RULE="$READ_RULE" perl -i -pe 's/\Q$ENV{READ_RULE}\E/    lines="\$(cat -- "\$1")" || rc=\$?/' "$LIB"
assert_eq "$(grep -c -F -- "$READ_RULE" "$LIB")" "0" "control removed the event list"
new_checkout start_span_control
run session-start-row "$START"
for _ in $(seq 70); do run session-start-row "$STOP"; done
assert_eq "$(start_found "$LIB")" "none" "control: a reader taking the last lines alone loses a start seventy Stops back"
# The top-level gate removed from the same copy: a nested harness writes.
mutate_lib() { # OLD NEW
  assert_eq "$(grep -c -F -- "$1" "$LIB")" "1" "control finds: $1"
  OLD="$1" NEW="$2" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$LIB"
  assert_eq "$(grep -c -F -- "$1" "$LIB")" "0" "control removed: $1"
}
new_checkout nested_control
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
mutate_lib '  session_rows_top_level "$pane_pid" || return 0' '  :'
NESTED=1 run session-end-row "$END"
assert_eq "rows=$(row_count)" "rows=1" "control: without the top-level gate a nested harness writes the pane's row"
# The harness read from the install replaced by a fixed word: a codex install
# writes claude.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  HARNESS_MUTANT="$TMP_ROOT/harness-mutant.sh"
  cp "$HOOK" "$HARNESS_MUTANT"
  assert_eq "$(grep -c -F '    _ "$SCRIPTS" "$ROOT" "$HARNESS" "$ROW_EVENT"' "$HARNESS_MUTANT")" "1" "control finds the row's harness"
  sed -i.bak 's/    _ "\$SCRIPTS" "\$ROOT" "\$HARNESS" "\$ROW_EVENT"/    _ "$SCRIPTS" "$ROOT" claude "$ROW_EVENT"/' "$HARNESS_MUTANT"
  assert_eq "$(grep -c -F '    _ "$SCRIPTS" "$ROOT" "$HARNESS" "$ROW_EVENT"' "$HARNESS_MUTANT")" "0" "control replaced it"
  CONTROL_OUT="$(HOOK_UNDER_TEST="$HARNESS_MUTANT" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
  assert_eq "$(grep -c '^  FAIL  a hook installed under .codex/hooks writes a codex row$' <<<"$CONTROL_OUT")" "1" \
    "control: a row harness fixed at claude fails the codex install row"
  assert_eq "$(grep -c '^  FAIL  a Codex SessionEnd writes a codex row$' <<<"$CONTROL_OUT")" "1" \
    "control: a row harness fixed at claude fails the Codex SessionEnd row"
fi
# The event the wrapper names removed from the checkout's copy of
# session-start-row: a Copilot payload, which spells none, writes no row.
new_checkout event_control .github/hooks
WRAPPER="$CHECKOUT/.github/hooks/session-start-row.sh"
EVENT_RULE='exec "$BASH" "$JUDGE" row SessionStart'
assert_eq "$(grep -c -x -F -- "$EVENT_RULE" "$WRAPPER")" "1" "control finds the wrapper's event"
EVENT_RULE="$EVENT_RULE" perl -i -pe 's/^\Q$ENV{EVENT_RULE}\E$/exec "\$BASH" "\$JUDGE" row/' "$WRAPPER"
assert_eq "$(grep -c -x -F -- "$EVENT_RULE" "$WRAPPER")" "0" "control removed it"
run session-start-row "$COP_START" "${COP_ENV[@]}"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=lane-mail-check: rows-unwritten=$CHECKOUT rows=0" \
  "control: without the wrapper's event a Copilot start writes no row"

# A Jarvis launch: the runtime record's pending row names generation 3 on
# server 7000, pane %9, with the id the launch preassigned where the harness
# takes one, and the harness carries JARVIS_RECORD and JARVIS_GENERATION. The
# checkout has no overseer mailbox, so the record is the only place a start
# lands. Payloads are each harness's SessionStart: Codex 0.160.0's, Copilot
# CLI 1.0.91's camelCase, and the pi-hooks carrier's.
CODEX_START='{"session_id":"019a","transcript_path":"/r/rollout-019a.jsonl","cwd":"/work","hook_event_name":"SessionStart","source":"startup","model":"gpt-5"}'
PI_START='{"hook_event_name":"SessionStart","source":"startup","session_id":"p1","transcript_path":"/p/p1.jsonl"}'
jarvis_checkout() { # LABEL HOOK_HOME [PREASSIGNED] [MAILBOX=absent]
  local harness
  case "$2" in
    .claude/hooks) harness=claude ;;
    .codex/hooks) harness=codex ;;
    .github/hooks) harness=copilot ;;
    .pi/kendex/hooks) harness=pi ;;
    *) return 1 ;;
  esac
  new_checkout "$1" "$2"
  [ "${4:-absent}" = present ] || rm -rf -- "${CHECKOUT:?}/tmp"
  RECORD="$TMP_ROOT/$1-record.json"
  jq -nc --arg harness "$harness" --arg id "${3:-}" '{harness: $harness, generation: 3, pending: ({generation: 3, server: 7000, pane: "%9"}
    + (if $id == "" then {} else {native_session_id: $id} end))}' >"$RECORD"
}
pending() { jq -r '[.pending.native_session_id, .pending.session_file, (.pending.started_at | type)] | map(. // "-") | join(",")' "$RECORD"; }
JARVIS_ENV=(JARVIS_GENERATION=3)
while IFS='|' read -r label home preassigned payload want account; do
  jarvis_checkout "jarvis_$label" "$home" "$preassigned"
  run session-start-row "$payload" "${COP_ENV[@]}" CODEX_HOME=/accounts/codex PI_CODING_AGENT_DIR=/accounts/pi \
    "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
  assert_eq "RC=$RC first=$(first_line) pending=$(pending) mailbox=$([ -e "$CHECKOUT/tmp" ] && echo made || echo none)" \
    "RC=0 first=- pending=$want mailbox=none" "a managed $label start records its native identity with no mailbox"
  assert_eq "$(jq -r '.pending.observed_account' "$RECORD")" "$account" \
    "a managed $label start acknowledges its native account"
done <<JARVISTABLE
claude|.claude/hooks|5f0c|$START|5f0c,/t/5f0c.jsonl,number|/accounts/one
codex|.codex/hooks||$CODEX_START|019a,/r/rollout-019a.jsonl,number|/accounts/codex
copilot|.github/hooks|l1|$COP_START|l1,-,number|/accounts/cop
pi|.pi/kendex/hooks|p1|$PI_START|p1,/p/p1.jsonl,number|/accounts/pi
JARVISTABLE

# What leaves the record as it stands: a session in the same home with no
# Jarvis environment, one on another server or pane, one of another generation, a
# harness nested in the managed one, a second start of a launch already
# recorded, and a start the harness names by another id than the preassigned
# one, which alone is reported.
jarvis_untouched() { # LABEL PAYLOAD WANT_FIRST [ENV=VAL...]
  local label="$1" payload="$2" want="$3" before
  shift 3
  before="$(cat "$RECORD")"
  run session-start-row "$payload" "$@"
  assert_eq "RC=$RC first=$(first_line) same=$([ "$(cat "$RECORD")" = "$before" ] && echo yes || echo no)" \
    "RC=0 first=$want same=yes" "$label"
}
jarvis_checkout jarvis_unmanaged .claude/hooks
jarvis_untouched "a non-managed session in the same home writes nothing to the record" "$START" -
while IFS='|' read -r label nested env; do
  jarvis_checkout "jarvis_$label" .claude/hooks
  # shellcheck disable=SC2086  # env is a list of assignments.
  NESTED="$nested" jarvis_untouched "a $label session leaves the managed record unchanged" "$START" - \
    "JARVIS_RECORD=$RECORD" $env
done <<'JARVISUNTOUCHED'
server|0|TMUX_SERVER_ID=8000 JARVIS_GENERATION=3
pane|0|TMUX_PANE=%8 JARVIS_GENERATION=3
generation|0|JARVIS_GENERATION=2
nested|1|JARVIS_GENERATION=3
JARVISUNTOUCHED
jarvis_checkout jarvis_again .claude/hooks
run session-start-row "$START" "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
jarvis_untouched "a second start of a recorded launch leaves the first identity" \
  "${START/5f0c/6a1d}" - "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
jarvis_checkout jarvis_other_harness .claude/hooks
jq '.harness = "codex"' "$RECORD" >"$RECORD.next"
mv "$RECORD.next" "$RECORD"
jarvis_untouched "another native harness leaves the managed record unchanged" "$START" - \
  "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
while IFS='|' read -r mailbox count want_row; do
  jarvis_checkout "jarvis_mismatch_$mailbox" .claude/hooks 6a1d "$mailbox"
  jarvis_untouched "a mismatched start with mailbox $mailbox reports the refusal and preserves the record" "$START" \
    "lane-mail-check: rows-unwritten=$CHECKOUT" "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
  assert_eq "rows=$(row_count) row=$(last_row '[.event, .harness, .session_id, .transcript_path] | join(",")')" \
    "rows=$count row=$want_row" "a mismatched start with mailbox $mailbox keeps the ordinary row outcome"
  assert_eq "$(sed -n '2,$p' "$ERR_FILE" | grep -c -x -F "jarvis-identity=mismatch record=$RECORD" || true)" "1" \
    "the refused start with mailbox $mailbox reports its mismatch below the keyed notice"
done <<'JARVISMISMATCH'
absent|0|absent
present|1|SessionStart,claude,5f0c,/t/5f0c.jsonl
JARVISMISMATCH

# The brief-taken stamp: a Jarvis launch whose identity started under the
# session's id and whose Start brief the worker delivered takes the stamp
# once, at the lead's first tool call (lane-mail-halt) or turn end
# (lane-mail-check's own Stop run), and every other record stays as it stands.
# Payloads are Claude Code's PreToolUse and Stop and the pi-hooks carrier's.
TOOL="{\"hook_event_name\":\"PreToolUse\",$BASE,\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/work/SKILL.md\"}}"
SUB_TOOL="{\"hook_event_name\":\"PreToolUse\",$BASE,\"agent_id\":\"a1\",\"tool_name\":\"Read\",\"tool_input\":{}}"
PI_BASE='"session_id":"p1","transcript_path":"/p/p1.jsonl"'
PI_TOOL="{\"hook_event_name\":\"PreToolUse\",$PI_BASE,\"tool_name\":\"read\",\"tool_input\":{\"path\":\"SKILL.md\"}}"
PI_STOP="{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"working_agents\":0,$PI_BASE}"
jarvis_delivered() { # PATCH
  jq -c "{state: \"starting\", brief_delivered: true} + . | .pending += {started_at: 1790000001} | $1" "$RECORD" >"$RECORD.next"
  mv "$RECORD.next" "$RECORD"
}
taken() { jq -r '.pending.brief_taken // "none"' "$RECORD"; }
while IFS='|' read -r label home id wrapper payload patch want env; do
  jarvis_checkout "jarvis_taken_$label" "$home" "$id"
  jarvis_delivered "$patch"
  before="$(jq -c 'del(.pending.brief_taken)' "$RECORD")"
  # shellcheck disable=SC2086  # env is a list of assignments.
  run "$wrapper" "$payload" "JARVIS_RECORD=$RECORD" $env
  # A turn end goes on to judgements of its own, which report on this fixture.
  assert_eq "RC=$RC unwritten=$(grep -c '^lane-mail-check: jarvis-rows-' "$ERR_FILE" || true) taken=$(taken) rest=$([ "$(jq -c 'del(.pending.brief_taken)' "$RECORD")" = "$before" ] && echo same || echo changed)" \
    "RC=0 unwritten=0 taken=$want rest=same" "brief-taken stamp: $label"
done <<JARVISTAKEN
claude-tool|.claude/hooks|5f0c|lane-mail-halt|$TOOL|.|true|JARVIS_GENERATION=3
claude-stop|.claude/hooks|5f0c|lane-mail-check|$STOP|.|true|JARVIS_GENERATION=3
pi-tool|.pi/kendex/hooks|p1|lane-mail-halt|$PI_TOOL|.|true|JARVIS_GENERATION=3
pi-stop|.pi/kendex/hooks|p1|lane-mail-check|$PI_STOP|.|none|JARVIS_GENERATION=3
undelivered|.claude/hooks|5f0c|lane-mail-halt|$TOOL|.brief_delivered = false|none|JARVIS_GENERATION=3
running|.claude/hooks|5f0c|lane-mail-check|$STOP|.state = "running"|none|JARVIS_GENERATION=3
unstarted|.claude/hooks|5f0c|lane-mail-halt|$TOOL|.pending.started_at = null|none|JARVIS_GENERATION=3
other-session|.claude/hooks|6a1d|lane-mail-halt|$TOOL|.|none|JARVIS_GENERATION=3
other-generation|.claude/hooks|5f0c|lane-mail-halt|$TOOL|.|none|JARVIS_GENERATION=2
other-pane|.claude/hooks|5f0c|lane-mail-check|$STOP|.|none|TMUX_PANE=%8 JARVIS_GENERATION=3
subagent|.claude/hooks|5f0c|lane-mail-halt|$SUB_TOOL|.|none|JARVIS_GENERATION=3
stamped|.claude/hooks|5f0c|lane-mail-check|$STOP|.pending.brief_taken = "earlier"|earlier|JARVIS_GENERATION=3
JARVISTAKEN
# A record the stamp cannot read is reported under its key and passed.
jarvis_checkout jarvis_taken_unreadable .claude/hooks 5f0c
printf 'not json\n' >"$RECORD"
run lane-mail-halt "$TOOL" "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=lane-mail-check: jarvis-rows-unwritten=$RECORD" \
  "an unreadable launch record is reported and the tool call passes"

# --- control ------------------------------------------------------------------
# Each rule removed from a copy of the orch scripts reddens its row: the call,
# and the server, pane, generation and preassigned-id bindings.
n=0
while IFS='@' read -r old new label preassigned env; do
  n=$((n + 1))
  jarvis_checkout "jarvis_control_$n" .claude/hooks "$preassigned"
  rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
  LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
  mutate_lib "$old" "$new"
  if [ "$label" = harness ]; then
    jq '.harness = "codex"' "$RECORD" >"$RECORD.next"
    mv "$RECORD.next" "$RECORD"
  fi
  before="$(cat "$RECORD")"
  # shellcheck disable=SC2086  # env is a list of assignments.
  run session-start-row "$START" "JARVIS_RECORD=$RECORD" $env
  assert_eq "changed=$([ "$(cat "$RECORD")" = "$before" ] && echo no || echo yes)" \
    "changed=$([ "$label" = call ] && echo no || echo yes)" "control: $label"
done <<'JARVISCONTROL'
session_rows_jarvis_write "$JARVIS_RECORD" "${JARVIS_GENERATION:-}" "$key" "$2" <<<"$payload"@:@call@@JARVIS_GENERATION=3
(.pending.server | tostring) == $server@true@server@@TMUX_SERVER_ID=8000 JARVIS_GENERATION=3
 and .pending.pane == $pane@@pane@@TMUX_PANE=%8 JARVIS_GENERATION=3
(.pending.generation | tostring) == $generation@true@generation@@JARVIS_GENERATION=2
"mismatch"@"own"@preassigned@6a1d@JARVIS_GENERATION=3
.harness == $harness and@true and@harness@@JARVIS_GENERATION=3
JARVISCONTROL

# Each brief-taken rule removed from a copy reddens its row: the hook's own
# dispatch, the Pi Stop exclusion, and the started, session, delivery, launch
# state and write-once tests.
while IFS='@' read -r label file old new home id wrapper payload patch want; do
  jarvis_checkout "jarvis_taken_control_$label" "$home" "$id"
  jarvis_delivered "$patch"
  rm -f -- "${CHECKOUT:?}/.agents/skills/orch/scripts"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
  LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
  [ "$file" = lib ] || LIB="$CHECKOUT/$home/lane-mail-check.sh"
  mutate_lib "$old" "$new"
  run "$wrapper" "$payload" "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
  assert_eq "taken=$(taken)" "taken=$want" "control: brief-taken $label"
done <<JARVISTAKENCONTROL
dispatch@hook@{ [ "\$CALLER" = lead ] && [ -z "\$ITEM" ] && [ -n "\${JARVIS_RECORD:-}" ]; } || return 0@return 0@.claude/hooks@5f0c@lane-mail-halt@$TOOL@.@none
pi-stop@lib@[ "\$4:\$5" != pi:Stop ] || return 0@:@.pi/kendex/hooks@p1@lane-mail-check@$PI_STOP@.@true
started@lib@ and .pending.started_at != null@@.claude/hooks@5f0c@lane-mail-halt@$TOOL@.pending.started_at = null@true
session@lib@.pending.native_session_id == \$session and @@.claude/hooks@6a1d@lane-mail-halt@$TOOL@.@true
delivered@lib@.brief_delivered == true@true@.claude/hooks@5f0c@lane-mail-halt@$TOOL@.brief_delivered = false@true
starting@lib@.state == "starting"@true@.claude/hooks@5f0c@lane-mail-check@$STOP@.state = "running"@true
write-once@lib@.pending.brief_taken == null@true@.claude/hooks@5f0c@lane-mail-check@$STOP@.pending.brief_taken = "earlier"@true
JARVISTAKENCONTROL

# With a mailbox, losing the Jarvis error after the ordinary append hides the
# rows-unwritten notice. The record and ordinary row still have their results.
jarvis_checkout jarvis_return_control .claude/hooks 6a1d present
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
mutate_lib '  return "$jarvis_rc"' '  return 0'
CONTROL_OUT="$(jarvis_untouched "mailbox mismatch reports the refusal" "$START" \
  "lane-mail-check: rows-unwritten=$CHECKOUT" "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}")"
assert_eq "$(grep -c '^  FAIL  mailbox mismatch reports the refusal$' <<<"$CONTROL_OUT")" "1" \
  "control: dropping the final Jarvis error fails the mailbox mismatch assertion"
assert_eq "rows=$(row_count) row=$(last_row '[.event, .harness, .session_id, .transcript_path] | join(",")')" \
  "rows=1 row=SessionStart,claude,5f0c,/t/5f0c.jsonl" "control: the ordinary row was appended before the error was lost"
jarvis_checkout jarvis_account_control .claude/hooks
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
mutate_lib 'observed_account: $account' 'observed_account: ""'
run session-start-row "$START" "JARVIS_RECORD=$RECORD" "${JARVIS_ENV[@]}"
CONTROL_OUT="$(assert_eq "$(jq -r '.pending.observed_account' "$RECORD")" /accounts/one \
  'native account acknowledgement')"
assert_eq "$(grep -c '^  FAIL  native account acknowledgement$' <<<"$CONTROL_OUT")" "1" \
  "control: absent native acknowledgement fails the account assertion"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
