#!/usr/bin/env bash
# Lane preference routing, through the real launcher and fleet record writer.
# lanes owns room; this consumer fixture answers its documented exit codes and
# logs the harness and model it was asked to judge. No live account is read.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-stubs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$TEST_DIR/../scripts" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-preference: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-preference: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-preference: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts" "$TMP_ROOT/home" "$TMP_ROOT/pi/packages/@vanillagreen/pi-hooks/extensions" "$TMP_ROOT/codex"
cp -R "$SCRIPTS_DIR/." "$REPO/scripts/"
orch_fixture_shared_libs "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
printf '{"compaction":{"enabled":false}}\n' > "$TMP_ROOT/pi/settings.json"
printf '{"version":"0.12.0","pi":{"extensions":["./extensions/lane-mail-wake.ts"]}}\n' > "$TMP_ROOT/pi/packages/@vanillagreen/pi-hooks/package.json"
printf 'export const reading = {context_window: 1};\n' > "$TMP_ROOT/pi/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
BIN="$TMP_ROOT/bin"
ot_stub_bin "$BIN"
cat > "$BIN/lanes" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == pick ]] || exit 0
h="" m="" prev=""
for a in "$@"; do
  case "$prev" in --harness) h="$a" ;; --model) m="$a" ;; esac
  prev="$a"
done
printf '%s:%s\n' "$h" "$m" >> "$PICK_LOG"
case "$WALL:$h" in all:*|pi:pi) exit 3 ;; error:*) exit 6 ;; esac
case "$h" in claude) d="$HOME/.claude" ;; pi) d="$PI_CODING_AGENT_DIR" ;; codex) d="$CODEX_TEST_HOME" ;; *) exit 0 ;; esac
jq -cn --arg d "$d" '{config_dir: $d}'
STUB
chmod +x "$BIN/lanes"
source "$SCRIPTS_DIR/lib/lane-launch.sh"
printf '%s\n' "$LAUNCH_UNATTENDED_TEXT" > "$TMP_ROOT/brief"
PREF='pi:github-copilot/gpt-6.1-sol:high,codex:gpt-6.1-sol:high'
assert_eq "$(cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" scripts/orch-env ORCH_LANE_PREFERENCE '')" '' 'orch-env leaves the lane preference unset'
printf '[env]\nORCH_LANE_PREFERENCE = "%s"\n' "$PREF" > "$REPO/kendex.settings.toml"
assert_eq "$(cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" scripts/orch-env ORCH_LANE_PREFERENCE '')" "$PREF" 'orch-env reads the program preference from settings'
OT="$REPO/scripts/open-terminal"

