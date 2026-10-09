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
printf '%s\n' "$PWD" > "$STUB_DIR/open-terminal.cwd"
printf '%s\n' "${ORCH_TMUX_SESSION:-unset}" > "$STUB_DIR/open-terminal.session"
printf '%s\n' "$@" > "$STUB_DIR/open-terminal.args.tmp"
mv -- "$STUB_DIR/open-terminal.args.tmp" "$STUB_DIR/open-terminal.args"
n=0
while [[ -f "$STUB_DIR/open-terminal-hold" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
exit "${STUB_RELAUNCH_EXIT:-0}"
EOF
chmod +x "$TMP_ROOT/bin/open-terminal-stub.sh"

# stage SCREEN PICK — gh-2 claimed on SPENT by pane %3 and recorded running
# KEN-2 on claude MODEL; SCREEN `walled` is the account's banner under the
# composer and `working` a turn in flight printing the same words; PICK is
# `fresh` (FRESH qualifies), `spent` (the pick hands back SPENT) or `none`.
stage() {
  local screen="${1%%:*}" profile="${1#*:}" harness=claude model="$MODEL" flags="--model $MODEL --effort high --permission-mode dontAsk" item=KEN-2 tracker=linear host="" cwd="$TMP_ROOT/repo" refresh=false
  PROFILE_ENV=()
  new_case "wall_$((++CASE_SEQ))"
  printf '900 %%3\n' > "$STUB_DIR/panes.txt"
  printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
  mkdir -p "$STATE_DIR/claims"
  printf '900\t%%3\t%s\tgh-2\t2026-08-16T00:00:00Z\n' "$SPENT" > "$STATE_DIR/claims/a.claim"
  case "$profile" in
    github) item=issue-2; tracker=github ;;
    hosted|hosted-legacy|stop-failed|stop-unconfirmed) host="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
      mkdir -p "$STUB_DIR/host/srv/lane/tmp/lane-mail/$item" "$STUB_DIR/host/srv/clone/tmp"
      printf 'gitdir: /srv/clone/.git/worktrees/%s\n' "$item" > "$STUB_DIR/host/srv/lane/.git"
      PROFILE_ENV=(LANE_HOST_STUB_LOG="$STUB_DIR/host.calls" LANE_HOST_STUB_DIR="$STUB_DIR/host")
      [[ "$profile" != stop-failed ]] || PROFILE_ENV+=(LANE_HOST_STUB_STOP_STATUS=1)
      [[ "$profile" != stop-unconfirmed ]] || PROFILE_ENV+=(LANE_HOST_STUB_STOP_OUT=unconfirmed) ;;
    peer) cwd="$STUB_DIR/peer"; mkdir -p "$cwd" ;;
    refresh) refresh=true ;;
    codex) harness=codex; model=gpt-5; flags='-m gpt-5 -c model_reasoning_effort=high --ask-for-approval never' ;;
    copilot) harness=copilot; flags='--model claude-opus-5-5 --reasoning-effort high --allow-all-tools' ;;
    pi) harness=pi; model=pi-claude/claude-opus-5-5; flags='--model pi-claude/claude-opus-5-5 --thinking high' ;;
    legacy|checkout-gone|walled|working) ;;
    *) echo "stage: unknown profile $profile" >&2; exit 1 ;;
  esac
  local mail_root="$STUB_DIR/tree"
  [[ -z "$host" ]] || mail_root=/srv/lane
  mkdir -p "$STUB_DIR/tree/tmp/lane-mail/$item"
  if [[ "$harness" == pi ]]; then
    printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"error","message":"429 Usage limit reached for this model"}' \
      > "$mail_root/tmp/lane-mail/$item/session-rows.jsonl"
  fi
  jq -n --arg spent "$SPENT" --arg model "$model" --arg harness "$harness" --arg flags "$flags" --arg root "$mail_root" \
    --arg item "$item" --arg tracker "$tracker" --arg cwd "$cwd" --arg host "$host" --argjson refresh "$refresh" \
    '{triaged: [], lanes: [{item: $item, tracker: $tracker, repo: "owner/repo",
      host: (if $host == "" then null else $host end),
      window: "gh-2", harness: $harness, mail_root: $root, model: $model, effort: "high", account: $spent, status: "running",
      recovery: {cwd: $cwd, flags: $flags, session: "main", refresh: $refresh}}]}' \
    > "$STUB_DIR/oversee-state.json"
  case "$profile" in
    legacy|hosted-legacy) jq 'del(.lanes[].recovery)' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/edited"; mv "$STUB_DIR/edited" "$STUB_DIR/oversee-state.json" ;;
    checkout-gone) jq '.lanes[].recovery.cwd += "/removed"' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/edited"; mv "$STUB_DIR/edited" "$STUB_DIR/oversee-state.json" ;;
  esac
  case "$screen" in
    walled) printf '%b\n' '⏺ Working through the queue.' "$BANNER" "$COMPOSER" > "$STUB_DIR/pane-gh-2.txt" ;;
    working) printf '%b\n' '⏺ Reading the suite.' "  printf \"$BANNER\"" 'esc to interrupt' > "$STUB_DIR/pane-gh-2.txt" ;;
    *) echo "stage: unknown screen $1" >&2; exit 1 ;;
  esac
  local pick_file="$STUB_DIR/pick-$harness-$model"
  mkdir -p "${pick_file%/*}"
  case "$2" in
    fresh) printf '{"config_dir":"%s"}\n' "$FRESH" > "$pick_file.json" ;;
    spent) printf '{"config_dir":"%s"}\n' "$SPENT" > "$pick_file.json" ;;
    none) printf '{"walled":1,"unmeasured":0,"seats":0,"qualifying_count":0,"walled_resets_at":null}\n' > "$pick_file.json"
      printf '3' > "$pick_file.rc" ;;
    failed) printf '1' > "$pick_file.rc" ;;
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
      stopped) value=0; [[ ! -f "$STUB_DIR/host.calls" ]] || value="$(grep -c '^stop ' "$STUB_DIR/host.calls" || true)" ;;
      cwd) relaunch_args >/dev/null; value="$(cat "$STUB_DIR/open-terminal.cwd")"; [[ "$value" != "$STUB_DIR/peer" ]] || value=peer ;;
      session) relaunch_args >/dev/null; value="$(cat "$STUB_DIR/open-terminal.session")" ;;
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
    env=(TZ=UTC OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" ${PROFILE_ENV[@]+"${PROFILE_ENV[@]}"})
    [[ "$setting" == - ]] || env+=(ORCH_WALL_RELAUNCH="$setting")
    ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
    OUT="$(run_watch "${env[@]}" -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>"$ERR")" && RC=0 || RC=$?
    assert_eq "$(facts "$expect")" "$expect" "$label" "$ERR"
  done
}

