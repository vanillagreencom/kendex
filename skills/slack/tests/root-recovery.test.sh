#!/usr/bin/env bash
# Surface: per-root relay start and poll recovery. Inputs: slack/scripts/lib/**,
# mailbox/scripts/lib/** and slack/tests/lib/**. The fake API records real posts.
# Controls remove isolation, retries or diagnostic memory and restore the
# pre-cut inactive retention and main's inactive event drop.
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

# Inactive roots keep accepted live replies, but ignore edits and deletions
# before holding a delivery. The controls restore the two historical failures.
while read -r subtype mode; do
  BAD_ROOT="$(sk_new_root "inactive-$subtype-$mode")"
  GOOD_ROOT="$(sk_new_root "active-$subtype-$mode")"
  for ROOT in "$BAD_ROOT" "$GOOD_ROOT"; do sk_bind "$ROOT"; sk_poll "$ROOT"; done
  case "$mode" in
    pre-cut)
      sk_mutant pre-cut relay.py '(    def handle\([\s\S]*?        ts = str\(message\["ts"\]\)\n)' '\1        if path == "live":\n            self.pending_live[ts] = message\n            if not active:\n                return\n'
      ;;
    main)
      sk_mutant main-drop relay.py 'if event.get\("type"\) != "message" or root is None:' 'if event.get("type") != "message" or root is None or root not in self.roots:'
      ;;
  esac
  cat > "$SK_TMP/inactive-probe.py" <<'PY'
import json, pathlib, subprocess, sys, time, urllib.request
if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]
sys.path.insert(0, sys.argv[1])
from api import Slack
from relay import Relay
from settings import load
bad, good = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
subtype = sys.argv[4]
settings = load()
api = Slack(settings.token, settings.api_url)
channel = json.loads((bad / "tmp/slack/binding.json").read_text())["channel"]
# This parent is beyond catch-up's history horizon. Only live retention can
# recover its reply once the mailbox command returns.
parent = api.post("_test/message", channel=channel, user="U001", text="Old parent.",
                  ts="%.6f" % (time.time() - 8 * 86400))["ts"]
scripts = bad / ".agents/skills/mailbox/scripts"
source = scripts.resolve()
scripts.unlink()
relay = None
try:
    relay = Relay([bad, good], settings, api)
    assert [root.path for root in relay.roots] == [good]
    app = Slack(settings.app_token, settings.api_url, token_name="SLACK_APP_TOKEN", scope="connections:write")
    assert relay.open(app)
    fields = {} if subtype == "reply" else {"subtype": subtype}
    stamp = api.post("_test/message", channel=channel, user="U001", text="Outage reply.",
                     thread_ts=parent, **fields)["ts"]
    envelope = relay.incoming.get(timeout=10)
    assert envelope["payload"]["event"]["ts"] == stamp
    # The child process deadline bounds this acknowledgement barrier.
    while True:
        with urllib.request.urlopen(settings.api_url + "/_test/state") as response:
            state = json.load(response)
        if envelope["envelope_id"] in state["acks"]:
            break
    relay.deliver(envelope)
    if subtype == "reply":
        relay.deliver(envelope)
        scripts.symlink_to(source)
        assert relay.poll_once()
        assert relay.poll_once()
        events = [json.loads(line) for line in (bad / "tmp/lane-mail/overseer/to-lane.jsonl").read_text().splitlines()] if (bad / "tmp/lane-mail/overseer/to-lane.jsonl").exists() else []
        delivered = [event for event in events if event.get("delivery_id") == channel + ":" + stamp]
        print(json.dumps({"count": len(delivered), "text": [event["text"] for event in delivered]}))
    else:
        # Drive the production two-reading reload decision while the root
        # stays inactive, then close the real socket through its reload path.
        with pathlib.Path(sys.argv[1], "relay.py").open("a") as stream:
            stream.write("\n# package update\n")
        assert not relay.poll_once()
        assert not relay.poll_once()
        assert relay.settled
        print(json.dumps({"reload": relay.close_for_reload(), "inactive": bad not in [root.path for root in relay.roots]}))
finally:
    if not scripts.exists():
        scripts.symlink_to(source)
    if relay is not None:
        relay.stop_reader.set()
        if relay.reader is not None:
            relay.reader.join(timeout=10)
            assert not relay.reader.is_alive()
        for root in relay.by_channel.values():
            root.hold_lock.release()
            root.lock.release()
PY
  # Each row needs a disposable source, including the package-update row.
  [ "$mode" != production ] || sk_copy "inactive-$subtype"
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_LINEAR_DIR="$SK_LINEAR_STUB" \
    SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_APP_TOKEN="$SK_APP_TOKEN" SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_TMP/inactive-probe.py" "${SK_BIN%/*}/lib" "$BAD_ROOT" "$GOOD_ROOT" "$subtype")" || RC=$?
  assert_eq "$RC" 0 "$subtype/$mode: the acknowledged event reaches the production delivery and recovery path"
  RESULT="$(printf '%s\n' "$OUT" | tail -n 1)"
  if [ "$subtype" = reply ]; then
    GOT="$(jq -c '[.count,.text]' <<<"$RESULT")"
    WANT='[1,["Outage reply."]]'
  else
    GOT="$(jq -c '[.reload,.inactive]' <<<"$RESULT")"
    WANT='[true,true]'
  fi
  if [ "$mode" = production ]; then
    assert_eq "$GOT" "$WANT" "$subtype: ignored events permit reload and an outage reply arrives once"
  else
    sk_assert_red "$GOT" "$WANT" "$subtype/$mode: the historical behavior fails the same outcome assertion"
  fi
  sk_bin_reset
done <<'ROWS'
message_changed production
message_changed pre-cut
message_deleted production
message_deleted pre-cut
reply production
reply main
ROWS

sk_summary
