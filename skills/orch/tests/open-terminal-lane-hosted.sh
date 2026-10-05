#!/usr/bin/env bash
# Tests for open-terminal's hosted --lane launch: lane-host create, the ssh
# pane and its prompt wait.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. Every run gets its own claim store, tmux log and
# pane counter, so no row reads another's launches. tmux, worktree and gh are
# stubs: run under a live session (TMUX set) open-terminal's default is tmux
# mode, and an unstubbed launch would open a real window per row. The world
# they share is lib/open-terminal-lane-world.sh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-hosted: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-hosted: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-hosted: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-lane-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-lane-world.sh"

echo "=== a hosted launch goes through lane-host create and an ssh pane ==="
# The host stub answers create with one fixed line. A hosted launch calls no
# worktree helper, types ssh, then the remote prefix, and renders no lane env
# prefix while its claim still names the lane. A relaunch hands the picked
# account and --relaunch to create and continues the harness natively. Create
# exit 75 skips the item; any other exit fails it before a window opens. A
# harness the host protocol does not name and a wake are refused before create,
# and a create line missing a field fails the item before a window opens.
HOST_STUB="$TEST_DIR/fixtures/lane-host"
# Every provider call the run made, in order: one `,`-joined verb and argument
# list per call, the calls themselves joined with `;`. A row that asserts this
# asserts the whole call sequence, so a call the launcher adds cannot pass
# unnoticed.
host_call() { [[ -f "$RUN/host.log" ]] || { echo nolog; return; }; sed -E -e 's/ +$//' -e "s#$H/\\.##g" -e 's/ /,/g' "$RUN/host.log" | paste -sd';' -; }
typed() { grep -cF -- "$1" "$RUN/tmux.log" 2>/dev/null || true; }
said() { grep -cxF -- "$1" <<<"$OUT" || true; }

run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD" --harness claude --lane work --repo o/r KEN-40
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") calls=$(host_call) ssh=$(typed "clear; ssh 'lane.example'") remote=$(typed "exec bash -lc 'cd /srv/lane && exec true --model opus --effort high $QUESTION_OFF_ALL'") env=$(typed CLAUDE_CONFIG_DIR=) opened=$(said "open-terminal: tmux-opened item=KEN-40 host=$HOST_STUB path=/srv/lane")" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude calls=accounts;create,--item,KEN-40,--repo,o/r,--harness,claude,--account,eclaude;cat,--item,KEN-40,/srv/lane/.git;put,--item,KEN-40,/srv/clone/.git/lane-mail/ken-40;cat,--item,KEN-40,/srv/clone/.git/lane-mail/ken-40;put,--item,KEN-40,/srv/clone/.git/worktrees/lane/lane-refresh;put,--item,KEN-40,/srv/lane/tmp/lane-mail/KEN-40/context.json ssh=1 remote=1 env=0 opened=1" \
  "a hosted launch creates through lane-host, types ssh then the remote line, and renders no lane env prefix"
# The refresh record a hosted launch puts where the lane's .git names its
# worktree git directory: the lane's root for --lane-refresh, else empty, which
# the drift hook reads as no refresh lane, since the host has no verb that
# deletes it.
hosted_refresh() { local f="$RUN/remote/srv/clone/.git/worktrees/lane/lane-refresh"; [[ -f "$f" ]] && printf '[%s]' "$(cat "$f")" || printf none; }
assert_eq "refresh=$(hosted_refresh)" "refresh=[]" "a hosted launch without --lane-refresh empties the refresh record"
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD" --harness claude --lane work --repo o/r --lane-refresh KEN-40
assert_eq "rc=$RC refresh=$(hosted_refresh)" "rc=0 refresh=[/srv/lane]" "a hosted --lane-refresh launch puts the lane's root in the refresh record"
# Q is how single_quote renders one quote of the continuation line inside the
# remote command. A hosted relaunch selects a resume or the start brief and
# counts only once its pane draws a harness screen, which HARNESS_UP shows once the remote command is typed;
# open-terminal-relaunch-route.sh holds that route's own rows.
#
# One row per harness. Codex's resume arm stays promptless under D002, while
# its fresh arm carries the start brief. Pi's resume carries the continuation
# line, while its fresh arm carries the start brief.
# Write it as ${Q} wherever a letter, digit or underscore follows: `$Qopus` is
# the variable Qopus, which under `set -u` empties the whole substitution the
# expectation was built in and leaves the row comparing against nothing.
Q="'\\''"
printf 'Working (esc to interrupt)\n' > "$TMP_ROOT/harness-screen"
HARNESS_UP="OT_HARNESS_SCREEN=$TMP_ROOT/harness-screen"
# The flags a hosted claude command leads with, as the remote command quotes them.
CLAUDE_LEAD="$Q--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}$Q $Q--disallowedTools=AskUserQuestion,EnterPlanMode$Q $Q--model$Q ${Q}opus$Q $Q--effort$Q ${Q}high$Q"
# The unattended words every brief and continuation line closes on, the text
# read from lib/lane-launch.sh, which renders and judges them.
UNATTENDED_TEXT="$( source "$SCRIPTS_DIR/lib/lane-launch.sh" && printf '%s' "$LAUNCH_UNATTENDED_TEXT" )"
[[ -n "$UNATTENDED_TEXT" ]] || { echo "lib/lane-launch.sh named no unattended text" >&2; exit 1; }
# hosted_resume ITEM NAME BRIEF — the remote command of a hosted claude
# relaunch, the continuation line and the start brief each closing on the
# unattended words.
hosted_resume() { printf "exec bash -lc 'cd /srv/lane && { claude %s --continue %s%s %s%s || [ \$? -ne 1 ] || exec claude -n %s %s %s%s %s%s; }'" "$CLAUDE_LEAD" "$Q" "$HOSTED_LINE" "$UNATTENDED_TEXT" "$Q" "$2" "$CLAUDE_LEAD" "$Q" "$3" "$UNATTENDED_TEXT" "$Q"; }
hosted_line() { printf 'Resume the orch workflow for %s from where this session stopped. Run .agents/skills/orch/scripts/lane-mail inbox --item %s first and act on every directive it prints, then re-arm your mailbox monitor on .agents/skills/orch/scripts/lane-mail watch --item %s through your harness background wake.' "$1" "$1" "$1"; }
HOSTED_LINE="$(hosted_line KEN-41)"
run_ot "$HARNESS_UP;$CHOICE" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --relaunch KEN-41
assert_eq "$(observe "rc=0 creates=nolog launched=1") calls=$(host_call) remote=$(typed "$(hosted_resume KEN-41 KEN-41 '/orch start KEN-41')")" \
  "rc=0 creates=nolog launched=1 calls=accounts;create,--item,KEN-41,--repo,o/r,--harness,claude,--account,claude,--relaunch;cat,--item,KEN-41,/srv/lane/.git;put,--item,KEN-41,/srv/clone/.git/lane-mail/ken-41;cat,--item,KEN-41,/srv/clone/.git/lane-mail/ken-41;put,--item,KEN-41,/srv/clone/.git/worktrees/lane/lane-refresh;put,--item,KEN-41,/srv/lane/tmp/lane-mail/KEN-41/context.json remote=1" \
  "a hosted claude relaunch passes the picked account and --relaunch, and continues natively with the continuation line, the start brief behind it"
