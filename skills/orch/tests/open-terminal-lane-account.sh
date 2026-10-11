#!/usr/bin/env bash
# Fresh and replacement --cmd launches through a real tmux pane. Inputs: open-terminal,
# lane-launch, lane-cap, workflow-state and the shared launcher fixtures.
# Each harness wrapper either preserves the picked account or overwrites it as
# dotfiles account wrappers do. The launched child records its environment
# before drawing the harness marker. Each child has a parent-process deadline.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/question-off.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
REAL_TMUX="$(command -v tmux)" || { echo 'lane-account: tmux-missing' >&2; exit 1; }

if [[ "${1:-}" == --case ]]; then
  ROOT="$2" OT="$3" MODE="$4" HARNESS="${5:-claude}"
  case "$HARNESS" in
    claude) VAR=CLAUDE_CONFIG_DIR; CHOICE='--model opus --effort high'; SCREEN='? for shortcuts' ;;
    codex) VAR=CODEX_HOME; CHOICE='--model gpt-6-astra -c model_reasoning_effort=high'; SCREEN='› ' ;;
    copilot) VAR=COPILOT_HOME; CHOICE='--model claude-opus-5.5 --reasoning-effort high'; SCREEN='› ' ;;
  esac
  ACCOUNT="n$HARNESS"
  [[ "$HARNESS" != claude ]] || ACCOUNT=neutralclaude
  mkdir -p "$ROOT/bin" "$ROOT/home/.$ACCOUNT" "$ROOT/home/.e$HARNESS" "$ROOT/home/.$HARNESS" "$ROOT/real-bin"
  ot_stub_bin "$ROOT/bin"
  printf '#!%s\ncase "${1:-}" in check) exit 0 ;; list) echo "[]" ;; pick) echo %q ;; esac\n' \
    "$BASH" "$(jq -cn --arg dir "$ROOT/home/.$ACCOUNT" '{config_dir:$dir}')" > "$ROOT/bin/lanes"
  chmod +x "$ROOT/bin/lanes"
  printf '#!%s\nif [[ "${1:-}" == kill-window && -f %q ]]; then exit 1; fi\nexec %q -S %q "$@"\n' \
    "$BASH" "$ROOT/close-fails" "$REAL_TMUX" "$ROOT/s" > "$ROOT/real-bin/tmux"
  chmod +x "$ROOT/real-bin/tmux"
  tm() { env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" SHELL="$BASH" "$REAL_TMUX" -S "$ROOT/s" "$@"; }
  trap 'tm kill-server 2>/dev/null || true' EXIT
  trap 'exit 143' TERM
  tm -f /dev/null new-session -d -s fixture -x 200 -y 50
  tm set-option -g default-shell "$BASH"
  tm set-option -g default-command "$BASH --noprofile --norc -i"
  printf '#!%s\nprintf "%%s" "${%s:-}" > %q\nprintf "%%s\\n" %q\nexec sleep 30\n' \
    "$BASH" "$VAR" "$ROOT/account" "$SCREEN" > "$ROOT/bin/$HARNESS-real"
  chmod +x "$ROOT/bin/$HARNESS-real"
  {
    printf '#!%s\n' "$BASH"
    printf '[[ ! -f %q ]] || export %s=%q\n' "$ROOT/wrong-account" "$VAR" "$ROOT/home/.$HARNESS"
    printf 'exec %q "$@"\n' "$ROOT/bin/$HARNESS-real"
  } > "$ROOT/bin/$HARNESS"
  chmod +x "$ROOT/bin/$HARNESS"
  if [[ "$HARNESS" == codex ]]; then
    printf '[projects."%s"]\ntrust_level = "trusted"\n' "$ROOT/worktree-KEN-1" > "$ROOT/home/.ncodex/config.toml"
  elif [[ "$HARNESS" == copilot ]]; then
    mkdir -p "$ROOT/home/.ncopilot/hooks"
    for hook in lane-mail-check lane-mail-start lane-mail-compact; do
      printf '{}\n' > "$ROOT/home/.ncopilot/hooks/$hook.json"
      printf '#!%s\nexit 0\n' "$BASH" > "$ROOT/home/.ncopilot/hooks/$hook.sh"
    done
    printf '#!%s\n[[ "${1:-}" == hooks-off ]] || exit 1\nprintf '\''{"switched_off_by":null}\\n'\''\n' "$BASH" > "$ROOT/bin/kendex"
    chmod +x "$ROOT/bin/kendex"
  fi
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$ROOT/state" "$PWD"
  launch() { # LOG LANE ITEM [FLAGS]
    local log="$1" lane="$2" item="$3"
    shift 3
    local harness_args=(--harness "$HARNESS")
    if [[ "$MODE" == auto-* ]]; then harness_args=(); lane="auto:$HARNESS"; fi
    RC=0
    env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" SHELL="$BASH" ORCH_TMUX_SESSION=fixture \
      LINEAR_TEAM= ORCH_LANE_HOST=local WORKTREE_CLI="$ROOT/bin/worktree" LANES_CLI="$ROOT/bin/lanes" \
      OT_WT_LOG="$ROOT/worktree.log" OT_WT_FIXED="$ROOT/worktree-$item" ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SETTLE_MS=1 \
      ORCH_OVERSEER_LANES=1 OVERSEE_WATCH_STATE_DIR="$ROOT/claims" \
      "$OT" --tmux --state-dir "$ROOT/state" ${harness_args[@]+"${harness_args[@]}"} --lane "$lane" \
      --cmd "$HARNESS $CHOICE $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" "$@" "$item" > "$log" 2>&1 || RC=$?
  }
  [[ "$MODE" != wrong && "$MODE" != auto-wrong ]] || touch "$ROOT/wrong-account"
  launch "$ROOT/launch.log" "$ROOT/home/.$ACCOUNT" KEN-1
  if [[ "$MODE" == relaunch || "$MODE" == close-fails ]]; then
    [[ "$RC" -eq 0 ]] || exit 72
    "$SCRIPTS_DIR/workflow-state" --state-dir "$ROOT/state" get oversee \
      '[.lanes[] | select(.item == "KEN-1")] | first' > "$ROOT/prior"
    mv -- "$ROOT/launch.log" "$ROOT/first-launch.log"
    rm -- "$ROOT/account"
    touch "$ROOT/wrong-account"
    [[ "$MODE" != close-fails ]] || touch "$ROOT/close-fails"
    launch "$ROOT/launch.log" "$ROOT/home/.eclaude" KEN-1 --relaunch
  fi
  # Baseline controls return before the child starts. Its account file is the
  # acknowledgement that this row reached the real exec path.
  for i in {1..100}; do [[ ! -f "$ROOT/account" ]] || break; sleep 0.02; done
  [[ -f "$ROOT/account" ]] || exit 71
  account="$(cat "$ROOT/account")"
  panes="$(tm list-panes -a -F '#{window_name}')"
  present=false
  ! grep -qxF KEN-1 <<<"$panes" || present=true
  record="$("$SCRIPTS_DIR/workflow-state" --state-dir "$ROOT/state" get oversee '[.lanes[]? | select(.item == "KEN-1")] | first // null')"
  extra='{}'
  if [[ -f "$ROOT/prior" ]]; then
    retained="$(jq -cn --slurpfile prior "$ROOT/prior" --argjson record "$record" \
      '{prior_account: ($record.account == $prior[0].account), prior_harness: ($record.harness == $prior[0].harness),
        mail_root: ($record.mail_root == $prior[0].mail_root), record_unchanged: ($record == $prior[0])}')"
    refused_rc="$RC"
    rm -- "$ROOT/wrong-account"
    launch "$ROOT/next-launch.log" "$ROOT/home/.neutralclaude" KEN-2
    next_record="$("$SCRIPTS_DIR/workflow-state" --state-dir "$ROOT/state" get oversee \
      '[.lanes[]? | select(.item == "KEN-2") | .status] | first // "none"')"
    panes="$(tm list-panes -a -F '#{window_name}')"
    next_present=false
    ! grep -qxF KEN-2 <<<"$panes" || next_present=true
    extra="$(jq -cn --argjson retained "$retained" --argjson next_rc "$RC" --arg next_record "$next_record" \
      --argjson next_pane "$next_present" '$retained + {next_rc:$next_rc,next_record:$next_record,next_pane:$next_pane}')"
    RC="$refused_rc"
  fi
  jq -cn --argjson rc "$RC" --arg account "${account##*/}" --argjson pane "$present" --argjson record "$record" \
    --argjson extra "$extra" '{rc:$rc,account:$account,pane:$pane,record: ($record.status // "none")} + $extra' > "$ROOT/result"
  exit
