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
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-harness-gate: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-harness-gate: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-harness-gate: scratch=resolve-failed" >&2; exit 1; }
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
# The worktree CLI of a launch that goes on to open its window, for the rows
# that read the command the terminal runs: a fresh repository per item.
cat > "$BIN/worktree-make" <<STUB
#!/usr/bin/env bash
d="$TMP_ROOT/wt/\${2:-unknown}"
case "\${1:-}" in
  exists) echo false ;;
  merged) exit 1 ;;
  path) printf '%s\n' "\$d" ;;
  create) mkdir -p "\$d"; git init -q "\$d"; git -C "\$d" config gc.auto 0; git -C "\$d" config maintenance.auto false; printf '%s\n' "\$d" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/term" "$BIN/gh" "$BIN/worktree-stub" "$BIN/worktree-make" "$BIN/provider"

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
# The Copilot account a copilot launch naming no lane runs on, so no row reads
# the developer's own.
CP_HOME="$TMP_ROOT/copilot-home"
mkdir -p "$CP_HOME"
# The pi-hooks carrier Pi loads, sending the window on its Stop payload or not,
# and listing the lane mail wake among its extensions or not.
PI_WAKE_MANIFEST='{"pi":{"extensions":["./extensions/hooks.ts","./extensions/lane-mail-wake.ts"]}}'
pi_carrier() { # sends|old|nowake|none
  rm -rf -- "${PI_AGENT:?}/packages"
  [[ "$1" != none ]] || return 0
  mkdir -p "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions"
  if [[ "$1" == old ]]; then
    printf 'export const f = { session_id: 1 };\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  else
    printf 'export const f = { context_window: 1 };\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  fi
  if [[ "$1" == nowake ]]; then
    printf '{"version":"0.12.0","pi":{"extensions":["./extensions/hooks.ts"]}}\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/package.json"
  else
    printf '%s\n' "$PI_WAKE_MANIFEST" > "$PI_AGENT/packages/@vanillagreen/pi-hooks/package.json"
  fi
}

