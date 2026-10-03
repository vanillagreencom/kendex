#!/usr/bin/env bash
# open-terminal's launch=cloud-session arm, the claude-cloud host kind: the
# refusals of what a cloud session cannot take, the cloud-bundle-risk check,
# the item worktree and its pushed branch, one `claude -p --cloud` under the
# lane's account in that worktree whose task is the brief file closed by the
# session words, the session id it prints, and the lane record naming the
# kind, the account and that id with no window. A launch that failed after its
# create launches again over the tree it left. A kind whose launch this build
# does not make refuses as kind-unbuilt.
#
# The suite runs a copy of open-terminal beside the real lane-host, which
# declares the claude-cloud line, in a temp git repo whose origin is a
# github.com URL; the worktree CLI, gh, lanes and the `claude` CLI are stubs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_HOST CCR_FORCE_BUNDLE
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
# clears every lane. `claude` logs its CLAUDE_CONFIG_DIR and its working
# directory under a `--` separator, then its argv one %q-quoted word a line,
# prints STUB_CLAUDE_OUT and exits STUB_CLAUDE_EXIT. The worktree stub logs
# every call and makes the item's directory on create, which exits 75, the
# ownership claim, where that directory stands and no --reuse asserts it.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in list) echo "[]" ;; esac\nexit 0\n' > "$BIN/lanes"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
{ printf -- '--\n'; printf 'config=%s\ncwd=%s\n' "${CLAUDE_CONFIG_DIR:-}" "$PWD"; printf '%q\n' "$@"; } >> "$STUB_CLAUDE_LOG"
printf '%s\n' "$STUB_CLAUDE_OUT"
exit "${STUB_CLAUDE_EXIT:-0}"
EOF
WT_LOG="$TMP_ROOT/worktree.log"
cat > "$BIN/worktree" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$WT_LOG"
case "\${1:-}" in
  create) [[ ! -d "$TMP_ROOT/wt/\$2" || "\${3:-}" == --reuse ]] || exit 75
    mkdir -p "$TMP_ROOT/wt/\$2"; printf '%s\n' "$TMP_ROOT/wt/\$2" ;;
  exists) [[ -d "$TMP_ROOT/wt/\$2" ]] && echo true || echo false ;;
  push) ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$BIN/gh" "$BIN/lanes" "$BIN/claude" "$BIN/worktree"

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
STATE="$TMP_ROOT/state"
SESSION_TEXT="$(bash -c 'source "$1" && printf "%s" "$LAUNCH_SESSION_TEXT"' _ "$SCRIPTS_DIR/lib/lane-launch.sh")"
[[ -n "$SESSION_TEXT" ]] || { echo "open-terminal-cloud: lib/lane-launch.sh named no session words" >&2; exit 1; }
STARTED='{"ok":true,"session_id":"session_01CLOUD","url":"https://claude.ai/code/session_01CLOUD"}'
# The overseer's brief, the item's whole task, quotes and all, and the task
# word the claude stub logs for it closed by the session words.
BRIEF="$TMP_ROOT/brief.md"
# shellcheck disable=SC2016  # the brief's own backticks.
printf '%s\n' "Fix the parser's \"--flag\" handling." '' 'Done when: `parse --flag` exits 0.' > "$BRIEF"
printf -v TASK_WORD '%q' "$(cat "$BRIEF")"$'\n\n'"$SESSION_TEXT"

