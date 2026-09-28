#!/usr/bin/env bash
# Tests that a lane launched by open-terminal never holds its harness question
# tool. A lane asks its overseer through lane-mail ask; a question dialog in a
# lane's pane waits for an answer nobody at the pane gives.
#
# Two surfaces, one table each:
#   render  every command open-terminal builds carries the harness's
#           question-tool words, once, ahead of the caller's flags
#   gate    a --cmd launch, whose template is the whole command, is refused as
#           launch-question-tool-missing when it does not carry them itself
# and the same two for the unattended words a Pi brief closes on, whose gate
# refuses as launch-unattended-missing.
#
# The fixture is open-terminal-codex-prompt.sh's: a copy of open-terminal in a
# temp git repo, a stub worktree CLI, and a ghostty stub that captures the
# composed command a GUI launch hands to `bash -lc`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured lane host would turn these local launches into
# hosted ones; the caller environment outranks project settings.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-question-tool: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-question-tool: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-question-tool: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# A codex launch naming no --lane prepares its folder trust under the account
# LANES_HOME points at, so both are pinned inside the fixture: an inherited
# CODEX_HOME would send that preparation to the developer's live account.
FLEET_HOME="$TMP_ROOT/fleet-home"
mkdir -p "$FLEET_HOME"
LAUNCH_ENV=(LANES_HOME="$FLEET_HOME" CODEX_HOME=)

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" > "$OT_CAPTURE"
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/ghostty" "$BIN/gh"
# Pinned, so no row resolves the developer's own terminal.
export TERMINAL=ghostty

STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "create" ]]; then
  d="$TMP_ROOT/wt/\${2:-unknown}"
  mkdir -p "\$d"
  git init -q "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SCRIPTS_DIR/open-terminal" "$REPO/scripts/open-terminal"
cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$REPO/scripts/"
cp -R "$SCRIPTS_DIR/lib/." "$REPO/scripts/lib/"
orch_fixture_shared_libs "$REPO"
chmod +x "$REPO/scripts/open-terminal"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"

# launch ITEM ARGS... — one GUI launch of ITEM. Sets RC, ERR (stderr) and CMD,
# the command after the pane's `cd ... && ` (none when nothing launched), and
# CREATED, whether a worktree was made for ITEM.
launch() {
  local item="$1" cap="$TMP_ROOT/cap-$1"
  shift
  RC=0
  env "${LAUNCH_ENV[@]}" OT_CAPTURE="$cap" ORCH_STATE_DIR="$TMP_ROOT/state" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" \
    "$OT" --ghostty "$@" "$item" >/dev/null 2>"$TMP_ROOT/err-$item" || RC=$?
  ERR="$(cat "$TMP_ROOT/err-$item")"
  CMD=none
  if [[ "$RC" -eq 0 ]]; then
    # open_gui starts the terminal in the background, so its capture lands
    # after open-terminal has exited.
    for _ in $(seq 1 50); do [[ -s "$cap" ]] && break; sleep 0.1; done
    [[ ! -s "$cap" ]] || { CMD="$(cat "$cap")"; CMD="${CMD##* && }"; CMD="${CMD#env CODEX_HOME=* }"; CMD="${CMD#ORCH_COMPACTION_OVERRIDES=* }"; }
  fi
  CREATED=no
  [[ ! -d "$TMP_ROOT/wt/$(tr '[:lower:]' '[:upper:]' <<<"$item")" ]] || CREATED=yes
}

# Pi's unattended words, read from lib/lane-launch.sh, the table open-terminal
# renders and judges them from, so no suite holds a second copy of the text.
PI_UNATTENDED_TEXT="$(bash -c 'source "$1" && launch_choice_unattended pi' _ "$SCRIPTS_DIR/lib/lane-launch.sh")"
[[ -n "$PI_UNATTENDED_TEXT" ]] || { echo "lib/lane-launch.sh named no pi unattended text" >&2; exit 1; }

