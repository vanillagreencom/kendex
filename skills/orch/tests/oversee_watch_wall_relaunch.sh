#!/usr/bin/env bash
# Tests for the usage-limit route oversee-watch runs itself (wall_route): a lane
# the judge reads walled is relaunched on an account `lanes pick` qualifies for
# the model its record names, and usage-limit goes out only where none does or
# under ORCH_WALL_RELAUNCH=ask. What the watch reads off the banner is
# oversee_watch_usage_limit.sh's; this suite builds the same sandbox from
# lib/oversee-watch-harness.sh.
#
# One table. A row names the screen gh-2 shows, what `lanes pick` answers and
# the setting, and the facts the run must show; `facts` reads exactly those.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

RESET_NOW=1788364800
BANNER="You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)"
COMPOSER='\xe2\x9d\xaf\xc2\xa0'
SPENT=/home/me/.eclaude
FRESH=/home/me/.fclaude
MODEL=claude-opus-5-5

# The relaunch the watch starts detached: its argv, one word a line, lands in
# open-terminal.args, and it then stays running while open-terminal-hold
# exists, for at most ten seconds, as a launch still opening its window.
cat > "$TMP_ROOT/bin/open-terminal-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_DIR/open-terminal.args.tmp"
mv -- "$STUB_DIR/open-terminal.args.tmp" "$STUB_DIR/open-terminal.args"
n=0
while [[ -f "$STUB_DIR/open-terminal-hold" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
EOF
chmod +x "$TMP_ROOT/bin/open-terminal-stub.sh"

# stage SCREEN PICK — gh-2 claimed on SPENT by pane %3 and recorded running
# KEN-2 on claude MODEL; SCREEN `walled` is the account's banner under the
# composer and `working` a turn in flight printing the same words; PICK is
# `fresh` (FRESH qualifies), `spent` (the pick hands back SPENT) or `none`.
stage() {
  new_case "wall_$((++CASE_SEQ))"
  printf '900 %%3\n' > "$STUB_DIR/panes.txt"
  printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
  mkdir -p "$STATE_DIR/claims"
  printf '900\t%%3\t%s\tgh-2\t2026-08-16T00:00:00Z\n' "$SPENT" > "$STATE_DIR/claims/a.claim"
  jq -n --arg spent "$SPENT" --arg model "$MODEL" '{triaged: [], lanes: [{item: "KEN-2", tracker: "linear",
    window: "gh-2", harness: "claude", model: $model, effort: "high", account: $spent, status: "running"}]}' \
    > "$STUB_DIR/oversee-state.json"
  case "$1" in
    walled) printf '%b\n' '⏺ Working through the queue.' "$BANNER" "$COMPOSER" > "$STUB_DIR/pane-gh-2.txt" ;;
    working) printf '%b\n' '⏺ Reading the suite.' "  printf \"$BANNER\"" 'esc to interrupt' > "$STUB_DIR/pane-gh-2.txt" ;;
    *) echo "stage: unknown screen $1" >&2; exit 1 ;;
  esac
  case "$2" in
    fresh) printf '{"config_dir":"%s"}\n' "$FRESH" > "$STUB_DIR/pick-claude-$MODEL.json" ;;
    spent) printf '{"config_dir":"%s"}\n' "$SPENT" > "$STUB_DIR/pick-claude-$MODEL.json" ;;
    none) printf '{"walled":1,"unmeasured":0,"seats":0,"qualifying_count":0,"walled_resets_at":null}\n' > "$STUB_DIR/pick-claude-$MODEL.json"
      printf '3' > "$STUB_DIR/pick-claude-$MODEL.rc" ;;
    *) echo "stage: unknown pick $2" >&2; exit 1 ;;
  esac
  printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
}

# The detached relaunch is waited for by its own file, under a deadline: a row
# expecting none reads the absence after the same wait.
relaunch_args() {
  local n=0
  while [[ ! -f "$STUB_DIR/open-terminal.args" && "$n" -lt 50 ]]; do sleep 0.1; n=$((n + 1)); done
  if [[ -f "$STUB_DIR/open-terminal.args" ]]; then paste -sd' ' - < "$STUB_DIR/open-terminal.args"; else echo none; fi
}

