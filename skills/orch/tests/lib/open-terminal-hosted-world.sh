#!/usr/bin/env bash
# Common hosted launch fixtures and provider-call assertions.
source "$(dirname "${BASH_SOURCE[0]}")/open-terminal-lane-world.sh"
HOST_STUB="$TEST_DIR/fixtures/lane-host"

# Every provider call the run made, in order: one `,`-joined verb and argument
# list per call, the calls themselves joined with `;`. A row that asserts this
# asserts the whole call sequence, so a call the launcher adds cannot pass
# unnoticed.
host_call() { [[ -f "$RUN/host.log" ]] || { echo nolog; return; }; sed -E -e 's/ +$//' -e "s#$H/\\.##g" -e 's/ /,/g' "$RUN/host.log" | paste -sd';' -; }
typed() { grep -cF -- "$1" "$RUN/tmux.log" 2>/dev/null || true; }
said() { grep -cxF -- "$1" <<<"$OUT" || true; }

Q="'\\''"
printf 'Working (esc to interrupt)\n' > "$TMP_ROOT/harness-screen"
HARNESS_UP="OT_HARNESS_SCREEN=$TMP_ROOT/harness-screen"

UNATTENDED_TEXT="$( source "$SCRIPTS_DIR/lib/lane-launch.sh" && printf '%s' "$LAUNCH_UNATTENDED_TEXT" )" || exit 1
CLAUDE_LEAD="$Q--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}$Q $Q--disallowedTools=AskUserQuestion,EnterPlanMode$Q $Q--model$Q ${Q}claude-opus-5-5$Q $Q--effort$Q ${Q}high$Q"
# hosted_resume ITEM NAME BRIEF — the remote command of a hosted claude
# relaunch, the continuation line and the start brief each closing on the
# unattended words.
hosted_resume() { printf "exec bash -lc 'cd /srv/lane && export KENDEX_LANE_ORIGIN=%s/srv/lane%s && $SCRUB_UNSET export KENDEX_USER_EMAIL=%s%s && { claude %s --continue %s%s %s%s || [ \$? -ne 1 ] || exec claude -n %s %s %s%s %s%s; }'" "$Q" "$Q" "$Q" "$Q" "$CLAUDE_LEAD" "$Q" "$HOSTED_LINE" "$UNATTENDED_TEXT" "$Q" "$2" "$CLAUDE_LEAD" "$Q" "$3" "$UNATTENDED_TEXT" "$Q"; }
hosted_line() { printf 'Resume the orch workflow for %s from where this session stopped. Run .agents/skills/mailbox/scripts/lane-mail inbox --item %s first and act on every envelope it prints, answers and directives alike, as its text directs, then re-arm your mailbox monitor on .agents/skills/mailbox/scripts/lane-mail watch --item %s through your harness background wake.' "$1" "$1" "$1"; }
hosted_refresh() { local f="$RUN/remote/srv/clone/.git/worktrees/lane/lane-refresh"; [[ -f "$f" ]] && printf '[%s]' "$(cat "$f")" || printf none; }
