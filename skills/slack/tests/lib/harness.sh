# shellcheck shell=bash
# The one fixture builder and assertion library of the slack suites: a fake
# Slack API the suite starts, a checkout with the real lane-mail, and the
# package run under an explicit environment. Sourced, never run.
#
# A control runs a mutant: a copy of scripts/ with one rule edited out,
# beside a link to the real orch skill, so the copy resolves its settings
# loader and secret pattern the way the tracked script does.
set -u
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export PYTHONDONTWRITEBYTECODE=1

SK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
SK_RUN_FROM=""
SK_FAKE="$SK_ROOT/skills/slack/tests/lib/fake_slack.py"
SK_LANE_MAIL="$SK_ROOT/skills/orch/scripts/lane-mail"
SK_TOKEN="test-token-$$"
SK_APP_TOKEN="test-app-token-$$"
OWNER="brad@example.test"
OWNER2="ann@example.test"
OWNERS="$OWNER,$OWNER2"
HANDLE="bradm"
SK_PASS=0
SK_FAIL=0
SK_URL=""
FAKE_PID=""
SK_BG_PIDS=""
RC=0
OUT=""
ERR=""
ERR1=""

set -e
# Native macOS mktemp uses its system temp root without an explicit template.
SK_TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/slack.XXXXXX")" || { printf 'slack-tests: scratch=mktemp-failed\n' >&2; exit 1; }
[ -d "$SK_TMP" ] && [ ! -L "$SK_TMP" ] || { printf 'slack-tests: scratch=not-a-directory value=[%s]\n' "$SK_TMP" >&2; exit 1; }
SK_TMP="$(cd -- "$SK_TMP" && pwd -P)" || { printf 'slack-tests: scratch=resolve-failed\n' >&2; exit 1; }
# Lane TMPDIR can sit inside a checkout. Keep fixture discovery below its
# physical parent so a plain launch directory reads its own settings.
export GIT_CEILING_DIRECTORIES="${SK_TMP%/*}"
set +e
mkdir -p "$SK_TMP/home"
sk_cleanup() {
  [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null
  # shellcheck disable=SC2086
  [ -z "$SK_BG_PIDS" ] || kill $SK_BG_PIDS 2>/dev/null
  rm -rf -- "${SK_TMP:?}"
}
trap sk_cleanup EXIT

ok() { SK_PASS=$((SK_PASS + 1)); printf '  ok   %s\n' "$1"; return 0; }
bad() {
  SK_FAIL=$((SK_FAIL + 1))
  printf '  FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi
  return 0
}
assert_eq() { # GOT WANT NAME
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected: $2 | got: $1"; fi
}
assert_has() { # HAYSTACK NEEDLE NAME
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "missing: $2 | in: $1" ;; esac
}
assert_lacks() { # HAYSTACK NEEDLE NAME
  case "$1" in *"$2"*) bad "$3" "present: $2 | in: $1" ;; *) ok "$3" ;; esac
}
# field LINE KEY — the value of one KEY=VALUE word of a keyed line
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
sk_summary() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$SK_PASS" "$SK_FAIL"
  if [ "$((SK_PASS + SK_FAIL))" -eq 0 ]; then
    printf '%s: asserted nothing\n' "$(basename "$0")" >&2
    return 1
  fi
  [ "$SK_FAIL" -eq 0 ]
}

