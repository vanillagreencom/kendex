#!/usr/bin/env bash
# Tests for the hosted ssh launch contract.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-hosted: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-hosted: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-hosted: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-hosted-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-hosted-world.sh"


echo "=== the hosted ssh prompt wait has its own bound and one retry ==="
# A sandbox whose tailnet route comes up late shows its shell seconds after the
# first bound runs out. The wait spends its bound, interrupts the stalled
# client, waits for the pane's own shell to come back and dials again, so the
# launch still starts its lane instead of leaving a window holding a live ssh
# session and no harness. The interrupt is load-bearing: a paste made while ssh
# holds the pane is typed into that session and dials nothing, which is what
# the stub replays.
#
# The bound is ORCH_LANE_SSH_PROMPT_SECS, and NOT ORCH_TMUX_VERIFY_SECS, which
# keeps bounding the harness-screen and brief waits. $OT_SSH_CONNECTS_ON names
# the connection whose host answers, so a row puts the prompt on the first
# dial, on the retry's dial, or on neither. Every row reads the whole refusal
# line, whose reason, bound and attempt count are the facts only it carries.
SSH_LINE="clear; ssh 'lane.example'"
INTERRUPT="send-keys -t %1 C-c"
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_CONNECTS_ON=1;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-120
assert_eq "$(observe "rc=0 launched=1 promptmissing=none") ssh=$(typed "$SSH_LINE") int=$(typed "$INTERRUPT")" \
  "rc=0 launched=1 promptmissing=none ssh=1 int=0" \
  "a prompt on the first dial launches the lane on one ssh paste, with no interrupt and no retry"
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_CONNECTS_ON=2;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-121
assert_eq "$(observe "rc=0 launched=1 promptmissing=none") ssh=$(typed "$SSH_LINE") int=$(typed "$INTERRUPT")" \
  "rc=0 launched=1 promptmissing=none ssh=2 int=1" \
  "a host that answers only the second dial is reached by the interrupt and the retry, and the lane launches"
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_CONNECTS_ON=3;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-122
assert_eq "$(observe "rc=1 promptmissing=item=KEN-122,host=$HOST_STUB,reason=prompt-silent,seconds=1,attempts=2") ssh=$(typed "$SSH_LINE") int=$(typed "$INTERRUPT")" \
  "rc=1 promptmissing=item=KEN-122,host=$HOST_STUB,reason=prompt-silent,seconds=1,attempts=2 ssh=2 int=1" \
  "a host that answers neither dial is remote-prompt-missing naming prompt-silent, the bound and both attempts"
# A pane no longer running ssh is a session that died, not a client to
# interrupt: nothing is interrupted and nothing is dialled a second time.
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_CONNECTS_ON=3;OT_SSH_DIES_AFTER=1;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-123
assert_eq "$(observe "rc=1 promptmissing=item=KEN-123,host=$HOST_STUB,reason=session-gone,seconds=1,attempts=1") ssh=$(typed "$SSH_LINE") int=$(typed "$INTERRUPT")" \
  "rc=1 promptmissing=item=KEN-123,host=$HOST_STUB,reason=session-gone,seconds=1,attempts=1 ssh=1 int=0" \
  "a pane whose ssh session died under the first wait is session-gone on one paste, with no interrupt"
# The new bound is judged by the block that judges ORCH_TMUX_VERIFY_SECS, so it
# takes the same keyed refusal under its own name, before any window opens.
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_SSH_PROMPT_SECS=abc;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-124
assert_eq "$(observe "rc=1 launched=nolog seconds_invalid=setting=ORCH_LANE_SSH_PROMPT_SECS,value=abc") create=$(host_call)" \
  "rc=1 launched=nolog seconds_invalid=setting=ORCH_LANE_SSH_PROMPT_SECS,value=abc create=nolog" \
  "a non-integer ssh bound is the verify-seconds-invalid refusal under its own setting name, before any create"
# The ceiling the --help text promises, which is 300 and not the 120 the
# verification timeout takes. The host answers the first dial, so the clamped
# value is never waited out.
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_SSH_PROMPT_SECS=400;OT_SSH_CONNECTS_ON=1;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-130
assert_eq "$(observe "rc=0 launched=1 seconds_clamped=setting=ORCH_LANE_SSH_PROMPT_SECS,value=400,limit=300")" \
  "rc=0 launched=1 seconds_clamped=setting=ORCH_LANE_SSH_PROMPT_SECS,value=400,limit=300" \
  "an oversized ssh bound is clamped loudly to its own ceiling of 300, and the lane still launches"
# The other direction of the gate: a local lane reaches neither ssh wait, so a
# broken ssh bound must not abort one. Its hosted twin is KEN-124 above.
run_ot "ORCH_LANE_SSH_PROMPT_SECS=abc;$CHOICE_CMD" --harness claude --lane "$H/.claude" KEN-131
assert_eq "$(observe "rc=0 launched=1 seconds_invalid=none")" "rc=0 launched=1 seconds_invalid=none" \
  "a local claude tmux lane reads the ssh bound nowhere and is not aborted by a broken one"

