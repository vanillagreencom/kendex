#!/usr/bin/env bash
# Surface: per-root relay start and poll recovery. Inputs: slack/scripts/lib/**,
# mailbox/scripts/lib/** and slack/tests/lib/**. The fake API records real posts.
# Controls remove start isolation, poll isolation, retries or diagnostic memory.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
while IFS='|' read -r fault control; do
  BAD_ROOT="$(sk_new_root "bad-$fault-$control")"
  GOOD_ROOT="$(sk_new_root "good-$fault-$control")"
  for ROOT in "$BAD_ROOT" "$GOOD_ROOT"; do
    sk_bind "$ROOT"
    sk_poll "$ROOT"
    sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text "$(basename "$ROOT")" "Notice $(basename "$ROOT").")" >/dev/null
  done
  BAD_CH="$(sk_channel "$BAD_ROOT")"
  GOOD_CH="$(sk_channel "$GOOD_ROOT")"
  if [ "$fault" = poll ]; then
    sk_store_fixture "$BAD_ROOT" 'def read_events(box, jq_defs, previous, receipts=False, timeout=30):
    marker = box.parent.parent / "failure"
    if not receipts and marker.exists():
        raise ValueError(marker.read_text())
    return _read_events(box, jq_defs, previous, receipts=receipts, timeout=timeout)'
  fi
  case "$control" in
    start) sk_mutant root-start relay.py '            self.root_failed\(path, err\)' '            raise err' ;;
    poll) sk_mutant root-poll relay.py '                self.root_failed\(root, err\)\n                clean = False' '                raise err' ;;
    retry) sk_mutant root-retry relay.py '        for path in self.paths:\n            if path not in active' '        for path in ():\n            if path not in active' ;;
    diagnostic) sk_mutant root-diagnostic relay.py '        if self.root_errors.get\(path\) != error:' '        if True:' ;;
  esac
  cat > "$SK_TMP/root-probe.py" <<'PY'
import contextlib, io, json, pathlib, subprocess, sys, urllib.request

if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]
sys.path.insert(0, sys.argv[1])
from api import Slack
from refusals import Refusal, keyed
from relay import Relay
from settings import load

bad, good, fault = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
scripts = bad / ".agents/skills/mailbox/scripts"
journal = bad / "tmp/slack/journal.jsonl"
saved_scripts = scripts.resolve()
saved_journal = journal.read_text()
marker = bad / "tmp/failure"
def break_root(second=False):
    if fault == "poll":
        marker.write_text("second" if second else "first")
    elif (fault == "missing") != second:
        scripts.unlink()
    else:
        journal.write_text("{invalid\n")
def restore():
    if not scripts.exists():
        scripts.symlink_to(saved_scripts)
    journal.write_text(saved_journal)
    if marker.exists():
        marker.unlink()

warnings = io.StringIO()
relay = None
posts = []
def poll():
    result = relay.poll_once()
    with urllib.request.urlopen(settings.api_url + "/_test/state") as response:
        messages = json.load(response)["messages"]
    counts = []
    for path in (bad, good):
        channel = json.loads((path / "tmp/slack/binding.json").read_text())["channel"]
        counts.append(sum(message.get("text") == "Notice " + path.name + "." for message in messages.get(channel, [])))
    posts.append(counts)
    return result
try:
    with contextlib.redirect_stderr(warnings):
        break_root()
        settings = load()
        relay = Relay([bad, good], settings, Slack(settings.token, settings.api_url))
        polls = [poll(), poll()]
        initial = warnings.getvalue().splitlines()
        restore()
        break_root(second=True)
        polls += [poll(), poll()]
        changed = warnings.getvalue().splitlines()
        restore()
        polls.append(poll())
        if fault == "poll":
            break_root()
            polls.append(poll())
        repeated = warnings.getvalue().splitlines()
    print(json.dumps({"polls": polls, "posts": posts, "initial": initial, "changed": changed, "repeated": repeated}))
except Refusal as err:
    print(keyed(err.key, err.value), file=sys.stderr)
    sys.exit(2)
finally:
    if relay is not None:
        for root in relay.roots:
            root.hold_lock.release()
            root.lock.release()
    restore()
