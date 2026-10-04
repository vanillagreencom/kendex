#!/usr/bin/env bash
# open-terminal's launch=cloud-session arm, the claude-cloud host kind: the
# refusals of what a cloud session cannot take, tmux mode among them, the
# cloud-bundle-risk check, the item worktree and its pushed branch, the item's
# window opened in that worktree running `claude --cloud` interactively, never
# with -p or --print, under the lane's account, naming the lane's model id and
# the pushed branch as --ref with CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
# in its environment, the brief file closed by the session words sent as its
# first prompt once the composer is up, the CLI exiting before that as a
# failed launch, the session id the claude.ai session URL in the pane carries,
# and the lane record naming the kind, the account, that id and the window,
# and the standard tier whatever orch words the brief quotes. A kind whose
# launch this build does not make refuses as kind-unbuilt.
#
# The suite runs a copy of open-terminal beside the real lane-host, which
# declares the claude-cloud line, in a temp git repo whose origin is a
# github.com URL; the worktree CLI, gh, lanes and tmux are stubs, the pane the
# stub draws standing in for the `claude` CLI.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_HOST CCR_FORCE_BUNDLE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
export ORCH_OVERSEER_LANES=1000
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
# clears every lane. tmux holds one window, pane %1, whose new-window call it
# logs to $TMUX_DIR/calls with every key pressed, and keeps the Nth paste's
# text in $TMUX_DIR/paste.N. The pane runs its shell until the first paste,
# the launch line, then claude, and draws: before the launch line nothing;
# after it a dialog until STUB_DIALOG_KEYS keys have been pressed, the launch
# line's Enter among them, then the empty composer, or with STUB_CLAUDE_REFUSE=1 the CLI's refusal of --ref and
# the shell again; after the second paste, the brief, STUB_SCREEN. The worktree stub logs
# every call, makes the item's directory on create, a git checkout on the
# item's lowercased branch unless STUB_WT_PLAIN=1, and exits STUB_PUSH_EXIT on
# push.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
cat > "$BIN/lanes" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "[]" ;;
  pick)
    if [[ "${STUB_LANES_REPO_UNSET:-false}" == true ]]; then
      printf 'lanes: cloud-repo-unset account=%s repo=owner/repo\n' "$3" >&2
      exit 7
    fi
    ;;
esac
exit 0
EOF
TMUX_DIR="$TMP_ROOT/tmux"
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
d="$STUB_TMUX_DIR"
pastes="$(cat "$d/pastes" 2>/dev/null || echo 0)"
keys="$(grep -c '^key ' "$d/calls" 2>/dev/null || true)"
running=bash
[[ "$pastes" -eq 0 || "${STUB_CLAUDE_REFUSE:-}" == 1 ]] || running=claude
case "${1:-}" in
  has-session | set-option | paste-buffer) ;;
  list-windows) echo 1 ;;
  new-window) printf '%s\n' "$*" >> "$d/calls"; echo "$$ %1" ;;
  display-message) echo 0 ;;
  list-panes) printf '%%1 %s %s\n' "$$" "$running" ;;
  load-buffer) pastes=$((pastes + 1)); echo "$pastes" > "$d/pastes"; cat > "$d/paste.$pastes" ;;
  send-keys) printf 'key %s\n' "${*: -1}" >> "$d/calls" ;;
  capture-pane)
    if [[ "$pastes" -ge 2 ]]; then printf '%s\n' "$STUB_SCREEN"
    elif [[ "$pastes" -eq 0 ]]; then :
    elif [[ "${STUB_CLAUDE_REFUSE:-}" == 1 ]]; then echo 'Error: --ref cc-1 cannot be honored: the GitHub App is not set up for this repository'
    elif [[ "$keys" -lt "${STUB_DIALOG_KEYS:-0}" ]]; then echo 'Do you trust the files in this folder?'
    else printf '\xe2\x9d\xaf\xc2\xa0\n'; fi ;;
  *) echo "unexpected tmux stub call: $*" >&2; exit 1 ;;