# facts EXPECT — the run's value of every field EXPECT names, in its order (in
# a needle `+` reads as a space and %e as `=`):
#   rc         exit status            first   the first stdout line, or none
#   second     the second stdout line  out~T  whether stdout carries T
#   err~T      whether stderr carries T
#   pick       the --exclude-lane the pick named, `none` with no pick
#   killed     the kill-window targets, `none` with no kill
#   relaunch~T whether the relaunch argv carries T, `false` with no relaunch
facts() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    needle="${name#*~}"; needle="${needle//+/ }"; needle="${needle//%e/=}"
    case "$name" in
      rc) value="$RC" ;;
      first) value="$(sed -n 1p <<<"$OUT")"; value="${value:-none}"; value="${value// /+}" ;;
      second) value="$(sed -n 2p <<<"$OUT")"; value="${value:-none}"; value="${value// /+}" ;;
      out~*) value="$(grep -qF -- "$needle" <<<"$OUT" && echo true || echo false)" ;;
      err~*) value="$(grep -qF -- "$needle" "$ERR" && echo true || echo false)" ;;
      pick) value="$(awk '$1 == "pick" { for (i = 2; i < NF; i++) if ($i == "--exclude-lane") print $(i + 1) }' \
              "$STUB_DIR/lanes.args" 2>/dev/null)"; value="${value:-none}" ;;
      killed) value=none; [[ ! -f "$STUB_DIR/kill-window.calls" ]] || value="$(paste -sd, - < "$STUB_DIR/kill-window.calls")" ;;
      relaunch~*) value="$(relaunch_args)"; [[ "$value" == none ]] && value=false \
              || value="$(grep -qF -- "$needle" <<<"$value" && echo true || echo false)" ;;
      *) echo "facts: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# wall_table ROW... — `label|screen|pick|setting|expect`, setting the
