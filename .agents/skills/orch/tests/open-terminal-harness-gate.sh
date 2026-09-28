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

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "term %%s\\n" "$*" >> "$OT_TERM_LOG"\n' > "$BIN/term"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
# The worktree CLI a launch the gate passes reaches next: an empty path, which
# open-terminal refuses by name before any window opens.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/worktree-stub"
# A lane host that answers nothing: the gate is judged before it is asked.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/provider"
# The tmux server a new pane would inherit from: running where OT_TMUX_ENV
# exists, its global environment that file's lines, and unreadable where the
# file holds `!unreadable`.
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
[ -e "$OT_TMUX_ENV" ] || exit 1
case "$1:${2:-}" in
  list-sessions:) exit 0 ;;
  show-environment:-g) [ "$(cat "$OT_TMUX_ENV")" != '!unreadable' ] && cat "$OT_TMUX_ENV" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/term" "$BIN/gh" "$BIN/worktree-stub" "$BIN/provider" "$BIN/tmux"

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
GATE_KEYS='unsupported-for-oversee|compaction-on|launch-window-unknown|launch-compaction-missing|pi-settings-unreadable|launch-question-tool-missing|launch-model-missing|launch-effort-missing'
# launch NAME ARGS... — the gate's line open-terminal wrote, or `passed` where it
# wrote none, for a GUI launch of CC-1 under ARGS; OT names another copy. Its
# stdout is kept in $TMP_ROOT/NAME.out.
# LAUNCH_ENV holds assignments the launch runs under, after every key that
# moves a claude alias is cleared; the Claude config directory and the tmux
# server are the fixture's.
CLAUDE_KEYS='CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL'
CLAUDE_CFG="$TMP_ROOT/claude-config"
TMUX_ENV_FILE="$TMP_ROOT/tmux-global.env"
mkdir -p "$CLAUDE_CFG"
launch() { # NAME ARGS...
  local name="$1" rc=0 line
  shift
  # shellcheck disable=SC2086 # CLAUDE_KEYS and LAUNCH_ENV are one word each
  ( cd "$REPO" && unset $CLAUDE_KEYS && PATH="$BIN:$PATH" ORCH_STATE_DIR="$TMP_ROOT/$name.state" WORKTREE_CLI="$BIN/worktree-stub" \
    OT_TERM_LOG="$TMP_ROOT/$name.term" TERMINAL=term TMUX= PI_CODING_AGENT_DIR="$PI_AGENT" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CFG" OT_TMUX_ENV="$TMUX_ENV_FILE" \
    env ${LAUNCH_ENV:-} "${OT:-$REPO/scripts/open-terminal}" --ghostty "$@" CC-1 ) \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || rc=$?
  line="$(grep -E "^open-terminal: ($GATE_KEYS) " "$TMP_ROOT/$name.err" || true)"
  printf '%s' "${line:-passed}"
}

FLEET=(--state-dir "$TMP_ROOT/fleet")
# The words the launch-choice table gives each harness, as a --cmd command
# carries them.
CLAUDE_WORDS="'--settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}'"
CODEX_WORDS='-c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0'
CLAUDE_QUESTION=--disallowedTools=AskUserQuestion,EnterPlanMode
CODEX_QUESTION='-c features.default_mode_request_user_input=false'
CLAUDE_TEMPLATE="claude --model opus --effort high $CLAUDE_QUESTION $CLAUDE_WORDS {item}"

echo "=== a fleet launch runs claude and codex only where compaction goes off and the window is named ==="
while IFS='|' read -r label want args; do
  eval "set -- $args"
  assert_eq "$(launch row "$@")" "$want" "$label"
done <<ROWS
claude on a model with a window passes|passed|${FLEET[*]} --harness claude --launch-flags '--model opus --effort high'
claude on sonnet, a 1M window, passes|passed|${FLEET[*]} --harness claude --launch-flags '--model sonnet --effort high'
claude on haiku, a 200K window, passes|passed|${FLEET[*]} --harness claude --launch-flags '--model haiku --effort high'
claude on a model whose window no row names is refused|open-terminal: launch-window-unknown harness=claude model=claude-sonnet-4-6|${FLEET[*]} --harness claude --launch-flags '--model claude-sonnet-4-6 --effort high'
claude naming no model is refused the same way|open-terminal: launch-window-unknown harness=claude model=none|${FLEET[*]} --harness claude
codex passes, its rollout naming its window|passed|${FLEET[*]} --harness codex --launch-flags '-m gpt-6-astra -c model_reasoning_effort=high'
a claude --cmd carrying the compaction words passes|passed|${FLEET[*]} --harness claude --cmd "\$CLAUDE_TEMPLATE"
a claude --cmd without them is refused, naming them|open-terminal: launch-compaction-missing harness=claude word=--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}|${FLEET[*]} --harness claude --cmd 'claude --model opus --effort high $CLAUDE_QUESTION {item}'
a claude --cmd whose JSON the shell would strip is refused, the word never reaching claude whole|open-terminal: launch-compaction-missing harness=claude word=--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}|${FLEET[*]} --harness claude --cmd "claude --model opus --effort high $CLAUDE_QUESTION --settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}} {item}"
a claude --cmd quoting only the JSON passes|passed|${FLEET[*]} --harness claude --cmd "claude --model opus --effort high $CLAUDE_QUESTION --settings='{\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}' {item}"
a codex --cmd without them is refused, one word field per word|open-terminal: launch-compaction-missing harness=codex word=-c word=model_auto_compact_token_limit=9223372036854775807 word=-c word=model_auto_compact_token_limit_scope=body_after_prefix word=-c word=model_post_turn_compact_threshold_percent=0|${FLEET[*]} --harness codex --cmd 'codex -m gpt-6-astra -c model_reasoning_effort=high $CODEX_QUESTION {item}'
a codex --cmd carrying them passes|passed|${FLEET[*]} --harness codex --cmd 'codex -m gpt-6-astra -c model_reasoning_effort=high $CODEX_QUESTION $CODEX_WORDS {item}'
a fleet --cmd naming no harness is refused|open-terminal: unsupported-for-oversee harness=none|${FLEET[*]} --cmd 'claude --model opus {item}'
opencode in a fleet is refused|open-terminal: unsupported-for-oversee harness=opencode|${FLEET[*]} --harness opencode --launch-flags '--model m'
copilot in a fleet is refused, no switch turning its compaction off and no adapter reading its window|open-terminal: unsupported-for-oversee harness=copilot|${FLEET[*]} --harness copilot --launch-flags '--model claude-opus-5 --reasoning-effort high'
copilot with no fleet passes|passed|--harness copilot --launch-flags '--model claude-opus-5 --reasoning-effort high'
opencode with no fleet passes|passed|--harness opencode --launch-flags '--model m'
claude on a model with no window, with no fleet, passes|passed|--harness claude --launch-flags '--model claude-sonnet-4-6 --effort high'
ROWS