HOSTED_LINE='Resume the orch workflow for KEN-48 from where this session stopped. Run .agents/skills/orch/scripts/lane-mail inbox --item KEN-48 first and act on every directive it prints.'
PI_RELAUNCH="$HARNESS_UP;ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_COPILOT_POOL=$H/.eclaude=1/10;flags=--model github-copilot/opus --thinking high"
run_ot "$PI_RELAUNCH" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-48
PI_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
PI_RESUME="0) exec pi '--exclude-tools' 'question' '--model' 'github-copilot/opus' '--thinking' 'high' --session \"\$session\" '$HOSTED_LINE $UNATTENDED_TEXT' ;; 1) exec pi"
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") lookup=$(grep -cF 'session=$(bash .agents/skills/orch/scripts/lib/lane-relaunch.sh pi KEN-48 ' <<<"$PI_REMOTE" || true) resume=$(grep -cF "$PI_RESUME" <<<"$PI_REMOTE" || true) fresh=$(grep -cF "'/skill:orch start KEN-48 $UNATTENDED_TEXT'" <<<"$PI_REMOTE" || true)" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude lookup=1 resume=1 fresh=1" \
  "a hosted pi relaunch selects its host session or the start brief, keeping its lane and continuation line"
PI_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pi-native/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pi-native/orch"
mutate_file "$OPEN_TERMINAL" '      codex | pi)' '      pi) printf '\''pi %s-c%s\n'\'' "$flags" "$line"; return ;;'$'\n''      pi | codex)'
run_ot "$PI_RELAUNCH" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-48
PI_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
assert_eq "rc=$RC selection=$(grep -cF "$PI_RESUME" <<<"$PI_REMOTE" || true) native=$(grep -cF " -c '$HOSTED_LINE $UNATTENDED_TEXT'" <<<"$PI_REMOTE" || true)" \
  "rc=0 selection=0 native=1" "control: the old pi -c form fails the resume-or-fresh assertion"
OPEN_TERMINAL="$PI_OT_SHIPPED"
# A hosted Pi launch on a pi-claude model is refused before any pick, judge or
# host call, auto and named alike: the host protocol hands a Pi lane its
# account as its Pi root and carries no Claude seat. The control drops the
# refusal, and the auto launch goes on to the provider.
for pi_seat_lane in auto work; do
  run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model pi-claude/opus --thinking high" --host "$HOST_STUB" --harness pi --lane "$pi_seat_lane" --repo o/r KEN-1690
  assert_eq "$(observe "rc=1 launched=nolog hostseat=host=$HOST_STUB,model=pi-claude/opus") calls=$(host_call)" \
    "rc=1 launched=nolog hostseat=host=$HOST_STUB,model=pi-claude/opus calls=nolog" \
    "a hosted Pi launch on a pi-claude model under --lane $pi_seat_lane is refused before any host call"
done
PI_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pi-seat/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pi-seat/orch"
mutate_file "$OPEN_TERMINAL" '"$(lane_pick_harness pi "$LAUNCH_MODEL")" == claude ]]; then' '"$(lane_pick_harness pi "$LAUNCH_MODEL")" == claude-dropped ]]; then'
run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model pi-claude/opus --thinking high" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-1690
assert_eq "$(observe "hostseat=none") called=$([[ "$(host_call)" == nolog ]] && echo no || echo yes)" "hostseat=none called=yes" \
  "control: without the refusal a hosted Pi launch on a pi-claude model goes on to the provider"
