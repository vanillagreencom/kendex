#!/usr/bin/env bash
# The harness gate a fleet launch passes before anything else: a lane launched
# into an oversee fleet hands off at a share of its own window, which a harness
# adapter reads, and runs with its harness's own compaction off, so the handoff
# comes first. A launch that turned compaction off on a session whose window
# nothing can name would run it into its wall with neither, so each harness is
# admitted only where both halves hold. A launch naming no fleet state is
# judged on none of it.
#
# Every row stops before a window could open: a launch the gate passes is
# handed an empty worktree path by the stubbed worktree CLI and refused later,
# so a row reads the gate's own line, or `passed` where stderr carries none.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "term %%s\\n" "$*" >> "$OT_TERM_LOG"\n' > "$BIN/term"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
# The worktree CLI a launch the gate passes reaches next: an empty path, which
# open-terminal refuses by name before any window opens.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/worktree-stub"
# A lane host that answers nothing: the Pi gate refuses before it is asked.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/provider"
chmod +x "$BIN/term" "$BIN/gh" "$BIN/worktree-stub" "$BIN/provider"

# stage DIR — a copy of the orch scripts in a git repo of its own, so the
# project root, and the project .pi/settings.json the Pi rule reads, are the
# fixture's.
stage() {
  mkdir -p "$1/scripts"
  cp -R "$SCRIPTS_DIR/." "$1/scripts/"
  orch_fixture_shared_libs "$1"
  git -C "$1" init -q
}
REPO="$TMP_ROOT/repo"
stage "$REPO"
PI_AGENT="$TMP_ROOT/pi-agent"
mkdir -p "$PI_AGENT"
# The pi-hooks carrier Pi loads, sending the window on its Stop payload or not.
pi_carrier() { # sends|old|none
  rm -rf -- "${PI_AGENT:?}/packages"
  [[ "$1" != none ]] || return 0
  mkdir -p "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions"
  if [[ "$1" == sends ]]; then
    printf 'export const f = { context_window: 1 };\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  else
    printf 'export const f = { session_id: 1 };\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  fi
}

# The launch-choice refusals that run ahead of the gate are read too, so a row
# refused before the gate cannot read as one the gate passed.
GATE_KEYS='unsupported-for-oversee|compaction-on|launch-window-unknown|launch-compaction-missing|pi-compaction-unverified|pi-settings-unreadable|launch-question-tool-missing|launch-model-missing|launch-effort-missing'
# launch NAME ARGS... — the gate's line open-terminal wrote, or `passed` where it
# wrote none, for a GUI launch of CC-1 under ARGS; OT names another copy.
launch() { # NAME ARGS...
  local name="$1" rc=0 line
  shift
  ( cd "$REPO" && PATH="$BIN:$PATH" ORCH_STATE_DIR="$TMP_ROOT/$name.state" WORKTREE_CLI="$BIN/worktree-stub" \
    OT_TERM_LOG="$TMP_ROOT/$name.term" TERMINAL=term TMUX= PI_CODING_AGENT_DIR="$PI_AGENT" \
    "${OT:-$REPO/scripts/open-terminal}" --ghostty "$@" CC-1 ) \
    >/dev/null 2>"$TMP_ROOT/$name.err" || rc=$?
  line="$(grep -E "^open-terminal: ($GATE_KEYS) " "$TMP_ROOT/$name.err" || true)"
  printf '%s' "${line:-passed}"
}

FLEET=(--state-dir "$TMP_ROOT/fleet")
# The words the launch-choice table gives each harness, as a --cmd command
# carries them.
CLAUDE_WORDS="'--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}'"
CODEX_WORDS='-c model_auto_compact_token_limit=9223372036854775807'
CLAUDE_QUESTION=--disallowedTools=AskUserQuestion,EnterPlanMode
CODEX_QUESTION='-c features.default_mode_request_user_input=false'
CLAUDE_TEMPLATE="claude --model opus --effort high $CLAUDE_QUESTION $CLAUDE_WORDS {item}"

echo "=== a fleet launch runs claude and codex only where compaction goes off and the window is named ==="
while IFS='|' read -r label want args; do
  eval "set -- $args"
  assert_eq "$(launch row "$@")" "$want" "$label"