esac
EOF
WT_LOG="$TMP_ROOT/worktree.log"
cat > "$BIN/worktree" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$WT_LOG"
case "\${1:-}" in
  create)
    mkdir -p "$TMP_ROOT/wt/\$2"
    if [[ "\${STUB_WT_PLAIN:-}" != 1 ]]; then
      git init -q "$TMP_ROOT/wt/\$2"
      git -C "$TMP_ROOT/wt/\$2" config gc.auto 0
      git -C "$TMP_ROOT/wt/\$2" config maintenance.auto false
      git -C "$TMP_ROOT/wt/\$2" symbolic-ref HEAD "refs/heads/\$(printf '%s' "\$2" | tr '[:upper:]' '[:lower:]')"
    fi
    printf '%s\n' "$TMP_ROOT/wt/\$2" ;;
  push) exit "\${STUB_PUSH_EXIT:-0}" ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$BIN/gh" "$BIN/lanes" "$BIN/tmux" "$BIN/worktree"

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
# The overseer's brief, the item's whole task, quotes and all, and the first
# prompt the pane takes for it, closed by the session words. It quotes an orch
# tier word, as an issue's text can.
BRIEF="$TMP_ROOT/brief.md"
# shellcheck disable=SC2016  # the brief's own backticks.
printf '%s\n' "Fix the parser's \"--flag\" handling." '' 'Done when: `parse --flag` exits 0 under /orch small runs.' > "$BRIEF"
PROMPT="$(cat "$BRIEF")"$'\n\n'"$SESSION_TEXT"