OPEN_TERMINAL="$PI_OT_SHIPPED"
# A hosted Pi relaunch on a Copilot model whose pool neither the provider's
# harness=pi row nor the override reads is refused as unmeasured, with the fix
# naming the provider's accounts read, and open-terminal does not ask whether
# the provider holds the account: the judge already read the provider's row.
run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model github-copilot/claude-sonnet-5 --thinking high" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-1665
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,step=windows unanswered=0 relaunchgate=0 poolfix=host:$H/.eclaude")" \
  "rc=1 launched=nolog unreadable=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,step=windows unanswered=0 relaunchgate=0 poolfix=host:$H/.eclaude" \
  "a hosted Pi relaunch on an unread Copilot pool is refused as unmeasured, naming the accounts read, open-terminal never asking whether the provider holds the account"
# The provider's harness=pi row is the pool with no hand-set number: a row with
# room admits the relaunch, and a walled row refuses it on the monthly bucket
# even where the override states room.
PI_ROW_FILE="$TMP_ROOT/hosted-accounts-pi.tsv"
pi_hosted_row() { # PCT
  printf 'account=%s\tharness=pi\tmonthly-pct=%s\tmonthly-resets=2026-10-07T00:00:00Z\n' "$H/.eclaude" "$1" > "$PI_ROW_FILE"
}
pi_hosted_row 40
run_ot "$HARNESS_UP;ORCH_LANE_ALIASES=eclaude=work;LANE_HOST_STUB_ACCOUNTS=$PI_ROW_FILE;flags=--model github-copilot/claude-sonnet-5 --thinking high" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=0 launched=1 unreadable=none poolfix=none")" "rc=0 launched=1 unreadable=none poolfix=none" \
  "a hosted Pi relaunch is admitted on the provider's pool row with no stated reading"
pi_hosted_row 97
run_ot "ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_COPILOT_POOL=$H/.eclaude=1/10;LANE_HOST_STUB_ACCOUNTS=$PI_ROW_FILE;flags=--model github-copilot/claude-sonnet-5 --thinking high" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,pct=97,bucket=monthly,projected-headroom=3")" \
  "rc=1 launched=nolog walled=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,pct=97,bucket=monthly,projected-headroom=3" \
  "a hosted Pi relaunch is refused on a walled provider row, the stated override replaced"
# A provider row that holds the Pi root and reads no pool leaves it unmeasured,
# and the relaunch is refused: asked whether the provider holds the account,
# open-terminal would take the row as held and relaunch on a pool nobody read.
printf 'account=%s\tharness=pi\tstatus=refused\tdetail=http-403-forbidden\n' "$H/.eclaude" > "$PI_ROW_FILE"
PI_HELD="ORCH_LANE_ALIASES=eclaude=work;LANE_HOST_STUB_ACCOUNTS=$PI_ROW_FILE;flags=--model github-copilot/claude-sonnet-5 --thinking high"
run_ot "$PI_HELD" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 poolfix=row:$H/.eclaude")" "rc=1 launched=nolog relaunchgate=0 poolfix=row:$H/.eclaude" \
  "a hosted Pi relaunch on a provider row that reads no pool is refused, never relaunched as held"
# The same row under `auto` is the unstated refusal, its fix naming the row,
# never a walled pool: nobody read it. The control drops the unstated arm, and
# the refusal is reported as lanes failing.
run_ot "$PI_HELD" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-1669
assert_eq "$(observe "rc=1 launched=nolog pickrefusal=copilot-pool-unstated,setting=ORCH_LANE_COPILOT_POOL poolfix=row:$H/.eclaude")" \
  "rc=1 launched=nolog pickrefusal=copilot-pool-unstated,setting=ORCH_LANE_COPILOT_POOL poolfix=row:$H/.eclaude" \
  "a hosted auto Pi launch on a provider row that reads no pool is refused as unstated, naming the row"
pi_control ctl-pi-auto-row open-terminal '    5:pi) ot_message copilot-pool-unstated' '    5:pi-dropped) ot_message copilot-pool-unstated' \
  "$PI_HELD" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-1669
assert_eq "$(observe "rc=1 pickrefusal=none failed=exit=5")" "rc=1 pickrefusal=none failed=exit=5" \
  "control: without the unstated arm the auto refusal on an unread row is reported as lanes failing"
PI_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pi-host/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pi-host/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$LANE_HOST" == local || "$LAUNCH_HARNESS" == pi ]]' '[[ "$LANE_HOST" == local ]]'
run_ot "$HARNESS_UP;$PI_HELD" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=0 relaunchgate=1")" "rc=0 relaunchgate=1" \
  "control: a Pi relaunch that asks the provider relaunches on a held row whose pool nobody read"
OPEN_TERMINAL="$PI_OT_SHIPPED"
# A hosted copilot launch: the account holds its login and a pool with room,
# the provider is handed --harness copilot, and the remote line runs copilot
# under the launch policy lib/lane-launch.sh's lane_copilot_env prints, the
# skills tree named by the host's own $HOME, with no local COPILOT_HOME: the
# provider's prefix sets that.
mkdir -p "$H/.1copilot"
printf '{"copilot_tokens":"gho_fixture"}\n' > "$H/.1copilot/config.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.1copilot.json"
COPILOT_HOSTED="flags=--model claude-opus-5 --reasoning-effort high --allow-all"
run_ot "$COPILOT_HOSTED" --host "$HOST_STUB" --harness copilot --lane "$H/.1copilot" --repo o/r KEN-1935
COPILOT_REMOTE="exec bash -lc 'cd /srv/lane && exec env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS=\"\$HOME/.agents/skills\" COPILOT_ALLOW_ALL=true copilot $Q--autopilot$Q"
assert_eq "$(observe "rc=0 launched=1") create=$(host_call | tr ';' '\n' | grep -c '^create,--item,KEN-1935,--repo,o/r,--harness,copilot,--account,1copilot$') remote=$(typed "$COPILOT_REMOTE") local=$(typed COPILOT_HOME=)" \
  "rc=0 launched=1 create=1 remote=1 local=0" \
  "a hosted copilot launch creates with --harness copilot and runs copilot under the launch policy, the provider setting COPILOT_HOME"
