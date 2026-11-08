#!/usr/bin/env bash
# Tests for the block-argv-kill hook.
#
# The shared command reader separates command candidates from quoted data
# and heredoc bodies. `kill`, `pgrep` and `ps` are the control side: the
# commands the refusal sends the caller to must pass.
#
# Every refusal opens with `block-argv-kill: <key>=<value>`, and that line is
# the contract: the first-line table below pins the key and the value of each
# condition beside its exit status, and the English under it is not asserted.
#
# HOOK_UNDER_TEST overrides the script under test for a planted copy.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-argv-kill.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo 'block-argv-kill.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'block-argv-kill.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'block-argv-kill.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

assert_eq() {
  if [ "$1" = "$2" ]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
json_for() {
  jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}

run_hook() { # command -> rc, stderr in ERR_FILE
  set +e
  json_for "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

# The tmux rule reads TMUX from the hook's own environment, so these rows set
# it, or unset it, rather than inherit the session the suite runs in.
run_with_tmux() { # TMUX-value command -> rc, stderr in ERR_FILE; an empty value unsets TMUX
  set +e
  if [ -n "$1" ]; then
    json_for "$2" | TMUX="$1" "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  else
    json_for "$2" | env -u TMUX "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  fi
  rc=$?
  set -e
}

run_payload() { # raw-json -> rc, stderr in ERR_FILE
  set +e
  printf '%s' "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The hook's dependency list, in the order it checks them: the shared table
# pins it as the value of the world that has none of them.
PAYLOAD_ADVISORY=1
PAYLOAD_TOOLS=jq,cat

# shellcheck source=lib/payload-rows.sh
. "$TEST_DIR/lib/payload-rows.sh"

echo "=== block-argv-kill: a kill by name or pattern is refused ==="
run_hook 'pkill -f mutation-stability';        assert_eq "$rc" 2 'pkill with an argv pattern is refused'
run_hook 'pkill kendex';                       assert_eq "$rc" 2 'pkill by process name is refused'
run_hook 'pkill -x -TERM cargo';               assert_eq "$rc" 2 'flags between the verb and the name change nothing'
run_hook 'killall node';                       assert_eq "$rc" 2 'killall is refused'
run_hook 'sudo killall -9 vite';               assert_eq "$rc" 2 'a wrapper in front of the verb is still the verb'
run_hook '/usr/bin/pkill -f foo';              assert_eq "$rc" 2 'an absolute path in front of the verb is still the verb'
run_hook 'make stop; pkill -f serve';          assert_eq "$rc" 2 'the verb is found after a semicolon'
run_hook 'true && killall -q gulp';            assert_eq "$rc" 2 'the verb is found in an and-list'
run_hook "$(printf 'echo start\npkill -f watcher')"; assert_eq "$rc" 2 'the verb is found on the second line'
run_hook 'x=$(pkill -f a)';                    assert_eq "$rc" 2 'the verb is found inside a command substitution'
run_hook 'pkill';                              assert_eq "$rc" 2 'a bare pkill with no argument is refused'
run_hook '"pkill" -f a';                       assert_eq "$rc" 2 'a quoted verb is still the verb'
run_hook "$(printf 'pkill \\\n  -f a')";       assert_eq "$rc" 2 'a verb ending its line is still the verb'
run_hook '$(which pkill) -f a';                assert_eq "$rc" 2 'a verb closing a substitution is still the verb'

echo "=== block-argv-kill: attached shell redirections keep the refusal ==="
# Shell tools emit attached operators as well as whitespace-separated ones.
# A quoted operator inside a data word is not a shell redirection.
while IFS='|' read -r label want text; do
  run_hook "$text"
  assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
done <<'ROWS'
an attached output redirect still names pkill|rc=2 first=block-argv-kill: refused=pkill|pkill>/dev/null -f node
an attached input redirect still names killall|rc=2 first=block-argv-kill: refused=killall|killall</dev/null node
a quoted executable keeps its attached redirect|rc=2 first=block-argv-kill: refused=pkill|"pkill">/dev/null -f node
an operator inside quoted data stays data|rc=0 first=-|echo "pkill>note"
ROWS

echo "=== block-argv-kill: the named forms pass ==="
run_hook 'kill 1234';                          assert_eq "$rc" 0 'kill on a PID passes'
run_hook 'kill -TERM 1234 5678';               assert_eq "$rc" 0 'kill with a signal and several PIDs passes'
run_hook 'kill -- -1234';                      assert_eq "$rc" 0 'kill on a process group passes'
run_hook 'pgrep -af mutation-stability';       assert_eq "$rc" 0 'pgrep passes: finding a PID is not killing by pattern'
run_hook 'ps -o pid,args -p 1234';             assert_eq "$rc" 0 'ps passes'
run_hook 'readlink /proc/1234/cwd';            assert_eq "$rc" 0 'reading a process cwd passes'
run_hook 'cat killall.log';                    assert_eq "$rc" 0 'the verb glued to a suffix is another word'
run_hook 'pkill-wrapper --dry-run';            assert_eq "$rc" 0 'the verb glued to a hyphenated suffix is another word'
run_hook 'echo unpkill';                       assert_eq "$rc" 0 'the verb glued to a prefix is another word'
run_hook 'git status';                         assert_eq "$rc" 0 'a command with neither verb passes'

echo "=== block-argv-kill: quoted and heredoc data pass ==="
assert_data_mention() {
  run_hook "$1"
  assert_eq "$rc" 0 "$2"
}
while IFS='|' read -r label text; do
  text=$(printf '%b' "$text")
  assert_data_mention "$text" "$label"
done <<'ROWS'
the verb inside a quoted string passes|echo "never use pkill here"
the verbs inside a heredoc body pass|cat <<'NOTE'\nnever use pkill or killall here\nNOTE
ROWS

# One control restores raw scanning in a disposable hook. The same quoted
# data assertion must turn red while the real command text stays intact.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  mkdir -p "$TMP_ROOT/control/hooks" "$TMP_ROOT/control/skills/commit-guards/scripts/lib"
  cp "$TEST_DIR/../../skills/commit-guards/scripts/lib/command-position.sh" "$TMP_ROOT/control/skills/commit-guards/scripts/lib/command-position.sh"
  matches=$(grep -Fxc 'command_segments "$COMMAND"' "$HOOK") || exit 1
  [ "$matches" = 1 ] || { echo 'block-argv-kill.test: control=edit-site' >&2; exit 1; }
  sed 's/^command_segments "$COMMAND"$/SEGMENTS=$COMMAND/' "$HOOK" >"$TMP_ROOT/control/hooks/block-argv-kill.sh"
  control_rc=0
  (
    HOOK="$TMP_ROOT/control/hooks/block-argv-kill.sh"
    PASS=0 FAIL=0
    assert_data_mention 'echo "never use pkill here"' 'the verb inside a quoted string passes'
    [ "$FAIL" -eq 0 ]
  ) >"$TMP_ROOT/control.log" 2>&1 || control_rc=$?
  assert_eq "$control_rc" 1 'control: raw scanning makes the quoted-data assertion fail'
fi

echo "=== block-argv-kill: the stated limits ==="
# A spelling the shell assembles from quotes or escapes stays outside the
# frozen lexical-scanner class; the shared reader does not assemble words.
run_hook 'echo "pkill"';                       assert_eq "$rc" 2 'a single-word quoted argument remains a possible command word'
run_hook "p'kill' -f x";                       assert_eq "$rc" 0 'a verb the shell assembles from quotes is not seen'
run_hook 'kill\all x';                         assert_eq "$rc" 0 'a verb the shell assembles from an escape is not seen'

echo "=== block-argv-kill: a tmux stop inside a tmux session names its server ==="
# A row is `label|tmux|want|command`: `lane` runs the hook with TMUX naming a
# named-socket lane server, `default` with TMUX naming the default socket a
# plain `tmux` launch gives, `out` with TMUX unset; `want` is the status and
# the leading keyed lines, `;`-joined. The last two rows are the word
# reading's stated limits, in both directions.
REFUSED='rc=2 keys=tmux-socket=kill-server;fix=env -u TMUX tmux -S PATH kill-server'
while IFS='|' read -r label where want text; do
  [ -n "$label" ] || continue
  case "$want" in refused) want=$REFUSED ;; passes) want='rc=0 keys=' ;; esac
  case "$where" in
    lane) run_with_tmux /tmp/tmux-1000/fleet-lane,6710,0 "$text" ;;
    default) run_with_tmux /tmp/tmux-1000/default,4242,0 "$text" ;;
    *) run_with_tmux '' "$text" ;;
  esac
  assert_eq "rc=$rc keys=$(keyed_block "$ERR_FILE" block-argv-kill)" "$want" "$label"
