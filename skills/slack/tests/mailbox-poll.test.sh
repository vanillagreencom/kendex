#!/usr/bin/env bash
# Surface: relay mailbox reads. Inputs: skills/slack/scripts/lib/**,
# skills/mailbox/scripts/lib/**, skills/slack/tests/lib/** and
# skills/slack/tests/fixtures/mailbox-pre-read-events/**.
# Fake time drives the real worker loop. The control restores the existing
# events subprocess path and fails the same idle-process assertion.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
while IFS='|' read -r mode transport format; do
  ROOT="$(sk_new_root "$transport-$mode-$format")"
  [ "$format" != historical ] || sk_historical_mailbox "$ROOT"
  sk_bind "$ROOT"
  assert_eq "$RC" 0 "$mode: one root binds before measurement"
  if [ "$transport" = eyes ]; then
    sk_poll "$ROOT"
    CH="$(sk_channel "$ROOT")"
    sk_inject "$CH" U001 'Unread directive.' >/dev/null
    sk_poll "$ROOT"
    assert_eq "$RC" 0 "$mode: an unread directive waits at eyes before measurement"
  fi
  if [ "$mode" = subprocess ]; then
    sk_mutant poll-subprocess mailbox.py '        rows, _ = self\._read_events\(\)' '        code, out, err = self._run("events", "--item", "overseer")\n        if code != 0:\n            raise Refusal("lane-mail-failed", err.strip())\n        rows = [json.loads(raw) for raw in out.splitlines() if raw.strip()]'
  fi
  PROBE_RC=0
  RESULT="$(env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_BOT_TOKEN="$SK_TOKEN" \
    SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_ROOT/skills/slack/tests/lib/mailbox_poll_probe.py" "${SK_BIN%/*}/lib" "$ROOT" "$transport")" || PROBE_RC=$?
  assert_eq "$PROBE_RC" 0 "$mode: the real relay runs a complete fake minute with no new mail"
  printf 'mailbox-poll: mode=%s transport=%s result=%s\n' "$mode" "$transport" "$RESULT"
  STARTS="$(jq -r .lane_mail_starts <<<"$RESULT")"
  if [ "$mode" = production ]; then
    assert_eq "$STARTS" 0 'idle relay starts no lane-mail subprocess in a fake minute'
  else
    sk_assert_red "$STARTS" 0 'control: the previous events subprocess path fails the idle-process assertion'
  fi
  sk_bin_reset
done <<'ROWS'
production|idle|current
subprocess|idle|current
production|reconnect|current
subprocess|reconnect|current
production|eyes|current
subprocess|eyes|current
production|idle|historical
production|reconnect|historical
production|eyes|historical
ROWS

sk_summary