COPILOT_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-copilot-host/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-copilot-host/orch"
mutate_file "$OPEN_TERMINAL" '"$HARNESS" =~ ^(claude|codex|pi|copilot)$ ]] || host_launch_ready=false' '"$HARNESS" =~ ^(claude|codex|pi)$ ]] || host_launch_ready=false'
run_ot "$COPILOT_HOSTED" --host "$HOST_STUB" --harness copilot --lane "$H/.1copilot" --repo o/r KEN-1935
assert_eq "$(observe "rc=1 launched=nolog") invalid=$(awk '$2 == "host-invalid" { print $NF }' <<<"$OUT")" "rc=1 launched=nolog invalid=harness=copilot" \
  "control: without copilot in the host protocol's harnesses a hosted copilot launch is host-invalid"
OPEN_TERMINAL="$COPILOT_OT_SHIPPED"
OPEN_TERMINAL="$(mutant_scripts ctl-copilot-policy/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-copilot-policy/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$HARNESS" != copilot ]] || cmd="$(lane_copilot_env' '[[ "$HARNESS" == copilot ]] || cmd="$(lane_copilot_env'
run_ot "$COPILOT_HOSTED" --host "$HOST_STUB" --harness copilot --lane "$H/.1copilot" --repo o/r KEN-1936
assert_eq "$(observe "rc=0 launched=1") policy=$(typed "COPILOT_ALLOW_ALL=true copilot")" "rc=0 launched=1 policy=0" \
  "control: without the hosted policy a hosted copilot lane keeps the COPILOT_GITHUB_TOKEN its host exports"
OPEN_TERMINAL="$COPILOT_OT_SHIPPED"
CODEX_RELAUNCH="$HARNESS_UP;LANE_HOST_STUB_SELECTION=resume;ORCH_LANE_ALIASES=eclaude=work;flags=-m gpt-6-astra -c model_reasoning_effort=high"
run_ot "$CODEX_RELAUNCH" --host "$HOST_STUB" --harness codex --lane work --repo o/r --relaunch KEN-49
CODEX_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
CODEX_LEAD="codex '-c' 'check_for_update_on_startup=false' '-c' 'model_auto_compact_token_limit=9223372036854775807' '-c' 'model_auto_compact_token_limit_scope=body_after_prefix' '-c' 'model_post_turn_compact_threshold_percent=0' '-c' 'features.default_mode_request_user_input=false' '-m' 'gpt-6-astra' '-c' 'model_reasoning_effort=high'"
CODEX_RESUME="0) printf resume > tmp/lane-mail/KEN-49/relaunch-selection || exit 2; exec $CODEX_LEAD resume \"\$session\" ;; 1) printf fresh > tmp/lane-mail/KEN-49/relaunch-selection || exit 2; exec $CODEX_LEAD 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for KEN-49. $UNATTENDED_TEXT'"
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") lookup=$(grep -cF 'session=$(bash .agents/skills/orch/scripts/lib/lane-relaunch.sh codex KEN-49 ' <<<"$CODEX_REMOTE" || true) arms=$(grep -cF "$CODEX_RESUME" <<<"$CODEX_REMOTE" || true) compaction=$(typed "ORCH_COMPACTION_OVERRIDES=$Q$CODEX_COMPACTION$Q") line=$(typed 'Resume the orch workflow for KEN-49')" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude lookup=1 arms=1 compaction=1 line=0" \
  "a hosted codex relaunch selects its host session promptless or the start brief, keeping its lane and compaction flags"
# The lane comes up idle, so the launcher owes the operator a record saying the
# line is still to be pasted; without one the summary reports the item as
# launched and nothing distinguishes it from a lane that got its instruction.
# The assertion named "the promptless resume is recorded as owing its
# continuation line" is what reddens if the record goes away.
assert_eq "$(said "open-terminal: resume-lineless item=KEN-49 harness=codex")" "1" \
  "the promptless resume is recorded as owing its continuation line"
# Parse-level control against the real codex parser. The host lookup supplies
# the session id. Appending one prompt parses (exit 1, stdin is not a terminal)
# only while the resume arm is promptless. An arm already carrying a prompt
# rejects the extra positional (exit 2). --help bypasses that argument check.
if command -v codex >/dev/null 2>&1; then
  RENDERED="$(sed -n 's/.*0) printf resume .*; exec \(codex .*\) ;; 1) printf fresh .*/\1/p' <<<"$CODEX_REMOTE")" || exit 1
  assert_eq "${RENDERED:-MISSING}" "$CODEX_LEAD resume \"\$session\"" \
    "the rendered resume arm is recovered from the pane log with no prompt"
  CODEX_PARSE_RC=0
  CODEX_HOME="$TMP_ROOT/codex-parse-home" timeout 20 bash -c "session=11111111-1111-4111-8111-111111111111; $RENDERED zz-appended-prompt" </dev/null >/dev/null 2>&1 || CODEX_PARSE_RC=$?
  assert_eq "$CODEX_PARSE_RC" "1" "a prompt appended to the rendering fits the unfilled prompt slot"
  CODEX_REFUSE_RC=0
  CODEX_HOME="$TMP_ROOT/codex-parse-home" timeout 20 codex resume 11111111-1111-4111-8111-111111111111 'a continuation line' zz-appended-prompt </dev/null >/dev/null 2>&1 || CODEX_REFUSE_RC=$?
  assert_eq "$CODEX_REFUSE_RC" "2" "control: the same append onto a resume carrying a line fails parsing"
else
  echo "  skip  codex is not installed; the parse-level control did not run"
fi
CODEX_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-codex-native/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-codex-native/orch"
mutate_file "$OPEN_TERMINAL" '      codex | pi)' '      codex) printf '\''codex %sresume --last\n'\'' "$flags"; return ;;'$'\n''      pi | codex)'
run_ot "$CODEX_RELAUNCH" --host "$HOST_STUB" --harness codex --lane work --repo o/r --relaunch KEN-49
CODEX_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
assert_eq "rc=$RC selection=$(grep -cF "$CODEX_RESUME" <<<"$CODEX_REMOTE" || true) native=$(grep -cF ' resume --last' <<<"$CODEX_REMOTE" || true)" \
  "rc=0 selection=0 native=1" "control: the old codex resume --last form fails the resume-or-fresh assertion"