PY
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_TMP/root-probe.py" "${SK_BIN%/*}/lib" "$BAD_ROOT" "$GOOD_ROOT" "$fault")" || RC=$?
  GOT="$RC|$(asks "$GOOD_CH" "Notice $(basename "$GOOD_ROOT").")|$(asks "$BAD_CH" "Notice $(basename "$BAD_ROOT").")"
  if [ "$control" = start ] || [ "$control" = poll ]; then
    sk_assert_red "$GOT" '0|1|1' "$control: removing root isolation fails healthy delivery and recovery"
    assert_eq "$GOT" '2|0|0' "$control: the fail-fast relay exits 2 and posts nothing"
  else
    if [ "$control" = retry ]; then
      sk_assert_red "$GOT" '0|1|1' 'removing construction retries prevents recovery'
    else
      assert_eq "$GOT" '0|1|1' "$fault/$control: the healthy root posts and the failed root recovers"
    fi
    RESULT="$(printf '%s\n' "$OUT" | tail -n 1)"
    if [ "$control" != retry ]; then
      assert_eq "$(jq -c '.posts[0]' <<<"$RESULT")" '[0,1]' "$fault: the first refused poll posts the healthy notice alone"
    fi
    GOT="$(jq -c '[.polls, (.initial | length), (.changed | length), (.repeated | length)]' <<<"$RESULT")"
    WANT='[[false,false,false,false,true],1,2,2]'
    [ "$fault" != poll ] || WANT='[[false,false,false,false,true,false],1,2,3]'
    if [ "$control" = diagnostic ] || [ "$control" = retry ]; then
      sk_assert_red "$GOT" "$WANT" "$control: the poll and diagnostic contract fails without the rule"
    else
      assert_eq "$GOT" "$WANT" "$fault: each refused poll retries, each cause change prints once, and recovery clears the cause"
    fi
    # The relay's operator consumes these keyed root and cause fields.
    assert_eq "$(jq -r --arg root "$BAD_ROOT" '[.initial[], .changed[], .repeated[]] | all(contains("root=" + $root))' <<<"$RESULT")" true "$fault: every keyed skip names the failed root"
  fi
  sk_bin_reset
done <<'ROWS'
missing|normal
journal|normal
poll|normal
missing|start
poll|poll
missing|retry
poll|diagnostic
ROWS

# Listen contention must refuse before Socket Mode, at start and retry.
# Jarvis probe contention must keep healthy mail and retained replies alive.
while read -r kind phase mode; do
  BAD_ROOT="$(sk_new_root "locked-$kind-$phase-$mode")"
  GOOD_ROOT="$(sk_new_root "lock-good-$kind-$phase-$mode")"
  sk_bind "$BAD_ROOT"
  sk_bind "$GOOD_ROOT"
  if [ "$kind" = jarvis ]; then
    sk_poll "$BAD_ROOT"
    sk_poll "$GOOD_ROOT"
    sk_lm "$GOOD_ROOT" notice --item overseer --to owner --file "$(sk_text "$kind-$phase-$mode" 'Jarvis healthy notice.')" >/dev/null
  fi
  if [ "$mode" = control ]; then
    case "$kind" in
      listen) sk_mutant duplicate-skip relay.py 'or isinstance\(err, LockRefusal\) and err.lock_name == LOCK' 'or False' ;;
      jarvis) sk_mutant ambiguous-lock relay.py 'or isinstance\(err, LockRefusal\) and err.lock_name == LOCK' 'or err.key == "relay-running"' ;;
    esac
  fi
  sk_ctl /_test/calls-reset >/dev/null
  if [ "$kind" = listen ]; then
    sk_ctl /_test/fault '{"method":"apps.connections.open","error":"missing_scope"}' >/dev/null
  else
    sk_ctl /_test/fault '{"method":"conversations.replies","error":"channel_not_found"}' >/dev/null
  fi
  cat > "$SK_TMP/lock-probe.py" <<'PY'
import fcntl, json, pathlib, subprocess, sys, time
if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]
sys.path.insert(0, sys.argv[1])
from api import Slack
from refusals import Refusal
from relay import Relay
from settings import load
from store import JARVIS_LOCK, RelayLock
bad, good, phase, command, kind = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), *sys.argv[4:]
holder = RelayLock(bad)
probe = None
relay = None
polls = []
reply = ""
error_key = ""
code = 0
try:
    if kind == "jarvis":
        settings = load()
        api = Slack(settings.token, settings.api_url)
        bad_session = bad / "tmp/jarvis-session"
        bad_lock = RelayLock(bad, JARVIS_LOCK)
        if phase == "initial":
            bad_session.touch()
            (bad / "kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = ' + json.dumps(str(bad_session)) + '\n')
            probe = bad_lock.path.open("a+")
            fcntl.flock(probe.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
        relay = Relay([bad, good], settings, api)
        app = Slack(settings.app_token, settings.api_url, token_name="SLACK_APP_TOKEN", scope="connections:write")
        assert relay.open(app)
        channel = json.loads((good / "tmp/slack/binding.json").read_text())["channel"]
        parent = api.post("_test/message", channel=channel, user="U001", text="Jarvis old parent.",
                          ts="%.6f" % (time.time() - 8 * 86400))["ts"]
        relay.deliver(relay.incoming.get(timeout=10))
        reply = api.post("_test/message", channel=channel, user="U001", text="Jarvis retained reply.", thread_ts=parent)["ts"]
        envelope = relay.incoming.get(timeout=10)
        assert envelope["payload"]["event"]["ts"] == reply
        relay.deliver(envelope)
        assert reply in relay.by_channel[channel].pending_live
        if phase == "retry":
            bad_session.touch()
            (bad / "kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = ' + json.dumps(str(bad_session)) + '\n')
            probe = bad_lock.path.open("a+")
            fcntl.flock(probe.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
        # held() takes the same shared OS lock while probing a mention hold.
        # The fixture retains its descriptor until the root attempts acquire.
        polls.append(relay.poll_once())
        polls.append(relay.poll_once())
        probe.close()
        probe = None
        bad_session.unlink()
        polls.append(relay.poll_once())
    elif phase == "initial":
        holder.acquire()
        child = subprocess.run([command, "listen", "--root", str(bad), "--root", str(good)],
                               capture_output=True, text=True, timeout=60)
        print(json.dumps({"code": child.returncode, "refused": child.stderr.startswith("slack: relay-running=")}))
    else:
        scripts = bad / ".agents/skills/mailbox/scripts"
        source = scripts.resolve()
        scripts.unlink()
        settings = load()
        relay = Relay([bad, good], settings, Slack(settings.token, settings.api_url))
        holder.acquire()
        scripts.symlink_to(source)
        try:
            relay.poll_once()
            app = Slack(settings.app_token, settings.api_url, token_name="SLACK_APP_TOKEN", scope="connections:write")
            relay.open(app)
        except Refusal as error:
            print(json.dumps({"code": 2, "refused": error.key == "relay-running"}))
except Refusal as error:
    if kind != "jarvis":
        raise
    error_key = error.key
    code = 2
finally:
    if probe is not None:
        probe.close()
    holder.release()
    if relay is not None:
        relay.stop_reader.set()
        if relay.reader is not None:
            relay.reader.join(timeout=10)
        for root in relay.roots:
            root.hold_lock.release()
            root.lock.release()
if kind == "jarvis":
    print(json.dumps({"error": error_key, "polls": polls, "reply": reply}))
    sys.exit(code)
PY
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_APP_TOKEN="$SK_APP_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_TMP/lock-probe.py" "${SK_BIN%/*}/lib" "$BAD_ROOT" "$GOOD_ROOT" "$phase" "$SK_BIN" "$kind")" || RC=$?
  RESULT="$(printf '%s\n' "$OUT" | tail -n 1)"
  if [ "$kind" = jarvis ]; then
    GOOD_CH="$(sk_channel "$GOOD_ROOT")"
    TS="$(jq -r .reply <<<"$RESULT")"
    DELIVERED=0
    if [ -f "$(sk_box "$GOOD_ROOT")/to-lane.jsonl" ]; then
      DELIVERED="$(jq -s --arg key "$GOOD_CH:$TS" '[.[] | select(.delivery_id == $key)] | length' "$(sk_box "$GOOD_ROOT")/to-lane.jsonl")"
    fi
    GOT="$RC|$(jq -c .polls <<<"$RESULT")|$(asks "$GOOD_CH" 'Jarvis healthy notice.')|$DELIVERED"
    if [ "$mode" = control ]; then
      sk_assert_red "$GOT" '0|[false,false,true]|1|1' "$phase: the current-head key-only lock rule stops healthy delivery and loses the retained old reply"
      assert_eq "$GOT" '2|[]|0|0' "$phase: the ambiguous lock classification exits before the healthy root serves its mail"
    else
      assert_eq "$GOT" '0|[false,false,true]|1|1' "$phase: Jarvis probe contention stays local while healthy mail and the retained old reply arrive once"
    fi
  else
    GOT="$RC|$(jq -cr '[.code,.refused]' <<<"$RESULT")|$(sk_state '[.calls[] | select(. == "apps.connections.open")] | length')"
    if [ "$mode" = control ]; then
      sk_assert_red "$GOT" '0|[2,true]|0' "$phase: removing listen-lock identity breaks the refusal before Socket Mode"
    else
      assert_eq "$GOT" '0|[2,true]|0' "$phase: a held listen lock is fatal before Socket Mode"
    fi
  fi
  sk_ctl /_test/faults-reset >/dev/null
  sk_bin_reset
done <<'ROWS'
listen initial production
listen initial control
listen retry production
listen retry control
jarvis initial production
jarvis initial control
jarvis retry production
jarvis retry control
ROWS

# The Socket Mode reader acknowledges the failed root's old-thread reply.
# Healthy-root delivery is a barrier after it, before the command returns.
while read -r mode; do
  BAD_ROOT="$(sk_new_root "live-bad-$mode")"
  GOOD_ROOT="$(sk_new_root "live-good-$mode")"
  sk_bind "$BAD_ROOT"
  sk_bind "$GOOD_ROOT"
  BAD_CH="$(sk_channel "$BAD_ROOT")"
  GOOD_CH="$(sk_channel "$GOOD_ROOT")"
  sk_poll "$BAD_ROOT"
  OLD="$(sk_inject "$BAD_CH" U001 'Old parent.' '' "\"ts\":\"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
  rm -- "$BAD_ROOT/.agents/skills/mailbox/scripts" "$BAD_ROOT/tmp/slack/status.json"
  if [ "$mode" = control ]; then
    sk_mutant inactive-drop relay.py '                self.waiting_live.setdefault\(path, \{\}\)\[str\(event\["ts"\]\)\] = event' '                pass'
  fi
  sk_relay_start "$GOOD_ROOT" --root "$BAD_ROOT"
  TS="$(sk_inject "$BAD_CH" U001 'Reply while inactive.' "$OLD")"
  sk_inject "$BAD_CH" U001 'Reply while inactive.' "$OLD" "\"ts\":\"$TS\"" >/dev/null
  GOOD_TS="$(sk_inject "$GOOD_CH" U001 'Healthy before recovery.')"
  assert_eq "$(landed "$GOOD_ROOT" "$GOOD_CH:$GOOD_TS")" 'Healthy before recovery.' "$mode: the healthy root serves events while the other root is inactive"
  assert_eq "$(sk_state "[.sent[] | select(.channel == \"$BAD_CH\" and .ts == \"$TS\") | .envelope_id] as \$ids | [(\$ids | length), (\$ids - .acks | length)] | @json")" '[2,0]' "$mode: the real message entry point acknowledges both deliveries before recovery"
  ln -s "$SK_ROOT/skills/mailbox/scripts" "$BAD_ROOT/.agents/skills/mailbox/scripts"
  TEXT="$(landed "$BAD_ROOT" "$BAD_CH:$TS")"
  if [ "$mode" = control ]; then
    sk_assert_red "$TEXT" 'Reply while inactive.' 'discarding configured inactive-root events loses the old-thread reply'
  else
    assert_eq "$TEXT" 'Reply while inactive.' 'recovery transfers the old-thread reply to live delivery'
    assert_eq "$(jq -s --arg key "$BAD_CH:$TS" '[.[] | select(.delivery_id == $key)] | length' "$(sk_box "$BAD_ROOT")/to-lane.jsonl")" 1 'the repeated live event reaches the recovered mailbox once'
    assert_eq "$(jq -sr --arg ts "$TS" '[.[] | select(.t == "in" and .ts == $ts)] | length' "$(sk_journal "$BAD_ROOT")")" 1 'the repeated live event has one journal delivery'
  fi
  GOOD_TS="$(sk_inject "$GOOD_CH" U001 'Healthy after recovery.')"
  assert_eq "$(landed "$GOOD_ROOT" "$GOOD_CH:$GOOD_TS")" 'Healthy after recovery.' "$mode: recovery keeps the healthy root serving"
  sk_relay_stop
  sk_bin_reset
done <<'ROWS'
production
control
ROWS

# Reload must keep acknowledged inactive-root events, whether delivery ran
# before the close or while the close drains the reader's queue.
while read -r phase mode; do
  BAD_ROOT="$(sk_new_root "reload-bad-$phase-$mode")"
  GOOD_ROOT="$(sk_new_root "reload-good-$phase-$mode")"
  sk_bind "$BAD_ROOT"
  sk_bind "$GOOD_ROOT"
  sk_poll "$BAD_ROOT"
  BAD_CH="$(sk_channel "$BAD_ROOT")"
  OLD="$(sk_inject "$BAD_CH" U001 'Reload old parent.' '' "\"ts\":\"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
  if [ "$mode" = control ]; then
    case "$phase" in
      before) sk_mutant inactive-close relay.py 'if self.socket is None or self.waiting_live or any' 'if self.socket is None or any' ;;
      drain) sk_mutant inactive-reexec relay.py 'return not self.waiting_live and not any' 'return not any' ;;
    esac
  fi
  cat > "$SK_TMP/reload-root-probe.py" <<'PY'
import json, pathlib, subprocess, sys
if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]
sys.path.insert(0, sys.argv[1])
from api import Slack
from relay import Relay
from settings import load
bad, good, channel, parent, phase = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), *sys.argv[4:]
scripts = bad / ".agents/skills/mailbox/scripts"
source = scripts.resolve()
scripts.unlink()
settings = load()
api = Slack(settings.token, settings.api_url)
relay = Relay([bad, good], settings, api)
try:
    app = Slack(settings.app_token, settings.api_url, token_name="SLACK_APP_TOKEN", scope="connections:write")
    assert relay.open(app)
    ts = api.post("_test/message", channel=channel, user="U001", text="Reload retained reply.", thread_ts=parent)["ts"]
    event = relay.incoming.get(timeout=10)
    assert event["payload"]["event"]["ts"] == ts
    if phase == "before":
        relay.deliver(event)
    else:
        relay.incoming.put(event)
    ready = relay.close_for_reload()
    connected = relay.socket is not None
    scripts.symlink_to(source)
    assert relay.poll_once()
    print(json.dumps({"ready": ready, "connected": connected, "ts": ts}))
finally:
    relay.stop_reader.set()
    relay.reader.join(timeout=10)
    for root in relay.roots:
        root.hold_lock.release()
        root.lock.release()
    if not scripts.exists():
        scripts.symlink_to(source)
PY
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_APP_TOKEN="$SK_APP_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_TMP/reload-root-probe.py" "${SK_BIN%/*}/lib" "$BAD_ROOT" "$GOOD_ROOT" "$BAD_CH" "$OLD" "$phase")" || RC=$?
  RESULT="$(printf '%s\n' "$OUT" | tail -n 1)"
  GOT="$RC|$(jq -c '[.ready,.connected]' <<<"$RESULT")"
  WANT='0|[false,false]'
  [ "$phase" != before ] || WANT='0|[false,true]'
  if [ "$mode" = control ]; then
    sk_assert_red "$GOT" "$WANT" "$phase: removing the inactive-event reload check breaks the connection or re-exec decision"
  else
    assert_eq "$GOT" "$WANT" "$phase: reload cannot re-exec over an acknowledged inactive-root event"
  fi
  TS="$(jq -r .ts <<<"$RESULT")"
  assert_eq "$(landed "$BAD_ROOT" "$BAD_CH:$TS")" 'Reload retained reply.' "$phase/$mode: recovery delivers the retained event through the real live path"
  sk_bin_reset
done <<'ROWS'
before production
before control
drain production
drain control
ROWS

sk_summary