# Each observation uses fresh state, an explicit child environment and a GUI
# stub. A successful GUI dispatch is asynchronous, so wait for its capture,
# bounded by wall time, rather than reading a log before the stub writes it.
observe() { # PREFERENCE WALL MODE TEXT
  local preference="$1" wall="$2" mode="$3" text="$4" caller="${5:-pi}" rc=0 key=none record='none|none|none' cmd="" written=no end args=()
  RUN="$TMP_ROOT/run"
  rm -rf -- "${RUN:?}"
  mkdir -p "$RUN"
  # The fleet state records the checkout every launch runs from as its
  # overseer's directory, which the overseer binding reads.
  ot_fleet_state "$REPO/scripts/workflow-state" "$RUN/state" "$REPO" || exit 1
  : > "$RUN/picks"
  if [[ "$mode" == cmd ]]; then args=(--cmd "$text" --brief-file "$TMP_ROOT/brief")
  elif [[ -n "$text" ]]; then args=(--launch-flags "$text"); fi
  (cd -- "$REPO" && env -i PATH="$BIN:$PATH" HOME="$TMP_ROOT/home" ORCH_LANE_HOST=local \
    ORCH_LANE_PREFERENCE="$preference" ORCH_OVERSEER_LANES=3 ORCH_TMUX_SESSION= \
    OVERSEE_WATCH_STATE_DIR="$RUN/claims" WORKTREE_CLI="$BIN/worktree" LANES_CLI="$BIN/lanes" \
    PI_CODING_AGENT_DIR="$TMP_ROOT/pi" CODEX_TEST_HOME="$TMP_ROOT/codex" \
    WALL="$wall" PICK_LOG="$RUN/picks" OT_WT_LOG="$RUN/worktrees" OT_CAPTURE="$RUN/command" TERMINAL=ghostty \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$OT" --ghostty --state-dir "$RUN/state" --harness "$caller" --lane auto \
    ${args[@]+"${args[@]}"} CC-1 > "$RUN/out" 2> "$RUN/err") || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    end=$((SECONDS + 10))
    while [[ ! -s "$RUN/command" ]] && (( SECONDS < end )); do sleep 0.01; done
    [[ -s "$RUN/command" ]] || { echo 'open-terminal-preference: capture=missing' >&2; exit 1; }
    cmd="$(cat -- "$RUN/command")"
    if { launch_choice_words_present 'pi' "$cmd" &&
         launch_choice_words_present '--model github-copilot/gpt-6.1-sol --thinking high' "$cmd"; } ||
       { launch_choice_words_present 'codex' "$cmd" &&
         launch_choice_words_present '-m gpt-6.1-sol -c model_reasoning_effort=high' "$cmd"; }; then
      written=yes
    fi
  else
    key="$(sed -n '/^open-terminal: entry-permission-untransferable /d; s/^open-terminal: \([^ ]*\).*/\1/p' "$RUN/err")"; key="${key%%$'\n'*}"
  fi
  if [[ -f "$RUN/state/workflow-state-oversee.json" ]]; then
    record="$("$REPO/scripts/workflow-state" --state-dir "$RUN/state" get oversee \
      '.lanes // [] | .[] | [.harness, .model, (.preference_entry // "none")] | join("|")' | tr -d '"')"
    [[ -n "$record" ]] || record='none|none|none'
  fi
  if [[ "$mode" == cmd && "$record" == codex\|*\|codex:* ]]; then
    launch_choice_words_present '-c features.default_mode_request_user_input=false' "$cmd" &&
      launch_choice_words_present '-c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0' "$cmd" &&
      ! launch_choice_words_present '--exclude-tools question' "$cmd" || written=no
  fi
  OBS="$rc|$key|$record|$written|$(paste -sd, - < "$RUN/picks")"
  [[ -s "$RUN/picks" ]] || OBS+=none
}

# Input shape is one table. Expected protocol values are independent of the
# launcher, including what its emitted command actually passes to the harness.
while IFS='|' read -r label pref wall mode text want; do
  [[ "$pref" != default ]] || pref="$PREF"
  [[ "$text" != template ]] || text='pi --exclude-tools question {brief}'
  observe "$pref" "$wall" "$mode" "$text"
  assert_eq "$OBS" "$want" "$label" "$RUN/err"
done <<'ROWS'
first entry with room|default|none|flags||0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:github-copilot/gpt-6.1-sol
walled Pi pool cannot grant Codex permissions|default|pi|flags||1|lane-unavailable|none|none|none|no|pi:github-copilot/gpt-6.1-sol
model-free command gets the preference|default|none|cmd|template|0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:github-copilot/gpt-6.1-sol
walled Pi command retains its permission route|default|pi|cmd|template|1|lane-unavailable|none|none|none|no|pi:github-copilot/gpt-6.1-sol
preference replaces an effort-only flag|default|none|flags|--thinking low|0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:github-copilot/gpt-6.1-sol
preference preserves brief quoting refusal|default|none|cmd|pi --exclude-tools question '{brief}'|1|brief-quoted|none|none|none|no|pi:github-copilot/gpt-6.1-sol
invalid later entry refuses before a pick|pi:github-copilot/gpt-6.1-sol:high,pi:bare:high|none|flags||1|invalid-preference|none|none|none|no|none
full walk refuses|default|all|flags||1|lane-unavailable|none|none|none|no|pi:github-copilot/gpt-6.1-sol
judge failure does not try another entry|default|error|flags||1|lane-resolution-failed|none|none|none|no|pi:github-copilot/gpt-6.1-sol
arbitrary command is not replaced|default|none|cmd|true {brief}|1|preference-command-invalid|none|none|none|no|none
unset preserves the missing-model gate||none|flags||1|launch-model-missing|none|none|none|no|none
explicit flags bypass even an invalid preference|invalid|none|flags|--model github-copilot/gpt-6.1-sol --thinking high|0|none|pi|github-copilot/gpt-6.1-sol|none|yes|pi:github-copilot/gpt-6.1-sol
explicit command bypasses even an invalid preference|invalid|none|cmd|pi --model github-copilot/gpt-6.1-sol --thinking high --exclude-tools question {brief}|0|none|pi|github-copilot/gpt-6.1-sol|none|yes|pi:github-copilot/gpt-6.1-sol
ROWS
# The refusal names the whole walk, not just the final model.
observe "$PREF" all flags ''
assert_file_contains "$RUN/err" "walk=$PREF" 'no-room refusal names the preference walk'

# Pi emits no permission word. A Codex entry is skipped before its picker,
# and the next Pi entry uses the caller's own permissions and brief.
for mode in flags cmd; do
  text=''; [[ "$mode" != cmd ]] || text='pi --exclude-tools question {brief}'
  observe 'codex:gpt-6.1-sol:high,pi:github-copilot/gpt-6.1-sol:high' none "$mode" "$text"
  assert_eq "$OBS" '0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:github-copilot/gpt-6.1-sol' 'Pi skips Codex and selects the next eligible entry'
  assert_file_contains "$RUN/err" 'open-terminal: entry-permission-untransferable entry=codex:gpt-6.1-sol:high source=pi target=codex' 'permission skip names entry and both harnesses'
  assert_file_not_contains "$RUN/command" '--dangerously-bypass-approvals-and-sandbox' 'Pi preference does not grant target bypass'
done
# The caller chooses permissions, not the model preference. Only an exact
# full-bypass posture reaches the cross-harness flag writer.
printf '%s\n' \
  'flags|--dangerously-skip-permissions|codex|gpt-6.1-sol|codex:gpt-6.1-sol:high' \
  'cmd|--dangerously-skip-permissions|codex|gpt-6.1-sol|codex:gpt-6.1-sol:high' \
  'flags||claude|fable|claude:fable:high' \
  'flags|--permission-mode dontAsk|claude|fable|claude:fable:high' \
  'flags|--dangerously-skip-permissions --permission-mode dontAsk|claude|fable|claude:fable:high' \
  > "$TMP_ROOT/permission-rows"
expected_source_bypass='--dangerously-skip-permissions'
while IFS='|' read -r mode flags want model entry; do
  text="$flags"; [[ "$mode" != cmd ]] || text="claude $flags {brief}"
  observe 'codex:gpt-6.1-sol:high,claude:fable:high' none "$mode" "$text" claude
  record="$("$REPO/scripts/workflow-state" --state-dir "$RUN/state" get oversee '.lanes[0] | [.harness,.model,.preference_entry] | join("|")' | tr -d '\"')"
  assert_eq "$record" "$want|$model|$entry" "$mode permission eligibility for [$flags]" "$RUN/err"
  if [[ "$want" == codex ]]; then
    if launch_choice_words_present '--dangerously-bypass-approvals-and-sandbox' "$(cat -- "$RUN/command")"; then pass 'cross-harness launch writes the authorized target bypass'
    else fail 'cross-harness launch lacks its authorized target bypass'; fi
    if launch_choice_words_present "$expected_source_bypass" "$(cat -- "$RUN/command")"; then fail 'source bypass was retained'; else pass 'source bypass is replaced'; fi
  else
    assert_file_contains "$RUN/err" 'open-terminal: entry-permission-untransferable entry=codex:gpt-6.1-sol:high source=claude target=codex' 'nontransferable caller posture skips Codex'
  fi
done < "$TMP_ROOT/permission-rows"

# One control for routing and one for each new refusal rule. Each mutation
# keeps the tested call or comparison, but removes its effect in a private copy.
for control in routing model settings grammar command permission; do
  mutant_file=open-terminal
  [[ "$control" != settings ]] || mutant_file=lib/overseer-launch.sh
  MUTANT="$(mutant_scripts "mutant-$control" "$mutant_file")/open-terminal"
  orch_fixture_shared_libs "$TMP_ROOT/mutant-$control"
  git -C "$TMP_ROOT/mutant-$control" init -q
  git -C "$TMP_ROOT/mutant-$control" config gc.auto 0
  git -C "$TMP_ROOT/mutant-$control" config maintenance.auto false
  OT="$MUTANT"
  case "$control" in
    routing)
      mutate_file "$OT" 'if [[ "$WAKE" != true && -n "${ORCH_LANE_PREFERENCE:-}"' 'if [[ "$WAKE" != true && -z "${ORCH_LANE_PREFERENCE:-}"'
      observe "$PREF" none flags ''
      assert_eq "$OBS" '1|launch-model-missing|none|none|none|no|none' 'control: the first-entry row turns red without routing' ;;
    model)
      mutate_file "$OT" 'preference_record="$(pick_auto_lane ' 'preference_record="$(LAUNCH_MODEL="" pick_auto_lane '
      observe "$PREF" none flags ''
      assert_eq "$OBS" '0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:' 'control: the first-entry row turns red when its pick loses the model' ;;
    settings)
      mutate_file "${OT%/*}/lib/overseer-launch.sh" 'launch_choice_lead_settings ${question[@]+"${question[@]}"}' 'true ${question[@]+"${question[@]}"}'
      observe 'codex:gpt-6.1-sol:high' none cmd 'claude --dangerously-skip-permissions {brief}' claude
      assert_eq "$OBS" '1|launch-question-tool-missing|none|none|none|no|codex:gpt-6.1-sol' 'control: the model-free fallback row turns red without harness settings' ;;
    grammar)
      mutate_file "$OT" 'ol_preference_entries "$ORCH_LANE_PREFERENCE" lane || {' 'ol_preference_entries "$ORCH_LANE_PREFERENCE" lane || true; false && {'
      observe 'pi:github-copilot/gpt-6.1-sol:high,pi:bare:high' none flags ''
      assert_eq "$OBS" '0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:github-copilot/gpt-6.1-sol' 'control: the invalid-entry row turns red without refusal' ;;
    command)
      mutate_file "$OT" '[[ "${LAUNCH_CHOICE_ARGV[0]}" == "$preference_harness" ]]' '[[ -n "${LAUNCH_CHOICE_ARGV[0]}" ]]'
      observe "$PREF" none cmd 'true --exclude-tools question {brief}'
      assert_eq "$OBS" '0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|pi:github-copilot/gpt-6.1-sol' 'control: the arbitrary-command row turns red without refusal' ;;
    permission)
      mutate_file "$OT" 'if ! ol_entry_permitted "$preference_entry"; then' 'if ! { ol_entry_permitted "$preference_entry" || true; }; then'
      observe 'codex:gpt-6.1-sol:high,pi:github-copilot/gpt-6.1-sol:high' none flags ''
      assert_eq "$OBS" '1|lane-resolution-failed|none|none|none|no|codex:gpt-6.1-sol' 'control: without permission eligibility the walk tries forbidden Codex instead of Pi' ;;
  esac