# sk_fake_start [FAKE ARGS...] — the fake API on a port of its own, SK_URL set.
sk_fake_start() {
  rm -f -- "${SK_TMP:?}/port"
  python3 "$SK_FAKE" --port-file "$SK_TMP/port" --token "$SK_TOKEN" --app-token "$SK_APP_TOKEN" \
    --user "$OWNER=U001" --user "$OWNER2=U002" "$@" &
  FAKE_PID=$!
  local tries=0
  # The server writes its port once bound; a real wait on that file, bounded.
  while [ ! -s "$SK_TMP/port" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then printf 'fake slack did not start\n' >&2; exit 1; fi
    sleep 0.1
  done
  SK_URL="http://127.0.0.1:$(cat "$SK_TMP/port")"
}

sk_ctl() { # PATH [JSON] — one control call, body on stdout
  if [ $# -gt 1 ]; then
    curl -sS -X POST -H 'Content-Type: application/json' --data "$2" "$SK_URL$1"
  else
    curl -sS "$SK_URL$1"
  fi
}
sk_state() { sk_ctl /_test/state | jq -r "$1"; } # JQ over the fake's state
asks() { sk_state "[.messages.${1}[] | select(.text | contains(\"$2\"))] | length"; } # CHANNEL TEXT — posts carrying it
# sk_inject CHANNEL USER TEXT [THREAD_TS] [EXTRA_JSON_FIELDS] — prints the ts
sk_inject() {
  local extra="${5:-}" thread="" text
  [ -z "${4:-}" ] || thread=", \"thread_ts\": \"$4\""
  [ -z "$extra" ] || extra=", $extra"
  text="$(jq -Rn --arg t "$3" '$t')"
  sk_ctl /_test/message "{\"channel\": \"$1\", \"user\": \"$2\", \"text\": $text$thread$extra}" | jq -r .ts
}

# sk_file ID NAME MIMETYPE CONTENT — the fake serves CONTENT as file ID, typed
# MIMETYPE; prints the file object a message's files[] carries for it, its
# size CONTENT's byte count as Slack gives it
sk_file() {
  sk_ctl /_test/file "$(jq -cn --arg id "$1" --arg t "$3" --arg c "$4" '{id: $id, type: $t, content: $c}')" >/dev/null
  jq -cn --arg id "$1" --arg name "$2" --arg type "$3" --arg url "$SK_URL/_files/$1" --arg c "$4" \
    '{id: $id, name: $name, mimetype: $type, size: ($c | utf8bytelength), url_private_download: $url}'
}
sk_mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; } # PATH — its permission bits

# sk_new_root NAME — an overseer checkout with the real orch scripts; prints it
sk_new_root() {
  local root="$SK_TMP/$1"
  mkdir -p "$root/.agents/skills/orch"
  git -C "$root" init -q
  git -C "$root" config gc.auto 0
  git -C "$root" config maintenance.auto false
  ln -sfn "$SK_ROOT/skills/orch/scripts" "$root/.agents/skills/orch/scripts"
  mkdir -p "$root/tmp"
  printf '{"overseer":{"server":"7000","pane":"%%0"}}\n' > "$root/tmp/workflow-state-oversee.json"
  # Ordinary Slack cases have a working tracker that matches none of their ids.
  # Tracker-link cases replace these keys or plant their own read failure.
  printf '{"urlKey":"workspace","keys":["FIXTURE"]}\n' > "$root/linear.json"
  printf '%s' "$root"
}
sk_box() { printf '%s/tmp/lane-mail/overseer' "$1"; }     # ROOT
# landed ROOT DELIVERY_ID [TRIES] — the text of the envelope keyed DELIVERY_ID,
# awaited TRIES tenths of a second, 200 unless given. Empty when none landed.
landed() {
  local tries=0 file text
  file="$(sk_box "$1")/to-lane.jsonl"
  while [ "$tries" -lt "${3:-200}" ]; do
    if [ -f "$file" ]; then
      text="$(jq -r --arg d "$2" 'select(.delivery_id == $d) | .text' "$file")"
      if [ -n "$text" ]; then printf '%s' "$text"; return 0; fi
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 0
}
# sk_stall_delivery ROOT: a real lane-mail send with no flock and a one-shot
# stalled jq delivery scan. The marker proves the shipped guard holds its lock.
sk_stall_delivery() {
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C python3 - "$1" "$SK_LANE_MAIL" <<'PY'
import pathlib, shlex, shutil, sys
root, mail = pathlib.Path(sys.argv[1]), shlex.quote(sys.argv[2])
bin_dir = root / "tmp/no-flock-bin"
bin_dir.mkdir()
for name in ("bash", "sh", "cat", "tail", "mkdir", "mv", "rm", "rmdir", "date", "awk", "sed", "git",
             "tr", "head", "sleep", "cp", "ln", "wc", "sort", "grep", "dirname", "basename", "touch",
             "chmod", "id", "uname", "mktemp", "env", "python3"):
    command = shutil.which(name)
    if command is None:
        sys.exit("mutex fixture: command-missing=" + name)
    (bin_dir / name).symlink_to(command)
jq = shutil.which("jq")
if jq is None:
    sys.exit("mutex fixture: command-missing=jq")
fault = bin_dir / "jq"
fault.write_text('''#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    *'select(.delivery_id == $key)'*)
      if [ ! -e tmp/scan-locked ]; then
        if command -v flock >/dev/null 2>&1; then exit 1; fi
        [ -d tmp/lane-mail/overseer/to-lane.jsonl.d ]
        printf 'locked\\n' > tmp/scan-locked
        exec sleep 60
      fi
      ;;
  esac
done
exec ''' + shlex.quote(jq) + ' "$@"\n')
fault.chmod(0o755)
scripts = root / ".agents/skills/orch/scripts"
scripts.unlink()
scripts.mkdir()
entry = scripts / "lane-mail"
entry.write_text('#!/usr/bin/env bash\nset -euo pipefail\nexec env PATH=' + shlex.quote(str(bin_dir)) + ' ' + mail + ' "$@"\n')
entry.chmod(0o755)
PY
  [ "$?" -eq 0 ] || exit 1
}
# sk_event_filter ROOT JQ — a lane-mail producer with changed event fields.
sk_event_filter() {
  rm -- "$1/.agents/skills/orch/scripts"
  mkdir -p "$1/.agents/skills/orch/scripts"
  python3 - "$1/.agents/skills/orch/scripts/lane-mail" "$SK_LANE_MAIL" "$2" <<'PY'
import pathlib, shlex, sys
path, mail, expression = pathlib.Path(sys.argv[1]), shlex.quote(sys.argv[2]), shlex.quote(sys.argv[3])
path.write_text(f'#!/usr/bin/env bash\nset -o pipefail\nif [ "$1" = events ]; then\n  {mail} "$@" | jq -c {expression}\nelse\n  exec {mail} "$@"\nfi\n')
path.chmod(0o755)
PY
}
sk_journal() { printf '%s/tmp/slack/journal.jsonl' "$1"; } # ROOT
# sk_legacy_warnings ROOT EXPECTED: read older lane-mail events twice in one process;
# print the diagnostics and fail unless each position warning appears once.
sk_legacy_warnings() {
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    python3 - "${SK_BIN%/*}/lib" "$1" "$2" <<'PY'
import contextlib, io, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from mailbox import LaneMail
mail = LaneMail(Path(sys.argv[2]))
warnings = io.StringIO()
with contextlib.redirect_stderr(warnings):
    mail.events()
    mail.events()
output = warnings.getvalue()
sys.stdout.write(output)
expected = sys.argv[3] + "\n"
sys.exit(0 if output == expected else 1)
PY
}
sk_lm() { ( cd "$1" && shift && env -u ORCH_ASK_WAIT_MINUTES "$SK_LANE_MAIL" "$@" ); } # ROOT ARGS...
sk_text() { printf '%s\n' "$2" > "$SK_TMP/$1.txt"; printf '%s' "$SK_TMP/$1.txt"; }   # NAME CONTENT

# sk_run [VAR=VALUE]... -- ARGS... — the package under an explicit environment
sk_run() {
  local vars=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  RC=0
  OUT="$(cd "${SK_RUN_FROM:-$SK_TMP/home}" && env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" KENDEX_USER_HANDLE="$HANDLE" \
    SLACK_POLL_SECONDS=1 ${vars[@]+"${vars[@]}"} "$SK_BIN" "$@" 2>"$SK_TMP/err")" || RC=$?
  ERR="$(cat "$SK_TMP/err")"
  ERR1="$(sed -n '1p' "$SK_TMP/err")"
}
sk_bind() { sk_run -- setup --root "$1"; }                 # ROOT
# sk_help_field: the help command succeeds and advertises the envelope key.
sk_help_field() {
  sk_run -- --help
  [ "$RC=$ERR" = "0=" ] || return 1
  case "$OUT" in *"envelope-field=ROOT id=ID field=FIELD"*) return 0 ;; *) return 1 ;; esac
}
# sk_relay_start ROOT [--root ROOT]... [VAR=VALUE]... — a relay on its Socket
# Mode connection over every ROOT in the background, launched from
# SK_RUN_FROM as sk_run is, polling every second unless a VAR says otherwise,
# its pid in SK_BG_PIDS, its stdout and stderr in SK_TMP/relay.out and
# relay.err; returns once the first ROOT's first status record is written.
# SK_RELAY_POLL=none exports no SLACK_POLL_SECONDS, so the launch checkout's
# own files set it. The exec chain makes $! the relay itself, so a kill
# reaches it and not a wrapper.
sk_relay_start() {
  local tries=0 root="${1:?}" roots=() poll=(SLACK_POLL_SECONDS=1)
  shift
  roots=(--root "$root")
  while [ $# -gt 1 ] && [ "$1" = --root ]; do roots+=(--root "$2"); shift 2; done
  [ "${SK_RELAY_POLL:-}" != none ] || poll=()
  rm -f -- "${root:?}/tmp/slack/status.json"
  ( cd "${SK_RUN_FROM:-$SK_TMP/home}" && exec env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_APP_TOKEN="$SK_APP_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    ${poll[@]+"${poll[@]}"} ${1+"$@"} "$SK_BIN" listen "${roots[@]}" >"$SK_TMP/relay.out" 2>"$SK_TMP/relay.err" ) &
  SK_BG_PIDS="$!"
  while [ ! -f "$root/tmp/slack/status.json" ] && [ "$tries" -lt 100 ]; do tries=$((tries + 1)); sleep 0.1; done
  [ -f "$root/tmp/slack/status.json" ] || { printf 'background relay wrote no status\n' >&2; exit 1; }
}
sk_relay_stop() { kill "$SK_BG_PIDS" 2>/dev/null; wait "$SK_BG_PIDS" 2>/dev/null; SK_BG_PIDS=""; }
sk_poll() { local root="$1"; shift; sk_run "$@" -- listen --root "$root" --once; } # ROOT [VAR=VALUE]...
# sk_event ROOT CHANNEL TS: one real RootRelay event without a history read.
sk_event() {
  sk_ctl /_test/state | jq --arg c "$2" --arg ts "$3" '.messages[$c][] | select(.ts == $ts)' >"$SK_TMP/event.json" || exit 1
  RC=0
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 - "$1" "$SK_TMP/event.json" "$(dirname "$SK_BIN")/lib" <<'PY' || RC=$?
import json, pathlib, sys, time
sys.path.insert(0, sys.argv[3])
from relay import RootRelay
from settings import DEFAULT_MASTER_MAX_AGE, Presence, load
from verbs import api_for
settings = load()
relay = RootRelay(pathlib.Path(sys.argv[1]), settings, Presence("", DEFAULT_MASTER_MAX_AGE), api_for(settings), time.time)
relay.on_message(json.loads(pathlib.Path(sys.argv[2]).read_text()), "UBOT")
PY
}
# sk_recovery ROOT MODE [ARG]: storage failure, crash or live retry through the real relay.
sk_recovery() {
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    python3 "$SK_ROOT/skills/slack/tests/lib/recovery_probe.py" "${SK_BIN%/*}/lib" "$2" "$1" "${3:-}" \
    2>"$SK_TMP/err")" || RC=$?
  ERR="$(cat "$SK_TMP/err")"
  ERR1="$(sed -n '1p' "$SK_TMP/err")"
}
# sk_assert_red GOT WANT NAME: the same behavioral assertion must fail on a mutant.
sk_assert_red() {
  local output result=0 before="$SK_FAIL"
  output="$(assert_eq "$1" "$2" "$3"; [ "$SK_FAIL" -eq "$before" ])" || result=$?
  assert_eq "$result" "1" "$3"
  [ "$result" -eq 1 ] || printf '%s\n' "$output"
}
sk_channel() { jq -r .channel "$1/tmp/slack/binding.json"; }   # ROOT — the bound channel
sk_reactions() { sk_state "[.messages.${1}[] | select(.ts == \"$2\") | (.reactions // [])[].name] | join(\",\")"; } # CHANNEL TS — its reaction names
# sk_rebind_at ROOT TS — the binding's moment moved to TS, so a first start
# reads the channel from there.
sk_rebind_at() {
  jq --arg t "$2" '.bound_at = $t' "$1/tmp/slack/binding.json" > "$SK_TMP/rebind.json" && cp "$SK_TMP/rebind.json" "$1/tmp/slack/binding.json"
}
# sk_age_envelope ROOT ID SECONDS — the envelope's `at` in the mailbox moved
# SECONDS into the past, the fixture's own file edited in place.
sk_age_envelope() {
  python3 - "$(sk_box "$1")" "$2" "$3" <<'PY'
import datetime, json, pathlib, sys
box, env_id, seconds = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
for name in ("to-overseer.jsonl", "to-lane.jsonl"):
    path = box / name
    if not path.is_file():
        continue
    lines = []
    for raw in path.read_text().splitlines():
        line = json.loads(raw)
        if line.get("id") == env_id:
            at = datetime.datetime.strptime(line["at"], "%Y-%m-%dT%H:%M:%SZ") - datetime.timedelta(seconds=seconds)
            line["at"] = at.strftime("%Y-%m-%dT%H:%M:%SZ")
        lines.append(json.dumps(line))
    path.write_text("".join(l + "\n" for l in lines))
PY
}

# sk_copy NAME — SK_BIN becomes a copy of scripts/ under SK_TMP/mut-NAME,
# which a row may edit as an update of the package does.
sk_copy() {
  local dir="$SK_TMP/mut-$1"
  rm -rf -- "${SK_TMP:?}/mut-$1"
  mkdir -p "$dir/skills/slack"
  cp -R "$SK_ROOT/skills/slack/scripts" "$dir/skills/slack/scripts"
  cp -R "$SK_ROOT/skills/slack/systemd" "$dir/skills/slack/systemd"
  ln -sfn "$SK_ROOT/skills/orch" "$dir/skills/orch"
  ln -sfn "$SK_LINEAR_STUB" "$dir/skills/linear"
  SK_BIN="$dir/skills/slack/scripts/slack"
}

# sk_mutant NAME FILE PATTERN REPLACEMENT — SK_BIN becomes a copy of scripts/
# with exactly one occurrence of PATTERN (a Python regex) replaced.
sk_mutant() {
  sk_copy "$1"
  if ! python3 - "${SK_BIN%/*}/lib/$2" "$3" "$4" <<'PY'
import re, sys
path, pattern, repl = sys.argv[1:4]
text = open(path).read()
new, n = re.subn(pattern, repl, text)
if n != 1 or new == text:
    sys.exit(1)
open(path, "w").write(new)
PY
  then
    printf 'mutant %s: pattern did not match exactly once\n' "$1" >&2
    exit 1
  fi
}
sk_bin_reset() { SK_BIN="$SK_SLACK"; }

# sk_tracker_fixture: local discovery stubs, never the developer's trackers.
sk_tracker_fixture() {
  mkdir -p "$SK_TMP/tracker/skills/slack" "$SK_TMP/tracker/skills/linear/scripts" "$SK_TMP/bin"
  cp -R "$SK_ROOT/skills/slack/scripts" "$SK_TMP/tracker/skills/slack/scripts"
  cp -R "$SK_ROOT/skills/slack/systemd" "$SK_TMP/tracker/skills/slack/systemd"
  ln -s "$SK_ROOT/skills/orch" "$SK_TMP/tracker/skills/orch"
  cp "$SK_ROOT/skills/slack/tests/lib/tracker_stub.py" "$SK_TMP/tracker/skills/linear/scripts/linear.sh"
  cp "$SK_ROOT/skills/slack/tests/lib/tracker_stub.py" "$SK_TMP/bin/gh"
  chmod +x "$SK_TMP/tracker/skills/linear/scripts/linear.sh" "$SK_TMP/bin/gh"
  SK_LINEAR_STUB="$SK_TMP/tracker/skills/linear"
  SK_SLACK="$SK_TMP/tracker/skills/slack/scripts/slack"
  SK_BIN="$SK_SLACK"
  PATH="$SK_TMP/bin:$PATH"
}

# sk_tracker_root NAME TEAM REPO: a root's declared tracker and read fixtures.
sk_tracker_root() {
  local root
  root="$(sk_new_root "$1")" || return $?
  printf '[env]\nLINEAR_TEAM = "%s"\n' "$2" > "$root/kendex.settings.toml"
  printf '{"urlKey":"workspace","keys":["HT","HTIO","KEN"]}\n' > "$root/linear.json"
  if [ -n "$3" ]; then printf '{"nameWithOwner":"%s"}\n' "$3" > "$root/github.json"; fi
  printf '%s' "$root"
}

# sk_markup ROOT MODE [TEXT] [FILE]: execute the real judge with an explicit env.
sk_markup() {
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    PYTHONPATH="${SK_BIN%/*}/lib" python3 "$SK_ROOT/skills/slack/tests/lib/markup_probe.py" "$@" \
    2>"$SK_TMP/err")" || RC=$?
  ERR="$(cat "$SK_TMP/err")"
}

