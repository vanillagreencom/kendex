#!/usr/bin/env bash
# Tests for how `lanes pick` spreads launches across accounts: every verdict
# charges each live claim on an account its expected burn, so an account whose
# room the lanes already on it will spend is dropped as a walled one is, by the
# chooser and by the named form alike; ties among the fewest claims break on
# that projected room; and the bare chooser never returns an overseer seat, an
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

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

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
cat > "$BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list-panes" ]] || exit 0
cat "$TMUX_PANES_FILE"
STUBEOF
chmod +x "$BIN/tmux"

# Three claude accounts: a at 20 percent used, b at 30, c at 60, each binding
# on its 5-hour window, and w binding on its weekly window at 86.
new_home spread
for lane in a:20 b:30 c:60; do
  make_lane "$H" "${lane%%:*}claude" 3600
  claude_usage "${lane#*:}" 10 5 Opus > "$FIXTURE_DIR/.${lane%%:*}claude.json"
done
make_lane "$H" wclaude 3600
claude_usage 10 86 5 Opus > "$FIXTURE_DIR/.wclaude.json"
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
      own:*) jq -n --arg a "$H/.${item#own:}claude" '{overseer: {account: $a}}' > "$FLEET/workflow-state-oversee.json" ;;
      peer:*) jq -n --arg a "$H/.${item#peer:}claude" '{overseer: {account: $a}}' > "$RUN/peer/workflow-state-oversee.json" ;;
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
            "$$" "$PANE_SEQ" "$H/.${lane}claude" "$PANE_SEQ" "$fleet" > "$STORE/claims/$PANE_SEQ.claim"
        done
        ;;
      *) echo "stage: unknown token in $item" >&2; exit 1 ;;
    esac
  done
}

