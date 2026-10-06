#!/usr/bin/env bash
# Tests for how `lanes pick` spreads launches across accounts: every verdict
# charges each live claim on an account its expected burn, so an account whose
# room the lanes already on it will spend is dropped as a walled one is, by the
# chooser and by the named form alike; selection charges that projected room;
# and a window-account chooser never returns an overseer seat, an
# account a fleet state records as its overseer's. The network layer is the
# fetch stub lib/lanes-fixture.sh writes, so every row runs offline.
#
# One table per case, one asserted row per shape. Every run gets its own claim
# store and fleet state directory, staged from the row alone.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Every lane this suite measures lives under LANES_HOME, and every threshold a
# row asserts is the script's default or the row's own setting.
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANE_MAX_PCT ORCH_LANE_BURN_PCT_PER_HOUR ORCH_LANE_HOST ORCH_STATE_DIR
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="$(cd "$TEST_DIR/.." && pwd)/scripts/lanes"

TMP_ROOT="$(mktemp -d)" || { echo "lanes-pick-spread: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-pick-spread: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-pick-spread: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/virtual-clock.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/question-off.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# Runs start in a repository carrying no settings, so neither the checkout's
# kendex.settings.toml nor its fleet state reaches a row.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"
git -C "$NOSETTINGS" init -q -b main
git -C "$NOSETTINGS" config gc.auto 0
git -C "$NOSETTINGS" config maintenance.auto false

# The tmux stub answers `list-panes` with the panes file, so a claim naming
# this process and a listed pane is live.
BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
virtual_clock_install "$BIN" "$TMP_ROOT/clock"
cat > "$BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list-panes" ]] || exit 0
cat "$TMUX_PANES_FILE"
STUBEOF
chmod +x "$BIN/tmux"
OT_BIN="$TMP_ROOT/ot-bin"
ot_stub_bin "$OT_BIN"

# Three claude accounts: a at 20 percent used, b at 30, c at 60, each binding
# on its 5-hour window, and w binding on its weekly window at 86.
new_home spread
for lane in a:20 b:30 c:60; do
  make_lane "$H" "${lane%%:*}claude" 3600
  claude_usage "${lane#*:}" 10 5 Opus > "$FIXTURE_DIR/.${lane%%:*}claude.json"
done
make_lane "$H" wclaude 3600
claude_usage 10 86 5 Opus > "$FIXTURE_DIR/.wclaude.json"
make_lane "$H" mclaude 3600
claude_usage 10 20 84 Opus > "$FIXTURE_DIR/.mclaude.json"
make_codex_token_lane "$H/.1codex" 3600
# Its reset is ten hours past the suite clock, beyond the five-hour bound on
# the session charge, so every row charges the full five hours.
CODEX_RESET="$("$BIN/date" +%s)" || exit 1
jq -n --argjson reset "$((CODEX_RESET + 36000))" '{rate_limit: {primary_window: {used_percent: 22, reset_at: $reset,
  limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.1codex.json"
ALL_DIRS="ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude:$H/.cclaude"

# stage SPEC — the claim store and fleet state for one run. SPEC items,
# separated by `;`:
#   claim:LANE:N[:FLEET]  N live claims on LANE's account, each naming FLEET's
#                         state file (own, peer or gone), or none
#   own:LANE              this checkout's fleet state records LANE as its overseer
#   peer:LANE             a peer fleet's state records LANE as its overseer
#   own:broken            this checkout's fleet state is not JSON
#   store:file            the claims path is a plain file, a store nobody can read
# Any other token is a typo and stops the suite.
PANE_SEQ=0
stage() {
  local spec="$1" items item lane n fleet i
  STORE="$RUN/store"; FLEET="$RUN/fleet"
  mkdir -p "$STORE/claims" "$FLEET" "$RUN/peer"
  : > "$RUN/panes"
  [[ -n "$spec" ]] || return 0
  IFS=';' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    case "$item" in
      own:broken) printf 'not json\n' > "$FLEET/workflow-state-oversee.json" ;;
      store:file) rmdir -- "${STORE:?}/claims" && : > "$STORE/claims" ;;
      own:*) jq -n --arg a "$H/.${item#own:}${ACCOUNT_HARNESS:-claude}" '{overseer: {account: $a}}' > "$FLEET/workflow-state-oversee.json" ;;
      peer:*) jq -n --arg a "$H/.${item#peer:}${ACCOUNT_HARNESS:-claude}" '{overseer: {account: $a}}' > "$RUN/peer/workflow-state-oversee.json" ;;
      claim:*)
        IFS=':' read -r _ lane n fleet <<<"$item"
        case "${fleet:-none}" in
          own) fleet="$FLEET/workflow-state-oversee.json" ;;
          peer) fleet="$RUN/peer/workflow-state-oversee.json" ;;
          gone) fleet="$RUN/ended/workflow-state-oversee.json" ;;
          none) fleet="" ;;
          *) echo "stage: unknown fleet token in $item" >&2; exit 1 ;;
        esac
        for ((i = 0; i < n; i++)); do
          PANE_SEQ=$((PANE_SEQ + 1))
          printf '%s %%%s\n' "$$" "$PANE_SEQ" >> "$RUN/panes"
          printf '%s\t%%%s\t%s\tken-%s\t2026-09-28T00:00:00Z\t%s\n' \
            "$$" "$PANE_SEQ" "$H/.${lane}${ACCOUNT_HARNESS:-claude}" "$PANE_SEQ" "$fleet" > "$STORE/claims/$PANE_SEQ.claim"
        done
        ;;
      *) echo "stage: unknown token in $item" >&2; exit 1 ;;
    esac
  done
}