echo "=== every command open-terminal builds takes the question tool away ==="
# HARNESS|FLAGS|ITEM|RENDERED COMMAND|WHAT. FLAGS `-` passes no --launch-flags;
# an ITEM spelled REPO#N launches GitHub item N of REPO.
# A caller's flags that already carry the words keep one copy, ahead of the rest.
for row in \
  "claude|-|CC-1|claude -n CC-1 '--disallowedTools=AskUserQuestion,EnterPlanMode' '/orch start CC-1'|claude denies AskUserQuestion and EnterPlanMode; naming no model, it keeps its compaction" \
  "claude|--model opus|CC-6|claude -n CC-6 '--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}' '--disallowedTools=AskUserQuestion,EnterPlanMode' '--model' 'opus' '/orch start CC-6'|a claude model the adapter names a window for turns its compaction off" \
  "claude|--model sonnet|CC-8|claude -n CC-8 '--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}' '--disallowedTools=AskUserQuestion,EnterPlanMode' '--model' 'claude-sonnet-5' '/orch start CC-8'|a claude alias is written as its model id, whose window turns its compaction off" \
  "claude|--model=sonnet|CC-10|claude -n CC-10 '--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}' '--disallowedTools=AskUserQuestion,EnterPlanMode' '--model=claude-sonnet-5' '/orch start CC-10'|the attached form of a claude alias is written as its model id too" \
  "claude|--model claude-sonnet-4-6|CC-7|claude -n CC-7 '--disallowedTools=AskUserQuestion,EnterPlanMode' '--model' 'claude-sonnet-4-6' '/orch start CC-7'|a claude model with no window keeps its compaction, and there is no mark to hand off at" \
  "codex|-|CC-2|codex '-c' 'check_for_update_on_startup=false' '-c' 'model_auto_compact_token_limit=9223372036854775807' '-c' 'model_auto_compact_token_limit_scope=body_after_prefix' '-c' 'model_post_turn_compact_threshold_percent=0' '-c' 'features.default_mode_request_user_input=false' 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-2'|codex disables the request_user_input feature after its update and compaction settings" \
  "pi|-|CC-3|pi '--exclude-tools' 'question' '/skill:orch start CC-3 $PI_UNATTENDED_TEXT'|pi excludes the pi-questions tool, and its brief closes on the unattended words, never on --append-system-prompt" \
  "pi|-|o/r#30|pi '--exclude-tools' 'question' '/skill:orch start github o/r#30 $PI_UNATTENDED_TEXT'|a github pi brief closes on the unattended words too" \
  "opencode|-|CC-4|opencode --prompt '/orch start CC-4'|an opencode lane keeps its question tool: no flag turns it off, so none is rendered" \
  "pi|--model sonnet:high --exclude-tools question|CC-5|pi '--exclude-tools' 'question' '--model' 'sonnet:high' '/skill:orch start CC-5 $PI_UNATTENDED_TEXT'|a caller's own copy of the words is carried once" \
  ; do
  IFS='|' read -r harness flags item want what <<<"$row"
  flag_args=()
  [[ "$flags" == - ]] || flag_args=(--launch-flags "$flags")
  if [[ "$item" == *#* ]]; then
    flag_args+=(--tracker github --repo "${item%#*}")
    item="${item#*#}"
  fi
  launch "$item" --harness "$harness" ${flag_args[@]+"${flag_args[@]}"}
  assert_eq "rc=$RC cmd=$CMD" "rc=0 cmd=$want" "render: $what"
done

echo "=== a --cmd launch that leaves the question tool on is refused ==="
# HARNESS|TEMPLATE|ITEM|RC|REFUSAL LINE (`-` for none)|CREATED|WHAT
# A refused launch makes no worktree. A harness with no words, and a launch
# naming no harness, has no row to judge it by.
for row in \
  "claude|true|CC-11|1|open-terminal: launch-question-tool-missing harness=claude word=--disallowedTools=AskUserQuestion,EnterPlanMode|no|a claude template without the words is refused" \
  "codex|true|CC-12|1|open-terminal: launch-question-tool-missing harness=codex word=-c word=features.default_mode_request_user_input=false|no|a codex template without the words is refused, one word field per word" \
  "pi|true|CC-13|1|open-terminal: launch-question-tool-missing harness=pi word=--exclude-tools word=question|no|a pi template without the words is refused" \
  "pi|true question --exclude-tools|CC-14|1|open-terminal: launch-question-tool-missing harness=pi word=--exclude-tools word=question|no|the words out of order are not the words" \
  "claude|true --disallowedTools=AskUserQuestion,EnterPlanMode|CC-15|0|-|yes|a claude template carrying the words launches" \
  "claude|true '--disallowedTools=AskUserQuestion,EnterPlanMode'|CC-16|0|-|yes|a word the template quotes is still the word" \
  "codex|true -c features.default_mode_request_user_input=false|CC-17|0|-|yes|a codex template carrying the words launches" \
  "pi|true --exclude-tools question '$PI_UNATTENDED_TEXT'|CC-18|0|-|yes|a pi template carrying the words launches" \
  "opencode|true|CC-19|0|-|yes|an opencode template is not asked for words it has none of" \
  "-|true|CC-20|0|-|yes|a template naming no harness is not asked for words" \
  ; do
  IFS='|' read -r harness template item want_rc want_err want_created what <<<"$row"
  harness_args=()
  [[ "$harness" == - ]] || harness_args=(--harness "$harness")
  launch "$item" ${harness_args[@]+"${harness_args[@]}"} --cmd "$template"
  refusal="$(awk '$2 == "launch-question-tool-missing" { print; exit }' <<<"$ERR")"
  assert_eq "rc=$RC created=$CREATED refusal=${refusal:--}" "rc=$want_rc created=$want_created refusal=$want_err" "gate: $what"
done

echo "=== a pi --cmd launch without the unattended words is refused ==="
# HARNESS|TEMPLATE|BRIEF FILE TEXT (`-` for none)|ITEM|RC|REFUSAL LINE (`-` for
# none)|TEXT PRINTED|CREATED|WHAT
# Every template carries its harness's question-tool words, so the gate
# judged is this one. The refusal prints the text on its last line, whole,
# and a refused launch makes no worktree.
PI_Q='--exclude-tools question'
for row in \
  "pi|true $PI_Q|-|CC-26|1|open-terminal: launch-unattended-missing harness=pi|yes|no|a pi template without the words is refused, printing the text" \
  "pi|true $PI_Q 'Ask when stuck.'|-|CC-27|1|open-terminal: launch-unattended-missing harness=pi|yes|no|a pi template briefing other text is refused" \
  "pi|true $PI_Q $PI_UNATTENDED_TEXT|-|CC-24|1|open-terminal: launch-unattended-missing harness=pi|yes|no|the words the shell splits into several arguments are not the words" \
  "pi|true $PI_Q '/skill:orch start CC-23 $PI_UNATTENDED_TEXT'|-|CC-23|0|-|no|yes|the words whole inside one argument of the template launch" \
  "pi|true $PI_Q {brief}|Lead CC-28. $PI_UNATTENDED_TEXT|CC-28|0|-|no|yes|the words in the brief file launch" \
  "pi|true $PI_Q {brief}|Lead CC-29.|CC-29|1|open-terminal: launch-unattended-missing harness=pi|yes|no|a brief file without the words is refused" \
  "claude|true --disallowedTools=AskUserQuestion,EnterPlanMode|-|CC-25|0|-|no|yes|a claude template is not asked for words its harness has none of" \
  ; do
  IFS='|' read -r harness template brief item want_rc want_err want_text want_created what <<<"$row"
  brief_args=()
  if [[ "$brief" != - ]]; then
    printf '%s\n' "$brief" > "$TMP_ROOT/brief-$item"
    brief_args=(--brief-file "$TMP_ROOT/brief-$item")
  fi
  launch "$item" --harness "$harness" ${brief_args[@]+"${brief_args[@]}"} --cmd "$template"
  refusal="$(awk '$2 == "launch-unattended-missing" { print; exit }' <<<"$ERR")"
  printed=no
  [[ "$(tail -n 1 <<<"$ERR")" != "$PI_UNATTENDED_TEXT" ]] || printed=yes
  assert_eq "rc=$RC created=$CREATED refusal=${refusal:--} printed=$printed" \
    "rc=$want_rc created=$want_created refusal=$want_err printed=$want_text" "gate: $what"
done

echo "=== must-fail controls ==="
# lead_control OLD NEW... — the lane-launch.sh copy restored, then each OLD
# replaced by its NEW at its one site.
lead_control() { # OLD NEW...
  cp "$SCRIPTS_DIR/lib/lane-launch.sh" "$REPO/scripts/lib/lane-launch.sh"
  while (( $# )); do
    assert_eq "$(grep -c -F -e "$1" "$REPO/scripts/lib/lane-launch.sh")" 1 "control finds its one site"
    perl -i -pe 'BEGIN { ($o, $n) = (shift, shift) } s/\Q$o\E/$n/' "$1" "$2" "$REPO/scripts/lib/lane-launch.sh"
    shift 2
  done
}
SETTINGS="'--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}' "
QUESTION="'--disallowedTools=AskUserQuestion,EnterPlanMode'"
# No rewrite at all: the id is judged and the bare alias written.
lead_control '  if [[ "$model_id" != "$model" ]]; then' '  if false; then'
launch CC-9 --harness claude --launch-flags '--model sonnet'
assert_eq "$CMD" "claude -n CC-9 $SETTINGS$QUESTION '--model' 'sonnet' '/orch start CC-9'" \
  "control: without the rewrite a claude alias reaches the command as named"
# The attached form missed: the alias runs as named, judged so, and keeps its
# compaction on, the attached row's value and words both gone.
ATTACHED='      words="${words//"$nl$spelling$model$nl"/$nl$spelling$model_id$nl}"'
lead_control "$ATTACHED" '      :'
launch CC-21 --harness claude --launch-flags '--model=sonnet'
assert_eq "$CMD" "claude -n CC-21 $QUESTION '--model=sonnet' '/orch start CC-21'" \
  "control: an attached alias the rewrite misses keeps its compaction on"
# The same miss with no judge after it: compaction off on the bare alias.
lead_control "$ATTACHED" '      :' '      || model_id="$model"' '      || :'
launch CC-22 --harness claude --launch-flags '--model=sonnet'
assert_eq "$CMD" "claude -n CC-22 $SETTINGS$QUESTION '--model=sonnet' '/orch start CC-22'" \
  "control: without the check after it, that miss turns compaction off on the bare alias"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
