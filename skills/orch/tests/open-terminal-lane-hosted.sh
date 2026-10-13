#!/usr/bin/env bash
# Tests for the hosted launch contract.
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


# Replay the actual provider command with a controlled cd result. The
# directory guard must cover both exec and the resume-or-fresh command group.
CD_HARNESS="$TMP_ROOT/cd-harness"
cat > "$CD_HARNESS" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'started\n' >> "$CD_HARNESS_LOG"
STUB
chmod +x "$CD_HARNESS"
cd_guard_result() { # CD_STATUS
  local line rc=0 attempted=no started=no
  line="$(grep -m1 '^exec bash -lc ' "$RUN/tmux.log")" || return 1
  : > "$RUN/cd-attempt"
  : > "$RUN/harness-started"
  env -i PATH="$PATH" HOME="$TMP_ROOT" CD_GUARD_STATUS="$1" \
    CD_ATTEMPT_LOG="$RUN/cd-attempt" CD_HARNESS_LOG="$RUN/harness-started" \
    "$BASH" -c '
      cd() { printf "attempted\n" >> "$CD_ATTEMPT_LOG"; return "$CD_GUARD_STATUS"; }
      claude() { printf "started\n" >> "$CD_HARNESS_LOG"; }
      export -f cd claude
      eval "$1"
    ' cd-guard "$line" > "$RUN/cd-replay.out" 2> "$RUN/cd-replay.err" || rc=$?
  [[ ! -s "$RUN/cd-attempt" ]] || attempted=attempted
  [[ ! -s "$RUN/harness-started" ]] || started=started
  printf 'rc=%s cd=%s harness=%s\n' "$rc" "$attempted" "$started"
}
assert_failed_cd() { # OBSERVATION
  assert_eq "$1" 'rc=1 cd=attempted harness=no' \
    'a failed hosted cd starts no harness' "$RUN/cd-replay.err"
}
run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_ALIASES=eclaude=work;cmd=$CD_HARNESS --model opus --effort high" --harness claude --lane work --repo o/r KEN-40
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") calls=$(host_call) ssh=$(typed "clear; ssh 'lane.example'") remote=$(typed "exec bash -lc 'cd /srv/lane && export KENDEX_LANE_ORIGIN=") env=$(typed CLAUDE_CONFIG_DIR=) opened=$(said "open-terminal: tmux-opened item=KEN-40 host=$HOST_STUB path=/srv/lane")" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude calls=accounts;create,--item,KEN-40,--repo,o/r,--harness,claude,--account,eclaude;cat,--item,KEN-40,/srv/lane/.git;put,--item,KEN-40,/srv/clone/.git/lane-mail/ken-40;cat,--item,KEN-40,/srv/clone/.git/lane-mail/ken-40;put,--item,KEN-40,/srv/clone/.git/worktrees/lane/lane-refresh;put,--item,KEN-40,/srv/lane/tmp/lane-mail/KEN-40/context.json ssh=1 remote=1 env=0 opened=1" \
  "a hosted launch creates through lane-host, types ssh then the remote line, and renders no lane env prefix"
assert_eq "$(ot_hosted_relaunch_text "$RUN/tmux.log")" \
  "exec bash -lc 'cd /srv/lane && export KENDEX_LANE_ORIGIN='/srv/lane' && $SCRUB_UNSET export KENDEX_USER_EMAIL='' && $CD_HARNESS --model opus --effort high $QUESTION_OFF_ALL'" \
  "the remote shell exports the host's lane origin"
assert_eq "$(cd_guard_result 0)" 'rc=0 cd=attempted harness=started' \
  'the hosted command starts its harness after a successful cd'
assert_failed_cd "$(cd_guard_result 1)"