# A pane read that fails on THIS machine is the local failure it is, never a
# host that showed no prompt: the operator is sent to their own tmux, not to a
# window on the sandbox. Both reads the wait makes get a row. The failure is
# aimed at the wait's own call, because the two subcommands have other readers
# in the same run: display-message also reads pane_in_mode before every paste,
# and capture-pane also carries the brief verification.
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_TMUX_FAIL_NTH=display-message:3;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-132
assert_eq "$(observe "rc=1 tmuxfailed=operation=display-message,item=KEN-132 promptmissing=none")" \
  "rc=1 tmuxfailed=operation=display-message,item=KEN-132 promptmissing=none" \
  "a failed pane-command read during the ssh wait is tmux-failed naming display-message, not remote-prompt-missing"
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_TMUX_FAIL_NTH=capture-pane:1;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-133
assert_eq "$(observe "rc=1 tmuxfailed=operation=capture-pane,item=KEN-133 promptmissing=none")" \
  "rc=1 tmuxfailed=operation=capture-pane,item=KEN-133 promptmissing=none" \
  "a failed pane capture during the ssh wait is tmux-failed naming capture-pane, not remote-prompt-missing"

# The two bounds are told apart by the polling, not by the refusal's own field:
# with three seconds for the ssh bound and one for the other, a host that
# answers neither dial is looked at four times per wait plus the one look that
# finds the pane back at its shell. Read against ORCH_TMUX_VERIFY_SECS the same
# run makes five looks, so a wait that took the wrong bound cannot pass here.
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_SSH_PROMPT_SECS=3;ORCH_TMUX_VERIFY_SECS=1;OT_SSH_CONNECTS_ON=3;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-126
assert_eq "$(observe "rc=1 promptmissing=item=KEN-126,host=$HOST_STUB,reason=prompt-silent,seconds=3,attempts=2") polls=$(grep -c '^display-message .*pane_current_command' "$RUN/tmux.log" || true)" \
  "rc=1 promptmissing=item=KEN-126,host=$HOST_STUB,reason=prompt-silent,seconds=3,attempts=2 polls=9" \
  "both waits poll on the ssh bound, which the run's look count separates from the verification timeout"

# A client already past connect keeps the pane through the interrupt: its
# terminal is in raw mode, so C-c is forwarded to the remote rather than
# killing it. The pane never comes back to its own shell, so no second line
# can be run and the refusal reports the one dial that was made, on a host
# that would have answered a later one. The third wait is here, and it takes
# the ssh bound: at three seconds against one for the verification timeout the
# run makes four looks per wait, where the harness bound would make two in the
# second wait and eight looks in all.
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_SSH_PROMPT_SECS=3;ORCH_TMUX_VERIFY_SECS=1;OT_SSH_CONNECTS_ON=2;OT_SSH_IGNORES_INTERRUPT=1;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-134
assert_eq "$(observe "rc=1 promptmissing=item=KEN-134,host=$HOST_STUB,reason=prompt-silent,seconds=3,attempts=1") ssh=$(typed "$SSH_LINE") int=$(typed "$INTERRUPT") polls=$(grep -c '^display-message .*pane_current_command' "$RUN/tmux.log" || true)" \
  "rc=1 promptmissing=item=KEN-134,host=$HOST_STUB,reason=prompt-silent,seconds=3,attempts=1 ssh=1 int=1 polls=8" \
  "a client that keeps the pane through the interrupt is refused on its one dial, the wait for the shell spending the ssh bound"
# The interrupt is a keystroke that can fail on this machine like any other,
# and it is refused under its own operation name: an operator sent to debug an
# ssh paste would be looking at a line that was never typed. The send-keys the
# interrupt makes is the second of the run, the first being the Enter that
# submits the ssh line.
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_CONNECTS_ON=2;OT_TMUX_FAIL_NTH=send-keys:2;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-135
assert_eq "$(observe "rc=1 tmuxfailed=operation=interrupt,item=KEN-135 promptmissing=none")" \
  "rc=1 tmuxfailed=operation=interrupt,item=KEN-135 promptmissing=none" \
  "an interrupt that fails on this machine is tmux-failed naming interrupt, not a host that showed no prompt"

# The screen is read for its LAST non-blank line, because a real login prints a
# banner above its prompt. One row per direction: a banner that itself ends in
# a prompt character above the real prompt launches, and a banner ending in a
# full stop below the real prompt does not. The second is the one a reader of
# the first line would pass.
BANNER_FIRST="$TMP_ROOT/ssh-screen-banner-first"
printf 'Last login from 100.64.0.2 >\ndev@lane:~$\n' > "$BANNER_FIRST"
BANNER_LAST="$TMP_ROOT/ssh-screen-banner-last"
printf 'dev@lane:~$\nThis sandbox rejoins the tailnet on boot.\n' > "$BANNER_LAST"
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_SCREEN=$BANNER_FIRST;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-136
assert_eq "$(observe "rc=0 launched=1 promptmissing=none") ssh=$(typed "$SSH_LINE")" \
  "rc=0 launched=1 promptmissing=none ssh=1" \
  "a prompt under a banner line is the line the wait reads, and the lane launches on one dial"