# ORCH_WALL_RELAUNCH value or `-` for none.
CASE_SEQ=0
RUN_SEQ=0
wall_table() {
  local row label screen pick setting expect env
  for row in "$@"; do
    IFS='|' read -r label screen pick setting expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'wall_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    stage "$screen" "$pick"
    env=(TZ=UTC OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh")
    [[ "$setting" == - ]] || env+=(ORCH_WALL_RELAUNCH="$setting")
    ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
    OUT="$(run_watch "${env[@]}" -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>"$ERR")" && RC=0 || RC=$?
    assert_eq "$(facts "$expect")" "$expect" "$label" "$ERR"
  done
}

RELAUNCHED="EVENT+lane-relaunched+KEN-2+lane=$FRESH+from=$SPENT"
USAGE_LIMIT="EVENT+usage-limit+gh-2+$SPENT+resets=2026-09-02T16:50:00Z"
ROW_RELAUNCH="a walled lane with a qualifying pick is relaunched there and named, never reported as usage-limit|walled|fresh|-|rc=0 first=$RELAUNCHED out~EVENT+usage-limit=false pick=$SPENT killed=%3 relaunch~--relaunch=true relaunch~--lane+$FRESH=true relaunch~--model+$MODEL+--effort+high+--dangerously-skip-permissions=true relaunch~KEN-2=true"
ROW_SPENT="the spent account handed back is refused, and the wall goes to the overseer|walled|spent|auto|rc=0 first=$USAGE_LIMIT second=pick+lane=$SPENT err~reason%espent-account=true killed=none relaunch~--relaunch=false"

echo "=== the watch owns the usage-limit route ==="
wall_table "$ROW_RELAUNCH" \
  "a walled lane no account qualifies for is usage-limit with its reset, the pick's answer under it|walled|none|auto|rc=0 first=$USAGE_LIMIT second=pick+none pick=$SPENT killed=none relaunch~--relaunch=false" \
  "a working lane printing limit text is left alone: no event, no pick, no kill|working|fresh|auto|rc=0 out~EVENT+usage-limit=false out~lane-relaunched=false pick=none killed=none relaunch~--relaunch=false" \
  "under ask the wall is usage-limit alone, with the pick's answer on the following line|walled|fresh|ask|rc=0 first=$USAGE_LIMIT second=pick+lane=$FRESH out~lane-relaunched=false killed=none relaunch~--relaunch=false" \
  "$ROW_SPENT"

new_case wall_setting_invalid
OUT="$(run_watch ORCH_WALL_RELAUNCH=maybe -- --max-loops 1 gh-1 gh-2 2>"$TMP_ROOT/invalid.err")" && RC=0 || RC=$?
assert_eq "$RC $(grep -c '^oversee-watch: wall-relaunch-invalid value=maybe$' "$TMP_ROOT/invalid.err" || true)" "2 1" \
  "a setting other than auto or ask stops the watch on its key"

# The window the relaunch killed is gone until the launch opens its new one:
# no window-gone while that launch runs, and window-gone once it ended without
# a window. GONE prints the second and third passes' window-gone counts.
gone_passes() {
  local n=0 second third
  stage walled fresh
  touch "$STUB_DIR/open-terminal-hold"
  run_watch TZ=UTC OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" -- --max-loops 1 \
    --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/gone.err" || return
  [[ "$(relaunch_args)" != none ]] || { echo "gone_passes: the relaunch never started" >&2; return 1; }
  printf 'gh-1\n' > "$STUB_DIR/windows.txt"
  second="$(run_watch TZ=UTC -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/gone.err" \
    | grep -c '^EVENT window-gone gh-2$' || true)"
  rm -f -- "${STUB_DIR:?}/open-terminal-hold"
  while [[ ! -f "$STATE_DIR/wall-relaunch.gh-2.exit" && "$n" -lt 150 ]]; do sleep 0.1; n=$((n + 1)); done
  third="$(run_watch TZ=UTC -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/gone.err" \
    | grep -c '^EVENT window-gone gh-2$' || true)"
  printf '%s %s' "$second" "$third"
}
assert_eq "$(gone_passes)" "0 1" \
  "the relaunched lane's missing window is no window-gone while its launch runs, and is once the launch ended" "$TMP_ROOT/gone.err"

# wall_control NAME OLD NEW ROW — ROW, its label marked as a control, against
# a copy of the watch with OLD replaced by NEW once.
wall_control() {
  local scripts
  scripts="$(mutant_scripts "$1/orch" oversee-watch)" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$1/github"
  mutate_file "$scripts/oversee-watch" "$2" "$3"
  WATCH_BIN="$scripts/oversee-watch" wall_table "control: $4"
}
# The unpatched watch: the route never runs, so the first row is usage-limit.
wall_control unrouted '[[ "$event" == usage-limit ]] && wall_route' 'false && wall_route' \
  "${ROW_RELAUNCH%%|*}|walled|fresh|-|rc=0 first=$USAGE_LIMIT killed=none relaunch~--relaunch=false"
# Without its refusal the spent account is relaunched onto.
wall_control spent-unrefused '[[ "$(lane_claims_canon "$to")" != "$(lane_claims_canon "$spent")" ]]' 'true' \
  "${ROW_SPENT%%|*}|walled|spent|auto|rc=0 first=EVENT+lane-relaunched+KEN-2+lane=$SPENT+from=$SPENT killed=%3"

# Without the pending check the launch's own gap is reported as window-gone.
scripts="$(mutant_scripts gone-unheld/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gone-unheld/github"
mutate_file "$scripts/oversee-watch" ' && ! wall_relaunch_pending "$lane"' ''
assert_eq "$(WATCH_BIN="$scripts/oversee-watch" gone_passes)" "1 1" \
  "control: without the pending check the window a running relaunch is opening reads window-gone" "$TMP_ROOT/gone.err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
