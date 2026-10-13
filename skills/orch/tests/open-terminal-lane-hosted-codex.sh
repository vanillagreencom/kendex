#!/usr/bin/env bash
# Tests for the hosted codex launch contract.
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


CODEX_RELAUNCH="$HARNESS_UP;LANE_HOST_STUB_SELECTION=resume;ORCH_LANE_ALIASES=eclaude=work;flags=-m gpt-6-astra -c model_reasoning_effort=high"
run_ot "$CODEX_RELAUNCH" --host "$HOST_STUB" --harness codex --lane "$H/.eclaude" --repo o/r --relaunch KEN-49
CODEX_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
CODEX_LEAD="codex '-c' 'check_for_update_on_startup=false' '-c' 'features.daemon_auto_start=false' '--dangerously-bypass-hook-trust' '-c' 'model_auto_compact_token_limit=9223372036854775807' '-c' 'model_auto_compact_token_limit_scope=body_after_prefix' '-c' 'model_post_turn_compact_threshold_percent=0' '-c' 'features.default_mode_request_user_input=false' '-m' 'gpt-6-astra' '-c' 'model_reasoning_effort=high'"
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
run_ot "$CODEX_RELAUNCH" --host "$HOST_STUB" --harness codex --lane "$H/.eclaude" --repo o/r --relaunch KEN-49
CODEX_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
assert_eq "rc=$RC selection=$(grep -cF "$CODEX_RESUME" <<<"$CODEX_REMOTE" || true) native=$(grep -cF ' resume --last' <<<"$CODEX_REMOTE" || true)" \
  "rc=0 selection=0 native=1" "control: the old codex resume --last form fails the resume-or-fresh assertion"
OPEN_TERMINAL="$CODEX_OT_SHIPPED"
# The expected arms still use the shipped text read above, not this copy.
CODEX_UNATTENDED_SCRIPTS="$(mutant_scripts ctl-codex-unattended/orch lib/lane-launch.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-codex-unattended/orch"
mutate_file "$CODEX_UNATTENDED_SCRIPTS/lib/lane-launch.sh" "LAUNCH_UNATTENDED_TEXT='This is" "LAUNCH_UNATTENDED_TEXT='changed unattended text. This is"
OPEN_TERMINAL="$CODEX_UNATTENDED_SCRIPTS/open-terminal"
run_ot "$CODEX_RELAUNCH" --host "$HOST_STUB" --harness codex --lane "$H/.eclaude" --repo o/r --relaunch KEN-49
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
run_ot "$HARNESS_UP;ORCH_LANE_ALIASES=eclaude=work;$CHOICE" --host "$HOST_STUB" --tracker github --harness claude --lane "$H/.eclaude" --repo o/r --relaunch 2708
assert_eq "$(observe "rc=0 creates=nolog launched=1") calls=$(host_call) remote=$(typed "$(hosted_resume issue-2708 github-2708 '/orch start github o/r#2708')")" \
  "rc=0 creates=nolog launched=1 calls=accounts;create,--item,issue-2708,--repo,o/r,--harness,claude,--account,eclaude,--relaunch;cat,--item,issue-2708,/srv/lane/.git;put,--item,issue-2708,/srv/clone/.git/lane-mail/issue-2708;cat,--item,issue-2708,/srv/clone/.git/lane-mail/issue-2708;put,--item,issue-2708,/srv/clone/.git/worktrees/lane/lane-refresh;put,--item,issue-2708,/srv/lane/tmp/lane-mail/issue-2708/context.json remote=1" \
  "a GitHub relaunch names the worktree id its mailbox is bound under, never the bare issue number, and asks the provider nothing beyond the judge's one accounts read on an account that measured"


lane_suite_end
