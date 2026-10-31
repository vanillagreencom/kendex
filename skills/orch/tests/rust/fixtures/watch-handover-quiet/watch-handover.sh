# shellcheck shell=bash
# The watch handover owner as the orch-runtime controller rows see it: a lib
# of the shape lib/watch-handover.sh has, sourced by the runtime and asked
# `watch_handover PREDECESSOR SUCCESSOR LANE_VAR LANE_HOME HARNESS [FLAG...]`.
# It starts no watch: it appends its arguments to $WATCH_HANDOVER_LOG, one
# line per call, then a line `HANDOFF=<the handoff it was handed>` and a line
# `generation=<the fleet record's generation at the call>` read from the
# fleet state under $ORCH_STATE_DIR, so a row reads which destination reached
# the owner and that the publication was recorded before the owner ran
# (decisions 115 (C), 120 M2); it answers `watch-handover pid=0
# pane=SUCCESSOR` or, with $WATCH_HANDOVER_FAIL set, `watch-restart-failed
# step=$WATCH_HANDOVER_FAIL` with status 1, as the real owner answers.
watch_handover() {
  if [ -n "${WATCH_HANDOVER_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$WATCH_HANDOVER_LOG"
    printf 'HANDOFF=%s\n' "${HANDOFF-}" >> "$WATCH_HANDOVER_LOG"
    printf 'generation=%s\n' "$(jq -r '.overseer.generation // "none"' "${ORCH_STATE_DIR:-.}/workflow-state-oversee.json" 2>/dev/null || echo unread)" >> "$WATCH_HANDOVER_LOG"
  fi
  if [ -n "${WATCH_HANDOVER_FAIL:-}" ]; then
    WATCH_HANDOVER_KEY=watch-restart-failed
    WATCH_HANDOVER_FIELDS=("step=$WATCH_HANDOVER_FAIL")
    return 1
  fi
  WATCH_HANDOVER_KEY=watch-handover
  WATCH_HANDOVER_FIELDS=(pid=0 "pane=$2" "runner=fixture")
}