# run_ot [KEEP] [SCRIPT=PATH] [ENV=VALUE...] -- ARGS... — one cloud launch of
# ARGS from the repo; sets RC and ERR, and resets the worktree and claude logs
# first, and the item worktrees unless KEEP.
run_ot() {
  local script="$OT" env_args=()
  if [[ "${1:-}" == KEEP ]]; then shift; else rm -rf -- "${TMP_ROOT:?}/wt"; fi
  [[ "${1:-}" != SCRIPT=* ]] || { script="${1#SCRIPT=}"; shift; }
  while [[ "${1:-}" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f -- "${TMP_ROOT:?}/worktree.log" "${TMP_ROOT:?}/claude.log"
  set +e
  (cd "$REPO" && env PATH="$BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" WORKTREE_CLI="$BIN/worktree" \
    LANES_CLI="$BIN/lanes" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' GH_REPO="" TMUX="" \
    STUB_CLAUDE_LOG="$TMP_ROOT/claude.log" STUB_CLAUDE_OUT="$STARTED" ${env_args[@]+"${env_args[@]}"} \
    "$script" "$@" >/dev/null 2>"$TMP_ROOT/err")
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}
CLOUD=(--host claude-cloud --harness claude --lane "$LANE_DIR" --launch-flags "--model opus --effort high" --brief-file "$BRIEF" --state-dir "$STATE")
record() {
  "$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "'"$1"'")] | first // {} | [.host, .kind, .account, .session_id, .window, .mail_root, .status] | map(. // "null") | join(" ")'
}
# The words the claude stub received, one %q-quoted word a line.
claude_argv() { [[ -f "$TMP_ROOT/claude.log" ]] && sed -n '4,$p' "$TMP_ROOT/claude.log" || true; }
made() { [[ -e "$WT_LOG" ]] && echo yes || echo no; }

echo "=== a cloud session is launched from the item's pushed branch and recorded ==="
run_ot -- "${CLOUD[@]}" CC-1
assert_eq "rc=$RC worktree=$(paste -sd, "$WT_LOG")" "rc=0 worktree=exists CC-1,create CC-1,push CC-1 --set-upstream" \
  "the launch creates the item worktree and pushes its branch before the session" "$TMP_ROOT/err"
assert_eq "$(sed -n '2,3p' "$TMP_ROOT/claude.log" | paste -sd' ' -)" "config=$LANE_DIR cwd=$TMP_ROOT/wt/CC-1" \
  "claude runs under the lane's account in the item worktree"
ARGV="$(claude_argv)"
assert_eq "$(sed -n '1,2p;4,5p' <<<"$ARGV" | paste -sd' ' -)" "-p --cloud --output-format json" \
  "the session starts through claude -p --cloud with JSON output"
assert_eq "task=$([[ "$(sed -n 3p <<<"$ARGV")" == "$TASK_WORD" ]] && echo brief || echo other)" "task=brief" \
  "the task is the brief file's text closed by the session words, never a start command or the mailbox words"
assert_eq "$(record CC-1)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD null $TMP_ROOT/wt/CC-1 running" \
  "the record names the host and kind, the account and the session id, and no window"

echo "=== what a cloud session cannot take refuses before anything is made ==="
# KEY FIELDS|ARGS|OLD|NEW: the refusal's first line past its key word, the
# launch options that meet it, `+` a space inside one option, and the control's
# edit, the rule's text kept and its behaviour removed.
# shellcheck disable=SC2016  # the script's own text, never expanded here.
REFUSAL_ROWS=(
  'cloud-session-invalid host=claude-cloud harness=codex|--harness codex --launch-flags --model+gpt-5.5 --brief-file|[[ "$HARNESS" == claude && -z "$CMD_TEMPLATE" ]]|[[ -z "$CMD_TEMPLATE" ]]'
  'cloud-session-invalid host=claude-cloud harness=claude|--harness claude --cmd stub-harness --brief-file|[[ "$HARNESS" == claude && -z "$CMD_TEMPLATE" ]]|[[ "$HARNESS" == claude ]]'
  'cloud-brief-missing host=claude-cloud|--harness claude --launch-flags --model+opus|[[ -n "$BRIEF_FILE" ]] || { ot_message cloud-brief-missing|true || { ot_message cloud-brief-missing'
  'relaunch-unbuilt host=claude-cloud relaunch=fresh|--harness claude --launch-flags --model+opus --relaunch --brief-file|fresh) [[ "$RELAUNCH" != true ]] ||| fresh) true ||'
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

echo "=== a launch with no ok answer carrying a session id stops there ==="
# OUT|LABEL: what claude printed.
for row in '{"ok":true,"url":"https://claude.ai/code"}|no session id' '{"ok":false,"session_id":"session_01CLOUD"}|an ok false answer'; do
  run_ot STUB_CLAUDE_OUT="${row%%|*}" -- "${CLOUD[@]}" CC-3
  assert_eq "rc=$RC unread=$(grep -cxF 'open-terminal: cloud-session-unread item=CC-3' <<<"$ERR" || true) record=$(record CC-3)" \
    "rc=1 unread=1 record=null null null null null null null" "${row#*|} is no record and a failed item" "$TMP_ROOT/err"
done

echo "=== a launch that failed after its create launches again over its tree ==="
run_ot STUB_CLAUDE_EXIT=1 -- "${CLOUD[@]}" CC-10
assert_eq "rc=$RC failed=$(grep -cxF 'open-terminal: cloud-launch-failed item=CC-10 exit=1' <<<"$ERR" || true) tree=$([[ -d "$TMP_ROOT/wt/CC-10" ]] && echo stands || echo gone)" \
  "rc=1 failed=1 tree=stands" "a session that fails to start leaves its tree and no record" "$TMP_ROOT/err"
RELAUNCHED="rc=0 worktree=exists CC-10,create CC-10 --reuse,push CC-10 --set-upstream record=claude-cloud claude-cloud $LANE_DIR session_01CLOUD null $TMP_ROOT/wt/CC-10 running"
run_ot KEEP -- "${CLOUD[@]}" CC-10
assert_eq "rc=$RC worktree=$(paste -sd, "$WT_LOG") record=$(record CC-10)" "$RELAUNCHED" \
  "the second launch reuses the unrecorded tree and records the session" "$TMP_ROOT/err"
run_ot KEEP -- "${CLOUD[@]}" CC-10
assert_eq "owned=$(grep -cxF 'open-terminal: item-owned item=CC-10 exit=75' <<<"$ERR" || true) claude=$([[ -e "$TMP_ROOT/claude.log" ]] && echo ran || echo none)" \
  "owned=1 claude=none" "a recorded item's tree stays its claim" "$TMP_ROOT/err"

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
mutant task-close '"$LAUNCH_SESSION_TEXT" --output-format json' '"$LAUNCH_UNATTENDED_TEXT" --output-format json'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-6
assert_eq "task=$([[ "$(claude_argv | sed -n 3p)" == "$TASK_WORD" ]] && echo brief || echo other)" "task=other" \
  "control: a task closing on the mailbox words fails the task row"
# shellcheck disable=SC2016
mutant record-kind '"$HOST_KIND" \' '"" \'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-7
assert_eq "$(record CC-7)" "claude-cloud null $LANE_DIR session_01CLOUD null $TMP_ROOT/wt/CC-7 running" \
  "control: a record written without the kind fails the record row"
# shellcheck disable=SC2016
mutant record-window 'lane_record_write "$RECORD_MODE" "$wt_id" "" "$wt"' 'lane_record_write "$RECORD_MODE" "$wt_id" "stub:$title" "$wt"'
run_ot SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-8
assert_eq "$(record CC-8)" "claude-cloud claude-cloud $LANE_DIR session_01CLOUD stub:CC-8 $TMP_ROOT/wt/CC-8 running" \
  "control: a record written with a window fails the record row"
# shellcheck disable=SC2016
mutant session-unread '|| { ot_message cloud-session-unread "item=$item" >&2; return 1; }' '|| session=""'
run_ot SCRIPT="$MUTANT" STUB_CLAUDE_OUT='{"ok":true,"url":"https://claude.ai/code"}' -- "${CLOUD[@]}" CC-9
assert_eq "rc=$RC" "rc=0" "control: a launch that continues past a missing session id fails the stop row"
mutant session-ok 'select(.ok == true) | .session_id' '.session_id'
run_ot SCRIPT="$MUTANT" STUB_CLAUDE_OUT='{"ok":false,"session_id":"session_01CLOUD"}' -- "${CLOUD[@]}" CC-11
assert_eq "rc=$RC" "rc=0" "control: an ok false answer read for its session id fails the ok row"
mutant reuse '    || create_args+=(--reuse)' '    || true'
run_ot SCRIPT="$MUTANT" STUB_CLAUDE_EXIT=1 -- "${CLOUD[@]}" CC-12
run_ot KEEP SCRIPT="$MUTANT" -- "${CLOUD[@]}" CC-12
assert_eq "owned=$(grep -cxF 'open-terminal: item-owned item=CC-12 exit=75' <<<"$ERR" || true)" "owned=1" \
  "control: without the reuse the second launch of a failed item is skipped as owned"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