echo "=== a claude alias whose model the environment can move has no window ==="
# `label|env|settings.json|tmux global environment|args|answer`: `-` is none.
# An alias is judged on every source a lane takes its environment from; the
# model id it would resolve to launches under the same environment.
alias_launch() { # NAME ENV SETTINGS TMUX ARGS...
  local name="$1" env="$2" settings="$3" tmux_env="$4"
  shift 4
  rm -f -- "${CLAUDE_CFG:?}/settings.json" "${TMUX_ENV_FILE:?}"
  [[ "$settings" == - ]] || printf '%s\n' "$settings" > "$CLAUDE_CFG/settings.json"
  [[ "$tmux_env" == - ]] || printf '%s\n' "$tmux_env" > "$TMUX_ENV_FILE"
  [[ "$env" != - ]] || env=""
  LAUNCH_ENV="$env" launch "$name" "$@"
}
SONNET="--launch-flags '--model sonnet --effort high'"
while IFS='|' read -r label env settings tmux_env args want; do
  eval "set -- $args"
  assert_eq "$(alias_launch alias "$env" "$settings" "$tmux_env" "$@")" "$want" "$label"
done <<ROWS
sonnet with nothing set passes|-|{"env":{"OTHER":"1"}}|OTHER=1|${FLEET[*]} --harness claude $SONNET|passed
sonnet under ANTHROPIC_DEFAULT_SONNET_MODEL is refused|ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6|-|-|${FLEET[*]} --harness claude $SONNET|open-terminal: launch-window-unknown harness=claude model=sonnet
sonnet under CLAUDE_CODE_USE_BEDROCK is refused|CLAUDE_CODE_USE_BEDROCK=1|-|-|${FLEET[*]} --harness claude $SONNET|open-terminal: launch-window-unknown harness=claude model=sonnet
claude-sonnet-5 under the same pin passes|ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6|-|-|${FLEET[*]} --harness claude --launch-flags '--model claude-sonnet-5 --effort high'|passed
claude-sonnet-5 under the same switch passes|CLAUDE_CODE_USE_BEDROCK=1|-|-|${FLEET[*]} --harness claude --launch-flags '--model claude-sonnet-5 --effort high'|passed
haiku ignores the sonnet pin|ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6|-|-|${FLEET[*]} --harness claude --launch-flags '--model haiku --effort high'|passed
haiku under ANTHROPIC_DEFAULT_HAIKU_MODEL is refused|ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-3-5-haiku|-|-|${FLEET[*]} --harness claude --launch-flags '--model haiku --effort high'|open-terminal: launch-window-unknown harness=claude model=haiku
a pin in the settings env is refused|-|{"env":{"ANTHROPIC_DEFAULT_SONNET_MODEL":"claude-sonnet-4-6"}}|-|${FLEET[*]} --harness claude $SONNET|open-terminal: launch-window-unknown harness=claude model=sonnet
a settings file jq cannot read is refused|-|not json|-|${FLEET[*]} --harness claude $SONNET|open-terminal: launch-window-unknown harness=claude model=sonnet
a switch in the tmux global environment is refused|-|-|CLAUDE_CODE_USE_VERTEX=1|${FLEET[*]} --harness claude $SONNET|open-terminal: launch-window-unknown harness=claude model=sonnet
a tmux marker removing the key passes|-|-|-CLAUDE_CODE_USE_VERTEX|${FLEET[*]} --harness claude $SONNET|passed
a tmux environment that cannot be read is refused|-|-|!unreadable|${FLEET[*]} --harness claude $SONNET|open-terminal: launch-window-unknown harness=claude model=sonnet
ROWS
rm -f -- "${CLAUDE_CFG:?}/settings.json" "${TMUX_ENV_FILE:?}"

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
a hosted Pi fleet lane is not judged on this machine's settings or carrier, which are its host's to hold|none|{"compaction":{"enabled":true}}|-|${FLEET[*]} --harness pi --host $BIN/provider|passed
no fleet passes whatever its settings|none|-|-|--harness pi|passed
ROWS
rm -f -- "$PI_AGENT/settings.json" "$REPO/.pi/settings.json"
assert_eq "$(grep -c 'jq: error\|parse error' "$TMP_ROOT/pi.err" || true)" "0" \
  "the last row's run carries no jq words; the unreadable row's did, under its key"

