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
case "$h" in pi) printf 'PI_CODING_AGENT_DIR=%s\n' "$PI_CODING_AGENT_DIR" ;; codex) printf 'CODEX_HOME=%s\n' "$CODEX_TEST_HOME" ;; esac
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
  local preference="$1" wall="$2" mode="$3" text="$4" rc=0 key=none record='none|none|none' cmd="" written=no end args=()
  RUN="$TMP_ROOT/run"
  rm -rf -- "${RUN:?}"
  mkdir -p "$RUN"
  : > "$RUN/picks"
  if [[ "$mode" == cmd ]]; then args=(--cmd "$text" --brief-file "$TMP_ROOT/brief")
  elif [[ -n "$text" ]]; then args=(--launch-flags "$text"); fi
  (cd -- "$REPO" && env -i PATH="$BIN:$PATH" HOME="$TMP_ROOT/home" ORCH_LANE_HOST=local \
    ORCH_LANE_PREFERENCE="$preference" ORCH_OVERSEER_LANES=3 ORCH_TMUX_SESSION= \
    OVERSEE_WATCH_STATE_DIR="$RUN/claims" WORKTREE_CLI="$BIN/worktree" LANES_CLI="$BIN/lanes" \
    PI_CODING_AGENT_DIR="$TMP_ROOT/pi" CODEX_TEST_HOME="$TMP_ROOT/codex" \
    WALL="$wall" PICK_LOG="$RUN/picks" OT_WT_LOG="$RUN/worktrees" OT_CAPTURE="$RUN/command" TERMINAL=ghostty \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$OT" --ghostty --state-dir "$RUN/state" --harness pi --lane auto \
    ${args[@]+"${args[@]}"} CC-1 > "$RUN/out" 2> "$RUN/err") || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    end=$((SECONDS + 10))
    while [[ ! -s "$RUN/command" ]] && (( SECONDS < end )); do sleep 0.01; done
    [[ -s "$RUN/command" ]] || { echo 'open-terminal-preference: capture=missing' >&2; exit 1; }
    cmd="$(cat -- "$RUN/command")"
    case "$cmd" in
      *'pi --model github-copilot/gpt-6.1-sol --thinking high'*|*'codex '*'-m gpt-6.1-sol -c model_reasoning_effort=high'*) written=yes ;;
    esac
  else
    key="$(sed -n 's/^open-terminal: \([^ ]*\).*/\1/p' "$RUN/err")"; key="${key%%$'\n'*}"
  fi
  if [[ -f "$RUN/state/workflow-state-oversee.json" ]]; then
    record="$("$REPO/scripts/workflow-state" --state-dir "$RUN/state" get oversee \
      '.lanes // [] | .[] | [.harness, .model, (.preference_entry // "none")] | join("|")' | tr -d '"')"
    [[ -n "$record" ]] || record='none|none|none'
  fi
  OBS="$rc|$key|$record|$written|$(wc -l < "$RUN/picks" | tr -d ' ')"
}

# Input shape is one table. Expected protocol values are independent of the
# launcher, including what its emitted command actually passes to the harness.
while IFS='|' read -r label pref wall mode text want; do
  [[ "$pref" != default ]] || pref="$PREF"
  [[ "$text" != template ]] || text='pi --exclude-tools question {brief}'
  observe "$pref" "$wall" "$mode" "$text"
  assert_eq "$OBS" "$want" "$label" "$RUN/err"
done <<'ROWS'
first entry with room|default|none|flags||0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|1
walled pool falls to native codex|default|pi|flags||0|none|codex|gpt-6.1-sol|codex:gpt-6.1-sol:high|yes|2
model-free command gets the preference|default|none|cmd|template|0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|1
preference replaces an effort-only flag|default|none|flags|--thinking low|0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|1
preference preserves brief quoting refusal|default|none|cmd|pi --exclude-tools question '{brief}'|1|brief-quoted|none|none|none|no|1
invalid later entry refuses before a pick|pi:github-copilot/gpt-6.1-sol:high,pi:bare:high|none|flags||1|invalid-preference|none|none|none|no|0
full walk refuses|default|all|flags||1|lane-unavailable|none|none|none|no|2
judge failure does not try another entry|default|error|flags||1|lane-resolution-failed|none|none|none|no|1
arbitrary command is not replaced|default|none|cmd|true {brief}|1|preference-command-invalid|none|none|none|no|1
unset preserves the missing-model gate||none|flags||1|launch-model-missing|none|none|none|no|0
explicit flags bypass even an invalid preference|invalid|none|flags|--model github-copilot/gpt-6.1-sol --thinking high|0|none|pi|github-copilot/gpt-6.1-sol|none|yes|1
explicit command bypasses even an invalid preference|invalid|none|cmd|pi --model github-copilot/gpt-6.1-sol --thinking high --exclude-tools question {brief}|0|none|pi|github-copilot/gpt-6.1-sol|none|yes|1
ROWS
# The refusal names the whole walk, not just the final model.
observe "$PREF" all flags ''
assert_file_contains "$RUN/err" "walk=$PREF" 'no-room refusal names the preference walk'

# One control for routing and one for each new refusal rule. Each mutation
# keeps the tested call or comparison, but removes its effect in a private copy.
for control in routing grammar command; do
  MUTANT="$(mutant_scripts "mutant-$control" open-terminal)/open-terminal"
  orch_fixture_shared_libs "$TMP_ROOT/mutant-$control"
  git -C "$TMP_ROOT/mutant-$control" init -q
  git -C "$TMP_ROOT/mutant-$control" config gc.auto 0
  git -C "$TMP_ROOT/mutant-$control" config maintenance.auto false
  OT="$MUTANT"
  case "$control" in
    routing)
      mutate_file "$OT" '-n "${ORCH_LANE_PREFERENCE:-}"' '-z "${ORCH_LANE_PREFERENCE:-}"'
      observe "$PREF" none flags ''
      assert_eq "$OBS" '1|launch-model-missing|none|none|none|no|0' 'control: the first-entry row turns red without routing' ;;
    grammar)
      mutate_file "$OT" 'ol_preference_entries "$ORCH_LANE_PREFERENCE" || {' 'ol_preference_entries "$ORCH_LANE_PREFERENCE" || true; false && {'
      observe 'pi:github-copilot/gpt-6.1-sol:high,pi:bare:high' none flags ''
      assert_eq "$OBS" '0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|1' 'control: the invalid-entry row turns red without refusal' ;;
    command)
      mutate_file "$OT" '[[ "${LAUNCH_CHOICE_ARGV[0]}" == "$preference_harness" ]]' '[[ -n "${LAUNCH_CHOICE_ARGV[0]}" ]]'
      observe "$PREF" none cmd 'true --exclude-tools question {brief}'
      assert_eq "$OBS" '0|none|pi|github-copilot/gpt-6.1-sol|pi:github-copilot/gpt-6.1-sol:high|yes|1' 'control: the arbitrary-command row turns red without refusal' ;;
  esac
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