OPEN_TERMINAL="$CODEX_OT_SHIPPED"
# The expected arms still use the shipped text read above, not this copy.
CODEX_UNATTENDED_SCRIPTS="$(mutant_scripts ctl-codex-unattended/orch lib/lane-launch.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-codex-unattended/orch"
mutate_file "$CODEX_UNATTENDED_SCRIPTS/lib/lane-launch.sh" "LAUNCH_UNATTENDED_TEXT='This is" "LAUNCH_UNATTENDED_TEXT='changed unattended text. This is"
OPEN_TERMINAL="$CODEX_UNATTENDED_SCRIPTS/open-terminal"
run_ot "$CODEX_RELAUNCH" --host "$HOST_STUB" --harness codex --lane work --repo o/r --relaunch KEN-49
CODEX_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
assert_eq "rc=$RC arms=$(grep -cF "$CODEX_RESUME" <<<"$CODEX_REMOTE" || true) changed=$(grep -cF 'changed unattended text.' <<<"$CODEX_REMOTE" || true)" \
  "rc=0 arms=0 changed=1" "control: changed unattended text fails the exact codex resume-or-fresh assertion"
OPEN_TERMINAL="$CODEX_OT_SHIPPED"
# A GitHub-tracker item is the issue number while its worktree id is issue-<n>,
# and the lane's mailbox is bound under the worktree id: write_lane_marker
# writes it there and the overseer's `lane-mail send --item` writes the same
# id. A line built from the bare number would send the lane to an empty mailbox
# and lose every queued answer, directive and halt. The hosted arm renders the
# line with no transcript lookup, so it is where the two ids are visibly
# distinct, and the assertion below is what reddens if the bare number returns.
HOSTED_LINE="$(hosted_line issue-2708)"
run_ot "$HARNESS_UP;ORCH_LANE_ALIASES=eclaude=work;$CHOICE" --host "$HOST_STUB" --tracker github --harness claude --lane work --repo o/r --relaunch 2708
assert_eq "$(observe "rc=0 creates=nolog launched=1") calls=$(host_call) remote=$(typed "$(hosted_resume issue-2708 github-2708 '/orch start github o/r#2708')")" \
  "rc=0 creates=nolog launched=1 calls=accounts;create,--item,issue-2708,--repo,o/r,--harness,claude,--account,eclaude,--relaunch;cat,--item,issue-2708,/srv/lane/.git;put,--item,issue-2708,/srv/clone/.git/lane-mail/issue-2708;cat,--item,issue-2708,/srv/clone/.git/lane-mail/issue-2708;put,--item,issue-2708,/srv/clone/.git/worktrees/lane/lane-refresh;put,--item,issue-2708,/srv/lane/tmp/lane-mail/issue-2708/context.json remote=1" \
  "a GitHub relaunch names the worktree id its mailbox is bound under, never the bare issue number, and asks the provider nothing beyond the judge's one accounts read on an account that measured"

# WHICH CREDENTIAL A HOSTED LAUNCH RUNS ON. The host runs the copy the provider
# put there, which is independent of this machine's copy only where the provider
# installs a secret of its own; a provider that re-seeds the host from the
# account's config dir at every create runs this machine's copy, on a relaunch as
# much as a fresh launch. So the PROVIDER'S ANSWER decides, never the --relaunch
# flag: the answer comes from `lanes host-accounts`, the one reader of that verb,
# and only `held` skips the usage gate.
#
# xclaude carries an expired access token and no refresh token to renew it with,
# so `lanes` reports it `expired`, the login proven dead, and measures no window.
# A client id is configured for every row on it: without one the renewal fails on
# this machine's own setting, which reads `error` and proves nothing about the
# login. Each row below differs from its neighbour in one thing: what the
# provider answers, and whether the launch is a relaunch.
make_dead_lane "$H" xclaude
printf 'account=%s\tharness=claude\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts.tsv"
HOSTED_ACCOUNT="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;$HOSTED_ACCOUNT;$CHOICE_CMD" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r KEN-77
assert_eq "$(observe "rc=1 launched=nolog credentialdead=lane=$H/.xclaude,host=$HOST_STUB unreadable=none")" \
  "rc=1 launched=nolog credentialdead=lane=$H/.xclaude,host=$HOST_STUB unreadable=none" \
  "a fresh hosted launch on an account this machine cannot renew is refused as host-credential-dead"