# The refresh record belongs to the hosted worktree's git directory, not its
# root. Without --lane-refresh the drift hook must read an empty record.
assert_eq "refresh=$(hosted_refresh)" "refresh=[]" "a hosted launch without --lane-refresh empties the refresh record"
CD_GUARD_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-hosted-cd/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-hosted-cd/orch"
mutate_file "$OPEN_TERMINAL" 'run="export KENDEX_LANE_ORIGIN=$(lane_single_quote "$remote_path") && $run"' \
  'run="export KENDEX_LANE_ORIGIN=$(lane_single_quote "$remote_path"); $run"'
run_ot "ORCH_LANE_HOST=$HOST_STUB;cmd=$CD_HARNESS --model opus --effort high" --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
CD_CONTROL_GOT="$(cd_guard_result 1)" || exit 1
assert_eq "$CD_CONTROL_GOT" 'rc=0 cd=attempted harness=started' \
  'control: the semicolon starts the hosted harness after a failed cd'
CD_CONTROL_RC=0
(
  FAIL=0
  assert_failed_cd "$CD_CONTROL_GOT"
  [[ "$FAIL" -eq 0 ]]
) > "$RUN/cd-assertion.out" 2>&1 || CD_CONTROL_RC=$?
assert_eq "$CD_CONTROL_RC" 1 \
  'control: the failed-cd assertion rejects the restored semicolon' "$RUN/cd-assertion.out"
OPEN_TERMINAL="$CD_GUARD_SHIPPED"

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
# Read the actual child environment on the provider's fresh and relaunch
# routes. A status-1 continuation starts a second, fresh Claude process.
RM_PROBE_BIN="$TMP_ROOT/rm-probe-bin"
# The unattended words every brief and continuation line closes on, the text
# read from lib/lane-launch.sh, which renders and judges them.
[[ -n "$UNATTENDED_TEXT" ]] || { echo "lib/lane-launch.sh named no unattended text" >&2; exit 1; }
mkdir -p "$RM_PROBE_BIN"
cat > "$RM_PROBE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
route=fresh
for arg in "$@"; do [[ "$arg" != --continue ]] || route=resume; done
printf '%s|%s|%s\n' "$route" "${CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT-unset}" \
  "${CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT-unset}" >> "$RM_PROBE_LOG"
[[ "$route" != resume ]] || exit "$RM_RESUME_STATUS"
STUB
chmod +x "$RM_PROBE_BIN/claude"
ln -s "$RM_PROBE_BIN/claude" "$RM_PROBE_BIN/codex"
hosted_rm_env() { # HARNESS FLAGS ROUTE RESUME_STATUS; sets HOSTED_RM_ENV
  local harness="$1" flags="$2" route="$3" resume_status="$4" args=() line launch="flags=$2"
  [[ "$route" != relaunch ]] || args+=(--relaunch)
  [[ "$route" != compound ]] || launch="cmd=true && $harness $flags '/orch start {item} $UNATTENDED_TEXT'"
  run_ot "$HARNESS_UP;$launch" --host "$HOST_STUB" --harness "$harness" \
    --lane "$H/.eclaude" --repo o/r ${args[@]+"${args[@]}"} KEN-41
  [[ "$RC" == 0 ]] || { HOSTED_RM_ENV=launch-failed; printf '%s\n' "$OUT" >&2; return; }
  line="$(grep -m1 '^exec bash -lc ' "$RUN/tmux.log")" || { HOSTED_RM_ENV=unrendered; return; }
  # Let the shell decode the provider's quoted argument. Execute that same
  # argument in its login shell with PATH set after the profile, as above.
  eval "set -- ${line#exec }" || { HOSTED_RM_ENV=undecodable; return; }
  : > "$RUN/rm-env"
  env -i PATH="$PATH" HOME="$TMP_ROOT" RM_PROBE_BIN="$RM_PROBE_BIN" \
    RM_PROBE_LOG="$RUN/rm-env" RM_RESUME_STATUS="$resume_status" \
    "$BASH" -lc 'PATH="$RM_PROBE_BIN:$PATH"; cd() { return 0; }; eval "$1"' \
    rm-probe "$3" > "$RUN/rm-replay.out" 2> "$RUN/rm-replay.err" || true
  HOSTED_RM_ENV="$(paste -sd';' "$RUN/rm-env")"
}
printf '%s\n' \
  'claude|--model opus --effort high --dangerously-skip-permissions|fresh|0|fresh|1|1' \
  'claude|--model opus --effort high --dangerously-skip-permissions|compound|0|fresh|1|1' \
  'claude|--model opus --effort high --permission-mode bypassPermissions|relaunch|0|resume|1|1' \
  'claude|--model opus --effort high --dangerously-skip-permissions|relaunch|1|resume|1|1;fresh|1|1' \
  'claude|--model opus --effort high --permission-mode dontAsk|fresh|0|fresh|unset|unset' \
  'claude|--model opus --effort high --permission-mode dontAsk|compound|0|fresh|unset|unset' \
  'claude|--model opus --effort high --permission-mode dontAsk|relaunch|1|resume|unset|unset;fresh|unset|unset' \
  'codex|-m gpt-6-astra -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox|fresh|0|fresh|unset|unset' \
  > "$TMP_ROOT/hosted-rm-rows"