# sk_age_file PATH SECONDS: move a fixture's mtime without a real wait.
sk_age_file() {
  python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}

# sk_master_read ROOT COUNT — the file the master's watch writes after drain.
sk_master_read() { printf '%s\n' "$2" > "$(sk_box "$1")/to-overseer.seen"; }

# sk_age_resume ROOT AT — the last resume moved to an age boundary.
sk_age_resume() {
  python3 - "$(sk_journal "$1")" "$2" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = [json.loads(raw) for raw in path.read_text().splitlines()]
resume = next(line for line in reversed(lines) if line["t"] == "resume")
resume["at"] = sys.argv[2]
path.write_text("".join(json.dumps(line) + "\n" for line in lines))
PY
}

# sk_unposted ROOT MASTER — notices written while the relay is down, with a
# standing start seed, then the first poll under fresh master presence. Each
# text carries its number: lane-mail refuses an owner notice text it already
# holds from the last 24 hours.
sk_unposted() {
  local name
  name="$(basename "$1")"
  sk_bind "$1"
  printf '{"t":"start","at":"","ids":[]}\n' > "$(sk_journal "$1")"
  for n in 1 2 3; do
    sk_lm "$1" notice --item overseer --to owner --file "$(sk_text "$name-$n" "Backlog in $name. Notice $n.")" >/dev/null
    sk_age_envelope "$1" "$(tail -n 1 "$(sk_box "$1")/to-overseer.jsonl" | jq -r .id)" 1200
  done
  sk_poll "$1" "SLACK_MASTER_FILE=$2"
}