run_ot "$HARNESS_UP;ORCH_LANES_CLAUDE_CLIENT_ID=client-1;$HOSTED_ACCOUNT;flags=--model fable --effort high" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r --relaunch KEN-78
assert_eq "$(observe "rc=0 launched=1 credentialdead=none unreadable=none relaunchgate=1")" \
  "rc=0 launched=1 credentialdead=none unreadable=none relaunchgate=1" \
  "a hosted relaunch on that same dead local copy proceeds, and says which credential runs it"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;$CHOICE_CMD" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r KEN-79
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "a provider holding no credential for the account leaves the refusal the unread window it was"
# The relaunch's skip is the provider's answer, not the flag. A provider with no
# accounts verb — the shipped reference lane-host-ssh, which copies this
# machine's account files to the host at every create — answers nothing, so the
# relaunch is judged on the local reading it runs on. Silent: the absent verb is
# no news.
RELAUNCH_FLAGS="$HARNESS_UP;flags=--model fable --effort high"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_NO_ACCOUNTS=1;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch KEN-100
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 unanswered=0 credentialdead=none unreadable=lane=$H/.xclaude,model=fable,step=windows")" \
  "rc=1 launched=nolog relaunchgate=0 unanswered=0 credentialdead=none unreadable=lane=$H/.xclaude,model=fable,step=windows" \
  "a hosted relaunch whose provider implements no accounts verb keeps the usage gate, and says nothing about a verb that is absent"

# WHICH unmeasured account gets the login remedy. The remedy is for a credential
# this machine holds and cannot renew, which `lanes` reports as `expired` and
# nothing else; an account that reads fine and simply has no window for the model
# is the unread window it always was. Its own lane, whose one window names a
# model no other row launches, so a pick asking for another model drops it.
make_lane "$H" vclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Haiku"}}}]}' > "$FIXTURE_DIR/.vclaude.json"
printf 'account=%s\tharness=claude\n' "$H/.vclaude" > "$TMP_ROOT/hosted-accounts-vclaude.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-vclaude.tsv;cmd=true --model sonnet --effort high" \
  --host "$HOST_STUB" --harness claude --lane "$H/.vclaude" --repo o/r KEN-110
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.vclaude,model=sonnet,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.vclaude,model=sonnet,step=windows" \
  "a hosted account the provider holds, unmeasured for this model but not expired, is the unread window and not a login to renew"
# WHICH account the provider's answer is about. An answer naming other accounts
# of this harness is an answer that does not name this one, so the exact
# comparison is what stands between a held account and a neighbour's.
printf 'account=%s\tharness=claude\n' "$H/.eclaude" > "$TMP_ROOT/hosted-accounts-other.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-other.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r KEN-111
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "a provider naming other accounts of this harness holds nothing for this one, so the refusal stays the unread window"

# THE WALL BINDS A HOSTED RELAUNCH TOO. A usage window belongs to the account,
# not to the copy of the credential that reads it, so a window measured at the
# threshold here is the window the sandbox meets; resuming would spend the
# sandbox start, the worktree step and the continuation line to open on a usage
# banner. The local twin is KEN-61 above, refused on the same shape, and the
# provider holds this account — which changes the UNMEASURED answer and nothing
# about the wall. Its own lane, so no row that follows reads this window.
make_lane "$H" wclaude 3600
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.wclaude.json"
printf 'account=%s\tharness=claude\n' "$H/.wclaude" > "$TMP_ROOT/hosted-accounts-walled.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-walled.tsv;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.wclaude" --repo o/r --relaunch KEN-107
assert_eq "$(observe "rc=1 launched=nolog creates=nolog relaunchgate=0 walled=lane=$H/.wclaude,model=fable,pct=95,bucket=model,projected-headroom=5")" \
  "rc=1 launched=nolog creates=nolog relaunchgate=0 walled=lane=$H/.wclaude,model=fable,pct=95,bucket=model,projected-headroom=5" \
  "a hosted relaunch onto an account the provider holds meets the wall its local twin meets"

# A verb that exists and fails is the other case: the reader prints the
# provider's own bytes under its keyed line, this launcher adds one of its own,
# and the gate still holds, because no answer establishes nothing.
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS_STATUS=7;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch KEN-101
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 unanswered=1 unreadable=lane=$H/.xclaude,model=fable,step=windows") provider=$(said 'lane-host-fixture: accounts-failed') reader=$(grep -c "^lanes: host-accounts-unreadable host=$HOST_STUB exit=7\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog relaunchgate=0 unanswered=1 unreadable=lane=$H/.xclaude,model=fable,step=windows provider=2 reader=2" \
  "a hosted relaunch whose provider fails the accounts verb keeps the gate, and the provider's and reader's lines appear for the judge's read and the arm's, beside the launcher's line"
# The reader's validation reaches this launcher, which does no matching of its
# own. A row `lanes` drops for a percentage nobody can parse holds no account
# here either, so the refusal is the unread window and not a login remedy the
# owner cannot act on.
printf 'account=%s\tharness=claude\tweekly-pct=999\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts-bad.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-bad.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r KEN-102
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows") dropped=$(grep -c "^lanes: host-account-invalid account=$H/.xclaude field=weekly-pct\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows dropped=2" \
  "an accounts row the reader drops, once for the judge's read and once for the arm's, holds no account for the launcher either"