while IFS='|' read -r harness flags route resume_status expected; do
  hosted_rm_env "$harness" "$flags" "$route" "$resume_status"
  assert_eq "$HOSTED_RM_ENV" "$expected" \
    "the hosted $harness $route child receives removal switches only for Claude bypass: $flags" "$RUN/rm-replay.err"
done < "$TMP_ROOT/hosted-rm-rows"
RM_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts hosted-rm-env-removed/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/hosted-rm-env-removed/orch"
rm -- "${OPEN_TERMINAL%/*}/lib/lane-launch.sh"
cp -- "$SCRIPTS_DIR/lib/lane-launch.sh" "${OPEN_TERMINAL%/*}/lib/lane-launch.sh"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-launch.sh" \
  "printf 'CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1 CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1'" \
  ": 'CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1 CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1'"
SAVED_FAIL="$FAIL"
FAIL=0
hosted_rm_env claude '--model opus --effort high --dangerously-skip-permissions' relaunch 1
assert_eq "$HOSTED_RM_ENV" 'resume|1|1;fresh|1|1' \
  'control: dropping the hosted environment words loses the switches in both processes' > "$TMP_ROOT/hosted-rm-control.out"
RM_CONTROL="$FAIL"
FAIL="$SAVED_FAIL"
assert_eq "$HOSTED_RM_ENV" 'resume|unset|unset;fresh|unset|unset' \
  'control: the hosted mutant reaches both Claude processes with neither switch'
assert_eq "$RM_CONTROL" 1 'control: the hosted resume and fallback children detect the missing environment words'
OPEN_TERMINAL="$RM_OT_SHIPPED"

