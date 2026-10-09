#!/usr/bin/env bash
# open-terminal's launch=cloud-session arm, the claude-cloud host kind: the
# refusals of what a cloud session cannot take, tmux mode among them, the
# cloud-bundle-risk check, the item worktree and its pushed branch, the item's
# window opened in that worktree running `claude --cloud` interactively, never
# with -p or --print, under the lane's account through its launcher or the env
# prefix, naming the lane's model id and, as its one --cloud= description and
# with no --ref, the brief file closed by the session words, which the pane's
# shell reads from the worktree's git directory, with
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 and CCR_FORCE_BUNDLE cleared, no
# key sent before claude runs in the pane and nothing pasted after its launch
# line, the account read back once its composer is up and a refusal there
# naming the session the CLI already made, the CLI exiting before that as a
# failed launch unless it printed its session URL, a started session, while
# a claude under a launcher's shell is no exit and an unreadable process table
# stops the launch, the session id the claude.ai session URL in the pane
# carries, and the lane record naming
# the kind, the account, that id and the window, and the tier the brief's
# item-tier line states, a whole line, null with no line or two distinct ones,
# whatever orch words or quoted results the brief carries. The prompt the
# launch writes holds the item branch where the session words name it. A
# launch prints no cloud-card-owed line. A kind whose launch this build does
# not make refuses as kind-unbuilt.
#
# The suite runs a copy of open-terminal beside the real lane-host, which
# declares the claude-cloud line, in a temp git repo whose origin is a
# github.com URL; the worktree CLI, gh and lanes are this suite's stubs, and
# tmux is lib/open-terminal-stubs.sh's, the pane it draws standing in for the
# `claude` CLI.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_HOST CCR_FORCE_BUNDLE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
export ORCH_OVERSEER_LANES=1000
export ORCH_OVERSEER_CLOUD_LANES=1000
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-cloud: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-cloud: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-cloud: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

# Stubs. gh answers nothing, so the repository resolves from the origin; lanes
# clears every lane. tmux is the shared stub, its pane drawing the composer
# once the launch line's Enter lands (OT_COMPOSER_ON_ENTER=1) and the session
# screen in $SCREEN once the composer was read. The worktree stub logs every
# call, makes the item's directory on create, a git checkout on the item's
# lowercased branch unless STUB_WT_PLAIN=1, with a directory where the cloud
# description goes under STUB_WT_PROMPT_DIR=1, and exits STUB_PUSH_EXIT on
# push.
# shellcheck source=lib/open-terminal-stubs.sh
source "$TEST_DIR/lib/open-terminal-stubs.sh"
OT_BIN="$TMP_ROOT/ot-bin"
ot_stub_bin "$OT_BIN"
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\n[[ "${STUB_GH_OK:-}" == 1 ]]\n' > "$BIN/gh"
cat > "$BIN/lanes" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "[]" ;;
  pick)
    if [[ "${STUB_LANES_REPO_UNSET:-false}" == true ]]; then
      printf 'lanes: cloud-repo-unset account=%s repo=owner/repo\n' "$3" >&2
      exit 7
    fi
    if [[ -n "${STUB_LANES_CREDIT_STATE:-}" ]]; then
      printf '%s\n' '{"wall":20,"binding_bucket":"weekly","binding_resets_at":"2099-08-01T06:00:00Z","status":"expired","refusal":{"cause":"cloud-credit","retry_at":null}}'
      case "$STUB_LANES_CREDIT_STATE" in walled) exit 3 ;; unmeasured) exit 5 ;; *) exit 1 ;; esac
    fi
    ;;