done <<'ROWS'
the FLT-1418 stop, TMUX_TMPDIR beside it, is refused|lane|refused|TMUX_TMPDIR=$d tmux kill-server
a session stop's fix ends at the verb, no redirect fragment after it|lane|rc=2 keys=tmux-socket=kill-session;fix=env -u TMUX tmux -S PATH kill-session|tmux kill-session -t probe 2>&1
a flag and its argument name no server|lane|refused|tmux -f /dev/null kill-server
a stop after an earlier tmux command on the line is found|lane|refused|tmux ls; /usr/bin/tmux kill-server
an env that keeps TMUX names no server|lane|refused|env TMUX_TMPDIR=/tmp/x tmux kill-server
an env that unsets TMUX names no server, whichever socket TMUX names|lane|refused|env -u TMUX tmux kill-server
a socket path names the server|lane|passes|tmux -S /tmp/probe.sock kill-server
a socket name names the server|lane|passes|tmux -L probe kill-server
the fix form passes|default|passes|env -u TMUX tmux -S /tmp/probe.sock kill-server
a tmux command that stops nothing passes|lane|passes|tmux list-sessions
outside a tmux session no server is inherited|out|passes|tmux kill-server
the words inside a quoted string are refused|lane|refused|echo "tmux kill-server"
a stop chained after another tmux command is not seen|lane|passes|tmux new -d \; kill-server
ROWS