done
# The real claim writer is the producer that walls Fable between batch items.
# Its weekly window has room before one live claim's scaled burn, while the
# shared windows Opus spends still have room after it. No picker is stubbed.
make_lane "$TMP_ROOT/home" claude
mkdir -p "$TMP_ROOT/usage"
claude_usage 10 20 94 'Fable 5.1' > "$TMP_ROOT/usage/.claude.json"
make_fetcher "$TMP_ROOT/fetch"
WAIT_BIN="$TMP_ROOT/wait-bin"
mkdir -p "$WAIT_BIN"
# Advance the real cap wait without a timed sleep. The fixture models another
# fleet leaving this cap while a real live claim on the account remains.
cat > "$WAIT_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == 5 ]] || exit 0
"$TEST_SCRIPTS/workflow-state" --state-dir "$TEST_STATE" set oversee lanes '[]' >/dev/null
source "$TEST_SCRIPTS/lib/lane-claims.sh"
lane_claim_write "$(lane_claims_dir "$TEST_REPO")" "$OT_TMUX_SERVER_PID" %1 "$HOME/.claude" other-fleet
STUB
chmod +x "$WAIT_BIN/sleep"
rejudge_command='claude --dangerously-skip-permissions {brief}'
# Each record also names the account its pick reading judged and the claims
# that reading charged: the batch's second item sees the first item's claim,
# and the wait sees the other fleet's. The batch's unkept control drops the
# walk's reading, and no record names a pick.
for surface in batch wait; do
  controls=(live mutant)
  [[ "$surface" != batch ]] || controls+=(unkept)
  for control in "${controls[@]}"; do
    OT="$REPO/scripts/open-terminal"
    if [[ "$control" == unkept ]]; then
      OT="$(mutant_scripts "unkept-rejudge-$surface" open-terminal)/open-terminal"
      orch_fixture_shared_libs "$TMP_ROOT/unkept-rejudge-$surface"
      git -C "$TMP_ROOT/unkept-rejudge-$surface" init -q
      git -C "$TMP_ROOT/unkept-rejudge-$surface" config gc.auto 0
      git -C "$TMP_ROOT/unkept-rejudge-$surface" config maintenance.auto false
      mutate_file "$OT" 'LANE_PICK_RECORD="$preference_record" PREFERENCE_ENTRY=' 'PREFERENCE_ENTRY='
    elif [[ "$control" == mutant ]]; then
      OT="$(mutant_scripts "mutant-rejudge-$surface" open-terminal)/open-terminal"
      orch_fixture_shared_libs "$TMP_ROOT/mutant-rejudge-$surface"
      git -C "$TMP_ROOT/mutant-rejudge-$surface" init -q
      git -C "$TMP_ROOT/mutant-rejudge-$surface" config gc.auto 0
      git -C "$TMP_ROOT/mutant-rejudge-$surface" config maintenance.auto false
      mutate_file "$OT" 'preference_select || return 1' 'LANE_PICK_RECORD="$(pick_auto_lane)" || return 1; PREFERENCE_LANE_ENV="$(pick_record_env "$LANE_PICK_RECORD")" || return 1'
    fi
    RUN="$TMP_ROOT/real-$surface-$control"
    mkdir -p "$RUN"
    ot_fleet_state "$REPO/scripts/workflow-state" "$RUN/state" "$REPO" || exit 1
    args=(--lane auto CC-11 CC-12)
    cap=3
    if [[ "$surface" == wait ]]; then
      cap=1
      args=(--lane "$TMP_ROOT/home/.claude" --wait-slot CC-12)
      "$REPO/scripts/workflow-state" --state-dir "$RUN/state" set oversee lanes '[{"item":"CC-9","status":"running","window":"stub:CC-9"}]' >/dev/null
      printf 1 > "$RUN/panes"
    fi
    rc=0
    (cd -- "$REPO" && env -i PATH="$WAIT_BIN:$BIN:$PATH" HOME="$TMP_ROOT/home" ORCH_LANE_HOST=local \
      ORCH_LANE_PREFERENCE='claude:fable:high,claude:opus:medium' ORCH_OVERSEER_LANES="$cap" ORCH_TMUX_SESSION=stub \
      ORCH_LANE_DIRS="$TMP_ROOT/home/.claude" ORCH_LANE_BURN_PCT_PER_HOUR=50 ORCH_LANES_USAGE_TTL=0 \
      ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" FIXTURE_DIR="$TMP_ROOT/usage" OVERSEE_WATCH_STATE_DIR="$RUN/claims" \
      WORKTREE_CLI="$BIN/worktree" LANES_CLI="$REPO/scripts/lanes" TEST_SCRIPTS="$REPO/scripts" TEST_STATE="$RUN/state" TEST_REPO="$REPO" \
      OT_TMUX_LOG="$RUN/tmux" OT_TMUX_PANES="$RUN/panes" OT_TMUX_SERVER_PID="$$" OT_WT_LOG="$RUN/worktrees" \
      GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$OT" --tmux --state-dir "$RUN/state" --harness claude \
      --cmd "$rejudge_command" --brief-file "$TMP_ROOT/brief" \
      "${args[@]}" > "$RUN/out" 2> "$RUN/err") || rc=$?
    commands=''
    while IFS= read -r command; do
      [[ -n "$command" ]] || continue
      commands+="$(launch_choice_launch_model claude "$command"):$(launch_choice_effort claude "$command"),"
    done <<<"$(sed -n '/^clear; /p' "$RUN/tmux" 2>/dev/null || true)"
    records="$("$REPO/scripts/workflow-state" --state-dir "$RUN/state" get oversee '.lanes | map([.item,.harness,.model,.preference_entry,(.pick.account // "none" | split("/") | last),(.pick.claims | tostring)] | join(":")) | join(",")' | tr -d '\"')"
    if [[ "$surface:$control" == batch:live ]]; then
      want='0|fable:high,opus:medium,|CC-11:claude:fable:claude:fable:high:.claude:0,CC-12:claude:opus:claude:opus:medium:.claude:1'
    elif [[ "$surface:$control" == batch:unkept ]]; then
      want='0|fable:high,opus:medium,|CC-11:claude:fable:claude:fable:high:none:null,CC-12:claude:opus:claude:opus:medium:none:null'
    elif [[ "$surface:$control" == batch:mutant ]]; then
      want='1|fable:high,|CC-11:claude:fable:claude:fable:high:.claude:0'
    elif [[ "$control" == live ]]; then
      want='0|opus:medium,|CC-12:claude:opus:claude:opus:medium:.claude:1'
    else
      want='1||'
    fi
    assert_eq "$rc|$commands|$records" "$want" "$surface $control rewalk uses the real claim and records the chosen command" "$RUN/err"
    if [[ "$surface" == wait ]]; then
      assert_file_contains "$RUN/out" 'open-terminal: slot-waiting item=CC-12' 'wait regression reaches the cap callback'
    fi
  done