RELAUNCHED="EVENT+lane-relaunched+KEN-2+lane=$FRESH+from=$SPENT"
USAGE_LIMIT="EVENT+usage-limit+gh-2+$SPENT+resets=2026-09-02T16:50:00Z"
ROW_RELAUNCH="a walled lane with a qualifying pick preserves its permission choice, host and session|walled|fresh|-|rc=0 first=$RELAUNCHED out~EVENT+usage-limit=false pick=$SPENT killed=none relaunch~--relaunch=true relaunch~--lane+$FRESH=true relaunch~--model+$MODEL+--effort+high+--permission-mode+dontAsk=true relaunch~--host+local=true relaunch~--continue-resume=true session=main relaunch~KEN-2=true"
ROW_SPENT="the spent account handed back is refused, and the wall goes to the overseer|walled|spent|auto|rc=0 first=$USAGE_LIMIT second=pick+lane=$SPENT err~reason%espent-account=true killed=none relaunch~--relaunch=false"

echo "=== the watch owns the usage-limit route ==="
wall_table "$ROW_RELAUNCH" \
  "a walled lane no account qualifies for is usage-limit with its reset, the pick's answer under it|walled|none|auto|rc=0 first=$USAGE_LIMIT second=pick+none pick=$SPENT killed=none relaunch~--relaunch=false" \
  "a working lane printing limit text is left alone: no event, no pick, no kill|working|fresh|auto|rc=0 out~EVENT+usage-limit=false out~lane-relaunched=false pick=none killed=none relaunch~--relaunch=false" \
  "under ask the wall is usage-limit alone, with the pick's answer on the following line|walled|fresh|ask|rc=0 first=$USAGE_LIMIT second=pick+lane=$FRESH out~lane-relaunched=false killed=none relaunch~--relaunch=false" \
  "$ROW_SPENT" \
  "a failed account read cannot start a replacement|walled|failed|auto|rc=0 second=pick+unjudged+exit=1 killed=none relaunch~--relaunch=false" \
  "a legacy record cannot replace unknown original permissions|walled:legacy|fresh|auto|rc=0 out~EVENT+usage-limit=true err~cause%epermission-choice-unrecorded=true killed=none relaunch~--relaunch=false" \
  "a removed launch checkout keeps the original lane|walled:checkout-gone|fresh|auto|rc=0 out~EVENT+usage-limit=true err~cause%echeckout-unavailable=true killed=none relaunch~--relaunch=false" \
  "a peer checkout remains the launch directory|walled:peer|fresh|auto|rc=0 cwd=peer relaunch~--host+local=true" \
  "an authorized refresh lane carries its refresh option|walled:refresh|fresh|auto|rc=0 relaunch~--lane-refresh=true" \
  "GitHub recovery converts the state item to the launcher number|walled:github|fresh|auto|rc=0 first=EVENT+lane-relaunched+issue-2+lane=$FRESH+from=$SPENT relaunch~--tracker+github=true relaunch~--repo+owner/repo=true relaunch~issue-2=false relaunch~2=true" \
  "Codex recovery keeps its restricted approval choice|walled:codex|fresh|auto|rc=0 relaunch~--ask-for-approval+never=true relaunch~--dangerously-bypass-approvals-and-sandbox=false" \
  "Copilot recovery keeps tools-only permission|walled:copilot|fresh|auto|rc=0 relaunch~--allow-all-tools=true relaunch~--yolo=false" \
  "Pi recovery keeps its provider model and session options|walled:pi|fresh|auto|rc=0 relaunch~--model+pi-claude/claude-opus-5-5+--thinking+high=true" \
  "a hosted recovery stops the old harness before launching|walled:hosted|fresh|auto|rc=0 stopped=1 relaunch~--relaunch=true killed=none" \
  "unknown original hosted choices refuse before stop|walled:hosted-legacy|fresh|auto|rc=0 stopped=0 out~EVENT+usage-limit=true relaunch~--relaunch=false" \
  "a hosted stop failure keeps the window and refuses replacement|walled:stop-failed|fresh|auto|rc=0 stopped=1 err~reason%estop-failed=true killed=none relaunch~--relaunch=false" \
  "a stop without confirmation cannot start a replacement|walled:stop-unconfirmed|fresh|auto|rc=0 stopped=1 err~reason%estop-failed=true killed=none relaunch~--relaunch=false"

