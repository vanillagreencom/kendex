#!/usr/bin/env bash
# Surface: listener worker progress. Inputs: skills/slack/scripts/lib/**,
# skills/slack/tests/lib/** and skills/mailbox/scripts/lib/**.
# Short real deadlines prove timer wiring; the parent bounds every child.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
sk_file FWORKER worker.txt text/plain 'moving-file-moving-file-moving-file-moving-file-moving-file-moving-file-moving-file-moving-file-' > "$SK_TMP/file.json"

while IFS='|' read -r mode control; do
  sk_bin_reset
  if [ "$control" = exit-zero ]; then
    sk_mutant exit-zero relay.py '                os\._exit\(2\)' '                return 0'
  elif [ "$control" = no-progress ]; then
    sk_mutant no-progress relay.py '                completed = time\.monotonic\(\)' '                completed = completed'
  elif [ "$control" = public-dispatch ]; then
    sk_mutant public-dispatch main.py '        return listen\(roots, settings, verbs\.api_for\(settings\), args\.once\)' '        from relay import Relay\n        return Relay(roots, settings, verbs.api_for(settings)).run(args.once)'
  elif [ "$control" = poll-no-renewal ]; then
    sk_mutant poll-no-renewal relay.py '                self\.progress\("poll", True\)' '                self.progress("poll")'
  elif [ "$control" = no-api-progress ]; then
    sk_mutant no-api-progress api.py '            self\.progress\("api:" \+ label, True\)' '            self.progress("api:" + label)'
  elif [ "$control" = no-chunk-progress ]; then
    sk_mutant no-chunk-progress api.py '                    self\.progress\("download", True\)' '                    self.progress("download")'
  fi
  ROOT="$(sk_new_root "$mode-$control")"
  sk_bind "$ROOT"
  assert_eq "$RC" 0 "$mode: the worker fixture binds"
  PROBE_RC=0
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_BOT_TOKEN="$SK_TOKEN" SLACK_APP_TOKEN="$SK_APP_TOKEN" \
    SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
    python3 "$SK_ROOT/skills/slack/tests/lib/worker_stall_probe.py" "${SK_BIN%/*}/lib" "$ROOT" "$mode" "$SK_TMP/file.json" \
    >"$SK_TMP/probe.out" 2>"$SK_TMP/probe.err" || PROBE_RC=$?
  if [ "$control" = production ]; then
    assert_eq "$PROBE_RC" 0 "$mode: the real listener enforces its progress contract"
  else
    assert_eq "$PROBE_RC" 1 "$mode: $control fails the same progress assertion"
  fi
  if [ "$PROBE_RC" -ne 0 ] && [ "$control" = production ]; then
    cat "$SK_TMP/probe.out" "$SK_TMP/probe.err"
  fi
done <<'ROWS'
startup-api|production
startup-api-once|production
startup-dns|production
connect-api|production
connect-dns|production
poll-api|production
reconnect|production
connected|production
api-progress|production
download|production
download-stall|production
startup-api|exit-zero
reconnect|no-progress
startup-api|public-dispatch
startup-api-once|public-dispatch
connected|poll-no-renewal
api-progress|no-api-progress
download|no-chunk-progress
ROWS

sk_summary