# The harness is part of the match, and the reader makes it: a row naming this
# account under the other harness is not this launch's account.
printf 'account=%s\tharness=codex\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts-codex.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-codex.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r KEN-103
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "an accounts row naming this account under another harness holds nothing for this launch"
# host-credential-dead is `expired` and no wider. A codex account whose usage
# read this machine could not make is the unread window, never the login
# remedy; one whose expired token `lanes` cannot renew, here for want of a
# refresh token, so no Codex CLI is started, reads `expired` and takes it.
make_codex_lane "$H/.xcodex"
printf 'account=%s\tharness=codex\n' "$H/.xcodex" > "$TMP_ROOT/hosted-accounts-xcodex.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-xcodex.tsv;cmd=true -m gpt-6-astra -c model_reasoning_effort=high" \
  --host "$HOST_STUB" --harness codex --lane "$H/.xcodex" --repo o/r KEN-104
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xcodex,model=gpt-6-astra,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xcodex,model=gpt-6-astra,step=windows" \
  "a codex lane this machine cannot measure is the unread window, never the login remedy"
make_codex_token_lane "$H/.ycodex" -60
printf 'account=%s\tharness=codex\n' "$H/.ycodex" > "$TMP_ROOT/hosted-accounts-ycodex.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-ycodex.tsv;cmd=true -m gpt-6-astra -c model_reasoning_effort=high" \
  --host "$HOST_STUB" --harness codex --lane "$H/.ycodex" --repo o/r KEN-105
assert_eq "$(observe "rc=1 launched=nolog credentialdead=lane=$H/.ycodex,host=$HOST_STUB unreadable=none")" \
  "rc=1 launched=nolog credentialdead=lane=$H/.ycodex,host=$HOST_STUB unreadable=none" \
  "a codex lane whose expired token cannot be renewed is refused as host-credential-dead"
# A folder whose credential only the provider holds: no local credentials file,
# and a provider row carrying its windows. The judge runs under the host this
# launch resolved, --host here with no ORCH_LANE_HOST, so the account is judged
# on the provider's row and launches.
mkdir -p "$H/.tokclaude"
printf '{}\n' > "$H/.tokclaude/.claude.json"
printf 'account=%s\tharness=claude\tsession-5h-pct=10\tweekly-pct=20\tmodel-pct=5\tmodel-label=Opus\n' \
  "$H/.tokclaude" > "$TMP_ROOT/hosted-accounts-token.tsv"
TOKEN_ROW="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token.tsv;$CHOICE_CMD"
run_ot "$TOKEN_ROW" --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r KEN-120
assert_eq "$(observe "rc=0 launched=1 unreadable=none")" "rc=0 launched=1 unreadable=none" \
  "a --host launch on a token-only folder the provider measures is judged on the provider's row and launches"
# A relaunch onto a host row that measured nothing proceeds on the provider's
# answer that it holds the account. The unmeasured arm asks that fresh, beside
# the judge's own read, so the provider is asked twice.
printf 'account=%s\tharness=claude\tstatus=unreachable\n' "$H/.tokclaude" > "$TMP_ROOT/hosted-accounts-token-dark.tsv"
: > "$TMP_ROOT/hosted-accounts-none.tsv"
TOKEN_STATE="$TMP_ROOT/token-state"
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token-dark.tsv;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-122
assert_eq "$(observe "rc=0 launched=1 relaunchgate=1") accounts=$(grep -c '^accounts' "$RUN/host.log" || true)" \
  "rc=0 launched=1 relaunchgate=1 accounts=2" \
  "a relaunch onto a host row that measured nothing proceeds on the arm's own accounts read"
# The judge's read is served from the answer the run above cached, which still
# names the account after the provider has dropped it. The arm's uncached read
# says it is gone, so the relaunch is refused as the unread window it is. That
# read also refreshes the cache, so the control below warms a state of its own.
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-none.tsv;$RELAUNCH_FLAGS" \
  --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-123
assert_eq "$(observe "rc=1 launched=0 relaunchgate=0 unreadable=lane=$H/.tokclaude,model=fable,step=windows")" \
  "rc=1 launched=0 relaunchgate=0 unreadable=lane=$H/.tokclaude,model=fable,step=windows" \
  "a relaunch whose cached host row the provider has since dropped is refused on the arm's fresh read"
# Control: an arm that takes the judge's host record as the provider holding
# the account relaunches onto the dropped account.
TOKEN_CTL_STATE="$TMP_ROOT/token-state-ctl"
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_CTL_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token-dark.tsv;$RELAUNCH_FLAGS" \
  --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-124
