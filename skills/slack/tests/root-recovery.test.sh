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

sk_summary
