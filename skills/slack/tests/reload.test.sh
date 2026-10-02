#!/usr/bin/env bash
# A running relay re-executes onto its package's new code, against the fake's
# WebSocket and a copy of the package a row edits as an update does. The
# rows: the status record and the doctor row carry the fingerprint of the
# code the relay runs; a file that changes between every two polls, an update
# still being written, is never loaded; an update that holds for two polls is
# loaded in the same process, with a new connection, a catch-up and the
# launch checkout's settings read again; a code file that cannot be read
# keeps the running code and reads failing with its refusal. A positive row
# waits up to twenty seconds, a control six. The controls: the check gone
# from the loop, the two-poll rule gone, the new image started under the
# loaded environment, the doctor row without the code, and the refusal kept
# out of the status record.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: reload on update ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
STATUS="$ROOT/tmp/slack/status.json"
# The launch checkout, whose private env file alone sets the poll interval.
SK_RUN_FROM="$SK_TMP/launch"
mkdir -p "$SK_RUN_FROM"
SK_RELAY_POLL=none

# code_of — 12 hex characters of one sha256 over SK_BIN's launcher and its
# lib/*.py in byte order, hashed here and not by the package
code_of() {
  local scripts="${SK_BIN%/*}"
  (export LC_ALL=C; cat -- "$scripts/slack" "$scripts"/lib/*.py) \
    | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])'
}
row() { sk_run -- listen --status --root "$ROOT"; LINE="$OUT"; }
# row_until KEY WANT SECONDS — the doctor row once KEY reads WANT, or the
# last one read SECONDS from now
row_until() {
  local end=$((SECONDS + $3))
  row
  while [ "$(field "$LINE" "$1")" != "$2" ] && [ "$SECONDS" -lt "$end" ]; do
    sleep 0.1
    row
  done
}
pid() { jq -r .pid "$STATUS"; }
reloads() { grep -c '^slack: reloading=' "$SK_TMP/relay.out"; }
# start NAME — a relay over ROOT on the package copy NAME sk_copy or
# sk_mutant made, polling every second
start() {
  printf 'export SLACK_POLL_SECONDS=1\n' > "$SK_RUN_FROM/.env.local"
  sk_relay_start "$ROOT"
  row
  [ "$(field "$LINE" connection)" = connected ] || { printf 'relay on %s did not connect\n' "$ROOT" >&2; exit 1; }
}
# churn — relay.py rewritten every fifth of a second for five seconds, so no
# two polls a second apart read the same file, then one last edit
churn() {
  local n=0
  while [ "$n" -lt 25 ]; do
    printf '# churn %s\n' "$n" >> "${SK_BIN%/*}/lib/relay.py"
    sleep 0.2
    n=$((n + 1))
  done
  printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
}

# --- an update that holds for two polls is loaded; one still being written is not ---
sk_copy live
C0="$(code_of)"
start
PID="$(pid)"
row
assert_eq "$(field "$LINE" code)=$(jq -r .code "$STATUS")" "$C0=$C0" \
  "the status record and the doctor row carry the fingerprint of the code the relay runs"
assert_eq "$(jq -r .poll_seconds "$STATUS")" "1" "the relay reads the poll interval from the launch checkout"
sk_ctl /_test/calls-reset >/dev/null
printf 'export SLACK_POLL_SECONDS=2\n' > "$SK_RUN_FROM/.env.local"
churn
C1="$(code_of)"
row_until code "$C1" 20
assert_eq "$(field "$LINE" code)=$(pid)" "$C1=$PID" "an update that holds for two polls is loaded in the same process"
assert_eq "$(reloads)=$(grep '^slack: reloading=' "$SK_TMP/relay.out")" "1=slack: reloading=$C1 running=$C0" \
  "a file that changed between every two polls was never loaded"
assert_eq "$(jq -r 'select(.t == "connect") | .t' "$(sk_journal "$ROOT")" | wc -l | tr -d ' ')" "2" \
  "the new image journals a connect of its own"
assert_eq "$(sk_state '[.calls[] | select(. == "apps.connections.open" or . == "conversations.history")] | unique | join(",")')" \
  "apps.connections.open,conversations.history" "the new image opens a connection and reads the channel's history"
assert_eq "$(jq -r .poll_seconds "$STATUS")" "2" "the new image reads the launch checkout's settings again"

# --- an unreadable code file keeps the running code ---
ln -s "$SK_TMP/missing" "${SK_BIN%/*}/lib/zz.py"
row_until state failing 20
assert_eq "$(field "$LINE" state)=${LINE#* fix=}" "failing=code-unreadable=${SK_BIN%/*}/lib/zz.py (No such file or directory)" \
  "an unreadable code file reads failing, with the refusal as its fix"
assert_eq "$(field "$LINE" code)=$(pid)=$(reloads)" "$C1=$PID=1" "an unreadable code file keeps the running code"
rm -- "${SK_BIN%/*}/lib/zz.py"
row_until state ok 20
assert_eq "$(field "$LINE" state)=$(field "$LINE" code)=$(reloads)" "ok=$C1=1" \
  "once the file reads again the relay is ok on the same code"
sk_relay_stop

# --- controls ---------------------------------------------------------------------
sk_mutant unchecked relay.py 'if self\.settled:\n                    return' 'if False:\n                    return'
start
PID="$(pid)"
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
C1="$(code_of)"
row_until code "$C1" 6
sk_assert_red "$(field "$LINE" code)=$(pid)" "$C1=$PID" "control: the check gone from the loop, an update is never loaded"
sk_relay_stop

sk_mutant unsettled relay.py 'reading != self\.code and reading == self\.reading' 'reading != self.code'
start
churn
sleep 2 # two polls past the last edit, so the last reload has started
sk_assert_red "$(reloads)" "1" "control: the two-poll rule gone, a file still being written is loaded"
sk_relay_stop

sk_mutant loaded-env relay.py '\*sys\.argv\[1:\]\], CALLER_ENV\)' '*sys.argv[1:]], dict(os.environ))'
start
printf 'export SLACK_POLL_SECONDS=2\n' > "$SK_RUN_FROM/.env.local"
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
C1="$(code_of)"
row_until code "$C1" 20
sk_assert_red "$(field "$LINE" code)=$(jq -r .poll_seconds "$STATUS")" "$C1=2" \
  "control: the new image started under the loaded environment keeps the old settings"
sk_relay_stop

sk_mutant row-code verbs.py "code=\{record\.get\('code'\) or '-'\}" 'code=-'
row
sk_assert_red "$(field "$LINE" code)" "$(jq -r .code "$STATUS")" "control: the doctor row without the code"

sk_mutant unreported relay.py 'return f"\{err\.key\}=\{err\.value\}"' 'return ""'
start
ln -s "$SK_TMP/missing" "${SK_BIN%/*}/lib/zz.py"
row_until state failing 6
sk_assert_red "$(field "$LINE" state)" "failing" "control: the refusal kept out of the status record, an unreadable file reads ok"
sk_relay_stop

sk_summary