assert_eq "$RC" "0" "control warm-up: the relaunch caches the provider's row naming the account"
TOKEN_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-held-cached/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-held-cached/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$LANE_HOST" == local || "$LAUNCH_HARNESS" == pi ]] || host_account_read "${LANE_ENV#*=}" "$LAUNCH_HARNESS"' \
  '[[ "$LANE_HOST" == local || "$LAUNCH_HARNESS" == pi ]] || { [[ "$(jq -r .measured_through <<<"$lane_record")" == host ]] && HOST_ACCOUNT=held; } || host_account_read "${LANE_ENV#*=}" "$LAUNCH_HARNESS"'
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_CTL_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-none.tsv;$RELAUNCH_FLAGS" \
  --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-125
assert_eq "$(observe "rc=0 launched=1 relaunchgate=1")" "rc=0 launched=1 relaunchgate=1" \
  "control: an arm trusting the judge's cached host row relaunches onto an account the provider dropped"
OPEN_TERMINAL="$TOKEN_OT_SHIPPED"
# A provider row the provider could not read, for an account this machine
# holds a live copy of and measures fresh: the judge takes this machine's
# reading, says so, and the fresh launch proceeds. The same row for a folder
# nothing measures, and for one whose local figure is past the TTL, leaves the
# unread window and the refusal it always had.
printf 'account=%s\tharness=claude\tstatus=unreachable\n' "$H/.claude" > "$TMP_ROOT/hosted-accounts-claude-dark.tsv"
CLAUDE_DARK="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-claude-dark.tsv;$CHOICE_CMD"
run_ot "$CLAUDE_DARK" --host "$HOST_STUB" --harness claude --lane "$H/.claude" --repo o/r KEN-126
assert_eq "$(observe "rc=0 launched=1 unreadable=none localreading=1")" "rc=0 launched=1 unreadable=none localreading=1" \
  "a fresh --host launch on an account the provider cannot read is judged on this machine's fresh reading, under its keyed line, and launches"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token-dark.tsv;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r KEN-127
assert_eq "$(observe "rc=1 launched=nolog localreading=0 unreadable=lane=$H/.tokclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog localreading=0 unreadable=lane=$H/.tokclaude,model=opus,step=windows" \
  "the same row for a folder this machine holds no credentials for stays the unread window on a fresh launch"
# The figure the first launch measured is aged past the default TTL and the
# endpoint set to refuse, so the second launch's refresh serves that old figure
# as rate_limited: measured, but not fresh.
DARK_STATE="$TMP_ROOT/claude-dark-state"
run_ot "OVERSEE_WATCH_STATE_DIR=$DARK_STATE;$CLAUDE_DARK" --host "$HOST_STUB" --harness claude --lane "$H/.claude" --repo o/r KEN-128
assert_eq "$RC" "0" "warm-up: the launch under its own state measures the account fresh"
age_usage_record "$DARK_STATE" "$H/.claude" 600
printf '429 0\n' > "$FIXTURE_DIR/.claude.status"
run_ot "OVERSEE_WATCH_STATE_DIR=$DARK_STATE;$CLAUDE_DARK" --host "$HOST_STUB" --harness claude --lane "$H/.claude" --repo o/r KEN-129
assert_eq "$(observe "rc=1 launched=0 localreading=0 unreadable=lane=$H/.claude,model=opus,step=windows")" \
  "rc=1 launched=0 localreading=0 unreadable=lane=$H/.claude,model=opus,step=windows" \
  "a local figure older than the TTL does not stand in for the unreachable row, so the fresh launch is refused"
rm -f -- "${FIXTURE_DIR:?}/.claude.status"
# Control: a judge that does not pass the resolved host reads this machine's
# no_credentials and refuses the unread window.
TOKEN_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-judge-host/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-judge-host/orch"
mutate_file "$OPEN_TERMINAL" 'lane_record="$(ORCH_LANE_HOST="$LANE_HOST" "$LANES_CLI" pick --lane' 'lane_record="$("$LANES_CLI" pick --lane'
run_ot "$TOKEN_ROW" --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r KEN-121
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.tokclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog unreadable=lane=$H/.tokclaude,model=opus,step=windows" \
  "control: a judge run without the resolved host refuses the token-only folder as an unread window"
OPEN_TERMINAL="$TOKEN_OT_SHIPPED"
run_ot "LANE_HOST_STUB_STATUS=75;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-42
assert_eq "$(observe "rc= launched=") owned=$(awk '$2 == "item-owned" { print $3 }' <<<"$OUT")" "rc=75 launched=nolog owned=item=KEN-42" \
  "a hosted create exit 75 skips the item as owned by another session"
run_ot "LANE_HOST_STUB_STATUS=1;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-43
assert_eq "$(observe "rc= launched= creates=") failed=$(said "open-terminal: host-create-failed item=KEN-43 exit=1")" "rc=1 launched=nolog creates=nolog failed=1" \
  "a hosted create failure is host-create-failed and opens no window"
run_ot "" --host "$HOST_STUB" --lane "$H/.eclaude" --repo o/r --cmd true KEN-44
assert_eq "$(observe "rc= launched= creates=") create=$(host_call) invalid=$(awk '$2 == "host-invalid" { print $NF }' <<<"$OUT")" "rc=1 launched=nolog creates=nolog create=nolog invalid=harness=" \
  "a hosted launch without a host-protocol harness is host-invalid before any create"
run_ot "" --host "$HOST_STUB" --harness claude --wake KEN-45
assert_eq "$(observe "rc=") create=$(host_call) wake=$(awk '$2 == "wake-invalid"' <<<"$OUT" | wc -l | tr -d '[:space:]')" "rc=1 create=nolog wake=1" \
  "a hosted wake is wake-invalid before any create"
run_ot "LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=/srv/lane;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-46
assert_eq "$(observe "rc= launched=") invalid=$(said "open-terminal: host-line-invalid item=KEN-46")" "rc=1 launched=nolog invalid=1" \
  "a create line missing its remote prefix is host-line-invalid and opens no window"
# lane-host create writes the hosted lane's marker on its host. A local one
# would bind the caller's own checkout, which would then pose as a lane.
HOSTCALLER="$TMP_ROOT/hostcaller"; mkdir -p "$HOSTCALLER"; git -C "$HOSTCALLER" init -q; git -C "$HOSTCALLER" config gc.auto 0; git -C "$HOSTCALLER" config maintenance.auto false
run_ot "cwd=$HOSTCALLER;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-47
assert_eq "$(observe "rc= launched=") local_marker=$([[ -e "$HOSTCALLER/.git/lane-mail" ]] && echo present || echo absent)" "rc=0 launched=1 local_marker=absent" \
  "a hosted launch writes no lane marker into the caller's own checkout"

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