# stage_rate LANE CURRENT PRIOR [CLAIMS] [ELAPSED] [AGE] [BUCKET]: LANE's cached figure at CURRENT
# percent on BUCKET (session by default), with a prior sample ELAPSED seconds earlier at
# PRIOR. ELAPSED defaults to 600 seconds. The record is written by a listing
# first, so its name is the one
# `lanes` keys it on. CLAIMS is the count at sample time, one by default;
# `missing` stages a record from before counts were stored. AGE defaults to zero;
# an age beyond the usage TTL makes the next command fetch a new sample.
stage_rate() {
  local lane="$1" f now staged=no
  (cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
    ORCH_LANE_DIRS="$H/.${lane}${ACCOUNT_HARNESS:-claude}" OVERSEE_WATCH_STATE_DIR="$STORE" TMUX_PANES_FILE="$RUN/panes" \
    STUB_CLOCK="$STUB_CLOCK" STUB_REAL_DATE="$STUB_REAL_DATE" STUB_REAL_SLEEP="$STUB_REAL_SLEEP" \
    PATH="$BIN:$PATH" "$LANES" list --json >/dev/null 2>&1)
  now="$("$BIN/date" +%s)" || exit 1
  for f in "$STORE"/usage/*.json; do
    [[ -f "$f" && "$(jq -r '.config_dir' "$f")" == "$H/.${lane}${ACCOUNT_HARNESS:-claude}" ]] || continue
    jq --argjson now "$now" --argjson current "$2" --argjson prior "$3" --arg claims "${4:-1}" \
      --argjson elapsed "${5:-600}" --argjson age "${6:-0}" --arg bucket "${7:-session}" '
      def pct($p): if .rate_limit then .rate_limit.primary_window.used_percent = $p
                   elif $bucket == "model" then .limits[0].percent = $p
                   else .five_hour.utilization = $p end;
      .fetched_at = ($now - $age) | .prior = {fetched_at: ($now - $age - $elapsed), usage: (.usage | pct($prior))}
      | .usage |= pct($current)
      | if $claims == "missing" then del(.sample_claims) else .sample_claims = ($claims | tonumber) end' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f" && staged=yes
  done
  [[ "$staged" == yes ]] || { echo "stage_rate: no cached record for $lane" >&2; exit 1; }
}

# table ROW...: `label|env|stage|rate|args|expect`: env is `;`-separated
# `env` arguments, stage a stage SPEC, rate `LANE:CURRENT:PRIOR[:CLAIMS[:ELAPSED[:AGE[:BUCKET]]]]` or empty.
# expect is `name=value` tokens: rc, seatrefusal (`named` where the first keyed
# line is the pick-overseer-seats refusal naming the seat step and this run's
# own fleet state, else that line), keyed.KEY (the first keyed stderr line
# carrying KEY, in the form key takes, or none), key (the first keyed stderr line as
# `key,field=value,...`), out (stdout whole), record.PATH (that path of the
# fleet state's first lane record), score_hundredths (its pick's
# selection_score), or a field of the JSON record. args `launch-fleet LANE` is
# a fleet launch of one claude lane on LANE, `auto` or a config dir.
RUN_SEQ=0
table() {
  local row label env stage_spec rate args expect env_args command got token name value rate_lane rate_now rate_prior rate_claims rate_elapsed rate_age rate_bucket
  for row in "$@"; do
    IFS='|' read -r label env stage_spec rate args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
    stage "$stage_spec"
    if [[ -n "$rate" ]]; then
      IFS=':' read -r rate_lane rate_now rate_prior rate_claims rate_elapsed rate_age rate_bucket <<<"$rate"
      stage_rate "$rate_lane" "$rate_now" "$rate_prior" "${rate_claims:-1}" "${rate_elapsed:-600}" "${rate_age:-0}" "${rate_bucket:-session}"
    fi
    env_args=()
    [[ -z "$env" ]] || IFS=';' read -ra env_args <<<"$env"
    # shellcheck disable=SC2206 # args contains suite-authored command words.
    command=("${LANES_UNDER_TEST:-$LANES}" $args)
    if [[ "$args" == launch ]]; then
      command=("${command[0]%/*}/open-terminal" --ghostty --harness codex --lane "$H/.1codex" --cmd "true -m gpt-6.1-sol -c model_reasoning_effort=high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" SPREAD-1)
    elif [[ "$args" == "launch-fleet "* ]]; then
      ot_fleet_state "${command[0]%/*}/workflow-state" "$FLEET" "$NOSETTINGS" || exit 1
      command=("${command[0]%/*}/open-terminal" --ghostty --harness claude --lane "${args#launch-fleet }" --state-dir "$FLEET" \
        --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" SPREAD-6)
    fi
    # The launcher reads settings from its source checkout. An empty team
    # keeps this projection test independent of tracker authentication.
    OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" LINEAR_TEAM= GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' LANES_CLI="${LANES_UNDER_TEST:-$LANES}" \
      ORCH_LANES_FETCH_CMD="$FETCHER" FETCH_LOG="$RUN/fetch.log" OVERSEE_WATCH_STATE_DIR="$STORE" ORCH_STATE_DIR="$FLEET" \
      STUB_CLOCK="$STUB_CLOCK" STUB_REAL_DATE="$STUB_REAL_DATE" STUB_REAL_SLEEP="$STUB_REAL_SLEEP" \
      TMUX_PANES_FILE="$RUN/panes" PATH="$BIN:$OT_BIN:$PATH" OT_WT_LOG="$RUN/worktree.log" \
      OT_CAPTURE="$RUN/ghostty" WORKTREE_CLI="$OT_BIN/worktree" TERMINAL=ghostty TMUX= ORCH_LANE_HOST=local ORCH_LANE_PREFERENCE= \
      ORCH_LANE_DIRS= ORCH_LANE_ALIASES= ORCH_LANE_EXCLUDE= ORCH_LANE_RETIRE= ORCH_LANE_COPILOT_POOL= ORCH_LANE_BURN_PCT_PER_HOUR= ORCH_LANE_MAX_PCT= \
      ${env_args[@]+"${env_args[@]}"} "${command[@]}" 2>"$RUN/err")
    RC=$?
    got=""
    for token in $expect; do
      name="${token%%=*}"
      case "$name" in
        rc) value="$RC" ;;
        out) value="$OUT" ;;
        launched) value="$(awk '$1 == "open-terminal:" && $2 == "terminal-opened" { print "yes" }' <<<"$OUT")"; value="${value:-no}" ;;
        sample_claims) value="$(jq -r --arg dir "$H/.1codex" 'select(.config_dir == $dir) | .sample_claims' "$STORE"/usage/*.json)" || exit 1 ;;
        fetched) value="$(cat "$RUN/fetch.log")" || exit 1 ;;
        headroom_hundredths) value="$(jq -r '.projected_headroom_pct * 100 | round' <<<"$OUT")" ;;
        record.*) value="$(jq -r ".lanes[0].${name#record.}" "$FLEET/workflow-state-oversee.json" 2>/dev/null || echo UNREADABLE)" ;;
        score_hundredths) value="$(jq -r '.lanes[0].pick.selection_score * 100 | round' "$FLEET/workflow-state-oversee.json" 2>/dev/null || echo UNREADABLE)" ;;
        seatrefusal)
          value="$(awk '$1 == "lanes:" { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$RUN/err")"
          [[ "$value" != "pick-overseer-seats,step=seat,state=$FLEET/workflow-state-oversee.json" ]] || value=named
          ;;
        keyed.*)
          value="$(awk -v k="${name#keyed.}" '$1 == "lanes:" && $2 == k { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$RUN/err")"
          value="${value:-none}"
          ;;
        key)
          value="$(awk '$1 == "lanes:" { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$RUN/err")"
          value="${value:-none}"
          ;;
        *) value="$(jq -r ".$name" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)" ;;
      esac
      got="$got $name=$value"
    done
    assert_eq "${got# }" "$expect" "$label" "$RUN/err"
  done
}

PICK='pick --harness claude --json'

echo "=== the projection charges each live claim its expected burn ==="
# 20 percent used with three claims at 30 an hour each projects 110 used, past
# the default 95: the account a reading alone would call the roomiest. The
# skipped-seat row measures a's one lane at 90 an hour, a point and a half a
# minute, so a projects 110 used and b, two claims at the default 5, 40.
table \
  "a lone seat whose claims project past the threshold is dropped the way a walled one is|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||$PICK|rc=3 walled=1 unmeasured=0" \
  "a named lane whose claims project past the threshold is refused under --projected on the chooser's rule|$ALL_DIRS;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||pick --lane $H/.aclaude --harness claude --projected --json|rc=3 wall=20 claims=3 projected_headroom_pct=-10 key=pick-lane-walled,lane=$H/.aclaude,wall=20,bucket=session,max-pct=95,projected-headroom=-10" \
  "the most-room seat whose claims project past the threshold is skipped, even for one with less room and more claims|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1;claim:b:2|a:20:5|$PICK|rc=0 config_dir=$H/.bclaude projected_headroom_pct=60" \
  "both readings have room but their claims project past the threshold|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3;claim:b:4||$PICK|rc=3 walled=2 unmeasured=0" \
  "the pick names the projection it chose on|$ALL_DIRS|claim:a:1;claim:b:1;claim:c:1||$PICK|rc=0 config_dir=$H/.aclaude claims=1 burn_pct_per_lane_hour=5 projected_headroom_pct=75" \
  "a named lane judged without --projected reads the wall, as a lane's own handoff mark and a lane close ask|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:4||pick --lane $H/.aclaude --harness claude --min-headroom-pct 3 --json|rc=0 wall=20 projected_headroom_pct=-40 key=none" \
  "--projected is refused without --lane, the chooser judging the projection always|$ALL_DIRS|||$PICK --projected|rc=1 key=unknown-option,arg1=--projected" \
  "a weekly-bound account is charged the default by its window's length and stays a candidate|ORCH_LANE_DIRS=$H/.wclaude|claim:w:2||$PICK|rc=0 config_dir=$H/.wclaude binding_bucket=weekly" \
  "a burn of 0 charges a claim nothing|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=0|claim:a:3||pick --lane $H/.aclaude --harness claude --projected --json|rc=0 projected_headroom_pct=80" \
  "claims added after a one-claim sample each inherit its measured burn|ORCH_LANE_DIRS=$H/.aclaude|claim:a:2|a:20:15|pick --lane $H/.aclaude --harness claude --json|rc=0 usage_rate_state=measured burn_pct_per_lane_hour=30 projected_headroom_pct=20" \
  "a measured rate with nothing claimed charges nothing and names the default burn|ORCH_LANE_DIRS=$H/.aclaude||a:20:15|pick --lane $H/.aclaude --harness claude --json|rc=0 burn_pct_per_lane_hour=5 projected_headroom_pct=80" \
  "the listing carries the projection beside the verdict of the reading, whose wall lifts at its reset|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||list --harness claude --json|rc=0 [0].verdict=room [0].projected_headroom_pct=-10"

# open-terminal records claims and re-picks before cached usage refreshes.
# A cached six-point hourly burn leaves 74 room with one claim, then 68
# with two. The idle competitor keeps 70. Both samples stay unchanged.
table \
  "one measured claim still leaves more projected room than the idle account|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1|a:20:19|$PICK|rc=0 config_dir=$H/.aclaude projected_headroom_pct=74" \
  "another claim on the same measured samples sends the chooser to the idle account|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:2|a:20:19|$PICK|rc=0 config_dir=$H/.bclaude projected_headroom_pct=70" \
  "the named projection charges the added measured claim too|ORCH_LANE_DIRS=$H/.aclaude|claim:a:2|a:20:19|pick --lane $H/.aclaude --harness claude --projected --json|rc=0 claims=2 burn_pct_per_lane_hour=6 projected_headroom_pct=68" \
  "enough claims wall the named measured projection|ORCH_LANE_DIRS=$H/.aclaude|claim:a:13|a:20:19|pick --lane $H/.aclaude --harness claude --projected --json|rc=3 projected_headroom_pct=2"

# The Codex window resets beyond five hours, so each claim is charged the
# shared burn for the five-hour session horizon: 78 room less 12 claims at 0.9554 for 5
# hours leaves 20.68.
ACCOUNT_HARNESS=codex table \
  "twelve sampled claims share the account burn in the chooser|ORCH_LANE_DIRS=$H/.1codex|claim:1:12|1:22:20:12:628|pick --harness codex --model gpt-6.1-sol --json|rc=0 config_dir=$H/.1codex claims=12 headroom_hundredths=2068" \
  "the named projection shares the same twelve-claim burn|ORCH_LANE_DIRS=$H/.1codex|claim:1:12|1:22:20:12:628|pick --lane $H/.1codex --harness codex --model gpt-6.1-sol --projected --json|rc=0 claims=12 headroom_hundredths=2068" \
  "open-terminal launches on the sampled twelve-claim account|ORCH_LANE_DIRS=$H/.1codex|claim:1:12|1:22:20:12:628|launch|rc=0 launched=yes" \
  "a fresh sample records its live claim count|ORCH_LANE_DIRS=$H/.1codex|claim:1:12||list --harness codex --json|rc=0 sample_claims=12"
# The usage endpoint returns 22 after an expired sample of 20. The fixed clock
# keeps the 628-second interval exact, including on a loaded runner.
ACCOUNT_HARNESS=codex table \
  "the first projection after a fetch shares the newly sampled account burn|ORCH_LANE_DIRS=$H/.1codex|claim:1:12|1:20:19:12:628:628|pick --harness codex --model gpt-6.1-sol --json|rc=0 claims=12 usage_rate_state=measured usage_age_s=0 headroom_hundredths=2068 sample_claims=12 fetched=.1codex"
table \
  "one sampled claim keeps its measured charge|ORCH_LANE_DIRS=$H/.aclaude|claim:a:1|a:20:19:1|$PICK|rc=0 burn_pct_per_lane_hour=6 projected_headroom_pct=74" \
  "an older cache record keeps the one-claim charge|ORCH_LANE_DIRS=$H/.aclaude|claim:a:2|a:20:19:missing|$PICK|rc=0 burn_pct_per_lane_hour=6 projected_headroom_pct=68" \
  "a zero-claim sample uses one as its divisor|ORCH_LANE_DIRS=$H/.aclaude|claim:a:2|a:20:19:0|$PICK|rc=0 burn_pct_per_lane_hour=6 projected_headroom_pct=68"

# Claims from open-terminal omit models. A cached Opus rate cannot share its
# six-point hourly charge across the two sampled account claims. Three live
# claims spend 18 points, with 16 left; shared windows remain below Opus.
table \
  "a model rate refuses the chooser despite unrelated sampled claims|ORCH_LANE_DIRS=$H/.mclaude|claim:m:3|m:84:78:2:3600:0:model|pick --harness claude --model opus --json|rc=3 walled=1 unmeasured=0" \
  "a model rate refuses the named projection on the same cached samples|ORCH_LANE_DIRS=$H/.mclaude|claim:m:3|m:84:78:2:3600:0:model|pick --lane $H/.mclaude --harness claude --model opus --projected --json|rc=3 binding_bucket=model usage_rate_state=measured burn_pct_per_lane_hour=6 projected_headroom_pct=-2"

CTRL="$(mutant_scripts mutant-model-rate-shared lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '(if .binding_bucket == "model" then 1 else ([._rate_sample_claims // 1, 1] | max) end)' '([._rate_sample_claims // 1, 1] | max)'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: sharing the model rate admits the chooser with spent room|ORCH_LANE_DIRS=$H/.mclaude|claim:m:3|m:84:78:2:3600:0:model|pick --harness claude --model opus --json|rc=0 binding_bucket=model burn_pct_per_lane_hour=3 projected_headroom_pct=7" \
  "control: sharing the model rate admits the named projected pick too|ORCH_LANE_DIRS=$H/.mclaude|claim:m:3|m:84:78:2:3600:0:model|pick --lane $H/.mclaude --harness claude --model opus --projected --json|rc=0 binding_bucket=model burn_pct_per_lane_hour=3 projected_headroom_pct=7"

CTRL="$(mutant_scripts mutant-rate-whole lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'then (.usage_rate_pct_per_min * 60) / (if .binding_bucket == "model" then 1 else ([._rate_sample_claims // 1, 1] | max) end)' 'then .usage_rate_pct_per_min * 60'
LANES_UNDER_TEST="$CTRL/lanes" ACCOUNT_HARNESS=codex table \
  "control: charging the whole account rate walls the twelve-claim account|ORCH_LANE_DIRS=$H/.1codex|claim:1:12|1:22:20:12:628|pick --harness codex --model gpt-6.1-sol --json|rc=3 walled=1"
CTRL="$(mutant_scripts mutant-sample-count lanes)" || exit 1
mutate_file "$CTRL/lanes" 'sample_claims="$(lane_claims_count "$LANE_CLAIMS_LIVE" "$2")"' 'sample_claims=1'
LANES_UNDER_TEST="$CTRL/lanes" ACCOUNT_HARNESS=codex table \
  "control: omitting the sampled count records one instead of twelve|ORCH_LANE_DIRS=$H/.1codex|claim:1:12||list --harness codex --json|rc=0 sample_claims=1"

CTRL="$(mutant_scripts mutant-fresh-sample-count lanes)" || exit 1
mutate_file "$CTRL/lanes" 'sample_claims="${USAGE_SAMPLE_CLAIMS:-1}"' 'sample_claims=1'
LANES_UNDER_TEST="$CTRL/lanes" ACCOUNT_HARNESS=codex table \
  "control: losing the fresh count walls the account before a cache read|ORCH_LANE_DIRS=$H/.1codex|claim:1:12|1:20:19:12:628:628|pick --harness codex --model gpt-6.1-sol --json|rc=3 walled=1 sample_claims=12 fetched=.1codex"

CTRL="$(mutant_scripts mutant-rate-divided lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'then (.usage_rate_pct_per_min * 60) / (if .binding_bucket == "model" then 1 else ([._rate_sample_claims // 1, 1] | max) end)' 'then (.usage_rate_pct_per_min * 60) / .claims'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: dividing by current claims keeps stacking launches on cached measured room|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:2|a:20:19|$PICK|rc=0 config_dir=$H/.aclaude projected_headroom_pct=74" \
  "control: the divided rate also admits a named launch whose claims spend its room|ORCH_LANE_DIRS=$H/.aclaude|claim:a:13|a:20:19|pick --lane $H/.aclaude --harness claude --projected --json|rc=0 projected_headroom_pct=74"

# Control: a verdict read off the wall alone keeps the account the lanes on it
# will spend, in both pick forms.
CTRL="$(mutant_scripts mutant-wall-only lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else 100 - .projected_headroom_pct' 'else .wall'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: judged on the wall alone, the chooser admits both spent projections and picks the less spent one|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3;claim:b:4||$PICK|rc=0 config_dir=$H/.aclaude projected_headroom_pct=-10" \
  "control: judged on the wall alone, the lone seat is picked|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||$PICK|rc=0 walled=null unmeasured=null" \
  "control: judged on the wall alone, the named lane has room|$ALL_DIRS;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||pick --lane $H/.aclaude --harness claude --projected --json|rc=0 wall=20 claims=3 projected_headroom_pct=-10 key=none"

# Control: a named lane judged on the projection whether asked or not refuses
# the lane whose reading has room, which every reader of the reading then
# acts on as a wall.
CTRL="$(mutant_scripts mutant-named-projected lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '(if $projected then judged_wall else .wall end)' 'judged_wall'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: projected unasked, the named lane is refused at the handoff mark|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:4||pick --lane $H/.aclaude --harness claude --min-headroom-pct 3 --json|rc=3"

# Control: the default charged whole against a weekly window drops the account
# with days of room left.
CTRL="$(mutant_scripts mutant-weekly-whole lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else $burn_default * 5 / 168 end' 'else $burn_default end'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: charged whole, the weekly-bound account is dropped|ORCH_LANE_DIRS=$H/.wclaude|claim:w:2||$PICK|rc=3 walled=1"

echo "=== the session window is charged to its reset whatever bucket binds ==="
# r is weekly-bound at 46 used with its session at 2, resetting in 4 hours; q
# is weekly-bound at 83 with its session at 5. Five claims on r charge its
# weekly window 0.74 and its session 5 x 5 x 4 = 100, so r projects past the
# threshold and the sixth lane goes to q. The resets are written against the
# suite clock just before the rows that read them.
NOW="$("$BIN/date" +%s)" || exit 1
make_lane "$H" rclaude 3600
jq -n --argjson now "$NOW" '{five_hour: {utilization: 2, resets_at: ($now + 14400 | todate)},
  seven_day: {utilization: 46, resets_at: ($now + 543600 | todate)}, limits: []}' > "$FIXTURE_DIR/.rclaude.json"
make_lane "$H" qclaude 3600
jq -n --argjson now "$NOW" '{five_hour: {utilization: 5, resets_at: ($now + 16200 | todate)},
  seven_day: {utilization: 83, resets_at: ($now + 288000 | todate)}, limits: []}' > "$FIXTURE_DIR/.qclaude.json"
RQ_DIRS="ORCH_LANE_DIRS=$H/.rclaude:$H/.qclaude"
table \
  "the sixth lane is not stacked on a weekly-bound account whose session the five on it spend before its reset|$RQ_DIRS|claim:r:5||$PICK|rc=0 config_dir=$H/.qclaude binding_bucket=weekly" \
  "the named projection refuses the stacked account on its session window|ORCH_LANE_DIRS=$H/.rclaude|claim:r:5||pick --lane $H/.rclaude --harness claude --projected --json|rc=3 binding_bucket=weekly projected_headroom_pct=-2 projected_window.bucket=session key=pick-lane-walled,lane=$H/.rclaude,wall=2,bucket=session,max-pct=95,projected-headroom=-2" \
  "the same account with no claims keeps its room and is picked|$RQ_DIRS|||$PICK|rc=0 config_dir=$H/.rclaude"

# The deciding window as the real output names it: the listing and the
# chooser's refusal date r's wall to its session reset, four hours out, not
# its weekly one. o is walled on its Opus window at 97, resetting in two days,
# and on its Sonnet window at 96, resetting in one, with no lanes on it and
# room on its session and weekly windows: a pick on Sonnet dates its wall to
# the Sonnet reset, where a pick naming no model judges the most-consumed
# Opus window and dates it a day later.
R_SESSION_RESET="$(jq -nr --argjson now "$NOW" '$now + 14400 | todate')" || exit 1
O_OPUS_RESET="$(jq -nr --argjson now "$NOW" '$now + 172800 | todate')" || exit 1
O_SONNET_RESET="$(jq -nr --argjson now "$NOW" '$now + 86400 | todate')" || exit 1
make_lane "$H" oclaude 3600
jq -n --argjson now "$NOW" '{five_hour: {utilization: 10, resets_at: ($now + 10800 | todate)},
  seven_day: {utilization: 20, resets_at: ($now + 432000 | todate)},
  limits: [{kind: "weekly_scoped", percent: 97, resets_at: ($now + 172800 | todate), scope: {model: {display_name: "Opus"}}},
    {kind: "weekly_scoped", percent: 96, resets_at: ($now + 86400 | todate), scope: {model: {display_name: "Sonnet"}}}]}' \
  > "$FIXTURE_DIR/.oclaude.json"
table \
  "the listing names the session window that decided r and its reset|ORCH_LANE_DIRS=$H/.rclaude|claim:r:5||list --harness claude --json|rc=0 [0].projected_window.bucket=session [0].projected_window.resets_at=$R_SESSION_RESET" \
  "the chooser's refusal dates r's wall to its session reset|ORCH_LANE_DIRS=$H/.rclaude|claim:r:5||$PICK|rc=3 walled=1 walled_resets_at=$R_SESSION_RESET" \
  "a pick on Sonnet dates o's wall to the Sonnet window's reset|ORCH_LANE_DIRS=$H/.oclaude|||$PICK --model sonnet|rc=3 walled=1 walled_resets_at=$O_SONNET_RESET" \
  "a pick naming no model dates o's wall to the most-consumed Opus window's reset|ORCH_LANE_DIRS=$H/.oclaude|||$PICK|rc=3 walled=1 walled_resets_at=$O_OPUS_RESET"
# u is weekly-bound at 90 with its session at 80 and no session reset: five
# lanes wall it on the session window, charged one hour each, and a wall
# whose deciding reset nobody stated is undated rather than dated to the
# weekly reset. Its control lets the weekly reset stand in.
make_lane "$H" uclaude 3600
jq -n --argjson now "$NOW" '{five_hour: {utilization: 80, resets_at: null},
  seven_day: {utilization: 90, resets_at: ($now + 288000 | todate)}, limits: []}' > "$FIXTURE_DIR/.uclaude.json"
table \
  "a session wall with no stated reset is undated, not dated to the weekly reset|ORCH_LANE_DIRS=$H/.uclaude|claim:u:5||$PICK|rc=3 walled=1 walled_resets_at=null"
CTRL="$(mutant_scripts mutant-reset-stand-in lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'if .projected_window == null then .binding_resets_at else .projected_window.resets_at end' '.projected_window.resets_at // .binding_resets_at'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: the binding reset standing in dates an unknown session wall to the weekly reset|ORCH_LANE_DIRS=$H/.uclaude|claim:u:5||$PICK|rc=3 walled=1 walled_resets_at=$(jq -nr --argjson now "$NOW" '$now + 288000 | todate')"
# Control: with no deciding window in the output, r's wall dates to the
# weekly reset days away.
CTRL="$(mutant_scripts mutant-window-unnamed lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '         projected_window:
           (if $binding_room == null then null' '         projected_window:
           (if true then null'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without the deciding window the refusal dates r's wall to its weekly reset|ORCH_LANE_DIRS=$H/.rclaude|claim:r:5||$PICK|rc=3 walled=1 walled_resets_at=$(jq -nr --argjson now "$NOW" '$now + 543600 | todate')"

# Control: a refusal read from the binding bucket names the weekly window the
# lanes did not wall.
CTRL="$(mutant_scripts mutant-walled-binding lanes)" || exit 1
mutate_file "$CTRL/lanes" "'if \$p and .projected_window != null then .projected_window.bucket else .binding_bucket end'" "'.binding_bucket'"
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: the named refusal read from the binding bucket names the weekly window|ORCH_LANE_DIRS=$H/.rclaude|claim:r:5||pick --lane $H/.rclaude --harness claude --projected --json|rc=3 key=pick-lane-walled,lane=$H/.rclaude,wall=2,bucket=weekly,max-pct=95,projected-headroom=-2"
# Control: projected on the binding bucket alone, the stacked account keeps
# its weekly room and takes the sixth lane.
CTRL="$(mutant_scripts mutant-session-unprojected lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else 100 - .session_5h_pct - .claims * $session_burn * $session_hours end) as $session_room' 'else null end) as $session_room'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: with no session projection the sixth lane stacks on the weekly-bound account|$RQ_DIRS|claim:r:5||$PICK|rc=0 config_dir=$H/.rclaude"
# Control: the session charged one hour per claim projects 73, above the
# weekly room, so the account still takes the sixth lane.
CTRL="$(mutant_scripts mutant-session-one-hour lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else [1, ([5, ($session_reset - $now) / 3600] | min)] | max end) as $session_hours' 'else 1 end) as $session_hours'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: a session charged one hour per claim still stacks the sixth lane|$RQ_DIRS|claim:r:5||$PICK|rc=0 config_dir=$H/.rclaude"

# The launch keeps the reading it was judged on in the lane record. q has no
# claims, so its rooms are its readings, 17 weekly and 95 session, and its
# session charge runs the 4.5 hours to its reset; the score is 17 weighted by
# the 80 hours to the weekly reset. A named lane keeps its judge's reading,
# which no score ranks: two claims on r charge its session 2 x 5 x 4.
SIXTH_RECORD="rc=0 record.account=$H/.qclaude record.pick.account=$H/.qclaude record.pick.binding_bucket=weekly record.pick.claims=0 record.pick.binding_projected_headroom_pct=17 record.pick.session_projected_headroom_pct=95 record.pick.session_burn_pct_per_lane_hour=5 record.pick.session_charge_hours=4.5 record.pick.projected_headroom_pct=17 score_hundredths=1721"
table \
  "the sixth lane's launch records the pick reading it was launched on|$RQ_DIRS|claim:r:5||launch-fleet auto|$SIXTH_RECORD" \
  "a named lane's launch records the reading its judge took|ORCH_LANE_DIRS=$H/.rclaude|claim:r:2||launch-fleet $H/.rclaude|rc=0 record.account=$H/.rclaude record.pick.account=$H/.rclaude record.pick.claims=2 record.pick.session_projected_headroom_pct=58 record.pick.selection_score=null"
# Control: a lane record that drops the pick turns the sixth-lane row red.
CTRL="$(mutant_scripts mutant-pick-unrecorded open-terminal)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/mutant-pick-unrecorded"
mutate_file "$CTRL/open-terminal" '+ (if $pick == null then {} else {pick:' '+ (if true then {} else {pick:'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: a record without the pick reading names no pick|$RQ_DIRS|claim:r:5||launch-fleet auto|rc=0 record.account=$H/.qclaude record.pick.account=null"

echo "=== an unread claim store is a notice for the reading and a refusal for the projection ==="
table \
  "a named lane read without --projected notices the unread store and answers the wall|ORCH_LANE_DIRS=$H/.aclaude|store:file||pick --lane $H/.aclaude --harness claude --json|rc=0 claims=null projected_headroom_pct=null key=pick-lane-claims,claims=null" \
  "a named lane judged --projected refuses an unread store with 6 before judging|ORCH_LANE_DIRS=$H/.aclaude|store:file||pick --lane $H/.aclaude --harness claude --projected --json|rc=6 out= key=pick-lane-claims-refused,lane=$H/.aclaude"

# Control: without the refusal the projection nobody could make is judged,
# and only the unmeasured null keeps it from reading as no lanes in flight.
CTRL="$(mutant_scripts mutant-store-notice lanes)" || exit 1
mutate_file "$CTRL/lanes" 'return 6' ':'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without the refusal the unread store reaches the judge|ORCH_LANE_DIRS=$H/.aclaude|store:file||pick --lane $H/.aclaude --harness claude --projected --json|rc=5"

echo "=== selection charges projected room, not the reading ==="
# a and b carry one claim each. a reads more room, 80 to b's 70, but its
# measured rate of half a point a minute projects 50 against b's default 65.
table \
  "with claims tied, the projected room decides, not the reading|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1;claim:b:1|a:20:15|$PICK|rc=0 config_dir=$H/.bclaude projected_headroom_pct=65"
# The equal-room row stages b at a's 20 percent.
claude_usage 20 10 5 Opus > "$FIXTURE_DIR/.bclaude.json"
table \
  "two seats with equal room pick the one with fewer live claims|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1||$PICK|rc=0 config_dir=$H/.bclaude"
claude_usage 30 10 5 Opus > "$FIXTURE_DIR/.bclaude.json"

# Control: ordered on the reading once the claims tie, the seat the lanes on it
# are spending fastest is returned.
CTRL="$(mutant_scripts mutant-rank-wall lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'sort_by([._tier, ._expires, (._score | neg), .claims, (.projected_headroom_pct | neg), .wall])' 'sort_by([.wall])'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: ranked on the reading, the tie goes to the seat burning fastest|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1;claim:b:1|a:20:15|$PICK|rc=0 config_dir=$H/.aclaude projected_headroom_pct=50"

echo "=== a window-account chooser never returns an overseer seat ==="
# a has the most room and no claim, so only the seat rule keeps it out.
table \
  "the seat this checkout's fleet records for its overseer is never returned|$ALL_DIRS|own:a||$PICK|rc=0 config_dir=$H/.bclaude" \
  "a peer fleet's overseer seat is omitted while the remaining accounts compete on projected room|$ALL_DIRS|peer:a;claim:b:1:peer||$PICK|rc=0 config_dir=$H/.bclaude" \
  "--for-overseer keeps the seat, for a pick that seats an overseer|$ALL_DIRS|own:a||$PICK --for-overseer|rc=0 config_dir=$H/.aclaude" \
  "a claim naming a fleet state that is gone holds no seat|$ALL_DIRS|claim:b:1:gone||$PICK|rc=0 config_dir=$H/.aclaude" \
  "a fleet state that cannot be read refuses the pick, naming the step and the state|$ALL_DIRS|own:broken||$PICK|rc=1 seatrefusal=named" \
  "an overseer seat that is the only account leaves nothing to pick, and the refusal counts and names it|ORCH_LANE_DIRS=$H/.aclaude|own:a||$PICK|rc=3 walled=0 unmeasured=0 seats=1 key=no-candidate,harness=claude,max-pct=95,model=none,walled=0,unmeasured=0,seats=1 keyed.pick-seat-omitted=pick-seat-omitted,lane=$H/.aclaude" \
  "a pick with room names no seat|$ALL_DIRS|own:a||$PICK|rc=0 keyed.pick-seat-omitted=none" \
  "the named form judges the account it is given, seat or not|$ALL_DIRS|own:a||pick --lane $H/.aclaude --harness claude --json|rc=0 config_dir=$H/.aclaude" \
  "--for-overseer is refused beside --lane, which omits nothing|$ALL_DIRS|||pick --lane $H/.aclaude --harness claude --for-overseer|rc=1 key=unknown-option,arg1=--for-overseer"

# Control: a chooser that omits no seat hands the overseer's account out.
CTRL="$(mutant_scripts mutant-no-seats lanes)" || exit 1
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutate_file "$CTRL/lanes" '"$exclude"$'"'"'\n'"'"'"$SEATS"' '"$exclude"'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: with no seat omitted, the overseer's account is returned|$ALL_DIRS|own:a||$PICK|rc=0 config_dir=$H/.aclaude" \
  "control: with no seat omitted, the peer overseer's account is returned|$ALL_DIRS|peer:a;claim:b:1:peer||$PICK|rc=0 config_dir=$H/.aclaude"

echo "=== pool picks keep overseer seats and charge monthly claims ==="
mkdir -p "$H/.acopilot/session-state" "$H/.api"
CP_ENV="ORCH_LANE_DIRS=$H/.acopilot;ORCH_LANE_COPILOT_POOL=$H/.acopilot"
ACCOUNT_HARNESS=copilot table \
  "the only Copilot account is the overseer seat and remains pickable|$CP_ENV=10/100|own:a||pick --harness copilot|rc=0 out=COPILOT_HOME=$H/.acopilot" \
  "a pool seat carries the monthly headroom and burns its live claim|$CP_ENV=10/100|own:a;claim:a:1||pick --harness copilot --json|rc=0 effective_headroom_pct=90 binding_bucket=monthly claims=1 burn_pct_per_lane_hour=0.034722222222222224" \
  "a pool at the threshold is walled, not omitted|$CP_ENV=95/100|own:a||pick --harness copilot --json|rc=3 walled=1 seats=0 keyed.pick-seat-omitted=none" \
  "a pool past the threshold is walled, not omitted|$CP_ENV=96/100|own:a||pick --harness copilot --json|rc=3 walled=1 seats=0" \
  "a pool pick reads no fleet seat state|$CP_ENV=10/100|own:broken||pick --harness copilot --json|rc=0 effective_headroom_pct=90"
ACCOUNT_HARNESS=pi table \
  "a Pi pool pick keeps its overseer seat|ORCH_LANE_COPILOT_POOL=$H/.api=10/100|own:a||pick --harness pi --model github-copilot/gpt-5 --json|rc=0 config_dir=$H/.api effective_headroom_pct=90" \
  "a Pi pool pick reads no fleet seat state|ORCH_LANE_COPILOT_POOL=$H/.api=10/100|own:broken||pick --harness pi --model github-copilot/gpt-5 --json|rc=0 effective_headroom_pct=90"
CTRL="$(mutant_scripts mutant-pool-seats lanes)" || exit 1
# shellcheck disable=SC2016
mutate_file "$CTRL/lanes" '"$for_overseer" != true && "$harness" != copilot && "$harness" != pi' '"$for_overseer" != true && "$harness" != pi'
LANES_UNDER_TEST="$CTRL/lanes" ACCOUNT_HARNESS=copilot table \
  "control: restoring Copilot seat omission drops the only pool account|$CP_ENV=10/100|own:a||pick --harness copilot --json|rc=3 walled=0 seats=1 keyed.pick-seat-omitted=pick-seat-omitted,lane=$H/.acopilot"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