fi

TMP_ROOT="$(mktemp -d)" || { echo 'lane-account: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
CONTROL="$(mutant_scripts custom-unchecked lib/lane-launch.sh)"
orch_fixture_shared_libs "${CONTROL%/scripts}"
mutate_file "$CONTROL/lib/lane-launch.sh" "printf 'custom\n'; return;" "printf 'unchecked\n'; return;"
STOP_CONTROL="$(mutant_scripts relaunch-stop open-terminal)"
orch_fixture_shared_libs "${STOP_CONTROL%/scripts}"
mutate_file "$STOP_CONTROL/open-terminal" \
  '[[ "$RELAUNCH" != true || "$FLEET" != true || -z "$UNTAKEN_PANE" ]] || launch_stop || true' \
  '[[ "$HOST_RELAUNCH" != true || "$FLEET" != true || -z "$UNTAKEN_PANE" ]] || launch_stop || true'

run_case() { # NAME SCRIPT MODE EXPECT [HARNESS]
  local name="$1" script="$2" mode="$3" want="$4" harness="${5:-claude}" rc=0 actual=missing
  RUN="$TMP_ROOT/$name"
  mkdir -p "$RUN"
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$TMP_ROOT" timeout 20 "$BASH" "$TEST_DIR/open-terminal-lane-account.sh" \
    --case "$RUN" "$script" "$mode" "$harness" > "$RUN/log" 2>&1 || rc=$?
  for log in first-launch launch next-launch; do
    [[ ! -f "$RUN/$log.log" ]] || cat "$RUN/$log.log" >> "$RUN/log"
  done
  [[ ! -f "$RUN/result" ]] || actual="$(cat "$RUN/result")"
  assert_eq "child=$rc $actual" "child=0 $want" "$name: real account, pane, record and fleet admission" "$RUN/log"
}

run_case preserved "$SCRIPTS_DIR/open-terminal" preserved '{"rc":0,"account":".neutralclaude","pane":true,"record":"running"}'
while IFS='|' read -r harness account; do
  run_case "auto-$harness-preserved" "$SCRIPTS_DIR/open-terminal" auto-preserved \
    "{\"rc\":0,\"account\":\"$account\",\"pane\":true,\"record\":\"running\"}" "$harness"
done <<'ROWS'
claude|.neutralclaude
codex|.ncodex
copilot|.ncopilot
ROWS
if ( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_process_env_readable ); then
  while IFS='|' read -r name script want; do
    run_case "$name" "$script" wrong "$want"
  done <<ROWS
wrong-account|$SCRIPTS_DIR/open-terminal|{"rc":1,"account":".claude","pane":false,"record":"none"}
control-unchecked|$CONTROL/open-terminal|{"rc":0,"account":".claude","pane":true,"record":"running"}
ROWS
  RAW_CONTROL="$(mutant_scripts raw-harness open-terminal)"
  orch_fixture_shared_libs "${RAW_CONTROL%/scripts}"
  mutate_file "$RAW_CONTROL/open-terminal" \
    'launch_form="$(lane_launch_form "$cmd" "$LAUNCH_HARNESS" "$launch_home" "$CMD_TEMPLATE")"' \
    'launch_form="$(lane_launch_form "$cmd" "$HARNESS" "$launch_home" "$CMD_TEMPLATE")"'
  while IFS='|' read -r harness account; do
    run_case "auto-$harness-wrong" "$SCRIPTS_DIR/open-terminal" auto-wrong \
      "{\"rc\":1,\"account\":\"$account\",\"pane\":false,\"record\":\"none\"}" "$harness"
    run_case "control-auto-$harness-unchecked" "$RAW_CONTROL/open-terminal" auto-wrong \
      "{\"rc\":0,\"account\":\"$account\",\"pane\":true,\"record\":\"running\"}" "$harness"
  done <<'ROWS'
claude|.claude
codex|.codex
copilot|.copilot
ROWS
  while IFS='|' read -r name script mode want; do
    run_case "$name" "$script" "$mode" "$want"
  done <<ROWS
relaunch-wrong|$SCRIPTS_DIR/open-terminal|relaunch|{"rc":1,"account":".claude","pane":false,"record":"stopped","prior_account":true,"prior_harness":true,"mail_root":true,"record_unchanged":false,"next_rc":0,"next_record":"running","next_pane":true}
relaunch-close-fails|$SCRIPTS_DIR/open-terminal|close-fails|{"rc":1,"account":".claude","pane":true,"record":"running","prior_account":true,"prior_harness":true,"mail_root":true,"record_unchanged":true,"next_rc":1,"next_record":"none","next_pane":false}
control-relaunch-stop|$STOP_CONTROL/open-terminal|relaunch|{"rc":1,"account":".claude","pane":false,"record":"running","prior_account":true,"prior_harness":true,"mail_root":true,"record_unchanged":true,"next_rc":1,"next_record":"none","next_pane":false}
ROWS
else
  printf '  skip wrong-account observations: no readable process environment\n'
fi
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