new_case wall_setting_invalid
OUT="$(run_watch ORCH_WALL_RELAUNCH=maybe -- --max-loops 1 gh-1 gh-2 2>"$TMP_ROOT/invalid.err")" && RC=0 || RC=$?
assert_eq "$RC $(grep -c '^oversee-watch: wall-relaunch-invalid value=maybe$' "$TMP_ROOT/invalid.err" || true)" "2 1" \
  "a setting other than auto or ask stops the watch on its key"

# A replacement can temporarily have no visible window:
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

# The old pane remains visible while the launcher prepares its replacement.
# Later passes must keep the same recovery, even if its wall still shows.
held_passes() {
  local second third n=0
  stage walled fresh
  touch "$STUB_DIR/open-terminal-hold"
  run_watch OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" -- \
    --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/held.err" || return
  [[ "$(relaunch_args)" != none ]] || return 1
  second="$(run_watch OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" -- \
    --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/held.err")" || return
  third="$(run_watch OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" -- \
    --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/held.err")" || return
  rm -f -- "${STUB_DIR:?}/open-terminal-hold"
  while [[ ! -f "$STATE_DIR/wall-relaunch.gh-2.exit" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
  printf '%s' "$(grep -c '^EVENT lane-relaunched ' <<<"$second" || true) $(grep -c '^EVENT lane-relaunched ' <<<"$third" || true)"
}
assert_eq "$(held_passes)" '0 0' \
  'later passes leave the recovery running while the old pane still shows its wall' "$TMP_ROOT/held.err"

stuck_passes() {
  local second third n=0
  stage walled fresh
  touch "$STUB_DIR/open-terminal-hold"
  run_watch ORCH_WATCH_PREPARE_SECS=1 OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" -- \
    --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/stuck.err" || return
  [[ "$(relaunch_args)" != none ]] || return 1
  printf '%s' "$((RESET_NOW + 2))" > "$STUB_DIR/now.epoch"
  second="$(run_watch ORCH_WATCH_PREPARE_SECS=1 -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/stuck.err")" || return
  third="$(run_watch ORCH_WATCH_PREPARE_SECS=1 -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/stuck.err")" || return
  rm -f -- "${STUB_DIR:?}/open-terminal-hold"
  while [[ ! -f "$STATE_DIR/wall-relaunch.gh-2.exit" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
  printf '%s' "$(grep -c '^EVENT lane-prepare-stuck KEN-2 .* reason=relaunch-pending$' <<<"$second" || true) $(grep -c '^EVENT lane-prepare-stuck ' <<<"$third" || true)"
}
assert_eq "$(stuck_passes)" '1 0' \
  'an overdue detached recovery reports its log once even when the old window survives' "$TMP_ROOT/stuck.err"

# The launcher can fail its record write after starting a healthy harness.
# Its completed status, not disappearance of the window, must cause the event.
failure_passes() {
  local marker n=0 second third
  stage walled fresh
  run_watch STUB_RELAUNCH_EXIT=1 OVERSEE_WATCH_OPEN_TERMINAL="$TMP_ROOT/bin/open-terminal-stub.sh" -- \
    --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/failure.err" || return
  marker="$STATE_DIR/wall-relaunch.gh-2"
  while [[ ! -f "$marker.exit" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
  [[ -f "$marker.exit" ]] || { echo "failure_passes: the launch has no completed status" >&2; return 1; }
  second="$(run_watch -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/failure.err")" || return
  third="$(run_watch -- --max-loops 1 --state "$STUB_DIR/oversee-state.json" gh-1 gh-2 2>>"$TMP_ROOT/failure.err")" || return
  printf '%s %s %s' \
    "$(grep -cxF "EVENT lane-prepare-failed KEN-2 reason=relaunch-failed exit=1 log=$STUB_DIR/wall-relaunch-KEN-2.log" <<<"$second" || true)" \
    "$(grep -c '^EVENT lane-prepare-failed ' <<<"$third" || true)" \
    "$([[ -f "$STUB_DIR/kill-window.calls" ]] && echo killed || echo retained)"
}
assert_eq "$(failure_passes)" '1 0 retained' \
  'a completed failed relaunch reports its exit and log once while retaining the surviving window' "$TMP_ROOT/failure.err"

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
  "${ROW_SPENT%%|*}|walled|spent|auto|rc=0 first=EVENT+lane-relaunched+KEN-2+lane=$SPENT+from=$SPENT killed=none"

wall_control pick-unrefused '    WALL_PICK="pick unjudged exit=$rc"
    [[ ! -s "$errf" ]] || cat -- "$errf" >&2
    return 1' '    WALL_PICK="pick unjudged exit=$rc"
    to=/home/me/.fclaude' \
  "a failed account read|walled|failed|auto|rc=0 first=$RELAUNCHED relaunch~--relaunch=true"
wall_control stop-unrefused '      ow_message wall-relaunch-refused "lane=$lane" reason=stop-failed "exit=$rc" >&2
      cat -- "$errf" >&2
      return 1' '      ow_message wall-relaunch-refused "lane=$lane" reason=stop-failed "exit=$rc" >&2' \
  "a failed hosted stop|walled:stop-failed|fresh|auto|rc=0 first=$RELAUNCHED relaunch~--relaunch=true"
wall_control stop-unconfirmed '|| ! grep -qE "^stopped item=$item processes=[0-9]+$" <<<"$out"' '|| false' \
  "a stop with no confirmation|walled:stop-unconfirmed|fresh|auto|rc=0 first=$RELAUNCHED relaunch~--relaunch=true"
wall_control context-unrefused '    ow_message wall-relaunch-refused "lane=$lane" reason=context-unavailable "cause=$LANE_RECOVERY_CAUSE" >&2
    return 1' '    ow_message wall-relaunch-refused "lane=$lane" reason=context-unavailable "cause=$LANE_RECOVERY_CAUSE" >&2
    return 0' \
  'an unknown original permission choice|walled:legacy|fresh|auto|rc=0 out~EVENT+usage-limit=false'

# Removing the launcher's context read makes the removed checkout look usable.
scripts="$(mutant_scripts checkout-unrefused/orch lib/lane-relaunch.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/checkout-unrefused/github"
mutate_file "$scripts/lib/lane-relaunch.sh" \
  'LANE_RECOVERY_CWD="$(cd -- "$LANE_RECOVERY_CWD" && pwd -P)" || return 1' \
  'LANE_RECOVERY_CWD="$PWD"'
WATCH_BIN="$scripts/oversee-watch" wall_table \
  "control: a removed launch checkout|walled:checkout-gone|fresh|auto|rc=0 first=$RELAUNCHED relaunch~--relaunch=true"

# The window replacement owner must receive the old window intact.
wall_control premature-kill '  # The exit status lands beside the marker, which ends wall_relaunch_pending.' \
  '  tmux kill-window -t "${4##* }"
  # The exit status lands beside the marker, which ends wall_relaunch_pending.' \
  "the launcher receives a pre-deleted window|walled|fresh|auto|rc=0 killed=%3"

# Without the pending check the launch's own gap is reported as window-gone.
scripts="$(mutant_scripts gone-unheld/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gone-unheld/github"
mutate_file "$scripts/oversee-watch" ' && ! wall_relaunch_pending "$lane"' ''
assert_eq "$(WATCH_BIN="$scripts/oversee-watch" gone_passes)" "1 1" \
  "control: without the pending check the window a running relaunch is opening reads window-gone" "$TMP_ROOT/gone.err"

scripts="$(mutant_scripts failure-unreported/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/failure-unreported/github"
mutate_file "$scripts/oversee-watch" '      if [[ "$rc" != 0 ]]; then' '      if false; then'
assert_eq "$(WATCH_BIN="$scripts/oversee-watch" failure_passes)" '0 0 retained' \
  'control: without completion reporting a failed relaunch leaves only the surviving window' "$TMP_ROOT/failure.err"

scripts="$(mutant_scripts held-restarted/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/held-restarted/github"
mutate_file "$scripts/oversee-watch" ' || ( "$event" == usage-limit && "$seen_reported" == lane-relaunched )' ''
assert_eq "$(WATCH_BIN="$scripts/oversee-watch" held_passes)" '1 1' \
  'control: without the recovery report identity each old-pane wall restarts the launch' "$TMP_ROOT/held.err"

scripts="$(mutant_scripts stuck-unreported/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/stuck-unreported/github"
mutate_file "$scripts/oversee-watch" 'elif (( PASS_NOW - since >= PREPARE_SECS )); then' 'elif false; then'
assert_eq "$(WATCH_BIN="$scripts/oversee-watch" stuck_passes)" '0 0' \
  'control: without the preparation bound a detached recovery can remain silent' "$TMP_ROOT/stuck.err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