run_ot "ORCH_LANE_HOST=$HOST_STUB;OT_SSH_SCREEN=$BANNER_LAST;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-137
assert_eq "$(observe "rc=1 promptmissing=item=KEN-137,host=$HOST_STUB,reason=prompt-silent,seconds=1,attempts=2")" \
  "rc=1 promptmissing=item=KEN-137,host=$HOST_STUB,reason=prompt-silent,seconds=1,attempts=2" \
  "a prompt with a banner line under it is not the line the wait reads, and the bound is spent"

# A hosted lane reads ORCH_TMUX_VERIFY_SECS only where it is claude with no
# --cmd: a fresh launch waits on its brief, a relaunch on its harness screen
# through tmux_wait_harness. The account read, and tmux_wait_harness as its
# premise, sit behind lane_account_readable, which is false for every hosted
# lane. So a broken one must not abort the hosted shapes that
# never consult it, and must still abort the ones that do. One row per term of
# that condition, the harness and the --cmd template, and one for each shape it
# lets through.
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_TMUX_VERIFY_SECS=abc;flags=-m gpt-6-astra -c model_reasoning_effort=high" --harness codex --lane "$H/.eclaude" --repo o/r KEN-127
assert_eq "$(observe "rc=0 launched=1 seconds_invalid=none")" "rc=0 launched=1 seconds_invalid=none" \
  "a hosted codex lane carries no brief and is not aborted by a broken verification timeout"
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_TMUX_VERIFY_SECS=abc;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r KEN-128
assert_eq "$(observe "rc=0 launched=1 seconds_invalid=none")" "rc=0 launched=1 seconds_invalid=none" \
  "a hosted --cmd lane carries no brief either, and is not aborted by the same broken timeout"
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_TMUX_VERIFY_SECS=abc;$CHOICE" --harness claude --lane "$H/.eclaude" --repo o/r --relaunch KEN-138
assert_eq "$(observe "rc=1 launched=nolog seconds_invalid=setting=ORCH_TMUX_VERIFY_SECS,value=abc")" \
  "rc=1 launched=nolog seconds_invalid=setting=ORCH_TMUX_VERIFY_SECS,value=abc" \
  "a hosted claude relaunch waits on its harness screen, so it refuses that broken timeout before any create"
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_TMUX_VERIFY_SECS=abc;$CHOICE" --harness claude --lane "$H/.eclaude" --repo o/r KEN-129
assert_eq "$(observe "rc=1 launched=nolog seconds_invalid=setting=ORCH_TMUX_VERIFY_SECS,value=abc")" \
  "rc=1 launched=nolog seconds_invalid=setting=ORCH_TMUX_VERIFY_SECS,value=abc" \
  "a fresh hosted claude launch, which waits on its brief, refuses that broken timeout before any create"

# A hosted lane's composer nudge and brief re-paste go into a pane ssh holds,
# so both are written expecting ssh: the harness runs on the host, never under
# this pane. The pane shows no brief after the launch line, then a ready
# composer once the nudge's Enter lands, then the brief the second paste sent.
BRIEF_ROW="ORCH_LANE_HOST=$HOST_STUB;OT_COMPOSER_ON_ENTER=3;$CHOICE"
brief_resend() { # ITEM
  printf 'rc=%s enters=%s brief=%s redelivered=%s refused=%s' "$RC" "$(typed "send-keys -t %1 Enter")" \
    "$(grep -cxF -- "/orch start $1 $UNATTENDED_TEXT" "$RUN/tmux.log" || true)" "$(said "open-terminal: brief-redelivered item=$1")" \
    "$(awk '$1 == "open-terminal:" && $2 == "pane-refused" { print $3, $4; exit }' <<<"$OUT" | tr ' ' ',')"
}
run_ot "$BRIEF_ROW" --harness claude --lane "$H/.eclaude" --repo o/r KEN-151
assert_eq "$(brief_resend KEN-151)" "rc=0 enters=4 brief=1 redelivered=1 refused=" \
  "a hosted claude lane whose first screen lacks the brief is nudged and re-sent the brief through its ssh pane"

# Control: the same launch against a copy that expects the harness in that
# pane has its nudge refused, so the brief is never re-sent and the lane fails.
# run_ot reads $OPEN_TERMINAL, so the mutant takes that name for its row and
# the shipped path is restored after.
BRIEF_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-running-ssh/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-running-ssh/orch"
mutate_file "$OPEN_TERMINAL" '    running=ssh' '    running="$HARNESS"'
run_ot "$BRIEF_ROW" --harness claude --lane "$H/.eclaude" --repo o/r KEN-152
assert_eq "$(brief_resend KEN-152)" "rc=1 enters=2 brief=0 redelivered=0 refused=operation=nudge,item=KEN-152" \
  "control: a hosted lane expecting its harness under the ssh pane has its nudge refused and never gets the brief"
OPEN_TERMINAL="$BRIEF_OT_SHIPPED"


lane_suite_end