# stage_rate LANE CURRENT PRIOR — LANE's cached figure at CURRENT percent on
# its 5-hour window, with a prior sample ten minutes earlier at PRIOR, so the
# run serves the figure and measures a rate of (CURRENT - PRIOR) / 10 percent a
# minute. The record is written by a listing first, so its name is the one
# `lanes` keys it on.
stage_rate() {
  local lane="$1" f now staged=no
  (cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
    ORCH_LANE_DIRS="$H/.${lane}claude" OVERSEE_WATCH_STATE_DIR="$STORE" TMUX_PANES_FILE="$RUN/panes" \
    PATH="$BIN:$PATH" "$LANES" list --json >/dev/null 2>&1)
  now="$(date +%s)"
  for f in "$STORE"/usage/*.json; do
    [[ -f "$f" && "$(jq -r '.config_dir' "$f")" == "$H/.${lane}claude" ]] || continue
    jq --argjson now "$now" --argjson current "$(claude_usage "$2" 10 5 Opus)" \
      --argjson prior "$(claude_usage "$3" 10 5 Opus)" \
      '.fetched_at = $now | .usage = $current | .prior = {fetched_at: ($now - 600), usage: $prior}' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f" && staged=yes
  done
  [[ "$staged" == yes ]] || { echo "stage_rate: no cached record for $lane" >&2; exit 1; }
}

# table ROW... — `label|env|stage|rate|args|expect`: env is `;`-separated
# `env` arguments, stage a stage SPEC, rate `LANE:CURRENT:PRIOR` or empty.
# expect is `name=value` tokens: rc, seatrefusal (`named` where the first keyed
# line is the pick-overseer-seats refusal naming the seat step and this run's
# own fleet state, else that line), keyed.KEY (the first keyed stderr line
# carrying KEY, in the form key takes, or none), key (the first keyed stderr line as
# `key,field=value,...`), out (stdout whole), or a field of the JSON record.
RUN_SEQ=0
table() {
  local row label env stage_spec rate args expect env_args got token name value rate_lane rate_now rate_prior
  for row in "$@"; do
    IFS='|' read -r label env stage_spec rate args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
    stage "$stage_spec"
    if [[ -n "$rate" ]]; then
      IFS=':' read -r rate_lane rate_now rate_prior <<<"$rate"
      stage_rate "$rate_lane" "$rate_now" "$rate_prior"
    fi
    env_args=()
    [[ -z "$env" ]] || IFS=';' read -ra env_args <<<"$env"
    # shellcheck disable=SC2086
    OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
      ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$STORE" ORCH_STATE_DIR="$FLEET" \
      TMUX_PANES_FILE="$RUN/panes" PATH="$BIN:$PATH" ${env_args[@]+"${env_args[@]}"} \
      "${LANES_UNDER_TEST:-$LANES}" $args 2>"$RUN/err")
    RC=$?
    got=""
    for token in $expect; do
      name="${token%%=*}"
      case "$name" in
        rc) value="$RC" ;;
        out) value="$OUT" ;;
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
  "the pick names the projection it chose on|$ALL_DIRS|claim:a:1;claim:b:1;claim:c:1||$PICK|rc=0 config_dir=$H/.aclaude claims=1 burn_pct_per_lane_hour=5 projected_headroom_pct=75" \
  "a named lane judged without --projected reads the wall, as a lane's own handoff mark and a lane close ask|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:4||pick --lane $H/.aclaude --harness claude --min-headroom-pct 3 --json|rc=0 wall=20 projected_headroom_pct=-40 key=none" \
  "--projected is refused without --lane, the chooser judging the projection always|$ALL_DIRS|||$PICK --projected|rc=1 key=unknown-option,arg1=--projected" \
  "a weekly-bound account is charged the default by its window's length and stays a candidate|ORCH_LANE_DIRS=$H/.wclaude|claim:w:2||$PICK|rc=0 config_dir=$H/.wclaude binding_bucket=weekly" \
  "a burn of 0 charges a claim nothing|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=0|claim:a:3||pick --lane $H/.aclaude --harness claude --projected --json|rc=0 projected_headroom_pct=80" \
  "a measured rate is shared out across the claims on the account|ORCH_LANE_DIRS=$H/.aclaude|claim:a:2|a:20:15|pick --lane $H/.aclaude --harness claude --json|rc=0 usage_rate_state=measured burn_pct_per_lane_hour=15 projected_headroom_pct=50" \
  "a measured rate with nothing claimed charges nothing and names the default burn|ORCH_LANE_DIRS=$H/.aclaude||a:20:15|pick --lane $H/.aclaude --harness claude --json|rc=0 burn_pct_per_lane_hour=5 projected_headroom_pct=80" \
  "the listing carries the projection beside the verdict of the reading, whose wall lifts at its reset|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||list --harness claude --json|rc=0 [0].verdict=room [0].projected_headroom_pct=-10"

# Control: a verdict read off the wall alone keeps the account the lanes on it
# will spend, in both pick forms.
CTRL="$(mutant_scripts mutant-wall-only lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else 100 - .projected_headroom_pct' 'else .wall'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: judged on the wall alone, the most-room seat is picked for its fewer claims|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1;claim:b:2|a:20:5|$PICK|rc=0 config_dir=$H/.aclaude" \
  "control: judged on the wall alone, the lone seat is picked|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||$PICK|rc=0 walled=null unmeasured=null" \
  "control: judged on the wall alone, the named lane has room|$ALL_DIRS;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:3||pick --lane $H/.aclaude --harness claude --projected --json|rc=0 wall=20 claims=3 projected_headroom_pct=-10 key=none"

# Control: a named lane judged on the projection whether asked or not refuses
# the lane whose reading has room, which every reader of the reading then
# acts on as a wall.
CTRL="$(mutant_scripts mutant-named-projected lanes)" || exit 1
mutate_file "$CTRL/lanes" '(if $projected then judged_wall else .wall end)' 'judged_wall'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: projected unasked, the named lane is refused at the handoff mark|ORCH_LANE_DIRS=$H/.aclaude;ORCH_LANE_BURN_PCT_PER_HOUR=30|claim:a:4||pick --lane $H/.aclaude --harness claude --min-headroom-pct 3 --json|rc=3"

# Control: the default charged whole against a weekly window drops the account
# with days of room left.
CTRL="$(mutant_scripts mutant-weekly-whole lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else $burn_default * 5 / 168 end' 'else $burn_default end'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: charged whole, the weekly-bound account is dropped|ORCH_LANE_DIRS=$H/.wclaude|claim:w:2||$PICK|rc=3 walled=1"

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

echo "=== among the fewest claims, the most projected room wins ==="
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
CTRL="$(mutant_scripts mutant-rank-wall lanes)" || exit 1
mutate_file "$CTRL/lanes" 'sort_by([.claims, (0 - .projected_headroom_pct), .wall])' 'sort_by([.claims, .wall])'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: ranked on the reading, the tie goes to the seat burning fastest|ORCH_LANE_DIRS=$H/.aclaude:$H/.bclaude|claim:a:1;claim:b:1|a:20:15|$PICK|rc=0 config_dir=$H/.aclaude projected_headroom_pct=50"

echo "=== the chooser never returns an overseer seat ==="
# a has the most room and no claim, so only the seat rule keeps it out.
table \
  "the seat this checkout's fleet records for its overseer is never returned|$ALL_DIRS|own:a||$PICK|rc=0 config_dir=$H/.bclaude" \
  "a peer fleet's overseer seat, found through its lane's claim, is never returned|$ALL_DIRS|peer:a;claim:b:1:peer||$PICK|rc=0 config_dir=$H/.cclaude" \
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