# sk_fake_systemctl — a systemctl of its own that appends its arguments to
# SK_TMP/systemctl.log, answers is-active with FAKE_SYSTEMCTL_ACTIVE (default
# active) and exits FAKE_SYSTEMCTL_EXIT (default 0); prints the directory to
# put first on PATH.
sk_fake_systemctl() {
  mkdir -p "$SK_TMP/bin"
  printf '#!/usr/bin/env bash\nprintf '"'"'%%s\\n'"'"' "$*" >> "%s/systemctl.log"\ncase "$*" in *is-active*) printf '"'"'%%s\\n'"'"' "${FAKE_SYSTEMCTL_ACTIVE:-active}" ;; esac\nexit "${FAKE_SYSTEMCTL_EXIT:-0}"\n' "$SK_TMP" > "$SK_TMP/bin/systemctl"
  chmod +x "$SK_TMP/bin/systemctl"
  printf '%s' "$SK_TMP/bin"
}
# sk_path_without NAME — one directory linking every executable on this
# shell's PATH but NAME, so a run under it finds everything else; prints it.
sk_path_without() {
  local dir="$SK_TMP/path-without-$1" d f name
  rm -rf -- "${SK_TMP:?}/path-without-$1"
  mkdir -p "$dir"
  local IFS=':'
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      name="${f##*/}"
      if [ -x "$f" ] && [ ! -d "$f" ] && [ "$name" != "$1" ] && [ ! -e "$dir/$name" ]; then
        ln -s "$f" "$dir/$name"
      fi
    done
  done
  printf '%s' "$dir"
}

sk_tracker_fixture || exit 1