done
# The real chooser judges the grant even when the fleet normally uses a
# Daytona provider. Every row starts with plan room so only grant eligibility
# determines whether the launch falls through to Codex.
git -C "$REPO" remote add origin https://github.com/owner/repo.git
cp "$TEST_DIR/fixtures/lane-host" "$REPO/daytona"
make_lane "$TMP_ROOT/home" claude
make_lane "$TMP_ROOT/home" aclaude
make_codex_lane "$TMP_ROOT/home/.codex"
mkdir -p "$TMP_ROOT/cloud-usage"
printf '{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":4102444800},"secondary_window":{"used_percent":20,"reset_at":4102444800}}}\n' > "$TMP_ROOT/cloud-usage/.codex.json"
printf 'Session started: https://claude.ai/code/session_01PREFERENCE\n' > "$TMP_ROOT/cloud-screen"
printf 'Working (esc to interrupt)\n' > "$TMP_ROOT/host-screen"
printf 'dev@lane:~$\n' > "$TMP_ROOT/ssh-screen"
CLOUD_PREF='claude@claude-cloud:claude-opus-5-5:high,codex:gpt-6.1-sol:high'
cloud_observe() { # ROW [SCRIPT_ROOT] [PREFERENCE]
  local row="$1" root="${2:-$REPO/scripts}" pref="${3:-$CLOUD_PREF}" remaining=20 lock=null expiry='2099-11-04T00:00:00Z' repos='claude=owner/repo' rc=0 brief_args=()
  local cloud_account=claude terminal_args=(--tmux) shape_args=() items=(CC-21) tmux_session=stub
  case "$row" in floor) remaining=5 ;; locked) lock='"overage"' ;; expired) expiry='2020-11-04T00:00:00Z' ;; no-repo) repos='' ;; esac
  case "$row" in
    missing-credit | unread-credit) cloud_account=aclaude; repos='aclaude=owner/repo' ;;
    relaunch) shape_args=(--relaunch) ;;
    batch) items+=(CC-22) ;;
    gui) terminal_args=(--ghostty); tmux_session='' ;;
    implicit-gui) terminal_args=(); tmux_session='' ;;
  esac
  claude_usage 10 20 10 Opus | jq --argjson remaining "$remaining" --argjson lock "$lock" --arg expiry "$expiry" \
    '. + {iguana_necktie: {limit_dollars:250,remaining_dollars:$remaining,locked_reason:$lock,resets_at:$expiry}}' \
    > "$TMP_ROOT/cloud-usage/.$cloud_account.json"
  case "$row" in
    missing-credit) jq 'del(.iguana_necktie)' "$TMP_ROOT/cloud-usage/.$cloud_account.json" > "$TMP_ROOT/cloud-usage/credit.next" ;;
    unread-credit) jq 'del(.iguana_necktie.remaining_dollars)' "$TMP_ROOT/cloud-usage/.$cloud_account.json" > "$TMP_ROOT/cloud-usage/credit.next" ;;
  esac
  case "$row" in missing-credit | unread-credit) mv -- "$TMP_ROOT/cloud-usage/credit.next" "$TMP_ROOT/cloud-usage/.$cloud_account.json" ;; esac
  RUN="$TMP_ROOT/cloud-run"
  rm -rf -- "${RUN:?}"
  mkdir -p "$RUN/remote/srv/lane"
  printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$RUN/remote/srv/lane/.git"
  ot_fleet_state "$REPO/scripts/workflow-state" "$RUN/state" "$REPO" || exit 1
  [[ "$row" == no-brief ]] || brief_args=(--brief-file "$TMP_ROOT/brief")
  (cd -- "$REPO" && env -i PATH="$BIN:$PATH" HOME="$TMP_ROOT/home" LANES_HOME="$TMP_ROOT/home" \
    ORCH_LANE_HOST="$REPO/daytona" ORCH_LANE_PREFERENCE="$pref" ORCH_LANE_CLOUD_CREDIT_FLOOR=5 \
    ORCH_LANE_CLOUD_REPOS="$repos" ORCH_LANE_DIRS="$TMP_ROOT/home/.$cloud_account:$TMP_ROOT/home/.codex" \
    ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" FIXTURE_DIR="$TMP_ROOT/cloud-usage" ORCH_LANES_USAGE_TTL=0 \
    OVERSEE_WATCH_STATE_DIR="$RUN/claims" ORCH_TMUX_SESSION="$tmux_session" ORCH_OVERSEER_LANES=3 \
    ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SSH_PROMPT_SECS=1 WORKTREE_CLI="$BIN/worktree" LANES_CLI="$root/lanes" \
    OT_WT_LOG="$RUN/worktrees" OT_TMUX_LOG="$RUN/tmux" OT_TMUX_PANES="$RUN/panes" OT_TMUX_SERVER_PID="$$" \
    OT_HARNESS_EXITS=1 OT_COMPOSER_ON_ENTER=1 OT_SCREEN_FILE="$TMP_ROOT/cloud-screen" OT_HARNESS_SCREEN="$TMP_ROOT/host-screen" OT_SSH_SCREEN="$TMP_ROOT/ssh-screen" \
    LANE_HOST_STUB_DIR="$RUN/remote" LANE_HOST_STUB_LOG="$RUN/host" OT_SLEEP_INSTANT=1 \
    TERMINAL=ghostty OT_CAPTURE="$RUN/command" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$root/open-terminal" ${terminal_args[@]+"${terminal_args[@]}"} --state-dir "$RUN/state" --harness claude --lane auto \
    --cmd "$rejudge_command" ${brief_args[@]+"${brief_args[@]}"} ${shape_args[@]+"${shape_args[@]}"} "${items[@]}" \
    > "$RUN/out" 2> "$RUN/err") || rc=$?
  local record key=none
  record="$("$REPO/scripts/workflow-state" --state-dir "$RUN/state" get oversee \
    '.lanes // [] | map([.harness,.kind,.host,.model,.preference_entry,(.session_id // "none")] | join("|")) | join(",")')"
  if [[ "$rc" -ne 0 ]]; then
    key="$(sed -n 's/^open-terminal: \([^ ]*\).*/\1/p' "$RUN/err")"; key="${key%%$'\n'*}"
  fi
  CLOUD_OBS="$rc|$key|$record"
}
CLOUD_WANT="0|none|claude|claude-cloud|claude-cloud|claude-opus-5-5|claude@claude-cloud:claude-opus-5-5:high|session_01PREFERENCE"
SSH_WANT="0|none|codex|ssh|$REPO/daytona|gpt-6.1-sol|codex:gpt-6.1-sol:high|none"
for row in room floor locked expired no-repo missing-credit unread-credit no-brief; do
  cloud_observe "$row"
  want="$SSH_WANT"
  case "$row" in room) want="$CLOUD_WANT" ;; no-brief) want='1|cloud-brief-missing|' ;; esac
  assert_eq "$CLOUD_OBS" "$want" "hosted preference: $row" "$RUN/err"
  if [[ "$row" == room ]]; then
    command="$(sed -n '/^clear; /p' "$RUN/tmux")"
    assert_eq "$(launch_choice_launch_model claude "$command"):$(launch_choice_effort claude "$command")" \
      'claude-opus-5-5:high' 'the cloud-first preference passes its model and high effort to Claude' "$RUN/err"
  fi