echo "=== a local Pi fleet launch on a Copilot model is judged on the Pi root its lane leaves ==="
# Such a launch's gate waits for its lane. A lane `lanes pick` chose from
# ORCH_LANE_COPILOT_POOL runs under PI_CODING_AGENT_DIR naming that account, so
# its settings and carrier are read there and not under the root this launcher
# inherited (PI_AGENT); a lane an `auto:claude` spec picked leaves the
# inherited root, which is judged; a hosted lane is judged on its host.
# pool_launch prints the gate line and the lane selected, as its variable and
# the directory's name.
POOL_ROOT="$TMP_ROOT/pool-root"
mkdir -p "$POOL_ROOT/packages/@vanillagreen/pi-hooks/extensions"
printf 'export const f = { context_window: 1 };\n' > "$POOL_ROOT/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
pi_carrier sends
POOL_FLAGS='--model github-copilot/claude-sonnet-5 --thinking high'
# One measured Claude account for the `auto:claude` pick, under a home of the
# suite's own so no pick reads the operator's accounts.
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
new_home lanes-home
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
make_fetcher "$TMP_ROOT/fetch"
export LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/lanes-state"
pool_launch() { # NAME POOL_SETTINGS AGENT_SETTINGS ARGS...
  local name="$1" gate selected
  printf '%s\n' "$2" > "$POOL_ROOT/settings.json"
  printf '%s\n' "$3" > "$PI_AGENT/settings.json"
  shift 3
  gate="$(ORCH_LANE_COPILOT_POOL="$POOL_ROOT=1/10" launch "$name" "${FLEET[@]}" --harness pi --launch-flags "$POOL_FLAGS" "$@")"
  selected="$(sed -n 's/^open-terminal: lane-selected lane=//p' "$TMP_ROOT/$name.out")"
  printf '%s selected=%s:%s' "$gate" "${selected%%=*}" "$(basename -- "${selected#*=}")"
}
POOL_OFF='{"compaction":{"enabled":false}}'
POOL_ON='{"compaction":{"enabled":true}}'
assert_eq "$(pool_launch pool-off "$POOL_OFF" "$POOL_ON" --lane auto)" "passed selected=PI_CODING_AGENT_DIR:pool-root" \
  "the pool account's own settings turning compaction off pass, whatever the inherited root says"
assert_eq "$(pool_launch pool-on "$POOL_ON" "$POOL_OFF" --lane auto)" \
  "open-terminal: compaction-on harness=pi file=$POOL_ROOT/settings.json selected=PI_CODING_AGENT_DIR:pool-root" \
  "the pool account's own settings turning compaction on are refused, naming that file"
assert_eq "$(pool_launch pool-claude "$POOL_OFF" "$POOL_ON" --lane auto:claude)" \
  "open-terminal: compaction-on harness=pi file=$PI_AGENT/settings.json selected=CLAUDE_CONFIG_DIR:.claude" \
  "a lane the spec picked on a Claude account leaves the inherited root, whose compaction on is refused"
assert_eq "$(pool_launch pool-hosted "$POOL_ON" "$POOL_OFF" --lane auto --host "$BIN/provider")" \
  "passed selected=PI_CODING_AGENT_DIR:pool-root" \
  "a hosted lane on the pool is not judged on this machine's copy of the account"
rm -f -- "${PI_AGENT:?}/settings.json" "${POOL_ROOT:?}/settings.json"

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
assert_eq "$(OT="$CTRL_OT" launch window-ctrl "${FLEET[@]}" --harness claude --launch-flags '--model claude-sonnet-4-6 --effort high')" passed \
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
control window-read-ctrl '"$CLAIM_ROOT" || { ot_message unsupported-for-oversee "harness=pi" "reason=no-window-read" >&2; return 1; }' '"$CLAIM_ROOT" || :'
assert_eq "$(OT="$CTRL_OT" launch window-read-ctrl "${FLEET[@]}" --harness pi)" passed \
  "control: without its refusal a Pi fleet lane whose carrier sends no window passes"
rm -f -- "$PI_AGENT/settings.json"
pi_carrier sends
printf '{"compaction":{"enabled":true}}\n' > "$PI_AGENT/settings.json"
control hosted-pi-ctrl '      if [[ "$LANE_HOST" == local ]]; then' '      if true; then'
assert_eq "$(OT="$CTRL_OT" launch hosted-pi-ctrl "${FLEET[@]}" --harness pi --host "$BIN/provider")" "open-terminal: compaction-on harness=pi $PI_FILE" \
  "control: judged on this machine's files, a hosted Pi fleet lane is refused on settings that are not its own"
rm -f -- "$PI_AGENT/settings.json"
assert_eq "$(OT="$CTRL_OT" pool_launch hosted-pool-ctrl "$POOL_ON" "$POOL_OFF" --lane auto --host "$BIN/provider")" \
  "open-terminal: compaction-on harness=pi file=$POOL_ROOT/settings.json selected=PI_CODING_AGENT_DIR:pool-root" \
  "control: judged on this machine's files, a hosted Pi lane on the pool is refused on its local account copy"
control pool-root-ctrl '  PI_CODING_AGENT_DIR="${LANE_ENV#*=}"' '  :'
assert_eq "$(OT="$CTRL_OT" pool_launch pool-root-ctrl "$POOL_OFF" "$POOL_ON" --lane auto)" \
  "open-terminal: compaction-on harness=pi file=$PI_AGENT/settings.json selected=PI_CODING_AGENT_DIR:pool-root" \
  "control: judged on the inherited root, a Pi fleet lane on the Copilot pool is refused on settings that are not its own"
control deferred-gate-ctrl '[[ "$PI_GATE_DEFERRED" != true ]] || pi_local_gate' '[[ "${LANE_ENV%%=*}" != PI_CODING_AGENT_DIR ]] || pi_local_gate'
assert_eq "$(OT="$CTRL_OT" pool_launch deferred-gate-ctrl "$POOL_OFF" "$POOL_ON" --lane auto:claude)" \
  "passed selected=CLAUDE_CONFIG_DIR:.claude" \
  "control: a deferred gate run only on the pool's own variable lets a Claude-picked Pi fleet lane start unchecked"
rm -f -- "${PI_AGENT:?}/settings.json" "${POOL_ROOT:?}/settings.json"
control compaction-ctrl '0) ot_message compaction-on "harness=pi" "file=$LANE_ADAPTER_PI_FILE"' '0) : ot_message compaction-on "harness=pi" "file=$LANE_ADAPTER_PI_FILE"'
assert_eq "$(OT="$CTRL_OT" launch compaction-ctrl "${FLEET[@]}" --harness pi)" passed \
  "control: without its refusal a Pi fleet lane Pi would compact passes the gate"
# Each source the alias rule reads, and the rule's own reach, with its answer
# replaced in a staged lane-launch.sh: the row it holds reads the other way.
# alias_control NAME OLD NEW ENV SETTINGS TMUX MODEL ANSWER, `-` is none.
alias_control() { # NAME OLD NEW ENV SETTINGS TMUX MODEL ANSWER
  stage "$TMP_ROOT/$1"
  mutate_file "$TMP_ROOT/$1/scripts/lib/lane-launch.sh" "$2" "$3"
  assert_eq "$(OT="$TMP_ROOT/$1/scripts/open-terminal" alias_launch "$1" "$4" "$5" "$6" \
    "${FLEET[@]}" --harness claude --launch-flags "--model $7 --effort high")" "$8" \
    "control: with $1 applied, $7 reads $8"
}
alias_control alias-env-ctrl '    [[ -z "${!key:-}" ]] || return 0' '    :' \
  ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6 - - sonnet passed
alias_control alias-settings-ctrl '    [[ "$found" == 0 ]] || return 0' '    :' \
  - '{"env":{"ANTHROPIC_DEFAULT_SONNET_MODEL":"claude-sonnet-4-6"}}' - sonnet passed
alias_control alias-settings-read-ctrl '"$settings" 2>/dev/null)" || return 0' '"$settings" 2>/dev/null)" || found=0' \
  - 'not json' - sonnet passed
alias_control alias-tmux-ctrl '        case "$line" in "$key="?*) return 0 ;; esac' '        :' \
  - - CLAUDE_CODE_USE_VERTEX=1 sonnet passed
alias_control alias-tmux-read-ctrl '    tmux_env="$(tmux show-environment -g 2>/dev/null)" || return 0' '    tmux_env=""' \
  - - '!unreadable' sonnet passed
alias_control alias-reach-ctrl '    *) return 1 ;;' '    *) keys="$LAUNCH_CHOICE_CLAUDE_PROVIDER_KEYS" ;;' \
  CLAUDE_CODE_USE_BEDROCK=1 - - claude-sonnet-5 'open-terminal: launch-window-unknown harness=claude model=claude-sonnet-5'
rm -f -- "${CLAUDE_CFG:?}/settings.json" "${TMUX_ENV_FILE:?}"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