done <<ROWS
claude on a model with a window passes|passed|${FLEET[*]} --harness claude --launch-flags '--model opus --effort high'
claude on a model whose window no row names is refused|open-terminal: launch-window-unknown harness=claude model=sonnet|${FLEET[*]} --harness claude --launch-flags '--model sonnet --effort high'
claude naming no model is refused the same way|open-terminal: launch-window-unknown harness=claude model=none|${FLEET[*]} --harness claude
codex passes, its rollout naming its window|passed|${FLEET[*]} --harness codex --launch-flags '-m gpt-6-astra -c model_reasoning_effort=high'
a claude --cmd carrying the compaction words passes|passed|${FLEET[*]} --harness claude --cmd "\$CLAUDE_TEMPLATE"
a claude --cmd without them is refused, naming them|open-terminal: launch-compaction-missing harness=claude word=--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}|${FLEET[*]} --harness claude --cmd 'claude --model opus --effort high $CLAUDE_QUESTION {item}'
a claude --cmd whose JSON the shell would strip is refused, the word never reaching claude whole|open-terminal: launch-compaction-missing harness=claude word=--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}|${FLEET[*]} --harness claude --cmd "claude --model opus --effort high $CLAUDE_QUESTION --settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}} {item}"
a claude --cmd quoting only the JSON passes|passed|${FLEET[*]} --harness claude --cmd "claude --model opus --effort high $CLAUDE_QUESTION --settings='{\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}' {item}"
a codex --cmd without them is refused, one word field per word|open-terminal: launch-compaction-missing harness=codex word=-c word=model_auto_compact_token_limit=9223372036854775807|${FLEET[*]} --harness codex --cmd 'codex -m gpt-6-astra -c model_reasoning_effort=high $CODEX_QUESTION {item}'
a codex --cmd carrying them passes|passed|${FLEET[*]} --harness codex --cmd 'codex -m gpt-6-astra -c model_reasoning_effort=high $CODEX_QUESTION $CODEX_WORDS {item}'
a fleet --cmd naming no harness is refused|open-terminal: unsupported-for-oversee harness=none|${FLEET[*]} --cmd 'claude --model opus {item}'
opencode in a fleet is refused|open-terminal: unsupported-for-oversee harness=opencode|${FLEET[*]} --harness opencode --launch-flags '--model m'
opencode with no fleet passes|passed|--harness opencode --launch-flags '--model m'
claude on a model with no window, with no fleet, passes|passed|--harness claude --launch-flags '--model sonnet --effort high'
ROWS

echo "=== a Pi fleet launch runs only where Pi will not compact and its window reaches the hook ==="
# `label|carrier|user settings|project settings|args|answer`: `-` is no file.
PI_FILE="file=$PI_AGENT/settings.json"
while IFS='|' read -r label carrier user project args want; do
  rm -f -- "$PI_AGENT/settings.json" "$REPO/.pi/settings.json"
  [[ "$user" == - ]] || printf '%s\n' "$user" > "$PI_AGENT/settings.json"
  if [[ "$project" != - ]]; then mkdir -p "$REPO/.pi"; printf '%s\n' "$project" > "$REPO/.pi/settings.json"; fi
  pi_carrier "$carrier"
  want="${want//@FILE@/$PI_FILE}"
  eval "set -- $args"
  assert_eq "$(launch pi "$@")" "$want" "$label"
done <<ROWS
compaction at its default is refused|sends|-|-|${FLEET[*]} --harness pi|open-terminal: compaction-on harness=pi @FILE@
compaction on is refused|sends|{"compaction":{"enabled":true}}|-|${FLEET[*]} --harness pi|open-terminal: compaction-on harness=pi @FILE@
compaction off with a carrier that sends the window passes|sends|{"compaction":{"enabled":false}}|-|${FLEET[*]} --harness pi|passed
a project turning compaction back on is refused, naming the project file|sends|{"compaction":{"enabled":false}}|{"compaction":{"enabled":true}}|${FLEET[*]} --harness pi|open-terminal: compaction-on harness=pi file=$REPO/.pi/settings.json
a carrier that sends no window is refused|old|{"compaction":{"enabled":false}}|-|${FLEET[*]} --harness pi|open-terminal: unsupported-for-oversee harness=pi reason=no-window-read
no carrier installed is refused|none|{"compaction":{"enabled":false}}|-|${FLEET[*]} --harness pi|open-terminal: unsupported-for-oversee harness=pi reason=no-window-read
a settings file jq cannot read is named|sends|not json|-|${FLEET[*]} --harness pi|open-terminal: pi-settings-unreadable @FILE@
a hosted Pi fleet lane, whose host keeps its own settings, is refused|sends|{"compaction":{"enabled":false}}|-|${FLEET[*]} --harness pi --host $BIN/provider|open-terminal: pi-compaction-unverified host=$BIN/provider
no fleet passes whatever its settings|none|-|-|--harness pi|passed
ROWS
rm -f -- "$PI_AGENT/settings.json" "$REPO/.pi/settings.json"
assert_eq "$(grep -c 'jq: error\|parse error' "$TMP_ROOT/pi.err" || true)" "0" \
  "the last row's run carries no jq words; the unreadable row's did, under its key"