done
LOCAL_PREF='claude@claude-cloud:claude-opus-5-5:high,codex@local:gpt-6.1-sol:high'
LOCAL_WANT='0|none|codex|local||gpt-6.1-sol|codex@local:gpt-6.1-sol:high|none'
while IFS='|' read -r row preference want; do
  cloud_observe "$row" "$REPO/scripts" "$preference"
  assert_eq "$CLOUD_OBS" "$want" "host launch eligibility: $row" "$RUN/err"
done <<ROWS
relaunch|$LOCAL_PREF|$LOCAL_WANT
batch|$LOCAL_PREF|$LOCAL_WANT,${LOCAL_WANT#0|none|}
gui|$LOCAL_PREF|$LOCAL_WANT
implicit-gui|$LOCAL_PREF|$LOCAL_WANT
ROWS
# A legacy entry still uses the fleet host. An entry naming local changes
# only its own route, without changing the configured fleet host.
cloud_observe floor "$REPO/scripts" 'codex:gpt-6.1-sol:high'
assert_eq "$CLOUD_OBS" "$SSH_WANT" 'legacy entry retains the Daytona host' "$RUN/err"
cloud_observe floor "$REPO/scripts" 'codex@local:gpt-6.1-sol:high'
assert_eq "$CLOUD_OBS" '0|none|codex|local||gpt-6.1-sol|codex@local:gpt-6.1-sol:high|none' 'entry host local overrides the fleet host' "$RUN/err"

# Each control removes one independent grant condition or host selection in a
# disposable copy. The same launch observation must then differ from its row.
for control in host floor locked expired no-repo credit-only grammar; do
  file=lib/lane-model.sh
  case "$control" in host) file=open-terminal ;; grammar) file=lib/overseer-launch.sh ;; esac
  root="$(mutant_scripts "cloud-control-$control" "$file")"
  orch_fixture_shared_libs "$TMP_ROOT/cloud-control-$control"
  git -C "$TMP_ROOT/cloud-control-$control" init -q
  git -C "$TMP_ROOT/cloud-control-$control" config gc.auto 0
  git -C "$TMP_ROOT/cloud-control-$control" config maintenance.auto false
  git -C "$TMP_ROOT/cloud-control-$control" remote add origin https://github.com/owner/repo.git
  case "$control" in
    host) mutate_file "$root/$file" 'LANE_HOST="${OL_ENTRY_HOST:-$preference_host}"' 'LANE_HOST="$preference_host"'; row=room; want="$CLOUD_WANT" ;;
    floor) mutate_file "$root/$file" 'and $c.remaining_dollars > $cloud_floor and' 'and'; row=floor; want="$SSH_WANT" ;;
    locked) mutate_file "$root/$file" ' and $c.locked_reason == null' ''; row=locked; want="$SSH_WANT" ;;
    expired) mutate_file "$root/$file" ' and $e > $now' ''; row=expired; want="$SSH_WANT" ;;
    no-repo) mutate_file "$root/$file" 'else . + {verdict: "cloud-repo-unset"} end;' 'else . end;'; row=no-repo; want="$SSH_WANT" ;;
    credit-only) mutate_file "$root/$file" 'elif $pool == "cloud-credit" then' 'elif false then'; row=floor; want="$SSH_WANT" ;;
    grammar) mutate_file "$root/$file" '"${2:-}" != lane ||' 'true ||'; row=room; want="$CLOUD_WANT" ;;
  esac
  cloud_observe "$row" "$root"
  if [[ "$CLOUD_OBS" != "$want" ]]; then pass "control: $control changes the hosted preference result"
  else fail "control: $control leaves the hosted preference result unchanged"; fi
  if [[ "$control" == credit-only ]]; then
    for row in missing-credit unread-credit; do
      cloud_observe "$row" "$root"
      if [[ "$CLOUD_OBS" != "$SSH_WANT" ]]; then pass "control: credit-only changes $row fallback"
      else fail "control: credit-only leaves $row fallback unchanged"; fi
    done
  fi