esac
exit 0
EOF
TMUX_LOG="$TMP_ROOT/tmux.log"
WT_LOG="$TMP_ROOT/worktree.log"
cat > "$BIN/worktree" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$WT_LOG"
case "\${1:-}" in
  create)
    if [[ -n "\${STUB_RESERVATION_LOG:-}" ]]; then
      awk -F'\t' '{print \$8}' "\$OVERSEE_WATCH_STATE_DIR/claims"/*.reserve > "\$STUB_RESERVATION_LOG"
    fi
    mkdir -p "$TMP_ROOT/wt/\$2"
    if [[ "\${STUB_WT_PLAIN:-}" != 1 ]]; then
      git init -q "$TMP_ROOT/wt/\$2"
      git -C "$TMP_ROOT/wt/\$2" config gc.auto 0
      git -C "$TMP_ROOT/wt/\$2" config maintenance.auto false
      git -C "$TMP_ROOT/wt/\$2" symbolic-ref HEAD "refs/heads/\$(printf '%s' "\$2" | tr '[:upper:]' '[:lower:]')"
      [[ "\${STUB_WT_PROMPT_DIR:-}" != 1 ]] || mkdir "$TMP_ROOT/wt/\$2/.git/cloud-prompt"
    fi
    printf '%s\n' "$TMP_ROOT/wt/\$2" ;;
  push) exit "\${STUB_PUSH_EXIT:-0}" ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$BIN/gh" "$BIN/lanes" "$BIN/worktree"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SCRIPTS_DIR/open-terminal" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/lane-host-ssh" "$SCRIPTS_DIR/workflow-state" \
  "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/orch-env" "$REPO/scripts/"
cp -R "$SCRIPTS_DIR/lib/." "$REPO/scripts/lib/"
orch_fixture_shared_libs "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" remote add origin https://github.com/owner/repo.git
OT="$REPO/scripts/open-terminal"
WS="$REPO/scripts/workflow-state"
LANE_DIR="$TMP_ROOT/.eclaude"
mkdir -p "$LANE_DIR"
# In the launch checkout, where an overseer's state sits, so the overseer
# binding reads the fleet's repository off the state directory.
STATE="$REPO/tmp/state"
SESSION_TEXT="$(bash -c 'source "$1" && printf "%s" "$LAUNCH_SESSION_TEXT"' _ "$SCRIPTS_DIR/lib/lane-launch.sh")"
[[ -n "$SESSION_TEXT" ]] || { echo "open-terminal-cloud: lib/lane-launch.sh named no session words" >&2; exit 1; }
STARTED='Session started: https://claude.ai/code/session_01CLOUD'
SCREEN="$TMP_ROOT/screen"
# screen LINE... — the session screen the next run_ot draws.
screen() { printf '%s\n' "$@" > "$SCREEN"; }
# The overseer's brief, the item's whole task, quotes and all, and the
# description claude takes for it, closed by the session words. It opens with
# `-`, which only the --cloud= form keeps the option's value, and quotes an
# orch tier word, as an issue's text can. The session words name the item
# branch, the stub worktree's lowercased item, wherever they say {branch}.
BRIEF="$TMP_ROOT/brief.md"
# shellcheck disable=SC2016  # the brief's own backticks.
printf '%s\n' "- Fix the parser's \"--flag\" handling." '' 'Done when: `parse --flag` exits 0 under /orch small runs.' > "$BRIEF"
PROMPT="$(cat "$BRIEF")"$'\n\n'"${SESSION_TEXT//\{branch\}/cc-1}"

# run_ot [SCRIPT=PATH] [ENV=VALUE...] -- ARGS... — one cloud launch of ARGS
# from the repo in tmux session `fleet`; sets RC, ERR and OUT, and resets the
# worktree log, the tmux stub's log and pane, the lane claims and the item
# worktrees first. The session screen is $STARTED unless the row drew its own
# with `screen` before it.
run_ot() {
  local script="$OT" env_args=()
  [[ "${1:-}" != SCRIPT=* ]] || { script="${1#SCRIPT=}"; shift; }
  while [[ "${1:-}" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f -- "${TMP_ROOT:?}/worktree.log" "${TMP_ROOT:?}/panes"
  rm -rf -- "${TMP_ROOT:?}/wt" "${TMP_ROOT:?}/claims"
  if [[ -n "${CAP_RESERVE_KIND:-}" ]]; then
    (source "$SCRIPTS_DIR/lib/lane-claims.sh" && lane_claim_reserve "$TMP_ROOT/claims/claims" "$$" CC-98 "$CAP_RESERVE_FLEET" "$CAP_RESERVE_KIND")
  fi
  : > "$TMUX_LOG"
  [[ -f "$SCREEN" ]] || screen "$STARTED"
  set +e
  # The ceiling keeps a plain item directory outside every repository wherever
  # TMPDIR sits, so its branch read fails as a real one does.
  (cd "$REPO" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" PATH="$BIN:$OT_BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" WORKTREE_CLI="$BIN/worktree" \
    LANES_CLI="$BIN/lanes" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' GH_REPO="" TMUX="" TMUX_PANE="" \
    ORCH_TMUX_SESSION=fleet ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SSH_PROMPT_SECS=1 \
    OT_TMUX_LOG="$TMUX_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/panes" OT_COMPOSER_ON_ENTER=1 OT_SCREEN_FILE="$SCREEN" \
    ${env_args[@]+"${env_args[@]}"} "$script" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err")
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
  OUT="$(cat "$TMP_ROOT/out")"
  rm -f -- "${SCREEN:?}"
}
# Its model is an alias the claude adapter maps, so the arguments row reads the id.
CLOUD=(--host claude-cloud --harness claude --lane "$LANE_DIR" --launch-flags "--model sonnet --effort high" --brief-file "$BRIEF" --state-dir "$STATE")
record() {
  "$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "'"$1"'")] | first // {} | [.host, .kind, .account, .session_id, .window, .mail_root, .status, .tier] | map(. // "null") | join(" ")'
}
# The Nth text pasted into the pane, its lines between the Nth load-buffer
# the stub logged and the paste-buffer after it, `none` where there was no
# Nth paste.
pasted() {
  awk -v n="$1" '
    on && /^paste-buffer / { exit }
    on { printf "%s%s", (lines++ ? "\n" : ""), $0; next }
    /^load-buffer / && ++k == n { on = 1 }
    END { if (!on) printf "none" }' "$TMUX_LOG"
}
# `ran` where the pane took an Nth paste, `none` where it did not.
typed() { [[ "$(pasted "$1")" == none ]] && echo none || echo ran; }
LAUNCH_LINE="clear; env -u CCR_FORCE_BUNDLE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 env CLAUDE_CONFIG_DIR='$LANE_DIR' claude --model claude-sonnet-5-5 --effort high --cloud=\"\$(cat -- '$TMP_ROOT/wt/CC-1/.git/cloud-prompt')\""
# The launch line run as the pane's shell runs it, `clear` and `claude` this
# suite's stubs, claude writing its arguments to $ARGV: `cloud=brief` where
# its one --cloud= value is the first prompt, `other` where a --cloud word is
# anything else, `none` where it got none, and the count of --ref words, an
# option the CLI does not have.
CLAUDE_BIN="$TMP_ROOT/claude-bin"
ARGV="$TMP_ROOT/argv"
mkdir -p "$CLAUDE_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLAUDE_BIN/clear"
# shellcheck disable=SC2016  # the stub's own text.
printf '#!/usr/bin/env bash\nprintf %s "$@" > "$ARGV_FILE"\n' "'%s\\0'" > "$CLAUDE_BIN/claude"
chmod +x "$CLAUDE_BIN/clear" "$CLAUDE_BIN/claude"
described() {
  local word cloud=none refs=0
  rm -f -- "${ARGV:?}"
  (cd "$TMP_ROOT" && env -i PATH="$CLAUDE_BIN:/usr/bin:/bin" ARGV_FILE="$ARGV" bash -c "$(pasted 1)") >/dev/null 2>&1 || true
  [[ -f "$ARGV" ]] || { echo "claude=unrun"; return; }
  while IFS= read -r -d '' word; do
    case "$word" in
      --cloud=*) if [[ "$cloud" == none && "${word#--cloud=}" == "$PROMPT" ]]; then cloud=brief; else cloud=other; fi ;;
      --cloud) cloud=other ;;
      --ref | --ref=*) refs=$((refs + 1)) ;;
    esac
  done < "$ARGV"
  echo "cloud=$cloud ref=$refs"
}
# Whether the launch line holds -p or --print as a word: the CLI refuses
# either beside --cloud.
print_words() { local word n=0; for word in $(pasted 1); do [[ "$word" != -p && "$word" != --print ]] || n=$((n + 1)); done; echo "$n"; }
made() { [[ -e "$WT_LOG" ]] && echo yes || echo no; }

# A declared kind selects the cap even when the host field names the other
# kind. Each row starts with a full Daytona fleet and its own cloud records.
cloud_cap_row() { # SCRIPT NAME STATUS CLOUD_COUNT [OPTION] [CLOUD_CAP]
  local script="$1" state="$REPO/tmp/cloud-cap-$2" n cloud_cap="${6:-1}"
  local CAP_RESERVE_KIND="" CAP_RESERVE_FLEET="$state/workflow-state-oversee.json"
  "$WS" --state-dir "$state" init oversee >/dev/null
  "$WS" --state-dir "$state" append oversee lanes \
    '{"item":"CC-90","kind":"ssh","host":"claude-cloud","status":"running","window":"fleet:CC-90"}' >/dev/null
  for ((n=0; n<$4; n++)); do
    "$WS" --state-dir "$state" append oversee lanes \
      '{"item":"CC-9'"$((n + 1))"'","kind":"claude-cloud","host":"daytona","status":"'"$3"'","window":"fleet:CC-9'"$((n + 1))"'"}' >/dev/null
  done
  local extra=()
  [[ "${5:-}" != over ]] || extra=(--over-cap)
  [[ "${5:-}" != reserve ]] || CAP_RESERVE_KIND=claude-cloud
  rm -f -- "$TMP_ROOT/reservation-kind"
  run_ot SCRIPT="$script" ORCH_OVERSEER_LANES=1 ORCH_OVERSEER_CLOUD_LANES="$cloud_cap" STUB_RESERVATION_LOG="$TMP_ROOT/reservation-kind" -- \
    "${CLOUD[@]}" --state-dir "$state" ${extra[@]+"${extra[@]}"} CC-50
  CAP_RESULT="rc=$RC made=$(made) setting=$(awk '$2 == "cap-reached" {for(i=3;i<=NF;i++) if($i ~ /^setting=/) print substr($i,9)}' <<<"$ERR")"
  CAP_OVER="$("$WS" --state-dir "$state" get oversee '[.lanes[] | select(.item == "CC-50")] | first | .over_cap // "none"')"
  CAP_RESERVED=none
  [[ ! -f "$TMP_ROOT/reservation-kind" ]] || CAP_RESERVED="$(cat "$TMP_ROOT/reservation-kind")"
}

echo "=== cloud sessions use their own cap beside a full Daytona fleet ==="
for status in running preparing parked; do
  for spec in 'below|0|rc=0 made=yes setting=' 'full|1|rc=1 made=no setting=ORCH_OVERSEER_CLOUD_LANES'; do
    IFS='|' read -r name count want <<<"$spec"
    cloud_cap_row "$OT" "$status-$name" "$status" "$count"
    assert_eq "$CAP_RESULT" "$want" "a $status cloud record counts only against the cloud cap"
    [[ "$name" != below ]] || assert_eq "$CAP_RESERVED" claude-cloud "the admitted launcher reserves a cloud slot before its worktree create"
  done
done
cloud_cap_row "$OT" configured running 1 '' 2
assert_eq "$CAP_RESULT" 'rc=0 made=yes setting=' "the cloud setting permits another session above the fleet limit"
cloud_cap_row "$OT" configured-full running 2 '' 2
assert_eq "$CAP_RESULT" 'rc=1 made=no setting=ORCH_OVERSEER_CLOUD_LANES' "the configured cloud limit refuses the next session"
cloud_cap_row "$OT" over running 1 over
assert_eq "$CAP_RESULT over=$CAP_OVER" 'rc=0 made=yes setting= over=cloud' \
  "an explicit cloud cap exception records the cloud cap"
cloud_cap_row "$OT" reserved running 0 reserve
assert_eq "$CAP_RESULT" 'rc=1 made=no setting=ORCH_OVERSEER_CLOUD_LANES' \
  "an unrecorded cloud launch reservation consumes the cloud slot"

# Restore today's all-record count in a disposable owner. The same below-cap
# row must fail its admission assertion on that count.
COUNT_CONTROL="$(mutant_scripts cloud-cap-control lib/lane-cap.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/cloud-cap-control"
mutate_file "$COUNT_CONTROL/lib/lane-cap.sh" \
  'if [[ ( "$kind" == claude-cloud && "$HOST_KIND" == claude-cloud ) || ( "$kind" != claude-cloud && "$HOST_KIND" != claude-cloud ) ]]; then' \
  'if true || [[ ( "$kind" == claude-cloud && "$HOST_KIND" == claude-cloud ) || ( "$kind" != claude-cloud && "$HOST_KIND" != claude-cloud ) ]]; then'
cloud_cap_row "$COUNT_CONTROL/open-terminal" control running 0
CAP_CONTROL="$(FAIL=0; assert_eq "$CAP_RESULT" 'rc=0 made=yes setting=' 'cloud admission' > "$TMP_ROOT/cloud-cap-control.out"; printf '%s' "$FAIL")"
assert_eq "$CAP_CONTROL $CAP_RESULT" '1 rc=1 made=no setting=ORCH_OVERSEER_CLOUD_LANES' \
  "control: counting the full Daytona fleet in the cloud cap turns the admission row red"
RESERVE_CONTROL="$(mutant_scripts cloud-reserve-control lib/lane-cap.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/cloud-reserve-control"
mutate_file "$RESERVE_CONTROL/lib/lane-cap.sh" \
  '&& (($7 == "claude-cloud") == (ENVIRON["CAP_KIND"] == "claude-cloud"))' \
  '&& (($7 == "claude-cloud") != (ENVIRON["CAP_KIND"] == "claude-cloud"))'
cloud_cap_row "$RESERVE_CONTROL/open-terminal" reserve-control running 0 reserve
CAP_CONTROL="$(FAIL=0; assert_eq "$CAP_RESULT" 'rc=1 made=no setting=ORCH_OVERSEER_CLOUD_LANES' 'cloud reservation' > "$TMP_ROOT/cloud-reserve-control.out"; printf '%s' "$FAIL")"
assert_eq "$CAP_CONTROL $CAP_RESULT" '1 rc=0 made=yes setting=' \
  "control: charging the reservation to the other cap turns the refusal row red"
WRITE_CONTROL="$(mutant_scripts cloud-reserve-write-control lib/lane-cap.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/cloud-reserve-write-control"
mutate_file "$WRITE_CONTROL/lib/lane-cap.sh" \
  'lane_claim_reserve "$store" "$$" "$2" "$CAP_FLEET" "$HOST_KIND"' \
  'lane_claim_reserve "$store" "$$" "$2" "$CAP_FLEET" ""'
cloud_cap_row "$WRITE_CONTROL/open-terminal" reserve-write-control running 0
CAP_CONTROL="$(FAIL=0; assert_eq "$CAP_RESERVED" claude-cloud 'cloud reservation kind' > "$TMP_ROOT/cloud-reserve-write-control.out"; printf '%s' "$FAIL")"
assert_eq "$CAP_CONTROL $CAP_RESULT" '1 rc=0 made=yes setting=' \
  "control: omitting the reservation kind turns the pre-record cloud slot assertion red"
BOUND_CONTROL="$(mutant_scripts cloud-cap-bound-control lib/lane-cap.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/cloud-cap-bound-control"
mutate_file "$BOUND_CONTROL/lib/lane-cap.sh" \
  'cap="$CLOUD_CAP"; setting=ORCH_OVERSEER_CLOUD_LANES; cap_kind=cloud' \
  'cap="$FLEET_CAP"; setting=ORCH_OVERSEER_CLOUD_LANES; cap_kind=cloud'
cloud_cap_row "$BOUND_CONTROL/open-terminal" bound-control running 1 '' 2
CAP_CONTROL="$(FAIL=0; assert_eq "$CAP_RESULT" 'rc=0 made=yes setting=' 'cloud cap setting' > "$TMP_ROOT/cloud-cap-bound-control.out"; printf '%s' "$FAIL")"
assert_eq "$CAP_CONTROL $CAP_RESULT" '1 rc=1 made=no setting=ORCH_OVERSEER_CLOUD_LANES' \
  "control: using the fleet limit turns the configured cloud admission assertion red"

echo "=== a cloud session is launched from the item's pushed branch and recorded ==="
run_ot -- "${CLOUD[@]}" CC-1
assert_eq "rc=$RC worktree=$(paste -sd, "$WT_LOG")" "rc=0 worktree=create CC-1 --no-checkout,push CC-1 --set-upstream" \
  "the launch creates the item worktree and pushes its branch before the session" "$TMP_ROOT/err"
assert_eq "$(grep -c -- "^new-window .* -n CC-1 -c $TMP_ROOT/wt/CC-1 " "$TMUX_LOG" || true)" 1 \
  "the item's window opens in the item worktree"
assert_eq "print-words=$(print_words)" "print-words=0" "the launch line holds neither -p nor --print"
assert_eq "$(pasted 1)" "$LAUNCH_LINE" \
  "the window runs claude --cloud interactively under the lane's account with its model id and selected effort, the description read from the worktree's git directory, CCR_FORCE_BUNDLE cleared and the #81776 workaround"
assert_eq "$(described) pasted=$(typed 2)" "cloud=brief ref=0 pasted=none" \
  "claude takes the brief file's text closed by the session words as its --cloud= description, never the mailbox words, with no --ref and nothing pasted after its line"
# branch_named ITEM BRANCH — the prompt file the launch of ITEM wrote: whether
# it names BRANCH, which the brief does not, and how many {branch} words it
# left unfilled.
branch_named() {
  local text
  text="$(cat -- "$TMP_ROOT/wt/$1/.git/cloud-prompt")" || { echo "prompt=unread"; return; }
  printf 'named=%s unfilled=%s' "$([[ "$text" == *"$2"* ]] && echo yes || echo no)" "$({ grep -oF '{branch}' <<<"$text" || true; } | wc -l | tr -d ' ')"
}
assert_eq "$(branch_named CC-1 cc-1)" "named=yes unfilled=0" \
  "the prompt the launch wrote names the item branch and leaves no {branch} word"
assert_eq "$(record CC-1)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:CC-1 $TMP_ROOT/wt/CC-1 running null" \
  "the record names the host and kind, the account, the session id the pane's URL carries, the window, and no tier, the brief carrying no item-tier line"
OWED='open-terminal: cloud-card-owed item=CC-1'
assert_eq "owed=$(grep -c "^$OWED" <<<"$ERR" || true)" "owed=0" \
  "a session that shows no card prints no cloud-card-owed line"

echo "=== a brief's item-tier line is the cloud lane's tier ==="
# The item-tier line, and a different result an issue's text can quote.
TIER_LINE='tier=small brief=small cause=estimate-within-small production=40 estimate=12 delta=40 paths=3'
TIER_QUOTE='tier=micro brief=micro cause=estimate-within-micro production=1 estimate=1 delta=1 paths=1'
# Each row: name, the lines the brief ends in (printf %b), the [tier,
# tier_inputs] recorded. A result quoted in prose is no line, a line may sit
# between blanks, and two distinct lines are no tier.
TIER_ROWS=(
  "line|$TIER_LINE|[\"small\",{\"estimate\":12,\"delta\":40,\"paths\":3}]"
  "quoted|An earlier lane recorded \`$TIER_QUOTE\` for it.\n  $TIER_LINE |[\"small\",{\"estimate\":12,\"delta\":40,\"paths\":3}]"
  "two lines|$TIER_QUOTE\n$TIER_LINE|[null,{\"estimate\":null,\"delta\":null,\"paths\":null}]"
)
tier_row() { # SCRIPT ROW ITEM — the launch of ROW's brief, its result and record in TIER
  local tail
  IFS='|' read -r _ tail _ <<<"$2"
  { cat "$BRIEF"; printf '%b\n' "$tail"; } > "$TMP_ROOT/brief-$3.md"
  run_ot SCRIPT="$1" -- --host claude-cloud --harness claude --lane "$LANE_DIR" --launch-flags "--model sonnet --effort high" \
    --brief-file "$TMP_ROOT/brief-$3.md" --state-dir "$STATE" "$3"
  TIER="rc=$RC $("$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "'"$3"'")] | first | [.tier, .tier_inputs] | tojson')"
}
for i in "${!TIER_ROWS[@]}"; do
  IFS='|' read -r name _ want <<<"${TIER_ROWS[$i]}"
  tier_row "$OT" "${TIER_ROWS[$i]}" "CC-4$i"
  assert_eq "$TIER" "rc=0 $want" "a cloud launch records the tier and inputs of the $name row" "$TMP_ROOT/err"
done

echo "=== the session words run no kendex-bound arming command ==="
# The words are the cloud session's first message, and the session runs the
# commands they name: a cloud machine has no kendex and no tools/setup, so
# either one is a step the session stops to ask about, while the commit-guards
# script arms the hooks with no kendex. arming LIB — the words lib/lane-launch.sh
# at LIB closes a brief on, as the count of each command they name.
HOOKS='.agents/skills/commit-guards/scripts/install-git-hooks'
arming() {
  local text
  text="$(bash -c 'source "$1" && printf "%s" "$LAUNCH_SESSION_TEXT"' _ "$1")" || { echo "unread"; return; }
  printf 'setup=%s install=%s hooks=%s' "$(grep -c 'tools/setup' <<<"$text" || true)" \
    "$(grep -c 'guard install' <<<"$text" || true)" "$(grep -cF "$HOOKS" <<<"$text" || true)"
}
ARMING_WANT="setup=0 install=0 hooks=1"
assert_eq "$(arming "$SCRIPTS_DIR/lib/lane-launch.sh")" "$ARMING_WANT" \
  "the session words name no kendex-bound arming command and arm through install-git-hooks"
# The kendex-bound step restored, in a copy of the lib.
ARMING_SENTENCE=' Where it is not, commit anyway, since the pull request CI, the review gate and the second-opinion gate hold the merge.'
lib="$TMP_ROOT/arming-lib"
cp -R "$SCRIPTS_DIR/lib" "$lib"
mutate_file "$lib/lane-launch.sh" "$ARMING_SENTENCE" "$ARMING_SENTENCE Before your first commit, run tools/setup where the repository has it, else kendex guard install."
assert_eq "red=$([[ "$(arming "$lib/lane-launch.sh")" != "$ARMING_WANT" ]] && echo yes || echo no)" "red=yes" \
  "control: session words restoring the kendex-bound step fail the arming row"

echo "=== a first-run dialog takes one Enter before the session read ==="
run_ot OT_COMPOSER_ON_ENTER=2 -- "${CLOUD[@]}" CC-14
assert_eq "rc=$RC keys=$(grep -c '^send-keys .* Enter$' "$TMUX_LOG" || true) pasted=$(typed 2) session=$(record CC-14 | cut -d' ' -f4)" \
  "rc=0 keys=2 pasted=none session=session_01CLOUD" \
  "one nudge dismisses the dialog, then the session is read and recorded" "$TMP_ROOT/err"

echo "=== a named account with no repository entry stops before launch ==="
run_ot STUB_LANES_REPO_UNSET=true -- "${CLOUD[@]}" CC-30
assert_eq "rc=$RC refused=$(grep -cxF "lanes: cloud-repo-unset account=$LANE_DIR repo=owner/repo" <<<"$ERR" || true) made=$(made) claude=$(typed 1)" \
  "rc=1 refused=1 made=no claude=none" "the launcher preserves the repository refusal and starts nothing" "$TMP_ROOT/err"
CTRL="$(mutant_scripts mutant-named-cloud-repo open-terminal)" || exit 1
mutate_file "$CTRL/open-terminal" '7) return 1 ;;' '7) : ;;'
run_ot SCRIPT="$CTRL/open-terminal" STUB_LANES_REPO_UNSET=true -- "${CLOUD[@]}" CC-31
assert_eq "rc=$RC made=$(made) claude=$(typed 1)" \
  "rc=0 made=yes claude=ran" "control: ignoring the repository refusal launches the cloud session" "$TMP_ROOT/err"

echo "=== a cloud allowance refusal precedes plan and credential branches ==="
for credit_state in walled unmeasured; do
  run_ot STUB_LANES_CREDIT_STATE="$credit_state" -- "${CLOUD[@]}" CC-32
  refusal="$(sed -n 's/^open-terminal: lane-credit-refused / /p' <<<"$ERR")"
  assert_eq "rc=$RC$refusal made=$(made) claude=$(typed 1)" \
    "rc=1 lane=$LANE_DIR cause=cloud-credit retry-at=none made=no claude=none" \
    "the named $credit_state grant refusal reports its own cause and no plan retry" "$TMP_ROOT/err"
done
CTRL="$(mutant_scripts mutant-named-cloud-credit open-terminal)" || exit 1
mutate_file "$CTRL/open-terminal" 'if [[ -n "$lane_refusal" ]]; then' 'if false && [[ -n "$lane_refusal" ]]; then'
run_ot SCRIPT="$CTRL/open-terminal" STUB_LANES_CREDIT_STATE=walled -- "${CLOUD[@]}" CC-32
assert_eq "rc=$RC cloud=$(grep -c '^open-terminal: lane-credit-refused ' <<<"$ERR" || true) plan=$(grep -c '^open-terminal: lane-model-walled ' <<<"$ERR" || true)" \
  'rc=1 cloud=0 plan=1' 'control: ignoring the cloud refusal reports the unrelated plan wall' "$TMP_ROOT/err"

echo "=== what a cloud session cannot take refuses before anything is made ==="
# KEY FIELDS|ARGS|OLD|NEW: the refusal's first line past its key word, the
# launch options that meet it, `+` a space inside one option, and the control's
# edit, the rule's text kept and its behaviour removed.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
REFUSAL_ROWS=(
  'cloud-session-invalid host=claude-cloud harness=codex relaunch=false items=1|--harness codex --launch-flags --model+gpt-5.5 --brief-file|[[ "$HARNESS" == claude && -z "$CMD_TEMPLATE" &&|[[ -z "$CMD_TEMPLATE" &&'
  'cloud-session-invalid host=claude-cloud harness=claude relaunch=false items=1|--harness claude --cmd stub-harness --brief-file|claude && -z "$CMD_TEMPLATE" && "$RELAUNCH"|claude && "$RELAUNCH"'
  'cloud-session-invalid host=claude-cloud harness=claude relaunch=true items=1|--harness claude --launch-flags --model+opus --relaunch --brief-file|"$RELAUNCH" != true && ${#ITEMS[@]}|${#ITEMS[@]}'
  'cloud-session-invalid host=claude-cloud harness=claude relaunch=false items=2|--harness claude --launch-flags --model+opus --brief-file CC-13|"$RELAUNCH" != true && ${#ITEMS[@]} -eq 1 ]]|"$RELAUNCH" != true ]]'
  'cloud-brief-missing host=claude-cloud|--harness claude --launch-flags --model+opus|[[ -n "$BRIEF_FILE" ]] || { ot_message cloud-brief-missing|true || { ot_message cloud-brief-missing'
  "host-invalid host=claude-cloud mode=ghostty lane=CLAUDE_CONFIG_DIR=$LANE_DIR harness=claude"'|--harness claude --launch-flags --model+opus+--effort+high --ghostty --brief-file|cloud-session) [[ "$TERMINAL_MODE" == tmux && -n "$LANE_ENV" ]]|cloud-session) [[ -n "$LANE_ENV" ]]'
)
# refusal_row SCRIPT ROW — the row's launch, with RC and ERR set and the count
# of its refusal line in REFUSED. A bare --brief-file takes the suite's brief.
refusal_row() {
  local line args opts=() opt
  IFS='|' read -r line args _ <<<"$2"
  for opt in $args; do
    opts+=("${opt//+/ }")
    [[ "$opt" != --brief-file ]] || opts+=("$BRIEF")
  done
  run_ot SCRIPT="$1" -- --host claude-cloud --lane "$LANE_DIR" "${opts[@]}" --state-dir "$STATE" CC-5
  REFUSED="$(grep -cxF "open-terminal: $line" <<<"$ERR" || true)"
}
for row in "${REFUSAL_ROWS[@]}"; do
  refusal_row "$OT" "$row"
  assert_eq "rc=$RC refused=$REFUSED made=$(made)" "rc=1 refused=1 made=no" "${row%%|*} refuses" "$TMP_ROOT/err"
done

echo "=== each cause of a bundled clone refuses before anything is made ==="
mkdir -p "$TMP_ROOT/bundling" "$REPO/.claude"
printf '{"env":{"CCR_FORCE_BUNDLE":"1"}}\n' > "$TMP_ROOT/bundling/settings.json"
# CAUSE|LANE|SETUP: the lane where it is not the suite's, and the setup that
# runs before the launch and is undone after it.
BUNDLE_ROWS=(
  "settings path=$TMP_ROOT/bundling/settings.json|$TMP_ROOT/bundling|"
  "settings path=$REPO/.claude/settings.json||cp $TMP_ROOT/bundling/settings.json $REPO/.claude/settings.json"
  "remote||git -C $REPO remote set-url origin https://gitlab.example/owner/repo.git"
)
bundle_row() { # SCRIPT ROW — the launch, with RC and ERR set
  local cause lane setup
  IFS='|' read -r cause lane setup <<<"$2"
  [[ -n "$lane" ]] || lane="$LANE_DIR"
  [[ -z "$setup" ]] || $setup
  run_ot SCRIPT="$1" -- --host claude-cloud --harness claude --lane "$lane" \
    --launch-flags "--model opus --effort high" --brief-file "$BRIEF" --state-dir "$STATE" CC-2
  rm -f -- "${REPO:?}/.claude/settings.json"
  git -C "$REPO" remote set-url origin https://github.com/owner/repo.git
}
for row in "${BUNDLE_ROWS[@]}"; do
  cause="${row%%|*}"
  bundle_row "$OT" "$row"
  assert_eq "rc=$RC refused=$(grep -cxF "open-terminal: cloud-bundle-risk item=CC-2 cause=$cause" <<<"$ERR" || true) made=$(made)" \
    "rc=1 refused=1 made=no" "cloud-bundle-risk cause=$cause refuses with no worktree made" "$TMP_ROOT/err"
done

echo "=== CCR_FORCE_BUNDLE in the environment is cleared on the launch line ==="
# The pane takes the tmux server's environment, never this one, so the line
# clears the variable where the CLI starts.
run_ot CCR_FORCE_BUNDLE=1 -- "${CLOUD[@]}" CC-15
assert_eq "rc=$RC clears=$(grep -c '^clear; env -u CCR_FORCE_BUNDLE ' <<<"$(pasted 1)" || true)" "rc=0 clears=1" \
  "a launch from an environment setting CCR_FORCE_BUNDLE goes ahead on a line that clears it" "$TMP_ROOT/err"

echo "=== a lane whose launcher is on PATH launches through it ==="
LAUNCHER_BIN="$TMP_ROOT/launcher-bin"
mkdir -p "$LAUNCHER_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAUNCHER_BIN/eclaude"
chmod +x "$LAUNCHER_BIN/eclaude"
LAUNCHER_LINE="clear; env -u CCR_FORCE_BUNDLE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 '$LAUNCHER_BIN/eclaude' --model claude-sonnet-5-5 --effort high --cloud=\"\$(cat -- '$TMP_ROOT/wt/CC-16/.git/cloud-prompt')\""
run_ot PATH="$LAUNCHER_BIN:$BIN:$OT_BIN:$PATH" -- "${CLOUD[@]}" CC-16
assert_eq "rc=$RC line=$([[ "$(pasted 1)" == "$LAUNCHER_LINE" ]] && echo launcher || echo other)" "rc=0 line=launcher" \
  "the lane's launcher, by the path the judge resolved and with no env prefix, starts the CLI" "$TMP_ROOT/err"

echo "=== the account is read back once the composer is up ==="
# The stub pane's pid is 0, so the read names no account and the launch
# stands; the line says the check ran.
run_ot -- "${CLOUD[@]}" CC-1
assert_eq "rc=$RC account=$(grep -c '^open-terminal: lane-unobserved item=CC-1 reason=' <<<"$ERR" || true)" "rc=0 account=1" \
  "the cloud arm reads the pane back against the picked account" "$TMP_ROOT/err"

echo "=== an account refusal names the session the CLI already made ==="
# The pane's child runs on another account, the case a wrapper on PATH
# exporting its own CLAUDE_CONFIG_DIR makes. The row needs a readable
# per-process environment and skips where the platform has none, the
# reader's own predicate deciding.
OTHER_LANE="$TMP_ROOT/.other"
mkdir -p "$OTHER_LANE"
mismatch_row() { # SCRIPT ITEM — the launch, its result in MISMATCH
  local tree child="$TMP_ROOT/mismatch-child"
  bash -c 'env CLAUDE_CONFIG_DIR="$1" sleep 30 & echo "$!" > "$2"; wait' _ "$OTHER_LANE" "$child" & tree=$!
  run_ot SCRIPT="$1" OT_PANE_PID="$tree" ORCH_TMUX_VERIFY_SECS=3 -- "${CLOUD[@]}" "$2"
  kill "$(cat "$child")" "$tree" 2>/dev/null || true
  MISMATCH="rc=$RC mismatch=$(grep -cxF "open-terminal: lane-mismatch item=$2 picked=$LANE_DIR observed=$OTHER_LANE" <<<"$ERR" || true) refused=$(grep -cxF "open-terminal: cloud-account-refused item=$2 session=session_01CLOUD" <<<"$ERR" || true) closed=$(grep -c '^kill-window' "$TMUX_LOG" || true) record=$(record "$2")"
}
MISMATCH_WANT="rc=1 mismatch=1 refused=1 closed=1 record=null null null null null null null null"
PROC_ENV=true
( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_process_env_readable ) || PROC_ENV=false
if [[ "$PROC_ENV" == true ]]; then
  mismatch_row "$OT" CC-23
  assert_eq "$MISMATCH" "$MISMATCH_WANT" \
    "a pane observed on another account names the session already running there, then closes the window with no record" "$TMP_ROOT/err"
else
  printf '  skip  cloud account refusal row (no readable per-process environment)\n'
fi

echo "=== no key reaches the pane before claude replaces its shell ==="
# The window's shell still reading its rc files holds the pane for three
# reads after the launch line, and a dialog in front of the composer takes
# one nudge, which the pane writer refuses while the shell is there.
LATE_ENV=(ORCH_TMUX_VERIFY_SECS=3 OT_HARNESS_LATE=3 OT_COMPOSER_ON_ENTER=2)
late_rows() { # SCRIPT LATE_ITEM UNSEEN_ITEM — the late and the unseen rows, their results in LATE and UNSEEN
  run_ot SCRIPT="$1" "${LATE_ENV[@]}" -- "${CLOUD[@]}" "$2"
  LATE="rc=$RC session=$(record "$2" | cut -d' ' -f4)"
  run_ot SCRIPT="$1" OT_HARNESS_LATE=99 -- "${CLOUD[@]}" "$3"
  UNSEEN="rc=$RC unseen=$(grep -cxF "open-terminal: cloud-cli-unseen item=$3 reason=bound" <<<"$ERR" || true) keys=$(grep -c '^send-keys .* Enter$' "$TMUX_LOG" || true) record=$(record "$3")"
}
late_rows "$OT" CC-17 CC-18
assert_eq "$LATE" "rc=0 session=session_01CLOUD" \
  "a claude starting three pane reads late is waited for, nudged and recorded"
assert_eq "$UNSEEN" "rc=1 unseen=1 keys=1 record=null null null null null null null null" \
  "a claude never seen in the pane stops with its own line, no key past the launch line's Enter and no record" "$TMP_ROOT/err"

echo "=== a claude under a pane reading as its shell is not an exited CLI ==="
# A launcher that runs claude as its child leaves its interpreter as the
# pane's command for the whole session. The stub pane's command reads bash
# throughout, a process named claude runs below the pane's pid, and the
# composer takes one nudge.
CHILD_BIN="$TMP_ROOT/child-bin"
mkdir -p "$CHILD_BIN"
cp "$(command -v sleep)" "$CHILD_BIN/claude"
child_row() { # SCRIPT ITEM — the launch, its result in CHILD
  local child
  "$CHILD_BIN/claude" 30 & child=$!
  run_ot SCRIPT="$1" OT_HARNESS_LATE=99 OT_COMPOSER_ON_ENTER=2 -- "${CLOUD[@]}" "$2"
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  CHILD="rc=$RC account=$(grep -c "^open-terminal: lane-unobserved item=$2 reason=$CHILD_REASON\$" <<<"$ERR" || true) session=$(record "$2" | cut -d' ' -f4)"
}
# The account check asks for a readable per-process environment before it
# reads the stub pane's pid, so a host without one names that instead.
CHILD_REASON=pane-pid
[[ "$PROC_ENV" == true ]] || CHILD_REASON=no-process-environment
CHILD_WANT="rc=0 account=1 session=session_01CLOUD"
child_row "$OT" CC-32
assert_eq "$CHILD" "$CHILD_WANT" \
  "a claude below a pane reading as its shell is nudged to its composer, its account read and its session recorded" "$TMP_ROOT/err"

echo "=== a pane showing no claude.ai session URL stops there ==="
# The session id bare, outside the URL the anchored read takes.
UNREAD_SCREEN='Started session_01CLOUD'
screen "$UNREAD_SCREEN"
run_ot -- "${CLOUD[@]}" CC-3
assert_eq "rc=$RC unread=$(grep -cxF 'open-terminal: cloud-session-unread item=CC-3' <<<"$ERR" || true) record=$(record CC-3)" \
  "rc=1 unread=1 record=null null null null null null null null" "no URL in the pane is no record and a failed item" "$TMP_ROOT/err"

echo "=== the session id is the CLI's own, read across the scrollback ==="
# NAME|ENV|BRIEF|SESSION|SCREEN...: the row's session screen, one line per
# field past the session id, read under ORCH_LANE_SSH_PROMPT_SECS=1, which is
# two reads. A brief quoting an earlier session's URL shows it before the
# CLI's own; a screen drawn on the second read is waited for; a URL six lines
# up is off a five-row pane; the CLI's cse_ ids are read as its session_ ones.
BRIEF_QUOTE="$TMP_ROOT/brief-quote.md"
printf '%s\n' 'Follow up on https://claude.ai/code/session_01OLD.' > "$BRIEF_QUOTE"
SESSION_ROWS=(
  "quoted||$BRIEF_QUOTE|session_01CLOUD|> Follow up on https://claude.ai/code/session_01OLD.|$STARTED"
  "second read|OT_SCREEN_ON=2|$BRIEF|session_01CLOUD|$STARTED"
  "scrolled||$BRIEF|session_01CLOUD|$STARTED|working 1|working 2|working 3|working 4|working 5|working 6"
  "cse||$BRIEF|cse_01CLOUD|Session started: https://claude.ai/code/cse_01CLOUD"
)
session_row() { # SCRIPT ROW ITEM — the launch, the session it recorded in SESSION
  local name env brief want lines=() envs=()
  IFS='|' read -r name env brief want <<<"$2"
  IFS='|' read -r -a lines <<<"${2#*|*|*|*|}"
  [[ -z "$env" ]] || envs=("$env")
  screen "${lines[@]}"
  run_ot SCRIPT="$1" ${envs[@]+"${envs[@]}"} -- --host claude-cloud --harness claude --lane "$LANE_DIR" \
    --launch-flags "--model sonnet --effort high" --brief-file "$brief" --state-dir "$STATE" "$3"
  SESSION="rc=$RC session=$(record "$3" | cut -d' ' -f4)"
}
for i in "${!SESSION_ROWS[@]}"; do
  IFS='|' read -r name _ _ want _ <<<"${SESSION_ROWS[$i]}"
  session_row "$OT" "${SESSION_ROWS[$i]}" "CC-4$i"
  assert_eq "$SESSION" "rc=0 session=$want" "the $name row records the session the CLI printed" "$TMP_ROOT/err"
done

echo "=== a failed push, branch read, composer or capture stops with no record ==="
# ENV|LINE|CLAUDE|WORKTREE|OLD -> NEW: the stub's failure, the refusal line
# past its key word, whether claude's line was typed, the worktree calls
# made, and the control's edit, the guard's text kept and its behaviour
# removed; the edit is the rest of the row, `|` and all. The pane of a
# composer that never came up shows no session URL, so its control fails the
# row on the refusal line. A capture that fails is the URL read's own, the
# composer wait's capture before it having succeeded.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
FAILURE_ROWS=(
  'STUB_PUSH_EXIT=1|cloud-push-failed item=CC-20|none|create CC-20 --no-checkout,push CC-20 --set-upstream||| { ot_message cloud-push-failed -> || true || { ot_message cloud-push-failed'
  'STUB_WT_PLAIN=1|cloud-branch-unread item=CC-25|none|create CC-25 --no-checkout||| { ot_message cloud-branch-unread -> || true || { ot_message cloud-branch-unread'
  'STUB_WT_PROMPT_DIR=1|cloud-prompt-failed item=CC-28|none|create CC-28 --no-checkout||| { ot_message cloud-prompt-failed -> || true || { ot_message cloud-prompt-failed'
  'OT_COMPOSER_ON_ENTER=99|cloud-composer-stuck item=CC-26|ran|create CC-26 --no-checkout,push CC-26 --set-upstream|    1 | 3) ->     1 | 3) ;; 9)'
  'OT_TMUX_FAIL_NTH=capture-pane:2|tmux-failed operation=capture-pane item=CC-27|ran|create CC-27 --no-checkout,push CC-27 --set-upstream|capture-pane -pJ -S - -t "$1" 2>/dev/null)" || return 2 -> capture-pane -pJ -S - -t "$1" 2>/dev/null)" || return 1'
)
failure_row() { # SCRIPT ROW — the launch, with RC and ERR set
  local env line item
  IFS='|' read -r env line _ <<<"$2"
  item="${line#* item=}"
  run_ot SCRIPT="$1" "$env" -- "${CLOUD[@]}" "${item%% *}"
}
# failure_seen ROW — the row's observation against its own refusal line.
failure_seen() {
  local line item
  IFS='|' read -r _ line _ <<<"$1"
  item="${line#* item=}"
  printf 'rc=%s refused=%s claude=%s prompt=%s worktree=%s record=%s' "$RC" "$(grep -cxF "open-terminal: $line" <<<"$ERR" || true)" \
    "$(typed 1)" "$(typed 2)" "$(paste -sd, "$WT_LOG")" "$(record "${item%% *}")"
}
# failure_want ROW — what the row's launch is held to: refused by its own line,
# nothing pasted after the launch line, and no record.
failure_want() {
  local line claude wt
  IFS='|' read -r _ line claude wt _ <<<"$1"
  printf 'rc=1 refused=1 claude=%s prompt=none worktree=%s record=null null null null null null null null' "$claude" "$wt"
}
for row in "${FAILURE_ROWS[@]}"; do
  IFS='|' read -r _ line _ <<<"$row"
  failure_row "$OT" "$row"
  assert_eq "$(failure_seen "$row")" "$(failure_want "$row")" "${line%% *} stops the launch with no record" "$TMP_ROOT/err"
done

echo "=== a CLI that exits before its composer is a failed launch ==="
# The CLI runs for one pane read, then the pane is back at its shell showing
# no session URL, where the pane writer would refuse a nudge.
exited_row() { # SCRIPT ITEM — the launch, its result in EXITED
  run_ot SCRIPT="$1" OT_HARNESS_EXITS=1 OT_COMPOSER_ON_ENTER=99 -- "${CLOUD[@]}" "$2"
  EXITED="rc=$RC failed=$(grep -cxF "open-terminal: cloud-launch-failed item=$2" <<<"$ERR" || true) refused=$(grep -c -e '^pane-write: ' -e '^open-terminal: pane-refused ' <<<"$ERR" || true) prompt=$(typed 2) record=$(record "$2")"
}
EXITED_WANT="rc=1 failed=1 refused=0 prompt=none record=null null null null null null null null"
exited_row "$OT" CC-21
assert_eq "$EXITED" "$EXITED_WANT" \
  "a CLI refusing its arguments ends claude in the pane, which stops the launch as cloud-launch-failed with no nudge sent" "$TMP_ROOT/err"

echo "=== a process table that cannot be read stops the launch under its own line ==="
# The CLI exits after one pane read and ps fails, so whether a claude runs
# under the shell is unknown: neither an exited CLI nor one to nudge.
PS_BIN="$TMP_ROOT/ps-bin"
mkdir -p "$PS_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$PS_BIN/ps"
chmod +x "$PS_BIN/ps"
process_row() { # SCRIPT ITEM — the launch, its result in PROCESS
  run_ot SCRIPT="$1" PATH="$PS_BIN:$BIN:$OT_BIN:$PATH" OT_HARNESS_EXITS=1 OT_COMPOSER_ON_ENTER=99 -- "${CLOUD[@]}" "$2"
  PROCESS="rc=$RC unseen=$(grep -cxF "open-terminal: cloud-cli-unseen item=$2 reason=process-read-failed" <<<"$ERR" || true) refused=$(grep -c -e '^pane-write: ' -e '^open-terminal: pane-refused ' <<<"$ERR" || true) record=$(record "$2")"
}
PROCESS_WANT="rc=1 unseen=1 refused=0 record=null null null null null null null null"
process_row "$OT" CC-34
assert_eq "$PROCESS" "$PROCESS_WANT" \
  "a failed process read after the composer wait began names itself, with no nudge sent and no record" "$TMP_ROOT/err"

echo "=== a CLI that prints its session and exits is a started session ==="
# Claude Code's detached --cloud path: the session's View URL printed, no
# composer drawn, and the pane back at its shell. NAME|ENV: the CLI exiting
# after one pane read, and one exiting before any read saw it. Neither takes a
# nudge, which the pane writer would refuse at the shell and report as a failed
# write.
DETACHED_ROWS=(
  'exits|OT_HARNESS_EXITS=1'
  'unseen|OT_HARNESS_LATE=99'
)
detached_row() { # SCRIPT ROW ITEM — the launch, its result in DETACHED
  screen 'Created cloud session: Fix the parser' 'View: https://claude.ai/code/session_01CLOUD?from=cli&m=0' \
    'Resume with: claude --teleport session_01CLOUD'
  run_ot SCRIPT="$1" "${2#*|}" OT_COMPOSER_ON_ENTER=99 OT_SCREEN_ON=0 -- "${CLOUD[@]}" "$3"
  DETACHED="rc=$RC unread=$(grep -cxF "open-terminal: lane-unobserved item=$3 reason=cli-exited" <<<"$ERR" || true) refused=$(grep -c -e '^pane-write: ' -e '^open-terminal: pane-refused ' <<<"$ERR" || true) record=$(record "$3")"
}
detached_want() { echo "rc=0 unread=1 refused=0 record=claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:$1 $TMP_ROOT/wt/$1 running null"; }
for i in "${!DETACHED_ROWS[@]}"; do
  detached_row "$OT" "${DETACHED_ROWS[$i]}" "CC-7$i"
  assert_eq "$DETACHED" "$(detached_want "CC-7$i")" \
    "the ${DETACHED_ROWS[$i]%%|*} row records the session the exited CLI printed, its account unread, with no refused write" "$TMP_ROOT/err"
done

echo "=== the launch arm is the declared launch ==="
CODEX_LINE=$'kind=codex-cloud\tlaunch=cloud-task\tchannel=task\tfiles=none\tstatus=task\tstop=none\trelaunch=fresh\tpark=none\taccounts=none\tpool=plan\tland=handoff'
cp "$TEST_DIR/fixtures/lane-host" "$TMP_ROOT/provider"
run_ot LANE_HOST_STUB_LOG="$TMP_ROOT/provider.log" LANE_HOST_STUB_CAPABILITIES="$CODEX_LINE" -- \
  --host "$TMP_ROOT/provider" --harness claude --lane "$LANE_DIR" --launch-flags "--model opus --effort high" CC-4
assert_eq "rc=$RC refused=$(grep -cxF 'open-terminal: kind-unbuilt kind=codex-cloud' <<<"$ERR" || true) made=$(made)" \
  "rc=1 refused=1 made=no" "a kind declaring launch=cloud-task refuses as kind-unbuilt" "$TMP_ROOT/err"

echo "=== controls ==="
# mutant_root NAME — a copy of the suite's scripts laid out as the suite's
# copy is, its root in MUTANT_ROOT.
mutant_root() {
  MUTANT_ROOT="$TMP_ROOT/$1"
  mkdir -p "$MUTANT_ROOT/scripts"
  cp -R "$REPO/scripts/." "$MUTANT_ROOT/scripts/"
  orch_fixture_shared_libs "$MUTANT_ROOT"
  git -C "$MUTANT_ROOT" init -q
}
# mutant NAME OLD NEW — such a copy with one rule of open-terminal removed,
# its path in MUTANT.
mutant() {
  mutant_root "$1"
  mutate_file "$MUTANT_ROOT/scripts/open-terminal" "$2" "$3"
  MUTANT="$MUTANT_ROOT/scripts/open-terminal"
}
# One per refusal: each removed in turn, its row's launch is refused no more.
for i in "${!REFUSAL_ROWS[@]}"; do
  IFS='|' read -r line _ old new <<<"${REFUSAL_ROWS[$i]}"
  mutant "refusal-$i" "$old" "$new"
  refusal_row "$MUTANT" "${REFUSAL_ROWS[$i]}"
  assert_eq "refused=$REFUSED" "refused=0" "control: without its rule, ${line%% *} row $i is not refused" "$TMP_ROOT/err"
done
# One per bundle cause: each removed in turn launches its own row.
cause_control() { # INDEX OLD NEW
  mutant "cause-$1" "$2" "$3"
  bundle_row "$MUTANT" "${BUNDLE_ROWS[$1]}"
  assert_eq "rc=$RC" "rc=0" "control: without its check the ${BUNDLE_ROWS[$1]%%|*} row launches" "$TMP_ROOT/err"
}
# shellcheck disable=SC2016  # the script's own text, never expanded here.
cause_control 0 "jq -e '(.env.CCR_FORCE_BUNDLE // null | tostring) != \"1\"' \"\$file\" >/dev/null 2>&1" 'true'
# shellcheck disable=SC2016
cause_control 2 'kendex_github_origin_slug "$CLAIM_ROOT" >/dev/null' 'true'
# shellcheck disable=SC2016
mutant task-close 'words="$LAUNCH_SESSION_TEXT"' 'words="$LAUNCH_UNATTENDED_TEXT"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-6
assert_eq "$(described)" "cloud=other ref=0" \
  "control: a description closing on the mailbox words fails the description row"
# shellcheck disable=SC2016
mutant record-kind '"$HOST_KIND" \' '"" \'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-7
assert_eq "$(record CC-7)" "claude-cloud null $LANE_DIR session_01CLOUD fleet:CC-7 $TMP_ROOT/wt/CC-7 running null" \
  "control: a record written without the kind fails the record row"
# shellcheck disable=SC2016
mutant record-window 'lane_record_write "$RECORD_MODE" "$wt_id" "$LAUNCH_SESSION:$title" "$wt"' 'lane_record_write "$RECORD_MODE" "$wt_id" "" "$wt"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-8
assert_eq "$(record CC-8)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD null $TMP_ROOT/wt/CC-8 running null" \
  "control: a record written with no window fails the record row"
# The detached probe kept, moved after the nudge: the exits row's nudge meets
# the shell and is refused.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
PROBE='    if [[ -n "$prompt" ]]; then
      rc=0
      cloud_cli_detached "$pane" "$prompt" || rc=$?
      case "$rc" in 0) return 5 ;; 2) return 1 ;; 3) return 4 ;; 4) return 6 ;; esac
    fi
'
# shellcheck disable=SC2016
NUDGE='    (( waited < TMUX_VERIFY_SECS )) || return 1
    launch_write nudge "$title" "$pane" "$expect" key Enter || return 3
'
mutant nudge-first "$PROBE$NUDGE" "$NUDGE$PROBE"
detached_row "$MUTANT" "${DETACHED_ROWS[0]}" CC-79
assert_eq "red=$([[ "$DETACHED" != "$(detached_want CC-79)" ]] && echo yes || echo no)" "red=yes" \
  "control: a nudge ahead of the detached probe fails the exits row" "$TMP_ROOT/err"
# One per failure guard: each removed in turn, its row fails.
for i in "${!FAILURE_ROWS[@]}"; do
  IFS='|' read -r _ line _ _ edit <<<"${FAILURE_ROWS[$i]}"
  mutant "failure-$i" "${edit%% -> *}" "${edit#* -> }"
  failure_row "$MUTANT" "${FAILURE_ROWS[$i]}"
  assert_eq "red=$([[ "$(failure_seen "${FAILURE_ROWS[$i]}")" != "$(failure_want "${FAILURE_ROWS[$i]}")" ]] && echo yes || echo no)" "red=yes" \
    "control: without its guard, the ${line%% *} row fails" "$TMP_ROOT/err"
done
# The branch read kept, moved below the push: the unread row meets the
# description write first and fails.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
BRANCH_READ='  branch="$(git -C "$wt" symbolic-ref --short HEAD)" || { ot_message cloud-branch-unread "item=$item" >&2; return 1; }'
# shellcheck disable=SC2016
PUSH='  "$WORKTREE_CLI" push "$wt_id" --set-upstream >&2 || { ot_message cloud-push-failed "item=$item" >&2; return 1; }'
mutant branch-after-push "$BRANCH_READ"$'\n' ""
mutate_file "$MUTANT" "$PUSH" "$PUSH"$'\n'"$BRANCH_READ"
failure_row "$MUTANT" "${FAILURE_ROWS[1]}"
assert_eq "red=$([[ "$(failure_seen "${FAILURE_ROWS[1]}")" != "$(failure_want "${FAILURE_ROWS[1]}")" ]] && echo yes || echo no)" "red=yes" \
  "control: a branch read below the push fails the cloud-branch-unread row" "$TMP_ROOT/err"
# One per launch argument: each removed in turn fails the launch line row.
# NAME|OLD -> NEW: the argument and the edit that drops it.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
ARG_EDITS=(
  'workaround| CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 $cmd" ->  $cmd"'
  'bundle clear|env -u CCR_FORCE_BUNDLE  -> env '
  'account prefix|  cmd="$(lane_launch_line "$cmd" claude "${LANE_ENV%%=*}" "${LANE_ENV#*=}" "$form")" || return 1 -> '
  'model|choice="$(launch_choice_write claude "$LAUNCH_MODEL" "$LAUNCH_EFFORT")" -> choice="$(launch_choice_write claude "$LAUNCH_MODEL" "$LAUNCH_EFFORT")"; choice="$(launch_choice_write claude "" "$LAUNCH_EFFORT")"'
  'effort|choice="$(launch_choice_write claude "$LAUNCH_MODEL" "$LAUNCH_EFFORT")" -> choice="$(launch_choice_write claude "$LAUNCH_MODEL" "$LAUNCH_EFFORT")"; choice="$(launch_choice_write claude "$LAUNCH_MODEL" "")"'
)
for i in "${!ARG_EDITS[@]}"; do
  edit="${ARG_EDITS[$i]#*|}"
  mutant "arg-$i" "${edit%% -> *}" "${edit#* -> }"
  run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-1
  if [[ "${ARG_EDITS[$i]%%|*}" == effort ]]; then
    assert_eq "$RC" 0 "control: omitting effort still launches the cloud session" "$TMP_ROOT/err"
  fi
  assert_eq "line=$([[ "$(pasted 1)" == "$LAUNCH_LINE" ]] && echo held || echo broke)" "line=broke" \
    "control: a launch without the ${ARG_EDITS[$i]%%|*} fails the launch line row" "$TMP_ROOT/err"
done
# The shared argument writer owns alias mapping. Keep the model-id control at
# that owner after the cloud caller stopped writing model arguments itself.
mutant_root model-id
# shellcheck disable=SC2016
mutate_file "$MUTANT_ROOT/scripts/lib/lane-launch.sh" 'if [[ "$1" == claude ]]; then lane_adapter_claude_model_id' 'if [[ "$1" == claude ]] && false; then lane_adapter_claude_model_id'
run_ot SCRIPT="$MUTANT_ROOT/scripts/open-terminal" -- "${CLOUD[@]}" CC-1
assert_eq "line=$([[ "$(pasted 1)" == "$LAUNCH_LINE" ]] && echo held || echo broke)" "line=broke" \
  "control: a launch without model alias mapping fails the launch line row" "$TMP_ROOT/err"
# One per description rule, each broken in turn: the description row fails.
# NAME|OLD -> NEW: --ref restored beside the description, an option the CLI
# does not have, and the description dropped, which the CLI refuses as
# missing.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
DESCRIPTION_EDITS=(
  'ref|$(lane_single_quote "$prompt_file"))\"" -> $(lane_single_quote "$prompt_file"))\" --ref cc-1"'
  'description|--cloud=\"\$(cat -- $(lane_single_quote "$prompt_file"))\"" -> --cloud"'
)
DESCRIPTION_WANTS=("cloud=brief ref=1" "cloud=other ref=0")
for i in "${!DESCRIPTION_EDITS[@]}"; do
  edit="${DESCRIPTION_EDITS[$i]#*|}"
  mutant "description-$i" "${edit%% -> *}" "${edit#* -> }"
  run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-1
  assert_eq "$(described)" "${DESCRIPTION_WANTS[$i]}" \
    "control: a launch line with the ${DESCRIPTION_EDITS[$i]%%|*} rule broken fails the description row" "$TMP_ROOT/err"
done
# The bundle clear dropped again: the CCR_FORCE_BUNDLE row's line no longer clears it.
edit="${ARG_EDITS[1]#*|}"
mutant bundle-row "${edit%% -> *}" "${edit#* -> }"
run_ot SCRIPT="$MUTANT" CCR_FORCE_BUNDLE=1 -- "${CLOUD[@]}" CC-15
assert_eq "clears=$(grep -c '^clear; env -u CCR_FORCE_BUNDLE ' <<<"$(pasted 1)" || true)" "clears=0" \
  "control: a launch line that keeps CCR_FORCE_BUNDLE fails the clear row" "$TMP_ROOT/err"
# The launcher judged away: the launcher row runs under the env prefix.
# shellcheck disable=SC2016
mutant launcher-form 'form="$(lane_launch_form "$cmd" claude "${LANE_ENV#*=}")" || return 1' 'form=prefix'
run_ot SCRIPT="$MUTANT" PATH="$LAUNCHER_BIN:$BIN:$OT_BIN:$PATH" -- "${CLOUD[@]}" CC-16
assert_eq "line=$([[ "$(pasted 1)" == "$LAUNCHER_LINE" ]] && echo launcher || echo other)" "line=other" \
  "control: a launch line that skips the launcher choice fails the launcher row" "$TMP_ROOT/err"
# The form left unrecorded: the account check reads `unchecked` and skips.
# shellcheck disable=SC2016
mutant account-form '  LANE_FORM="$form"' '  :'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-1
assert_eq "account=$(grep -c '^open-terminal: lane-unobserved item=CC-1 reason=' <<<"$ERR" || true)" "account=0" \
  "control: a cloud arm that leaves LANE_FORM unchecked fails the account row" "$TMP_ROOT/err"
# The start wait dropped: the late and the never-seen claude each meet a
# refused nudge and read as an exited CLI, neither under its own line.
# shellcheck disable=SC2016
mutant start-wait '  if ! cloud_cli_wait "$pane"; then' '  if false; then'
late_rows "$MUTANT" CC-60 CC-61
assert_eq "late=$([[ "$LATE" == "rc=0 session=session_01CLOUD" ]] && echo held || echo broke) unseen=$([[ "$UNSEEN" == "rc=1 unseen=1 "* ]] && echo held || echo broke)" \
  "late=broke unseen=broke" "control: without the start wait both rows fail" "$TMP_ROOT/err"
# -p restored beside --cloud, the line the CLI refuses: the print row fails.
# shellcheck disable=SC2016
mutant print 'cmd="claude $choice' 'cmd="claude -p $choice'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-10
assert_eq "print-words=$(print_words)" "print-words=1" "control: a launch line restoring -p fails the print row" "$TMP_ROOT/err"
# One per exited-CLI rule, each removed in turn: the exited row fails. NAME|OLD
# -> NEW: the exit read, and the composer wait's stop at a shell showing no
# URL, without which its nudge meets the shell and is refused.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
EXITED_EDITS=(
  'exit read|if ! lane_pane_by_id "$1" || ! is_bare_shell "$LANE_PANE_CMD"; then return 1; fi -> if true; then return 1; fi'
  'shell stop| 2) return 1 ;; 3) return 4 ;; ->  3) return 4 ;;'
)
for i in "${!EXITED_EDITS[@]}"; do
  edit="${EXITED_EDITS[$i]#*|}"
  mutant "exited-$i" "${edit%% -> *}" "${edit#* -> }"
  exited_row "$MUTANT" "CC-9$i"
  assert_eq "red=$([[ "$EXITED" != "${EXITED_WANT}" ]] && echo yes || echo no)" "red=yes" \
    "control: without the ${EXITED_EDITS[$i]%%|*} the exited row fails" "$TMP_ROOT/err"
done
# The child check dropped: the pane reads as an exited CLI showing no URL.
mutant child-check '    0) return 1 ;;
    1) rc=0 ;;' '    0 | 1) rc=0 ;;'
child_row "$MUTANT" CC-33
assert_eq "red=$([[ "$CHILD" != "$CHILD_WANT" ]] && echo yes || echo no)" "red=yes" \
  "control: without the child check the launcher-child row fails" "$TMP_ROOT/err"
# The failed process read taken as a claude still running: the process-read row's
# pane is nudged and the launch fails under another line.
# shellcheck disable=SC2016
mutant process-unread '*) CLOUD_CLI_UNSEEN=process-read-failed; return 4 ;;' '*) CLOUD_CLI_UNSEEN=process-read-failed; return 1 ;;'
process_row "$MUTANT" CC-35
assert_eq "red=$([[ "$PROCESS" != "$PROCESS_WANT" ]] && echo yes || echo no)" "red=yes" \
  "control: a failed process read taken as a running claude fails the process-read row" "$TMP_ROOT/err"
# The exited CLI's URL left unread: both detached rows fail.
# shellcheck disable=SC2016
mutant detached-read '  cloud_session_read "$1" "$2" 0 || rc=$?' '  rc=1'
for i in "${!DETACHED_ROWS[@]}"; do
  detached_row "$MUTANT" "${DETACHED_ROWS[$i]}" "CC-8$i"
  assert_eq "rc=$RC" "rc=1" "control: without the URL read the ${DETACHED_ROWS[$i]%%|*} row fails" "$TMP_ROOT/err"
done
# The refusal's session read dropped: the account refusal row names none.
if [[ "$PROC_ENV" == true ]]; then
  # shellcheck disable=SC2016
  mutant refusal-read '      ! cloud_session_read "$pane" "$prompt" || session="$CLOUD_SESSION"' '      ! false || session="$CLOUD_SESSION"'
  mismatch_row "$MUTANT" CC-24
  assert_eq "red=$([[ "$MISMATCH" != "$MISMATCH_WANT" ]] && echo yes || echo no)" "red=yes" \
    "control: an account refusal that reads no session fails the refusal row" "$TMP_ROOT/err"
fi
# shellcheck disable=SC2016
mutant session-unread '1) ot_message cloud-session-unread "item=$item" >&2; return 1 ;;' '1) session="" ;;'
screen "$UNREAD_SCREEN"
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-9
assert_eq "rc=$RC" "rc=0" "control: a launch that continues past a missing session id fails the unread row" "$TMP_ROOT/err"
# The URL anchor dropped: the bare id the unread row's pane shows is read.
mutant session-anchor "CLOUD_SESSION_RE='https://claude\.ai/code/((session|cse)_" "CLOUD_SESSION_RE='((session|cse)_"
screen "$UNREAD_SCREEN"
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-11
assert_eq "rc=$RC" "rc=0" "control: a session read without the claude.ai URL anchor fails the unread row" "$TMP_ROOT/err"
# One per session read rule: each removed in turn, its row records another
# session or none.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
SESSION_EDITS=(
  '      if [[ "$2" != *"$url"* ]]; then ->       if true; then'
  '    (( waited < secs )) || return 1 ->     return 1'
  'tmux capture-pane -pJ -S - -t "$1" -> tmux capture-pane -pJ -t "$1"'
  "((session|cse)_[[:alnum:]_-]+)' -> ((session)_[[:alnum:]_-]+)'"
)
for i in "${!SESSION_EDITS[@]}"; do
  edit="${SESSION_EDITS[$i]}"
  IFS='|' read -r name _ _ want _ <<<"${SESSION_ROWS[$i]}"
  mutant "session-$i" "${edit%% -> *}" "${edit#* -> }"
  session_row "$MUTANT" "${SESSION_ROWS[$i]}" "CC-5$i"
  assert_eq "red=$([[ "$SESSION" != "rc=0 session=$want" ]] && echo yes || echo no)" "red=yes" \
    "control: without its rule, the $name row records another session or none" "$TMP_ROOT/err"
done
# shellcheck disable=SC2016
mutant tier-brief 'cloud-session ]]; then RUN_TEXT=""' 'cloud-session ]]; then RUN_TEXT="$BRIEF_TEXT"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-12
assert_eq "$(record CC-12)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:CC-12 $TMP_ROOT/wt/CC-12 running small" \
  "control: a tier read from the brief's quoted orch words fails the record row"
# A verb-less command read as start: the record row states standard, a tier
# the cloud launch never judged.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutant tier-start '| first | .verb) as $verb' '| first | .verb // "start") as $verb'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-37
assert_eq "$(record CC-37)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:CC-37 $TMP_ROOT/wt/CC-37 running standard" \
  "control: a verb-less launch recorded as start fails the record row"
# One per item-tier read rule: each removed in turn, its row records another
# tier or none.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
TIER_EDITS=(
  'if $verb == null then $inputs.tier elif -> if $verb == null then null elif'
  '"^[[:space:]]*(?<line>" + $re + ")[[:space:]]*$" -> "(?<line>" + $re + ")"'
  '| unique | if length == 1 then first else null end -> | first'
)
for i in "${!TIER_EDITS[@]}"; do
  edit="${TIER_EDITS[$i]}"
  IFS='|' read -r name _ want <<<"${TIER_ROWS[$i]}"
  mutant "tier-$i" "${edit%% -> *}" "${edit#* -> }"
  tier_row "$MUTANT" "${TIER_ROWS[$i]}" "CC-4$((i + 3))"
  assert_eq "red=$([[ "$TIER" != "rc=0 $want" ]] && echo yes || echo no)" "red=yes" \
    "control: without its rule, the $name row records another tier or none" "$TMP_ROOT/err"
done
# The card line restored on every launch: the no-card row fails.
# shellcheck disable=SC2016
mutant card-owed '  ot_message cloud-session-started "item=$item" "session=$session"' \
  '  ot_message cloud-session-started "item=$item" "session=$session"
  printf '"'"'open-terminal: cloud-card-owed item=%s session=%s\n'"'"' "$item" "$session" >&2'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-1
assert_eq "owed=$(grep -c "^$OWED" <<<"$ERR" || true)" "owed=1" \
  "control: a launch printing cloud-card-owed with no card observed fails the no-card row" "$TMP_ROOT/err"
# The branch left unfilled: the description names no item branch.
# shellcheck disable=SC2016
mutant branch-fill '    prompt+="${words%%\{branch\}*}$branch"' '    prompt+="${words%%\{branch\}*}{branch}"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-1
assert_eq "$(described) $(branch_named CC-1 cc-1)" "cloud=other ref=0 named=no unfilled=4" \
  "control: session words with {branch} unfilled fail the description and prompt rows"
# Every {branch} gone from the words, in a copy of the lib: the description
# row, which builds its want from the same words, still passes, and the
# prompt row fails.
mutant_root branch-words
perl -0777 -pi -e 's/\{branch\}//g or die "branch-words: matches=0\n"' -- "$MUTANT_ROOT/scripts/lib/lane-launch.sh"
run_ot SCRIPT="$MUTANT_ROOT/scripts/open-terminal" -- "${CLOUD[@]}" CC-1
assert_eq "$(branch_named CC-1 cc-1)" "named=no unfilled=0" \
  "control: session words naming no {branch} fail the prompt row"

echo "=== a cloud claim has no source checkout and accepts a session directive ==="
# A real worktree and push, with network calls mapped to a local bare remote.
# The cloud CLI, tmux, account picker and GitHub reads are stubs.
REAL_WORKTREE="$TEST_DIR/../../worktree/scripts/worktree"
CLAIM_MAIL="$SCRIPTS_DIR/lane-mail"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config commit.gpgsign false
printf 'source payload\n' > "$REPO/payload.txt"
git -C "$REPO" add payload.txt
git -C "$REPO" commit -qm source
git init --bare -q "$TMP_ROOT/origin.git"
git -C "$TMP_ROOT/origin.git" config gc.auto 0
git -C "$TMP_ROOT/origin.git" config maintenance.auto false
git -C "$TMP_ROOT/origin.git" config user.name Test
git -C "$TMP_ROOT/origin.git" config user.email test@example.com
git -C "$TMP_ROOT/origin.git" config commit.gpgsign false
# Keep origin's GitHub identity visible to the bundle check. The transport
# stub adds Git's URL rewrite only to commands that contact the remote.
REAL_GIT="$(command -v git)"
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  case "\$arg" in
    fetch | push | ls-remote)
      exec "$REAL_GIT" -c "url.$TMP_ROOT/origin.git.insteadOf=https://github.com/owner/repo.git" "\$@" ;;
  esac
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN/git"
"$BIN/git" -C "$REPO" push -qu origin main
# A remote merge can advance main after claim creation. This wrapper changes
# the bare remote only after the real worktree has returned its claim path.
cat > "$BIN/claim-worktree" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" != create ]]; then exec "\$CLAIM_WORKTREE" "\$@"; fi
claim="\$("\$CLAIM_WORKTREE" "\$@")"
"\$CLAIM_WORKTREE" repair-links "\$claim"
git -C "\$claim" rev-parse HEAD > "$TMP_ROOT/claim-head"
if [[ "\${CLAIM_ADVANCE_BASE:-false}" == true ]]; then
  previous="\$(git -C "$TMP_ROOT/origin.git" rev-parse refs/heads/main)"
  blob="\$(printf '%s\n' "remote change \$previous" | git -C "$TMP_ROOT/origin.git" hash-object -w --stdin)"
  tree="\$(printf '100644 blob %s\tpayload.txt\n' "\$blob" | git -C "$TMP_ROOT/origin.git" mktree)"
  advanced="\$(printf 'remote merge\n' | git -C "$TMP_ROOT/origin.git" commit-tree "\$tree" -p "\$previous")"
  git -C "$TMP_ROOT/origin.git" update-ref refs/heads/main "\$advanced" "\$previous"
fi
printf '%s\n' "\$claim"
EOF
chmod +x "$BIN/claim-worktree"
# The fleet's real push guard holds the index to the pushed commit. It reads
# committed files through Git, so an absent source checkout can still pass.
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$TEST_DIR/../../commit-guards/scripts/pre-push" > "$REPO/.git/hooks/pre-push"
chmod +x "$REPO/.git/hooks/pre-push"
printf 'private setup\n' > "$REPO/private.txt"
printf 'copied setup\n' > "$REPO/copy.txt"
cat > "$CLAUDE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{ printf 'argv=%s\nconfig=%s\nstdin=' "$*" "${CLAUDE_CONFIG_DIR:-}"; cat; } > "$STUB_CLAUDE_LOG"
printf '{"ok":true}\n'
EOF

claim_row() { # OPEN_TERMINAL WORKTREE ITEM [ADVANCE_BASE=false]
  local claim git_dir mail_rc=0 mail_out base=same
  run_ot SCRIPT="$1" WORKTREE_CLI="$BIN/claim-worktree" CLAIM_WORKTREE="$2" CLAIM_ADVANCE_BASE="${4:-false}" \
    STUB_GH_OK=1 WORKTREE_DEFAULT_BRANCH=main \
    COMMIT_GUARDS_CHECKS=byte-ceiling \
    WORKTREE_BASE_DIR="$TMP_ROOT/claims-real" WORKTREE_SYMLINKS="private.txt" WORKTREE_COPIES="copy.txt" \
    WORKTREE_MKDIRS="scratch" -- "${CLOUD[@]}" "$3"
  [[ "$RC" -eq 0 ]] || { CLAIM_RESULT="launch=$RC"; return; }
  CLAIM_HEAD="$(cat "$TMP_ROOT/claim-head")"
  [[ "$(git -C "$TMP_ROOT/origin.git" rev-parse refs/heads/main)" == "$CLAIM_HEAD" ]] || base=advanced
  claim="$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$3"'") | .mail_root')"
  git_dir="$(git -C "$claim" rev-parse --absolute-git-dir)"
  mail_out="$(cd "$REPO" && env PATH="$CLAUDE_BIN:$BIN:$OT_BIN:$PATH" STUB_CLAUDE_LOG="$TMP_ROOT/directive.log" \
    "$CLAIM_MAIL" send --item "$3" --directive --file "$BRIEF" --state-dir "$STATE" 2>"$TMP_ROOT/mail.err")" || mail_rc=$?
  CLAIM_RESULT="launch=$RC files=$(find "$claim" -mindepth 1 -maxdepth 1 ! -name .git -print | wc -l | tr -d ' ') source=$([[ -f "$claim/payload.txt" ]] && echo yes || echo no) branch=$(git -C "$claim" symbolic-ref --short HEAD) claim=$(cat "$git_dir/kendex-issue") pushed=$(git -C "$TMP_ROOT/origin.git" rev-parse "refs/heads/$(git -C "$claim" symbolic-ref --short HEAD)") prompt=$([[ -s "$git_dir/cloud-prompt" ]] && echo yes || echo no) mail=$mail_rc base=$base"
  assert_eq "$mail_out" "lane-mail: sent item=$3 channel=session session=session_01CLOUD" \
    "the claim record routes its directive to the cloud session" "$TMP_ROOT/mail.err"
  assert_eq "$(cat "$TMP_ROOT/directive.log")" "argv=-p --cloud session_01CLOUD --output-format json"$'\n'"config=$LANE_DIR"$'\n'"stdin=$(cat "$BRIEF")" \
    "the session receives the directive under the record's account"
}
CLAIM_ROWS=('same|false|CC-101|cc-101' 'advanced|true|CC-105|cc-105')
for row in "${CLAIM_ROWS[@]}"; do
  IFS='|' read -r base advance item branch <<<"$row"
  claim_row "$OT" "$REAL_WORKTREE" "$item" "$advance"
  assert_eq "$CLAIM_RESULT" "launch=0 files=0 source=no branch=$branch claim=$branch pushed=$CLAIM_HEAD prompt=yes mail=0 base=$base" \
    "with a $base remote base, the cloud launch keeps the claim source-free, retains its prompt, pushes its snapshot and permits a directive" "$TMP_ROOT/err"
  claim="$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$item"'") | .mail_root')"
  git clone -q -b "$branch" "$TMP_ROOT/origin.git" "$TMP_ROOT/cloud-$branch"
  git -C "$TMP_ROOT/cloud-$branch" config user.name Test
  git -C "$TMP_ROOT/cloud-$branch" config user.email test@example.com
  git -C "$TMP_ROOT/cloud-$branch" config commit.gpgsign false
  git -C "$TMP_ROOT/cloud-$branch" config gc.auto 0
  git -C "$TMP_ROOT/cloud-$branch" config maintenance.auto false
  printf 'cloud work\n' > "$TMP_ROOT/cloud-$branch/cloud.txt"
  git -C "$TMP_ROOT/cloud-$branch" add cloud.txt
  git -C "$TMP_ROOT/cloud-$branch" commit -qm cloud
  git -C "$TMP_ROOT/cloud-$branch" push -q origin "$branch"
  cloud_head="$(git -C "$TMP_ROOT/cloud-$branch" rev-parse HEAD)"
  stale_push_rc=0
  (cd "$REPO" && env PATH="$BIN:$OT_BIN:$PATH" WORKTREE_DEFAULT_BRANCH=main COMMIT_GUARDS_CHECKS=byte-ceiling \
    WORKTREE_BASE_DIR="$TMP_ROOT/claims-real" "$REAL_WORKTREE" push "$item" > "$TMP_ROOT/stale-push.out" 2> "$TMP_ROOT/stale-push.err") || stale_push_rc=$?
  assert_eq "rc=$stale_push_rc local=$(git -C "$claim" rev-parse HEAD) remote=$(git -C "$TMP_ROOT/origin.git" rev-parse "refs/heads/$branch") files=$(find "$claim" -mindepth 1 -maxdepth 1 ! -name .git -print | wc -l | tr -d ' ')" \
    "rc=1 local=$CLAIM_HEAD remote=$cloud_head files=0" \
    "a stale claim publication preserves cloud commits and leaves the claim source-free" "$TMP_ROOT/stale-push.err"
  landing_rc=0
  (cd "$REPO" && env PATH="$BIN:$OT_BIN:$PATH" STUB_GH_OK=1 WORKTREE_DEFAULT_BRANCH=main \
    WORKTREE_BASE_DIR="$TMP_ROOT/claims-real" WORKTREE_SYMLINKS="private.txt" WORKTREE_COPIES="copy.txt" \
    WORKTREE_MKDIRS="scratch" "$REAL_WORKTREE" create "$item" --reuse > "$TMP_ROOT/landing.out" 2> "$TMP_ROOT/landing.err") || landing_rc=$?
  assert_eq "rc=$landing_rc head=$(git -C "$claim" rev-parse HEAD) source=$([[ -f "$claim/payload.txt" ]] && echo yes || echo no) cloud=$(cat "$claim/cloud.txt" 2>/dev/null || true) link=$([[ -L "$claim/private.txt" ]] && echo yes || echo no) copy=$(cat "$claim/copy.txt" 2>/dev/null || true) dir=$([[ -d "$claim/scratch" ]] && echo yes || echo no)" \
    "rc=0 head=$cloud_head source=yes cloud=cloud work link=yes copy=copied setup dir=yes" \
    "local landing gets cloud commits and project setup from the real launched claim" "$TMP_ROOT/landing.err"
done

# A publication consumer must use the owner's persisted claim state.
mkdir -p "$TMP_ROOT/publication-mutant/worktree"
cp -R "$TEST_DIR/../../worktree/scripts" "$TMP_ROOT/publication-mutant/worktree/scripts"
# shellcheck disable=SC2016
mutate_file "$TMP_ROOT/publication-mutant/worktree/scripts/worktree" 'if [[ "$PUSH_CHECKOUT_MODE" == claim ]]; then AUTO_REBASE=false; fi' 'if [[ "$PUSH_CHECKOUT_MODE" == claim ]]; then AUTO_REBASE=true; fi'
claim_row "$OT" "$TMP_ROOT/publication-mutant/worktree/scripts/worktree" CC-106 true
assert_eq "$CLAIM_RESULT" "launch=1" \
  "control: ignoring the claim state fails advanced-base publication" "$TMP_ROOT/err"
assert_contains "$ERR" "worktree-push-rebase-failed:" \
  "control: the advanced-base row reaches the real rebase failure" "$TMP_ROOT/err"

# Shared checkout hooks must leave remote-work claims without file setup.
mutate_file "$TMP_ROOT/publication-mutant/worktree/scripts/worktree" 'if [[ "$PUSH_CHECKOUT_MODE" == claim ]]; then AUTO_REBASE=true; fi' 'if [[ "$PUSH_CHECKOUT_MODE" == claim ]]; then AUTO_REBASE=false; fi'
mutate_file "$TMP_ROOT/publication-mutant/worktree/scripts/worktree" 'if [[ "$REPAIR_CHECKOUT_MODE" == claim ]]; then exit 0; fi' 'if [[ "$REPAIR_CHECKOUT_MODE" == claim ]]; then :; fi'
claim_row "$OT" "$TMP_ROOT/publication-mutant/worktree/scripts/worktree" CC-107
assert_eq "launch=$([[ "$CLAIM_RESULT" == 'launch=0 '* ]] && echo yes || echo no) setup=$([[ "$CLAIM_RESULT" == 'launch=0 files=0 '* ]] && echo absent || echo present)" "launch=yes setup=present" \
  "control: hook repair that ignores claim state writes file setup"

# Each producer of a checkout can break this contract: the launcher omitting
# the option, and worktree create ignoring it. Both leave source files.
# shellcheck disable=SC2016
mutant claim-checkout 'create "$wt_id" --no-checkout' 'create "$wt_id"'
claim_row "$MUTANT" "$REAL_WORKTREE" CC-102
assert_eq "full=$([[ "$CLAIM_RESULT" == 'launch=0 files='*' source=yes '* ]] && echo yes || echo no)" "full=yes" \
  "control: a full source checkout fails the cloud claim row"
mkdir -p "$TMP_ROOT/claim-mutant/worktree"
cp -R "$TEST_DIR/../../worktree/scripts" "$TMP_ROOT/claim-mutant/worktree/scripts"
# shellcheck disable=SC2016
mutate_file "$TMP_ROOT/claim-mutant/worktree/scripts/worktree" 'CHECKOUT_ARGS=(--no-checkout)' 'CHECKOUT_ARGS=()'
claim_row "$OT" "$TMP_ROOT/claim-mutant/worktree/scripts/worktree" CC-103
assert_eq "full=$([[ "$CLAIM_RESULT" == 'launch=0 files='*' source=yes '* ]] && echo yes || echo no)" "full=yes" \
  "control: create ignoring the checkout option fails the cloud claim row"
# shellcheck disable=SC2016
mutate_file "$TMP_ROOT/claim-mutant/worktree/scripts/worktree" 'git -C "$wt" read-tree HEAD || return 1' 'git -C "$wt" read-tree --empty || return 1'
claim_row "$OT" "$TMP_ROOT/claim-mutant/worktree/scripts/worktree" CC-104
assert_eq "$CLAIM_RESULT" "launch=1" "control: an empty index blocks the claim branch push"
assert_contains "$ERR" "pre-push: index-drift=" "the push guard refuses the empty index" "$TMP_ROOT/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