# The same replay under a parent environment holding every name
# LANE_LAUNCH_SCRUB lists: each hosted child, a relaunch's fallback included,
# holds none of them.
SCRUB_NAMES="$(bash -c 'source "$1/lib/lane-launch.sh" && printf "%s " "${LANE_LAUNCH_SCRUB[@]}"' _ "$SCRIPTS_DIR")" || exit 1
ID_PROBE_BIN="$TMP_ROOT/id-probe-bin"
mkdir -p "$ID_PROBE_BIN"
cat > "$ID_PROBE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
route=fresh held=""
for arg in "$@"; do [[ "$arg" != --continue ]] || route=resume; done
for name in $SCRUB_NAMES; do [[ -z "${!name+set}" ]] || held+="$name,"; done
printf '%s|%s\n' "$route" "${held:--}" >> "$ID_PROBE_LOG"
[[ "$route" != resume ]] || exit 1
STUB
chmod +x "$ID_PROBE_BIN/claude"
ln -s "$ID_PROBE_BIN/claude" "$ID_PROBE_BIN/codex"
hosted_identity() { # HARNESS FLAGS ROUTE; sets HOSTED_IDENTITY
  local args=() line parent=() name
  [[ "$3" != relaunch ]] || args+=(--relaunch)
  run_ot "$HARNESS_UP;flags=$2" --host "$HOST_STUB" --harness "$1" \
    --lane "$H/.eclaude" --repo o/r ${args[@]+"${args[@]}"} KEN-41
  [[ "$RC" == 0 ]] || { HOSTED_IDENTITY=launch-failed; printf '%s\n' "$OUT" >&2; return; }
  line="$(grep -m1 '^exec bash -lc ' "$RUN/tmux.log")" || { HOSTED_IDENTITY=unrendered; return; }
  eval "set -- ${line#exec }" || { HOSTED_IDENTITY=undecodable; return; }
  for name in $SCRUB_NAMES; do parent+=("$name=parent-$name"); done
  : > "$RUN/id-env"
  env -i PATH="$PATH" HOME="$TMP_ROOT" "${parent[@]}" SCRUB_NAMES="$SCRUB_NAMES" \
    ID_PROBE_BIN="$ID_PROBE_BIN" ID_PROBE_LOG="$RUN/id-env" \
    "$BASH" -lc 'PATH="$ID_PROBE_BIN:$PATH"; cd() { return 0; }; eval "$1"' \
    id-probe "$3" > "$RUN/id-replay.out" 2> "$RUN/id-replay.err" || true
  HOSTED_IDENTITY="$(paste -sd';' "$RUN/id-env")"
}
printf '%s\n' \
  'claude|--model opus --effort high --dangerously-skip-permissions|fresh|fresh|-' \
  'claude|--model opus --effort high --permission-mode dontAsk|fresh|fresh|-' \
  'claude|--model opus --effort high --permission-mode dontAsk|relaunch|resume|-;fresh|-' \
  'codex|-m gpt-6-astra -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox|fresh|fresh|-' \
  > "$TMP_ROOT/hosted-id-rows"
while IFS='|' read -r harness flags route expected; do
  hosted_identity "$harness" "$flags" "$route"
  assert_eq "$HOSTED_IDENTITY" "$expected" \
    "the hosted $harness $route child holds none of the launching session's identity: $flags" "$RUN/id-replay.err"
done < "$TMP_ROOT/hosted-id-rows"
ID_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts hosted-scrub-removed/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/hosted-scrub-removed/orch"
mutate_file "$OPEN_TERMINAL" 'run="unset ${LANE_LAUNCH_SCRUB[*]} && $run"' 'run="$run"'
hosted_identity claude '--model opus --effort high --permission-mode dontAsk' fresh
assert_eq "$HOSTED_IDENTITY" "fresh|${SCRUB_NAMES// /,}" \
  'control: without the hosted unset the child holds every identity name'
OPEN_TERMINAL="$ID_OT_SHIPPED"
# The flags a hosted claude command leads with, as the remote command quotes them.
HOSTED_LINE="$(hosted_line KEN-41)"
run_ot "$HARNESS_UP;$CHOICE" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --relaunch KEN-41
assert_eq "$(observe "rc=0 creates=nolog launched=1") calls=$(host_call) remote=$(typed "$(hosted_resume KEN-41 KEN-41 '/orch start KEN-41')")" \
  "rc=0 creates=nolog launched=1 calls=accounts;create,--item,KEN-41,--repo,o/r,--harness,claude,--account,claude,--relaunch;cat,--item,KEN-41,/srv/lane/.git;put,--item,KEN-41,/srv/clone/.git/lane-mail/ken-41;cat,--item,KEN-41,/srv/clone/.git/lane-mail/ken-41;put,--item,KEN-41,/srv/clone/.git/worktrees/lane/lane-refresh;put,--item,KEN-41,/srv/lane/tmp/lane-mail/KEN-41/context.json remote=1" \
  "a hosted claude relaunch passes the picked account and --relaunch, and continues natively with the continuation line, the start brief behind it"
assert_eq "$(cd_guard_result 0)" 'rc=0 cd=attempted harness=started' \
  'the hosted resume group starts its harness after a successful cd'
assert_failed_cd "$(cd_guard_result 1)"

lane_suite_end