# The launch-choice refusals that run ahead of the gate are read too, so a row
# refused before the gate cannot read as one the gate passed.
GATE_KEYS='unsupported-for-oversee|compaction-on|launch-window-unknown|launch-compaction-missing|pi-settings-unreadable|launch-question-tool-missing|launch-model-missing|launch-effort-missing|launch-unattended-missing'
# launch NAME ARGS... — the gate's line open-terminal wrote, or `passed` where it
# wrote none, for a GUI launch of CC-1 under ARGS; OT names another copy, and
# WT_CLI a worktree CLI other than the one that stops the launch before its
# window. Its stdout is kept in $TMP_ROOT/NAME.out, and the command its
# terminal ran in $TMP_ROOT/NAME.term.
launch() { # NAME ARGS...
  local name="$1" rc=0 line
  shift
  ( cd "$REPO" && PATH="$BIN:$PATH" ORCH_STATE_DIR="$TMP_ROOT/$name.state" WORKTREE_CLI="${WT_CLI:-$BIN/worktree-stub}" \
    OT_TERM_LOG="$TMP_ROOT/$name.term" TERMINAL=term TMUX= PI_CODING_AGENT_DIR="$PI_AGENT" COPILOT_HOME="$CP_HOME" \
    "${OT:-$REPO/scripts/open-terminal}" --ghostty "$@" CC-1 ) \
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
claude on sonnet, written as claude-sonnet-5, passes|passed|${FLEET[*]} --harness claude --launch-flags '--model sonnet --effort high'
claude on haiku, written as claude-haiku-4-5, passes|passed|${FLEET[*]} --harness claude --launch-flags '--model haiku --effort high'
claude on the attached --model=sonnet passes the same way|passed|${FLEET[*]} --harness claude --launch-flags '--model=sonnet --effort high'
a claude --cmd on the bare sonnet alias, run as written, is refused|open-terminal: launch-window-unknown harness=claude model=sonnet|${FLEET[*]} --harness claude --cmd "claude --model sonnet --effort high \$CLAUDE_QUESTION \$CLAUDE_WORDS {item}"
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
copilot with no fleet passes|passed|--harness copilot --launch-flags '--model claude-opus-5 --reasoning-effort high'
opencode with no fleet passes|passed|--harness opencode --launch-flags '--model m'
claude on a model with no window, with no fleet, passes|passed|--harness claude --launch-flags '--model claude-sonnet-4-6 --effort high'
ROWS

echo "=== a copilot fleet launch runs only where its account's status line writes the session record ==="
# `label|settings.json|args|answer`: `-` is no file. The record the status line
# writes is what the copilot adapter reads the lane's context from, so an
# account whose status line is another command, a script that is not there, or
# one refreshed too seldom for its record to stay fresh is refused under the
# cause the adapter names, and a hosted lane, whose account is its host's,
# always is. @SL@ is an executable copilot-statusline, @OTHER@ an executable
# script of another name, @GONE@ a copilot-statusline path holding nothing.
CP_FILE="file=$CP_HOME/settings.json"
CP_FLAGS="--launch-flags '--model claude-opus-5 --reasoning-effort high'"
CP_SL="$TMP_ROOT/sl/copilot-statusline"
CP_OTHER="$TMP_ROOT/sl/other-statusline"
mkdir -p "$TMP_ROOT/sl"
printf '#!/bin/sh\n' > "$CP_SL"
printf '#!/bin/sh\n' > "$CP_OTHER"
chmod +x "$CP_SL" "$CP_OTHER"
# A status line named bare resolves on the launch's PATH, which holds $BIN.
ln -s "$CP_SL" "$BIN/copilot-statusline"
CP_REFUSED="open-terminal: unsupported-for-oversee harness=copilot reason=status-line"
# cp_settings JSON — the account's settings file, or none for `-`.
cp_settings() {
  local body="$1"
  rm -f -- "${CP_HOME:?}/settings.json"
  body="${body//@SL@/$CP_SL}"
  body="${body//@OTHER@/$CP_OTHER}"
  body="${body//@GONE@/$TMP_ROOT/gone/copilot-statusline}"
  [[ "$body" == - ]] || printf '%s\n' "$body" > "$CP_HOME/settings.json"
}
while IFS='|' read -r label settings args want; do
  cp_settings "$settings"
  want="${want//@FILE@/$CP_FILE}"
  eval "set -- $args"
  assert_eq "$(launch copilot "$@")" "$want" "$label"
done <<ROWS
an account running copilot-statusline every 30 seconds passes|{"statusLine":{"type":"command","command":"@SL@","refreshInterval":30}}|${FLEET[*]} --harness copilot $CP_FLAGS|passed
an account with no settings file is refused|-|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=settings-missing @FILE@
a settings file jq cannot read is refused|not json|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=settings-unreadable @FILE@
a settings file with no command status line is refused|{"theme":"github"}|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=no-status-line @FILE@
an account whose status line is another command is refused|{"statusLine":{"type":"command","command":"@OTHER@","refreshInterval":30}}|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=other-command @FILE@
a status line naming a script that is not there is refused|{"statusLine":{"type":"command","command":"@GONE@","refreshInterval":30}}|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=command-missing @FILE@
a status line with no refresh interval is refused|{"statusLine":{"type":"command","command":"@SL@"}}|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=refresh-interval @FILE@
an interval at the record's freshness bound is refused|{"statusLine":{"type":"command","command":"@SL@","refreshInterval":120}}|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=refresh-interval @FILE@
an interval of 0, which refreshes nothing, is refused|{"statusLine":{"type":"command","command":"@SL@","refreshInterval":0}}|${FLEET[*]} --harness copilot $CP_FLAGS|$CP_REFUSED cause=refresh-interval @FILE@
a status line named bare passes where the launch's PATH resolves it|{"statusLine":{"type":"command","command":"copilot-statusline","refreshInterval":30}}|${FLEET[*]} --harness copilot $CP_FLAGS|passed
an interval one second under the bound passes|{"statusLine":{"type":"command","command":"@SL@","refreshInterval":119}}|${FLEET[*]} --harness copilot $CP_FLAGS|passed
a hosted copilot fleet lane is refused|{"statusLine":{"type":"command","command":"@SL@","refreshInterval":30}}|${FLEET[*]} --harness copilot --host $BIN/provider $CP_FLAGS|open-terminal: unsupported-for-oversee harness=copilot reason=hosted
no fleet passes with no status line|-|--harness copilot $CP_FLAGS|passed
ROWS
# One control per rule: the gate's call, the command match, the file test, the
# interval bound and the hosted arm.
cp_control() { # NAME FILE OLD NEW SETTINGS ARGS WANT LABEL
  local ctl="$TMP_ROOT/$1" name="$1" want="$7" label="$8"
  stage "$ctl"
  mutate_file "$ctl/scripts/$2" "$3" "$4"
  cp_settings "$5"
  eval "set -- $6"
  assert_eq "$(OT="$ctl/scripts/open-terminal" launch "$name" "$@")" "$want" "$label"
}
cp_control cp-call open-terminal 'copilot_fleet_gate || exit 1' ':' - "${FLEET[*]} --harness copilot $CP_FLAGS" passed \
  "control: without the gate's call an account with no status line launches into the fleet"
cp_control cp-match lib/adapters/copilot.sh '[ "${command##*/}" = copilot-statusline ]' '[ -n "$command" ]' \
  '{"statusLine":{"type":"command","command":"@OTHER@","refreshInterval":30}}' "${FLEET[*]} --harness copilot $CP_FLAGS" passed \
  "control: without the command match another status line passes"
cp_control cp-exists lib/adapters/copilot.sh '{ [ -n "$command" ] && [ -f "$command" ] && [ -x "$command" ]; }' '{ [ -n "$command" ]; }' \
  '{"statusLine":{"type":"command","command":"@GONE@","refreshInterval":30}}' "${FLEET[*]} --harness copilot $CP_FLAGS" passed \
  "control: without the file test a status line naming nothing passes"
cp_control cp-interval lib/adapters/copilot.sh '[ "$interval" -lt "$COPILOT_SESSION_MAX_AGE_S" ]' '[ "$interval" -le "$COPILOT_SESSION_MAX_AGE_S" ]' \
  '{"statusLine":{"type":"command","command":"@SL@","refreshInterval":120}}' "${FLEET[*]} --harness copilot $CP_FLAGS" passed \
  "control: with the bound inclusive an interval every record goes stale at passes"
cp_control cp-bare lib/adapters/copilot.sh '    *) command="$(command -v -- "$command" 2>/dev/null)" || command="" ;;' '    *) command="" ;;' \
  '{"statusLine":{"type":"command","command":"copilot-statusline","refreshInterval":30}}' "${FLEET[*]} --harness copilot $CP_FLAGS" "$CP_REFUSED cause=command-missing file=$CP_HOME/settings.json" \
  "control: without the PATH lookup a status line named bare is refused as missing"
cp_control cp-hosted open-terminal 'copilot) [[ "$LANE_HOST" == local ]] ||' 'copilot) true ||' \
  '{"statusLine":{"type":"command","command":"@SL@","refreshInterval":30}}' "${FLEET[*]} --harness copilot --host $BIN/provider $CP_FLAGS" passed \
  "control: without the hosted arm a hosted copilot fleet lane is not refused"
cp_settings -

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
a carrier that lists no lane mail wake passes|nowake|{"compaction":{"enabled":false}}|-|${FLEET[*]} --harness pi|passed
a settings file jq cannot read is named|sends|not json|-|${FLEET[*]} --harness pi|open-terminal: pi-settings-unreadable @FILE@
a hosted Pi fleet lane is not judged on this machine's settings or carrier, which are its host's to hold|none|{"compaction":{"enabled":true}}|-|${FLEET[*]} --harness pi --host $BIN/provider|passed
no fleet passes whatever its settings|none|-|-|--harness pi|passed
ROWS
rm -f -- "$PI_AGENT/settings.json" "$REPO/.pi/settings.json"
assert_eq "$(grep -c 'jq: error\|parse error' "$TMP_ROOT/pi.err" || true)" "0" \
  "the last row's run carries no jq words; the unreadable row's did, under its key"

echo "=== a local Pi fleet lane's carrier decides its brief's arm line, never the launch ==="
# With the lane mail wake the brief the terminal runs carries no arm line; a
# carrier without it launches all the same, its brief carrying the
# watch-delivery.md arm line and the launch naming the carrier's version.
printf '{"compaction":{"enabled":false}}\n' > "$PI_AGENT/settings.json"
# The brief carries Pi's unattended words, read from lib/lane-launch.sh, the
# table open-terminal judges them from, so the launch reaches the carrier.
PI_UNATTENDED_TEXT="$(bash -c 'source "$1" && launch_choice_unattended pi' _ "$SCRIPTS_DIR/lib/lane-launch.sh")"
[[ -n "$PI_UNATTENDED_TEXT" ]] || { echo "lib/lane-launch.sh named no pi unattended text" >&2; exit 1; }
printf 'Work the item.\n%s\n' "$PI_UNATTENDED_TEXT" > "$TMP_ROOT/pi-brief.txt"
PI_BRIEF_CMD='pi --exclude-tools question --model m --thinking high {brief}'
for row in "sends|0|0" "nowake|1|1"; do
  IFS='|' read -r carrier want_arm want_notice <<<"$row"
  pi_carrier "$carrier"
  answer="$(WT_CLI="$BIN/worktree-make" launch "brief-$carrier" "${FLEET[@]}" --harness pi --cmd "$PI_BRIEF_CMD" --brief-file "$TMP_ROOT/pi-brief.txt")"
  assert_eq "$answer arm=$(grep -cF 'arm the mailbox monitor `lane-mail watch --item CC-1`' "$TMP_ROOT/brief-$carrier.term" || true) notice=$(grep -c '^open-terminal: pi-mail-wake-missing harness=pi version=0.12.0$' "$TMP_ROOT/brief-$carrier.out" || true)" \
    "passed arm=$want_arm notice=$want_notice" \
    "a Pi fleet lane on a $carrier carrier launches, its brief carrying the arm line only where the carrier lists no mail wake"
done
rm -f -- "$PI_AGENT/settings.json"

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
printf '%s\n' "$PI_WAKE_MANIFEST" > "$POOL_ROOT/packages/@vanillagreen/pi-hooks/package.json"
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
control alias-id-ctrl '        [[ "$LAUNCH_CHOICE_COMPACTION" == on ]] || gate_window=false' '        launch_choice_compaction "$LAUNCH_HARNESS" "$LAUNCH_MODEL" >/dev/null || gate_window=false'
assert_eq "$(OT="$CTRL_OT" launch alias-id-ctrl "${FLEET[@]}" --harness claude --launch-flags '--model sonnet --effort high')" \
  "open-terminal: launch-window-unknown harness=claude model=sonnet" \
  "control: judged on the alias rather than the id it is written as, a sonnet fleet lane is refused"
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
pi_carrier nowake
control mail-wake-ctrl '  pi_mail_wake_read "$wakes" "$LANE_ADAPTER_PI_CARRIER_VERSION"' '  ot_message unsupported-for-oversee "harness=pi" "reason=no-mail-wake" >&2; return 1'
assert_eq "$(OT="$CTRL_OT" launch mail-wake-ctrl "${FLEET[@]}" --harness pi)" "open-terminal: unsupported-for-oversee harness=pi reason=no-mail-wake" \
  "control: a refusal planted on the absent wake stops the launch the rows above pass"
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