done

# Remove each launch-shape check independently; the selected cloud entry
# then reaches the existing refusal instead of the eligible fallback.
for row in relaunch batch gui; do
  preference="$LOCAL_PREF" want="$LOCAL_WANT"
  case "$row" in
    relaunch) old='&& "$RELAUNCH" != true ]] || continue'; new='&& ( "$RELAUNCH" != true || 1 == 1 ) ]] || continue' ;;
    batch) old='${#ITEMS[@]} -eq 1 && "$RELAUNCH" != true'; new='( ${#ITEMS[@]} -eq 1 || 1 == 1 ) && "$RELAUNCH" != true'; want="$LOCAL_WANT,${LOCAL_WANT#0|none|}" ;;
    gui) old='&& "$preference_mode" == tmux'; new='&& ( "$preference_mode" == tmux || 1 == 1 )' ;;
  esac
  root="$(mutant_scripts "cloud-shape-$row" open-terminal)"
  orch_fixture_shared_libs "$TMP_ROOT/cloud-shape-$row"
  git -C "$TMP_ROOT/cloud-shape-$row" init -q
  git -C "$TMP_ROOT/cloud-shape-$row" config gc.auto 0
  git -C "$TMP_ROOT/cloud-shape-$row" config maintenance.auto false
  git -C "$TMP_ROOT/cloud-shape-$row" remote add origin https://github.com/owner/repo.git
  mutate_file "$root/open-terminal" "$old" "$new"
  cloud_observe "$row" "$root" "$preference"
  if [[ "$CLOUD_OBS" != "$want" ]]; then pass "control: $row compatibility changes the fallback"
  else fail "control: $row compatibility leaves the fallback unchanged"; fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