# run_ot [SCRIPT=PATH] [ENV=VALUE...] -- ARGS... — one cloud launch of ARGS
# from the repo in tmux session `fleet`; sets RC and ERR, and resets the
# worktree log, the tmux stub's pane, the lane claims and the item worktrees
# first.
run_ot() {
  local script="$OT" env_args=()
  [[ "${1:-}" != SCRIPT=* ]] || { script="${1#SCRIPT=}"; shift; }
  while [[ "${1:-}" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f -- "${TMP_ROOT:?}/worktree.log"
  rm -rf -- "${TMP_ROOT:?}/wt" "${TMP_ROOT:?}/tmux" "${TMP_ROOT:?}/claims"
  mkdir -p "$TMUX_DIR"
  set +e
  # The ceiling keeps a plain item directory outside every repository wherever
  # TMPDIR sits, so its branch read fails as a real one does.
  (cd "$REPO" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" PATH="$BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" WORKTREE_CLI="$BIN/worktree" \
    LANES_CLI="$BIN/lanes" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' GH_REPO="" TMUX="" TMUX_PANE="" \
    ORCH_TMUX_SESSION=fleet ORCH_TMUX_VERIFY_SECS=1 STUB_TMUX_DIR="$TMUX_DIR" STUB_SCREEN="$STARTED" \
    ${env_args[@]+"${env_args[@]}"} "$script" "$@" >/dev/null 2>"$TMP_ROOT/err")
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}
# Its model is an alias the claude adapter maps, so the arguments row reads the id.
CLOUD=(--host claude-cloud --harness claude --lane "$LANE_DIR" --launch-flags "--model sonnet --effort high" --brief-file "$BRIEF" --state-dir "$STATE")
record() {
  "$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "'"$1"'")] | first // {} | [.host, .kind, .account, .session_id, .window, .mail_root, .status, .tier] | map(. // "null") | join(" ")'
}
# `ran` where the pane took an Nth paste, `none` where it did not.
typed() { [[ -e "$TMUX_DIR/paste.$1" ]] && echo ran || echo none; }
# The Nth text pasted into the pane, `none` where there was no Nth paste.
pasted() { if [[ -f "$TMUX_DIR/paste.$1" ]]; then cat -- "$TMUX_DIR/paste.$1"; else echo none; fi; }
LAUNCH_LINE="clear; env CLAUDE_CONFIG_DIR='$LANE_DIR' CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude --cloud --model 'claude-sonnet-5' --ref 'cc-1'"
# Whether the launch line holds -p or --print as a word: the CLI refuses
# either beside --cloud.
print_words() { local word n=0; for word in $(pasted 1); do [[ "$word" != -p && "$word" != --print ]] || n=$((n + 1)); done; echo "$n"; }
made() { [[ -e "$WT_LOG" ]] && echo yes || echo no; }

echo "=== a cloud session is launched from the item's pushed branch and recorded ==="
run_ot -- "${CLOUD[@]}" CC-1
assert_eq "rc=$RC worktree=$(paste -sd, "$WT_LOG")" "rc=0 worktree=create CC-1,push CC-1 --set-upstream" \
  "the launch creates the item worktree and pushes its branch before the session" "$TMP_ROOT/err"
assert_eq "$(grep -c -- "^new-window .* -n CC-1 -c $TMP_ROOT/wt/CC-1 " "$TMUX_DIR/calls" || true)" 1 \
  "the item's window opens in the item worktree"
assert_eq "print-words=$(print_words)" "print-words=0" "the launch line holds neither -p nor --print"
assert_eq "$(pasted 1)" "$LAUNCH_LINE" \
  "the window runs claude --cloud interactively under the lane's account, the lane's model by its id, the pushed item branch by --ref and the #81776 workaround"
assert_eq "prompt=$([[ "$(pasted 2)" == "$PROMPT" ]] && echo brief || echo other)" "prompt=brief" \
  "the first prompt is the brief file's text closed by the session words, never a start command or the mailbox words"
assert_eq "$(record CC-1)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:CC-1 $TMP_ROOT/wt/CC-1 running standard" \
  "the record names the host and kind, the account, the session id the pane's URL carries, the window, and the standard tier the brief's orch words leave"
assert_eq "owed=$(grep -cxF 'open-terminal: cloud-card-owed item=CC-1 session=session_01CLOUD' <<<"$ERR" || true)" "owed=1" \
  "the launch leaves the repository card to the operator and says so"

echo "=== a first-run dialog takes one Enter before the first prompt ==="
run_ot STUB_DIALOG_KEYS=2 -- "${CLOUD[@]}" CC-14
assert_eq "rc=$RC keys=$(grep -c '^key Enter$' "$TMUX_DIR/calls" || true) prompt=$([[ "$(pasted 2)" == "$PROMPT" ]] && echo brief || echo other) session=$(record CC-14 | cut -d' ' -f4)" \
  "rc=0 keys=3 prompt=brief session=session_01CLOUD" \
  "one nudge dismisses the dialog, then the brief is sent and the session recorded" "$TMP_ROOT/err"

echo "=== a named account with no repository entry stops before launch ==="
run_ot STUB_LANES_REPO_UNSET=true -- "${CLOUD[@]}" CC-30
assert_eq "rc=$RC refused=$(grep -cxF "lanes: cloud-repo-unset account=$LANE_DIR repo=owner/repo" <<<"$ERR" || true) made=$(made) claude=$(typed 1)" \
  "rc=1 refused=1 made=no claude=none" "the launcher preserves the repository refusal and starts nothing" "$TMP_ROOT/err"
CTRL="$(mutant_scripts mutant-named-cloud-repo open-terminal)" || exit 1
mutate_file "$CTRL/open-terminal" '7) return 1 ;;' '7) : ;;'
run_ot SCRIPT="$CTRL/open-terminal" STUB_LANES_REPO_UNSET=true -- "${CLOUD[@]}" CC-31
assert_eq "rc=$RC made=$(made) claude=$(typed 1)" \
  "rc=0 made=yes claude=ran" "control: ignoring the repository refusal launches the cloud session" "$TMP_ROOT/err"

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
# CAUSE|ENV|SETUP: the setup runs before the launch and is undone after it.
BUNDLE_ROWS=(
  "shell|CCR_FORCE_BUNDLE=0|"
  "settings path=$TMP_ROOT/bundling/settings.json|LANE=$TMP_ROOT/bundling|"
  "settings path=$REPO/.claude/settings.json||cp $TMP_ROOT/bundling/settings.json $REPO/.claude/settings.json"
  "remote||git -C $REPO remote set-url origin https://gitlab.example/owner/repo.git"
)
bundle_row() { # SCRIPT ROW — the launch, with RC and ERR set
  local cause env setup lane="$LANE_DIR" envs=()
  IFS='|' read -r cause env setup <<<"$2"
  case "$env" in LANE=*) lane="${env#LANE=}" ;; ?*) envs=("$env") ;; esac
  [[ -z "$setup" ]] || $setup
  run_ot SCRIPT="$1" ${envs[@]+"${envs[@]}"} -- --host claude-cloud --harness claude --lane "$lane" \
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

echo "=== a pane showing no claude.ai session URL stops there ==="
# The session id bare, outside the URL the anchored read takes.
UNREAD_SCREEN='Started session_01CLOUD'
run_ot STUB_SCREEN="$UNREAD_SCREEN" -- "${CLOUD[@]}" CC-3
assert_eq "rc=$RC unread=$(grep -cxF 'open-terminal: cloud-session-unread item=CC-3' <<<"$ERR" || true) record=$(record CC-3)" \
  "rc=1 unread=1 record=null null null null null null null null" "no URL in the pane is no record and a failed item" "$TMP_ROOT/err"

echo "=== a failed push, branch read or composer stops with no record ==="
# ENV|LINE|CLAUDE|WORKTREE|OLD -> NEW: the stub's failure, the refusal line
# past its key word, whether claude's line was typed, the worktree calls
# made, and the control's edit, the guard's text kept and its behaviour
# removed; the edit is the rest of the row, `|` and all. The pane of a
# composer that never came up still shows the session URL once a brief lands,
# so the guard alone stops the launch.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
FAILURE_ROWS=(
  'STUB_PUSH_EXIT=1|cloud-push-failed item=CC-20|none|create CC-20,push CC-20 --set-upstream||| { ot_message cloud-push-failed -> || true || { ot_message cloud-push-failed'
  'STUB_WT_PLAIN=1|cloud-branch-unread item=CC-25|none|create CC-25||| { ot_message cloud-branch-unread -> || true || { ot_message cloud-branch-unread'
  'STUB_DIALOG_KEYS=9|cloud-composer-stuck item=CC-26|ran|create CC-26,push CC-26 --set-upstream|  if [[ "$rc" -ne 0 ]]; then -> if false; then'
)
failure_row() { # SCRIPT ROW ITEM — the launch, with RC and ERR set
  local env line item
  IFS='|' read -r env line _ <<<"$2"
  item="${line#* item=}"
  run_ot SCRIPT="$1" "$env" -- "${CLOUD[@]}" "${3:-${item%% *}}"
}
for row in "${FAILURE_ROWS[@]}"; do
  IFS='|' read -r _ line claude wt _ <<<"$row"
  item="${line#* item=}"
  failure_row "$OT" "$row"
  assert_eq "rc=$RC refused=$(grep -cxF "open-terminal: $line" <<<"$ERR" || true) claude=$(typed 1) prompt=$(typed 2) worktree=$(paste -sd, "$WT_LOG") record=$(record "${item%% *}")" \
    "rc=1 refused=1 claude=$claude prompt=none worktree=$wt record=null null null null null null null null" "${line%% *} stops the launch with no brief sent and no record" "$TMP_ROOT/err"
done

echo "=== a CLI that exits before its composer is a failed launch ==="
run_ot STUB_CLAUDE_REFUSE=1 -- "${CLOUD[@]}" CC-21
assert_eq "rc=$RC refused=$(grep -cxF 'open-terminal: cloud-launch-failed item=CC-21' <<<"$ERR" || true) prompt=$(typed 2) record=$(record CC-21)" \
  "rc=1 refused=1 prompt=none record=null null null null null null null null" \
  "a refused --ref ends claude in the pane, which stops the launch as cloud-launch-failed" "$TMP_ROOT/err"

echo "=== the launch arm is the declared launch ==="
CODEX_LINE=$'kind=codex-cloud\tlaunch=cloud-task\tchannel=task\tfiles=none\tstatus=task\tstop=none\trelaunch=fresh\tpark=none\taccounts=none\tpool=plan\tland=handoff'
cp "$TEST_DIR/fixtures/lane-host" "$TMP_ROOT/provider"
run_ot LANE_HOST_STUB_LOG="$TMP_ROOT/provider.log" LANE_HOST_STUB_CAPABILITIES="$CODEX_LINE" -- \
  --host "$TMP_ROOT/provider" --harness claude --lane "$LANE_DIR" --launch-flags "--model opus --effort high" CC-4
assert_eq "rc=$RC refused=$(grep -cxF 'open-terminal: kind-unbuilt kind=codex-cloud' <<<"$ERR" || true) made=$(made)" \
  "rc=1 refused=1 made=no" "a kind declaring launch=cloud-task refuses as kind-unbuilt" "$TMP_ROOT/err"

echo "=== controls ==="
# mutant NAME OLD NEW — a copy of open-terminal with one rule removed, laid
# out as the suite's copy is, its path in MUTANT.
mutant() {
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/scripts"
  cp -R "$REPO/scripts/." "$root/scripts/"
  orch_fixture_shared_libs "$root"
  git -C "$root" init -q
  mutate_file "$root/scripts/open-terminal" "$2" "$3"
  MUTANT="$root/scripts/open-terminal"
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
cause_control 0 'if [[ -n "${CCR_FORCE_BUNDLE+set}" ]]; then' 'if false; then'
# shellcheck disable=SC2016
cause_control 1 "jq -e '(.env.CCR_FORCE_BUNDLE // null | tostring) != \"1\"' \"\$file\" >/dev/null 2>&1" 'true'
# shellcheck disable=SC2016
cause_control 3 'kendex_github_origin_slug "$CLAIM_ROOT" >/dev/null' 'true'
# shellcheck disable=SC2016
mutant task-close 'text "$BRIEF_TEXT"$'"'"'\n\n'"'"'"$LAUNCH_SESSION_TEXT"' 'text "$BRIEF_TEXT"$'"'"'\n\n'"'"'"$LAUNCH_UNATTENDED_TEXT"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-6
assert_eq "prompt=$([[ "$(pasted 2)" == "$PROMPT" ]] && echo brief || echo other)" "prompt=other" \
  "control: a first prompt closing on the mailbox words fails the prompt row"
# shellcheck disable=SC2016
mutant record-kind '"$HOST_KIND" \' '"" \'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-7
assert_eq "$(record CC-7)" "claude-cloud null $LANE_DIR session_01CLOUD fleet:CC-7 $TMP_ROOT/wt/CC-7 running standard" \
  "control: a record written without the kind fails the record row"
# shellcheck disable=SC2016
mutant record-window 'lane_record_write "$RECORD_MODE" "$wt_id" "$LAUNCH_SESSION:$title" "$wt"' 'lane_record_write "$RECORD_MODE" "$wt_id" "" "$wt"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-8
assert_eq "$(record CC-8)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD null $TMP_ROOT/wt/CC-8 running standard" \
  "control: a record written with no window fails the record row"
# One per failure guard: each removed in turn, its row's launch is recorded.
for i in "${!FAILURE_ROWS[@]}"; do
  IFS='|' read -r _ line _ _ edit <<<"${FAILURE_ROWS[$i]}"
  mutant "failure-$i" "${edit%% -> *}" "${edit#* -> }"
  failure_row "$MUTANT" "${FAILURE_ROWS[$i]}" "CC-2$((i + 2))"
  assert_eq "$(record "CC-2$((i + 2))")" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:CC-2$((i + 2)) $TMP_ROOT/wt/CC-2$((i + 2)) running standard" \
    "control: without its guard, the ${line%% *} row is recorded" "$TMP_ROOT/err"
done
# The branch read kept, moved below the push: the unread row pushes.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
BRANCH_READ='  branch="$(git -C "$wt" symbolic-ref --short HEAD)" || { ot_message cloud-branch-unread "item=$item" >&2; return 1; }'
# shellcheck disable=SC2016
PUSH='  "$WORKTREE_CLI" push "$wt_id" --set-upstream >&2 || { ot_message cloud-push-failed "item=$item" >&2; return 1; }'
mutant branch-after-push "$BRANCH_READ"$'\n'"$PUSH" "$PUSH"$'\n'"$BRANCH_READ"
failure_row "$MUTANT" "${FAILURE_ROWS[1]}"
assert_eq "worktree=$(paste -sd, "$WT_LOG")" "worktree=create CC-25,push CC-25 --set-upstream" \
  "control: a branch read below the push fails the cloud-branch-unread row's worktree calls" "$TMP_ROOT/err"
# One per launch argument: each removed in turn fails the launch line row.
# NAME|OLD -> NEW: the argument and the edit that drops it.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
ARG_EDITS=(
  'workaround| CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" -> "'
  'model| --model $(lane_single_quote "$model") -> '
  'model id|model="$(launch_choice_model_id claude "$LAUNCH_MODEL")" -> model="$LAUNCH_MODEL"'
  'ref| --ref $(lane_single_quote "$branch") -> '
)
for i in "${!ARG_EDITS[@]}"; do
  edit="${ARG_EDITS[$i]#*|}"
  mutant "arg-$i" "${edit%% -> *}" "${edit#* -> }"
  run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-1
  assert_eq "line=$([[ "$(pasted 1)" == "$LAUNCH_LINE" ]] && echo held || echo broke)" "line=broke" \
    "control: a launch without the ${ARG_EDITS[$i]%%|*} fails the launch line row" "$TMP_ROOT/err"
done
# -p restored beside --cloud, the line the CLI refuses: the print row fails.
mutant print 'claude --cloud --model' 'claude -p --cloud --model'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-10
assert_eq "print-words=$(print_words)" "print-words=1" "control: a launch line restoring -p fails the print row" "$TMP_ROOT/err"
# The classification removed: a CLI that exited reads as cloud-launch-failed no more.
# shellcheck disable=SC2016
mutant cli-exit 'if lane_pane_by_id "$pane" && is_bare_shell "$LANE_PANE_CMD"; then' 'if false; then'
run_ot SCRIPT="$MUTANT" STUB_CLAUDE_REFUSE=1 -- "${CLOUD[@]}" CC-21
assert_eq "refused=$(grep -cxF 'open-terminal: cloud-launch-failed item=CC-21' <<<"$ERR" || true)" "refused=0" \
  "control: without the exit read the refused --ref row is not cloud-launch-failed" "$TMP_ROOT/err"
# shellcheck disable=SC2016
mutant session-unread '1) ot_message cloud-session-unread "item=$item" >&2; return 1 ;;' '1) session="" ;;'
run_ot SCRIPT="$MUTANT" STUB_SCREEN="$UNREAD_SCREEN" -- "${CLOUD[@]}" CC-9
assert_eq "rc=$RC" "rc=0" "control: a launch that continues past a missing session id fails the unread row" "$TMP_ROOT/err"
# The URL anchor dropped: the bare id the unread row's pane shows is read.
mutant session-anchor "CLOUD_SESSION_RE='https://claude\.ai/code/(session_" "CLOUD_SESSION_RE='(session_"
run_ot SCRIPT="$MUTANT" STUB_SCREEN="$UNREAD_SCREEN" -- "${CLOUD[@]}" CC-11
assert_eq "rc=$RC" "rc=0" "control: a session read without the claude.ai URL anchor fails the unread row" "$TMP_ROOT/err"
# shellcheck disable=SC2016
mutant tier-brief '[[ "$HOST_LAUNCH" == cloud-session ]] || TIER_TEXT+=' 'TIER_TEXT+='
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-12
assert_eq "$(record CC-12)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD fleet:CC-12 $TMP_ROOT/wt/CC-12 running small" \
  "control: a tier read from the brief's quoted orch words fails the record row"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