echo "=== block-argv-kill: installed skill delivery layouts ==="
# These paths are emitted by Pi::hook_path, Env::global_skills_dir and
# desired_skill's shared/copy delivery, not paths selected by the payload.
while IFS='|' read -r label hook_rel reader_rel; do
  install_root="$TMP_ROOT/install-$label"
  installed="$install_root/$hook_rel/block-argv-kill.sh"
  reader_dir="$install_root/$reader_rel/commit-guards/scripts/lib"
  mkdir -p "${installed%/*}" "$reader_dir" "$install_root/home"
  cp "$HOOK" "$installed"
  cp "$TEST_DIR/../../skills/commit-guards/scripts/lib/command-position.sh" "$reader_dir/command-position.sh"
  while IFS='|' read -r probe want text; do
    json_for "$text" >"$TMP_ROOT/install-input"
    rc=0
    env -i HOME="$install_root/home" PATH="$PATH" TMUX=/fixture/lane,1,0 "$BASH_BIN" "$installed" <"$TMP_ROOT/install-input" > /dev/null 2>"$ERR_FILE" || rc=$?
    assert_eq "rc=$rc first=$(first_line)" "$want" "$label: $probe"
  done <<'PROBES'
a real name kill is refused|rc=2 first=block-argv-kill: refused=pkill|pkill -f node
an unnamed tmux stop is refused|rc=2 first=block-argv-kill: tmux-socket=kill-server|tmux kill-server
quoted data passes after loading the reader|rc=0 first=-|echo "never use pkill here"
PROBES
done <<'LAYOUTS'
project-shared|project/.pi/kendex/hooks|project/.agents/skills
global-shared|home/.pi/agent/kendex/hooks|home/.agents/skills
relocated-global-shared|relocated/agent/kendex/hooks|home/.agents/skills
global-copy|home/.pi/agent/kendex/hooks|home/.pi/agent/skills
LAYOUTS

echo "=== block-argv-kill: the first line of every condition ==="
first_table "\
the verb the command spelled is the value|command|2|block-argv-kill: refused=pkill|pkill -f mutation-stability
the other verb is a value of its own|command|2|block-argv-kill: refused=killall|killall node
a command it read and allows says nothing|command|0|-|kill 1234
an empty payload refuses rather than passing as an absent command|payload|0|block-argv-kill: payload=empty|-
a whitespace-only payload refuses the same way|payload|0|block-argv-kill: payload=empty| \t
a payload that is not JSON is refused unread|payload|0|block-argv-kill: payload=invalid-json|not JSON
"
set +e
"$BASH_BIN" "$HOOK" <"$TMP_ROOT" >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line) cause=$(cause_below)" \
  'rc=0 first=block-argv-kill: payload=unreadable cause=present' \
  'a stdin that cannot be read allows with the keyed line first and the cause under it'

payload_table "$HOOK" 'pkill -f x' 'kill 1234'

echo
echo "block-argv-kill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