echo "=== must-fail controls ==="
# Each rule's refusal replaced by a pass: the row it holds reads as passed.
# control NAME OLD NEW — a staged copy with OLD replaced by NEW, in CTRL_OT.
control() { # NAME OLD NEW
  stage "$TMP_ROOT/$1"
  mutate_file "$TMP_ROOT/$1/scripts/open-terminal" "$2" "$3"
  CTRL_OT="$TMP_ROOT/$1/scripts/open-terminal"
}
control unsupported-ctrl '*) ot_message unsupported-for-oversee "harness=${LAUNCH_HARNESS:-none}" >&2; exit 1 ;;' '*) ;;'
assert_eq "$(OT="$CTRL_OT" launch unsupported-ctrl "${FLEET[@]}" --harness opencode --launch-flags '--model m')" passed \
  "control: without its refusal an opencode fleet launch passes the gate"
control window-ctrl 'ot_message launch-window-unknown "harness=$LAUNCH_HARNESS" "model=${LAUNCH_MODEL:-none}" >&2' ': '
assert_eq "$(OT="$CTRL_OT" launch window-ctrl "${FLEET[@]}" --harness claude --launch-flags '--model sonnet --effort high')" passed \
  "control: without its refusal a claude fleet lane on a model with no window passes"
control compaction-missing-ctrl 'ot_message launch-compaction-missing "harness=$LAUNCH_HARNESS" "${compaction_fields[@]}" >&2' ': '
assert_eq "$(OT="$CTRL_OT" launch compaction-missing-ctrl "${FLEET[@]}" --harness claude --cmd "claude --model opus --effort high $CLAUDE_QUESTION {item}")" passed \
  "control: without its refusal a --cmd fleet lane keeps its compaction on"
# The words compared with the command's quoting stripped rather than removed as
# its shell removes it: the JSON the shell strips reads as the word.
stage "$TMP_ROOT/strip-ctrl"
mutate_file "$TMP_ROOT/strip-ctrl/scripts/lib/lane-launch.sh" \
  '[[ "${LAUNCH_CHOICE_ARGV[i + j]}" == "${want[j]}" ]] || continue 2' \
  '[[ "${LAUNCH_CHOICE_ARGV[i + j]}" == "${want[j]//\"/}" ]] || continue 2'
assert_eq "$(OT="$TMP_ROOT/strip-ctrl/scripts/open-terminal" launch strip-ctrl "${FLEET[@]}" --harness claude \
  --cmd "claude --model opus --effort high $CLAUDE_QUESTION --settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}} {item}")" passed \
  "control: compared unquoted, a word whose JSON the shell strips passes the gate"
printf '{"compaction":{"enabled":false}}\n' > "$PI_AGENT/settings.json"
pi_carrier old
control window-read-ctrl 'ot_message unsupported-for-oversee "harness=pi" "reason=no-window-read" >&2; exit 1;' ': ;'
assert_eq "$(OT="$CTRL_OT" launch window-read-ctrl "${FLEET[@]}" --harness pi)" passed \
  "control: without its refusal a Pi fleet lane whose carrier sends no window passes"
control hosted-pi-ctrl 'ot_message pi-compaction-unverified "host=$LANE_HOST" >&2; exit 1;' ': ;'
assert_eq "$(OT="$CTRL_OT" launch hosted-pi-ctrl "${FLEET[@]}" --harness pi --host "$BIN/provider")" "open-terminal: unsupported-for-oversee harness=pi reason=no-window-read" \
  "control: without its refusal a hosted Pi fleet lane is judged on this machine's files"
rm -f -- "$PI_AGENT/settings.json"
pi_carrier sends
control compaction-ctrl '0) ot_message compaction-on "harness=pi"' '0) : ot_message compaction-on "harness=pi"'
assert_eq "$(OT="$CTRL_OT" launch compaction-ctrl "${FLEET[@]}" --harness pi)" passed \
  "control: without its refusal a Pi fleet lane Pi would compact passes the gate"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
