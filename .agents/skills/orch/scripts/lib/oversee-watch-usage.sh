# shellcheck shell=bash
# Help text for oversee-watch. Sourced before argument parsing so help and
# usage errors need no project configuration or external commands.

usage() {
  cat <<'USAGE'
Usage: oversee-watch [--interval SECS] [--max-loops N] [--since ISO8601]
                     [--item ISSUE_ID]... [--repo OWNER/REPO]...
                     [LANE_WINDOW...]

Blocks until the fleet needs the overseer, prints one event, or one line per
item for `merged` and `triage`, then exits. Re-run it after handling the event
with the live lanes and items still in scope.

Events, checked in this order every pass:
  EVENT pr-watch rc=N        new review-gate attention; reducer output follows
  EVENT merged <PR> <branch> an --item PR merged at or after --since
  EVENT triage <item>        an item created at or after --since that is absent
                             from the fleet workflow state's triaged list
  EVENT window-gone <lane>   the tmux window no longer exists
  EVENT lane-exited <lane>   `pgrep -P` reports no child under a bare shell on
                             two passes; pane tail follows. An unusable probe
                             is not an answer and keeps the lane watched
  EVENT usage-limit <lane> [<config-dir>]
                             a live harness shows its limit banner below the
                             last user turn on its screen; pane tail follows
  EVENT lane-asking <lane>   a question or selection prompt differs from the
                             last one emitted for this lane; pane tail follows
  EVENT idle-after-return <lane>
                             the live harness sits idle on two passes; pane
                             tail follows
  EVENT heartbeat            --max-loops passes with no event; open PRs follow

The latest pr-watch attention lines follow every event when any exist. Triage
always reads the live tracker list; the workflow state's triaged verdicts are
the only deduplication. Lane prompts are keyed by the pane slice until that
prompt disappears or changes.

Options:
  --interval SECS     seconds between passes (default 240)
  --max-loops N       passes before a heartbeat (default 25)
  --since ISO8601     UTC created/merged-at floor, with a Z suffix. Pass the
                      fleet's fixed start time on every run, never "now"
  --item ISSUE_ID     live item; repeatable. No values skips merged with a note
  --repo OWNER/REPO   repository; repeatable and case-normalized. The reducer
                      covers all; merged and heartbeat read the first
  LANE_WINDOW...      tmux window names to watch; requires $TMUX

Exit codes:
  0  an EVENT line was printed
  2  usage or global failure: auth, repository, PR, tracker, fleet-state,
     watch-state, or tmux-lane read failed. A state write can fail after its
     event was printed; its baseline does not advance, so the event repeats

The pr-watch step writes: `--heal` dispatches PR_WATCH_WRITER_WORKFLOW on a
gate-stale line. Its credential needs actions:write.

Environment:
  OVERSEE_WATCH_PR_WATCH      path to pr-watch.sh
  OVERSEE_WATCH_TRACKER       path to the Linear CLI
  OVERSEE_WATCH_WORKFLOW_STATE path to workflow-state
  PR_WATCH_WRITER_WORKFLOW    workflow dispatched by pr-watch --heal
  OVERSEE_WATCH_STATE_DIR     pr-watch and lane-asking baselines plus claims/
USAGE
}
