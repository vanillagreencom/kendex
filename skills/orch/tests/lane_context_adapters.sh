#!/usr/bin/env bash
# Tests for the harness adapters under lib/adapters/ and the one judge of a
# context reading, lane_context_handoff_due, both reached through
# lib/lane-context.sh. An adapter turns the records its harness writes into
# one reading, the tokens the last response left in the context and the
# window the model has; the judge answers whether a reading is at or past a
# percentage of its own window. Every reader of a reading, the turn-end hook,
# `lanes context` and `oversee-succeed`, asks these two, so a row here pins
# what all of them decide.
#
# LIB_UNDER_TEST names another copy of the library, with its adapters beside
# it, for the must-fail controls at the end; each control runs only the one
# table its planted defect reaches.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LIB="${LIB_UNDER_TEST:-$SCRIPTS_DIR/lib/lane-context.sh}"

TMP_ROOT="$(mktemp -d)" || { echo "lane_context_adapters: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane_context_adapters: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane_context_adapters: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# The suite is a run of tables, each opened by `section NAME`. An ordinary run
# covers every table. A control's run, of a mutated copy, names the one table its planted defect
# reaches in LANE_CONTEXT_SUITE_ONLY, and runs that table alone. SITES records
# each assertion under its table, so a control finds the table from the
# assertion it expects to go red and refuses a name that two tables share.
SECTION_NOW=setup
SITES="$TMP_ROOT/sites"
: > "$SITES"
section() { # NAME
  SECTION_NOW="$1"
  [[ -z "${LIB_UNDER_TEST:-}" || -z "${LANE_CONTEXT_SUITE_ONLY:-}" || "$LANE_CONTEXT_SUITE_ONLY" == "$1" ]]
}
eval "assertions_$(declare -f pass)"
eval "assertions_$(declare -f fail)"
pass() { printf '%s\t%s\n' "$SECTION_NOW" "$1" >> "$SITES"; assertions_pass "$@"; }
fail() { printf '%s\t%s\n' "$SECTION_NOW" "$1" >> "$SITES"; assertions_fail "$@"; }

# A known managed launch for the ordinary transcript rows. Each configuration
# row below replaces its own evidence, independent of the developer machine.
export DISABLE_AUTO_COMPACT=1 DISABLE_COMPACT=0
unset ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST
export ORCH_COMPACTION_OVERRIDES='{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}'
export PI_CODING_AGENT_DIR="$TMP_ROOT/pi-reading-agent"
PI_READ_PROJECT="$TMP_ROOT/pi-reading-project"
mkdir -p "$PI_CODING_AGENT_DIR" "$PI_READ_PROJECT"
printf '%s\n' '{"compaction":{"enabled":false}}' > "$PI_CODING_AGENT_DIR/settings.json"

# reading LIB HARNESS WINDOW — the adapter's answer for the transcript on
# stdin, with TABs shown as `|` and the exit status beside it.
reading() { # LIB HARNESS WINDOW
  local out rc=0
  out="$(bash -c 'set -euo pipefail; source "$1"; lane_context_reading "$2" "$3" "$4"' _ "$1" "$2" "$3" "$PI_READ_PROJECT")" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ ${out//$'\t'/|}}"
}

# due LIB TOKENS WINDOW PCT — the judge's answer and exit status.
due() { # LIB TOKENS WINDOW PCT
  local out rc=0
  out="$(bash -c 'set -euo pipefail; source "$1"; shift; lane_context_handoff_due "$@"' _ "$@")" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $out}"
}

# One transcript line per spelling a harness writes, with a model and a figure.
# Each figure holds 7 output tokens, the response the next request sends back,
# so a figure one over a prompt is read only where the output is summed.
claude_line() { # MODEL TOKENS
  jq -nc --arg m "$1" --argjson t "$2" \
    '{type:"assistant",message:{model:$m,usage:{input_tokens:1,cache_read_input_tokens:($t - 8),cache_creation_input_tokens:0,output_tokens:7}}}'
}
codex_context() { # MODEL
  jq -nc --arg m "$1" '{type:"turn_context",payload:{model:$m}}'
}
codex_count() { # TOKENS WINDOW
  jq -nc --argjson t "$1" --argjson w "$2" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{input_tokens:($t - 7),output_tokens:7,total_tokens:$t},model_context_window:$w}}}'
}
pi_line() { # MODEL TOKENS [PROVIDER]
  jq -nc --arg m "$1" --argjson t "$2" --arg p "${3:-}" \
    '{type:"message",message:({role:"assistant",model:$m,usage:{input:1,output:7,cacheRead:($t - 8),cacheWrite:0,totalTokens:$t}}
      + (if $p == "" then {} else {provider:$p} end))}'
}

# The transcripts, each named for what it holds.
T="$TMP_ROOT/t"; mkdir -p "$T"
{ claude_line claude-opus-5-5 600000; claude_line claude-opus-5-5 1000; } > "$T/claude-last"
{ claude_line claude-opus-5-5 1000; printf '{"type":"assistant","message":{"usa'; } > "$T/claude-partial"
{ claude_line claude-fable-5-1 700000
  jq -nc '{type:"assistant",message:{model:"<synthetic>",usage:{input_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}'; } > "$T/claude-synthetic"
claude_line claude-sonnet-5 400000 > "$T/claude-sonnet"
claude_line claude-haiku-4-5-20251001 150000 > "$T/claude-haiku"
claude_line MyProviderModel 150000 > "$T/claude-unknown"
jq -nc '{type:"assistant",message:{model:"claude-opus-5-5",usage:{prompt_tokens:5}}}' > "$T/claude-unread"
jq -nc '{type:"user",message:{content:"hi"}}' > "$T/none"
{ codex_context gpt-6-astra; codex_count 1000 258400; codex_count 232560 258400; } > "$T/codex-last"
{ codex_context gpt-6-astra; codex_count 1000 258400
  jq -nc '{type:"event_msg",payload:{type:"token_count",info:null}}'; } > "$T/codex-null-info"
{ codex_context gpt-6-astra
  jq -nc '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{},model_context_window:258400}}}'; } > "$T/codex-unread"
codex_context gpt-6-astra > "$T/codex-none"
{ pi_line m 600000; pi_line m 1000; } > "$T/pi-last"
claude_line claude-opus-5-5 1000 > "$T/pi-claude-spelled"
pi_line claude-opus-5-5 1000 pi-claude > "$T/pi-provider"

if section reads; then
  echo "=== each adapter reads the last reading its harness recorded ==="
  # `file|harness|payload window|answer`
  while IFS='|' read -r file harness window want; do
    assert_eq "$(reading "$LIB" "$harness" "$window" < "$T/$file")" "$want" "$harness reads $file as: $want"
  done <<'ROWS'
claude-last|claude||rc=0 1000|1000000|claude-opus-5-5
claude-partial|claude||rc=0 1000|1000000|claude-opus-5-5
claude-synthetic|claude||rc=0 700000|1000000|claude-fable-5-1
claude-sonnet|claude||rc=0 400000|200000|claude-sonnet-5
claude-haiku|claude||rc=0 150000|200000|claude-haiku-4-5-20251001
claude-unknown|claude||rc=0 150000|200000|MyProviderModel
claude-unread|claude||rc=0 unread
none|claude||rc=0
codex-last|codex||rc=0 232560|258400|gpt-6-astra
codex-null-info|codex||rc=0 1000|258400|gpt-6-astra
codex-unread|codex||rc=0 unread
codex-none|codex||rc=0
pi-last|pi|200000|rc=0 1000|200000|m
pi-last|pi||rc=0 1000||m
pi-provider|pi|200000|rc=0 1000|200000|pi-claude/claude-opus-5-5
pi-claude-spelled|pi|200000|rc=0 unread
claude-last|opencode||rc=3
ROWS
fi

if section claude-identity; then
  echo "=== Claude families and native aliases need no version pins ==="
  echo "=== resolved Claude launch identity ==="
  while IFS='|' read -r model pin want mode recorded; do
    got="$(env ANTHROPIC_DEFAULT_OPUS_MODEL="$pin" ANTHROPIC_DEFAULT_FABLE_MODEL="$pin" \
      ANTHROPIC_DEFAULT_SONNET_MODEL="$pin" ANTHROPIC_DEFAULT_HAIKU_MODEL="$pin" "$BASH" -euo pipefail -c \
      '. "$1"; lane_adapter_claude_model_id "$2" "$3" "$4"' _ "$LIB" "$model" "${mode:-resolved}" "$recorded")"
    assert_eq "$got" "$want" "${mode:-resolved} identity $model pin=$pin"
  done <<'ROWS'
fable-5-1||claude-fable-5-1
claude-fable-5-1||claude-fable-5-1
claude-fable-5-1[1m]||claude-fable-5-1
claude-opus-4-8-20261001||claude-opus-4-8-20261001
sonnet||
sonnet|claude-sonnet-4-6|
sonnet[1m]|claude-sonnet-4-6|
fable||
best||
default||
opus||
sonnet|claude-sonnet-4-6|sonnet|recorded
sonnet|claude-sonnet-4-6|sonnet|launch
sonnet[1m]|claude-sonnet-4-6|sonnet[1m]|launch
opus|claude-opus-5-5|opus|launch
fable|claude-fable-5-5|fable|launch
haiku|claude-haiku-5-5|haiku|launch
fable||fable|recorded
opus[1m]||opus|recorded
haiku||haiku|recorded
fable-5-1||claude-fable-5-1|recorded
claude-opus-4-8-20261001||claude-opus-4-8-20261001|recorded
claude-sonnet-4-6|claude-sonnet-5-5|sonnet|resolved|sonnet
claude-opus-4-8||opus|resolved|opus[1m]
claude-fable-5-1||fable|resolved|fable
claude-haiku-5-5||haiku|resolved|haiku
claude-opus-4-8||claude-opus-4-8|resolved|sonnet
claude-opus-4-8||claude-opus-4-8|resolved|claude-opus-4-6
opusplan||opusplan|launch
MyProviderModel||MyProviderModel|launch
fable-5-1[1m]||claude-fable-5-1|launch
ROWS
  # `model|window|id`: a model, its window, and the id a launch writes for it.
  # Version fields do not change a family's handoff budget. Claude receives
  # native aliases and applies its own family overrides.
  while IFS='|' read -r model want id; do
    assert_eq "$(bash -c 'set -euo pipefail; source "$1"; lane_adapter_claude_window "$2"; lane_adapter_claude_model_id "$2"' _ "$LIB" "$model" | tr '\n' '|')" \
      "${want:+$want|}${id:-$model}|" "claude window of $model: ${want:-none}, written as ${id:-$model}"
  done <<'ROWS'
fable|1000000
opus[1m]|1000000
claude-opus-5-5|1000000
sonnet|200000
Sonnet|200000|sonnet
claude-sonnet-5|200000
claude-sonnet-5-5|200000
haiku|200000
claude-haiku-4-5|200000
claude-haiku-4-5-20251001|200000
claude-haiku-5-5|200000
claude-sonnet-9-9|200000
claude-sonnet-4-6|200000
claude-sonnet-4-5|200000
claude-sonnet-5-1|200000
sonnet[1m]|200000
haiku[1m]|200000
MyProviderModel|200000|myprovidermodel
|200000
ROWS
fi

if section dry-launch; then
  echo "=== dry launch keeps compaction off for new models ==="
  # Exercise the production gate and command builder in one shell. The second
  # build must not repeat the notice the first build emitted.
  while IFS='|' read -r model window notices; do
    got="$("$BASH" -euo pipefail -c '
      source "${1%/*}/lane-launch.sh"
      launch_choice_lead_settings claude --model "$2"
      launch_choice_lead_settings --question-off claude --model "$2"
      printf "%s|%s|%s\n" "$LAUNCH_CHOICE_COMPACTION" "$(lane_adapter_claude_window "$2")" "${LAUNCH_CHOICE_KEPT[*]}"
    ' _ "$LIB" "$model" 2>"$TMP_ROOT/launch.err")"
    assert_eq "${got%%|*}" on "dry launch $model disables compaction"
    remaining="${got#*|}"
    assert_eq "${remaining%%|*}" "$window" "dry launch $model uses its budget"
    assert_contains "${remaining#*|}" '--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}' "dry launch $model carries compaction settings"
    assert_eq "$(grep -c '^claude-window-default model=' "$TMP_ROOT/launch.err" || true)" "$notices" "dry launch $model notice count"
    if [[ "$notices" == 1 ]]; then
      assert_eq "$(cat "$TMP_ROOT/launch.err")" "claude-window-default model=$model window=$window" "dry launch $model notice fields"
    fi
  done <<'ROWS'
claude-sonnet-9-9|200000|0
claude-haiku-5-5|200000|0
claude-opus-5-5|1000000|0
claude-lyra-9-9|200000|1
ROWS
fi

if section compaction-config; then
  echo "=== effective compaction settings preserve unresolved token use ==="
  # harness|evidence|point. Enabled/unknown configurations keep the token count.
  while IFS='|' read -r harness evidence point; do
    case "$harness" in
      claude)
        answer=$(DISABLE_AUTO_COMPACT="$evidence" reading "$LIB" claude "" < "$T/claude-last")
        want="rc=0 1000|$point|claude-opus-5-5" ;;
      codex)
        answer=$(ORCH_COMPACTION_OVERRIDES="$evidence" reading "$LIB" codex "" < "$T/codex-last")
        want="rc=0 232560|$point|gpt-6-astra" ;;
      pi)
        printf '%s\n' "$evidence" > "$PI_CODING_AGENT_DIR/settings.json"
        answer=$(reading "$LIB" pi 200000 < "$T/pi-last" 2>"$TMP_ROOT/pi-settings.err")
        want="rc=0 1000|$point|m" ;;
    esac
    assert_eq "$answer" "$want" "$harness configuration $evidence gives point ${point:-unresolved}"
  done <<'ROWS'
claude|0|
claude|1|1000000
codex||
codex|not-json|
codex|[]|
codex|{"harness":"codex","settings":false}|
codex|{"harness":"claude","settings":{}}|
codex|{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807"}}|
codex|{"harness":"codex","settings":{"model_auto_compact_token_limit":"200000","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}|
codex|{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"total","model_post_turn_compact_threshold_percent":"0"}}|
codex|{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"80"}}|
codex|{"harness":"codex","settings":{"model_auto_compact_token_limit":"258400","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}|258400
pi|not-json|
pi|{}|
pi|{"compaction":{"enabled":true}}|
pi|{"compaction":{"enabled":false}}|200000
ROWS

  # Read the custom launch's generated environment, then run the real adapter.
  mkdir -p "$TMP_ROOT/launch-bin"
  cat > "$TMP_ROOT/launch-bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${ORCH_COMPACTION_OVERRIDES:-}"
STUB
  chmod +x "$TMP_ROOT/launch-bin/codex"
  while IFS='|' read -r cmd point; do
    evidence=$(PATH="$TMP_ROOT/launch-bin:$PATH" "$BASH" -euo pipefail -c '
      source "$1/lib/lane-launch.sh"
      line=$(lane_launch_line "$2" codex CODEX_HOME "$3" custom)
      "$BASH" -c "$line"
    ' _ "$SCRIPTS_DIR" "$cmd" "$TMP_ROOT/launch-home")
    answer=$(ORCH_COMPACTION_OVERRIDES="$evidence" reading "$LIB" codex "" < "$T/codex-last")
    assert_eq "$answer" "rc=0 232560|$point|gpt-6-astra" "custom Codex command window: $cmd"
  done <<'ROWS'
codex -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0|258400
codex prompt|
codex -c model_auto_compact_token_limit=9223372036854775807; echo unknown|
ROWS
fi

if section before-point; then
  # Every harness reaches the common judge through its adapter. Sonnet's mark
  # must fit a supported 200K session even when its alias selects a larger one.
  while IFS='|' read -r harness model tokens expected full; do
    case "$harness" in
      claude) claude_line "$model" "$tokens" > "$T/before-point" ;;
      codex) { codex_context "$model"; codex_count "$tokens" 258400; } > "$T/before-point" ;;
      pi) pi_line "$model" "$tokens" > "$T/before-point" ;;
    esac
    answer=$(reading "$LIB" "$harness" 200000 < "$T/before-point")
    point=${answer#*|}; point=${point%%|*}
    assert_eq "$(due "$LIB" "$tokens" "$point" 90)" "rc=0 $expected" "$harness $model before-point $tokens is $expected"
    rc=0
    "$BASH" -euo pipefail -c 'source "$1"; lane_context_window_full "$2" "$3" "$4"' _ "$LIB" "$tokens" "$point" "$harness" || rc=$?
    assert_eq "$rc" "$full" "$harness $model full-window status at $tokens"
  done <<'ROWS'
claude|claude-opus-5-5|399999|room|1
claude|claude-opus-5-5|400000|due|1
claude|sonnet|180000|room|1
claude|sonnet|180001|due|1
claude|claude-sonnet-4-5-20250929|190000|due|1
claude|claude-sonnet-4-6|190000|due|1
claude|claude-sonnet-9-9|190000|due|1
claude|claude-sonnet-4-5-20250929|200000|due|0
codex|gpt-6-astra|232560|room|1
codex|gpt-6-astra|232561|due|1
pi|m|180000|room|1
pi|m|180001|due|1
ROWS
fi

if section judge; then
  echo "=== the one judge answers at a share of the reading's own window ==="
  # `tokens|window|pct|answer`
  while IFS='|' read -r tokens window pct want; do
    assert_eq "$(due "$LIB" "$tokens" "$window" "$pct")" "$want" "$tokens of ${window:-no window} at $pct: $want"
  done <<'ROWS'
232560|258400|90|rc=0 room
232561|258400|90|rc=0 due
232559|258400|90|rc=0 room
117964|131072|90|rc=0 room
117965|131072|90|rc=0 due
399999|1000000|90|rc=0 room
400000|1000000|90|rc=0 due
400000||90|rc=0 due
400000|0|90|rc=0 due
399999||90|rc=1
400000|2000000|100|rc=0 due
180000|200000|100|rc=0 room
180001|200000|100|rc=0 due
160000|200000|80|rc=0 room
160001|200000|80|rc=0 due
0|258400|90|rc=0 room
258400|258400|100|rc=0 due
5||90|rc=1
5|0|90|rc=1
5|10|0|rc=2
5|10|101|rc=2
5|10|090|rc=2
05|10|90|rc=2
x|10|90|rc=2
5|1x|90|rc=2
ROWS
fi

if section window-full; then
  echo "=== a reading fills its window only where that window is a hard limit ==="
  # `tokens|window|harness|exit status`: claude, codex and pi name a window only
  # where the harness would not compact first; copilot's is its compaction point.
  while IFS='|' read -r tokens window harness want; do
    rc=0
    bash -c 'set -euo pipefail; source "$1"; lane_context_window_full "$2" "$3" "$4"' _ "$LIB" "$tokens" "$window" "$harness" || rc=$?
    assert_eq "rc=$rc" "$want" "window full: $tokens of ${window:-no window} on ${harness:-no harness}: $want"
  done <<'ROWS'
1000000|1000000|claude|rc=0
1000001|1000000|claude|rc=0
999999|1000000|claude|rc=1
258400|258400|codex|rc=0
200000|200000|pi|rc=0
800000|800000|copilot|rc=1
900000|800000|copilot|rc=1
5||claude|rc=1
5|0|claude|rc=1
x|10|claude|rc=2
05|10|claude|rc=2
5|1x|claude|rc=2
5|10|opencode|rc=3
5|10||rc=3
ROWS
fi

if section pi-compaction; then
  echo "=== a Pi launch reads whether Pi would compact the session ==="
  PI_AGENT="$TMP_ROOT/pi-agent"; PI_PROJECT="$TMP_ROOT/pi-project"
  mkdir -p "$PI_AGENT" "$PI_PROJECT/.pi"
  # `user settings|project settings|answer` — `-` is no file; 0 compacts, 1 does
  # not, 2 is a file that could not be read.
  while IFS='|' read -r user project want; do
    rm -f -- "$PI_AGENT/settings.json" "$PI_PROJECT/.pi/settings.json"
    [[ "$user" == - ]] || printf '%s\n' "$user" > "$PI_AGENT/settings.json"
    [[ "$project" == - ]] || printf '%s\n' "$project" > "$PI_PROJECT/.pi/settings.json"
    rc=0
    PI_CODING_AGENT_DIR="$PI_AGENT" bash -c 'source "$1"; lane_adapter_pi_compaction_on "$2"' _ "$LIB" "$PI_PROJECT" || rc=$?
    assert_eq "rc=$rc" "$want" "user $user and project $project: $want"
  done <<'ROWS'
-|-|rc=0
{}|-|rc=0
{"compaction":{"enabled":true}}|-|rc=0
{"compaction":{"enabled":false}}|-|rc=1
{"compaction":{"enabled":false}}|{"compaction":{"enabled":true}}|rc=0
{"compaction":{"enabled":false}}|{"compaction":{"enabled":false}}|rc=1
{"compaction":{"enabled":true}}|{"compaction":{"enabled":false}}|rc=0
not json|-|rc=2
ROWS
fi

if section record; then
  echo "=== the reading a turn end records, and the report's judgement of it ==="
  BOX="$TMP_ROOT/box"; mkdir -p "$BOX"
  bash -c 'source "$1"; lane_context_record "$2" codex 232560 258400 gpt-6-astra s1 "7000 %9"' _ "$LIB" "$BOX"
  assert_eq "$(jq -c 'del(.at)' "$BOX/context.json")" \
    '{"harness":"codex","model":"gpt-6-astra","tokens":232560,"window":258400,"used_pct":90,"capacity_source":null,"session_id":"s1","pane_key":"7000 %9","gap":null}' \
    "the record names the reading, the share used, and the session and pane it belongs to"
  assert_eq "$(bash -c 'source "$1"; lane_context_record_judged "$(cat "$2")" 90' _ "$LIB" "$BOX/context.json" | jq -c '.handoff_due')" \
    "false" "the report judges a recorded reading by the same judge"
  bash -c 'source "$1"; lane_context_record "$2" pi 1000 "" m' _ "$LIB" "$BOX"
  assert_eq "$(bash -c 'source "$1"; lane_context_record_judged "$(cat "$2")" 90' _ "$LIB" "$BOX/context.json" | jq -c '[.window, .used_pct, .handoff_due]')" \
    "[null,null,null]" "a reading with no window is recorded unmeasured and judged neither due nor room"
  assert_eq "$(ls -A "$BOX")" "context.json" "the record lands by a rename, leaving no staged file beside it"
  # A turn end that took no reading writes the reason as the gap, with no token
  # count, and the one parser of a record reads it back as a gap and not as a
  # reading, which the report's judge refuses to judge.
  bash -c 'source "$1"; lane_context_record "$2" claude null "" "" s1 "7000 %9" home-unnamed' _ "$LIB" "$BOX"
  assert_eq "$(jq -c 'del(.at)' "$BOX/context.json")" \
    '{"harness":"claude","model":null,"tokens":null,"window":null,"used_pct":null,"capacity_source":null,"session_id":"s1","pane_key":"7000 %9","gap":"home-unnamed"}' \
    "a gap record names the reason and the session and pane, with no reading"
  # shellcheck disable=SC2016  # expanded by the child shell.
  fields() { bash -c 'source "$1"; if lane_context_record_fields "$2"; then
      printf "rc=0 harness=%s tokens=%s pane=%s session=%s gap=%s at=%s\n" "$LANE_CTX_HARNESS" "${LANE_CTX_TOKENS:-none}" "$LANE_CTX_PANE_KEY" "${LANE_CTX_SESSION:-none}" "${LANE_CTX_GAP:-none}" "${LANE_CTX_AT:+set}"
    else echo "rc=$?"; fi' _ "$LIB" "$1"; }
  while IFS='|' read -r record expected what; do
    assert_eq "$(fields "$record")" "$expected" "$what"
  done <<ROWS
$(cat "$BOX/context.json")|rc=0 harness=claude tokens=none pane=7000 %9 session=s1 gap=home-unnamed at=set|a gap record parses with its gap, its session and no tokens
{"harness":"claude","tokens":5,"gap":null,"pane_key":"k","at":"t"}|rc=0 harness=claude tokens=5 pane=k session=none gap=none at=set|a reading parses with no gap
{"harness":"claude","tokens":null,"gap":null,"pane_key":"k"}|rc=1|a record with neither a reading nor a gap is no record
{"harness":"claude","tokens":5,"gap":"home-unnamed","pane_key":"k"}|rc=1|a record carrying both a reading and a gap is no record
ROWS
  assert_eq "$(bash -c 'source "$1"; if lane_context_record_judged "$(cat "$2")" 90; then echo rc=0; else echo "rc=$?"; fi' _ "$LIB" "$BOX/context.json")" \
    "rc=1" "the report's judge refuses a gap record as no reading"
  bash -c 'source "$1"; lane_context_record "$2" copilot 150000 217600 "" s1 "" "" "80% of tokenLimit"' _ "$LIB" "$BOX"
  assert_eq "$(bash -c 'source "$1"; lane_context_record_fields "$(cat "$2")"; printf "%s|%s|%s" "$LANE_CTX_SESSION" "$LANE_CTX_WINDOW" "$LANE_CTX_AT"' _ "$LIB" "$BOX/context.json" | cut -c1-12)" \
    "s1|217600|20" "a record's fields name its session apart from the time it was taken"
  assert_eq "$(jq -c '[.capacity_source, .gap]' "$BOX/context.json")" '["80% of tokenLimit",null]' \
    "a reading whose capacity is not the window its harness reported names where it came from, and names no gap"
fi

if section copilot-reading; then
  echo "=== a Copilot usage reading read as one reading ==="
  # copilot_reading PAYLOAD — lane_context_copilot_reading's answer, TABs as `|`.
  copilot_reading() { # PAYLOAD
    local out rc=0
    out="$(printf '%s' "$1" | bash -c 'source "$1"; lane_context_copilot_reading' _ "$LIB" 2>/dev/null)" || rc=$?
    printf 'rc=%s%s' "$rc" "${out:+ ${out//$'\t'/|}}"
  }
  # `payload|want`: the payload the copilot-lane-context extension hands the
  # usage arm, the capacity 80 percent of the token limit, rounded down.
  COPILOT_SOURCE="80% of tokenLimit, Copilot's backgroundCompactionThreshold default"
  while IFS='|' read -r payload want; do
    assert_eq "$(copilot_reading "$payload")" "${want//@/$COPILOT_SOURCE}" "copilot $payload: ${want//@/SOURCE}"
  done <<'ROWS'
{"session_id":"s1","cwd":"/w","current_tokens":150000,"token_limit":272000}|rc=0 150000|217600|@
{"session_id":"s1","cwd":"/w","current_tokens":0,"token_limit":24001}|rc=0 0|19200|@
{"current_tokens":150000,"token_limit":0}|rc=5
{"current_tokens":150000}|rc=5
{"current_tokens":"150000","token_limit":272000}|rc=5
{"current_tokens":1.5,"token_limit":272000}|rc=5
[]|rc=5
ROWS
fi

if section compaction-flag; then
  echo "=== a Copilot session's compaction flag, and whose it is ==="
  FLAGBOX="$TMP_ROOT/flagbox"; mkdir -p "$FLAGBOX"
  flagged() { # SESSION
    local rc=0
    bash -c 'source "$1"; lane_context_compaction_flagged "$2" "$3"' _ "$LIB" "$FLAGBOX" "$1" 2>/dev/null || rc=$?
    printf 'rc=%s' "$rc"
  }
  assert_eq "$(flagged s1)" "rc=1" "no flag standing flags no session"
  bash -c 'source "$1"; lane_context_compaction_flag "$2" copilot auto s1 "7000 %9"' _ "$LIB" "$FLAGBOX"
  assert_eq "$(jq -c 'del(.at)' "$FLAGBOX/compaction.json")" \
    '{"harness":"copilot","trigger":"auto","session_id":"s1","pane_key":"7000 %9"}' \
    "the flag names the trigger, and the session and pane it belongs to"
  assert_eq "$(flagged s1)" "rc=0" "its own session is flagged"
  assert_eq "$(flagged s2)" "rc=1" "another session is not, so a successor is never held on its predecessor's compaction"
  printf 'not json\n' > "$FLAGBOX/compaction.json"
  assert_eq "$(flagged s1)" "rc=2" "a flag that is no JSON object is unreadable, neither flagged nor clear"
fi

if section scope; then
  echo "=== the Copilot hook scope a session loads ==="
  SCOPES="$TMP_ROOT/scopes"
  scope() { # ROOT HOME
    local out rc=0
    out="$(bash -c 'source "$1"; lane_context_copilot_hooks "$2" "$3"' _ "$LIB" "$1" "$2")" || rc=$?
    printf 'rc=%s %s' "$rc" "${out#"$SCOPES"/}"
  }
  # render_hooks DIR NAME... — each NAME rendered as Copilot loads a hook, its
  # script beside its registry document; a name spelled NAME.sh renders the
  # script alone.
  render_hooks() { # DIR NAME...
    local dir="$1" name
    shift
    mkdir -p "$dir"
    for name in "$@"; do
      case "$name" in
        *.sh) : > "$dir/$name" ;;
        *) : > "$dir/$name.sh"; : > "$dir/$name.json" ;;
      esac
    done
  }
  render_hooks "$SCOPES/repo/.github/hooks" lane-mail-check lane-mail-compact lane-mail-start
  render_hooks "$SCOPES/home/hooks" lane-mail-check lane-mail-compact lane-mail-start
  render_hooks "$SCOPES/half/.github/hooks" lane-mail-check
  render_hooks "$SCOPES/nostart/.github/hooks" lane-mail-check lane-mail-compact
  render_hooks "$SCOPES/bare/.github/hooks" lane-mail-check lane-mail-compact.sh lane-mail-start
  # `root|home|want`, `-` naming none.
  while IFS='|' read -r root home want; do
    [ "$root" != - ] || root=""
    [ "$home" != - ] || home=""
    assert_eq "$(scope "${root:+$SCOPES/$root}" "${home:+$SCOPES/$home}")" "$want" "scope ${root:-none} under ${home:-none}: $want"
  done <<'ROWS'
repo|home|rc=0 repo/.github/hooks
half|home|rc=0 home/hooks
bare|home|rc=0 home/hooks
half|-|rc=1 
nostart|home|rc=0 home/hooks
nostart|-|rc=1 
bare|-|rc=1 
-|home|rc=0 home/hooks
-|-|rc=1 
ROWS
fi

if section owned; then
  echo "=== the ownership gate binds a reading to its own session's file ==="
  # lane_context_transcript_owned holds a transcript to the session id and launch
  # home the current-session record names, so a reader takes a reading only off
  # the file that session wrote: a newer unrelated transcript, a predecessor's in
  # the same pane, or one under an account the fleet never picked is refused.
  owned() { # HARNESS PATH SESSION HOME
    bash -c 'source "$1"
      if lane_context_transcript_owned "$2" "$3" "$4" "$5"; then echo "0 owned"
      else echo "$? $LANE_CONTEXT_OWNED_REASON"; fi' _ "$LIB" "$1" "$2" "$3" "$4"
  }
  OWN="$TMP_ROOT/own"
  CHOME="$OWN/claude-home"; mkdir -p "$CHOME/projects/repo"
  XHOME="$OWN/other-home"; mkdir -p "$XHOME/projects/repo"
  KHOME="$OWN/codex-home"; mkdir -p "$KHOME/sessions/2026/09/27"
  YHOME="$OWN/other-codex-home"; mkdir -p "$YHOME/sessions/2026/09/27"
  CLAUDE_OWNED="$CHOME/projects/repo/s1.jsonl"
  CLAUDE_S2="$CHOME/projects/repo/s2.jsonl"
  CLAUDE_FOREIGN="$XHOME/projects/repo/s1.jsonl"
  CLAUDE_SUBAGENT="$CHOME/projects/repo/s1/subagents/agent-x.jsonl"
  CODEX_OWNED="$KHOME/sessions/2026/09/27/rollout-2026-09-27T00-00-00-s1.jsonl"
  CODEX_S2="$KHOME/sessions/2026/09/27/rollout-2026-09-27T00-00-00-s2.jsonl"
  mkdir -p "$(dirname "$CLAUDE_SUBAGENT")"
  : > "$CLAUDE_OWNED"; : > "$CLAUDE_S2"; : > "$CLAUDE_FOREIGN"; : > "$CLAUDE_SUBAGENT"
  : > "$CODEX_OWNED"; : > "$CODEX_S2"
  # `harness|path|session|home|want`
  while IFS='|' read -r harness path session home want; do
    assert_eq "$(owned "$harness" "$path" "$session" "$home")" "$want" \
      "$harness $(basename -- "${path:-none}") for ${session:-none} under $(basename -- "${home:-none}"): $want"
  done <<ROWS
claude|$CLAUDE_OWNED|s1|$CHOME|0 owned
claude|$CLAUDE_S2|s1|$CHOME|1 session-mismatch
claude|$CLAUDE_SUBAGENT|s1|$CHOME|1 session-mismatch
claude|$CLAUDE_FOREIGN|s1|$CHOME|1 home-mismatch
claude||s1|$CHOME|1 binding-missing
claude|$CLAUDE_OWNED||$CHOME|1 binding-missing
claude|$CLAUDE_OWNED|s1||1 home-unnamed
codex|$CODEX_OWNED|s1|$KHOME|0 owned
codex|$CODEX_S2|s1|$KHOME|1 session-mismatch
codex|$CODEX_OWNED|s1|$YHOME|1 home-mismatch
opencode|$CLAUDE_OWNED|s1|$CHOME|3 harness-unlisted
opencode|$CLAUDE_OWNED||$CHOME|3 harness-unlisted
ROWS
fi

if section agent-reserve; then
  while IFS='|' read -r tokens window pct reserve want; do
    assert_eq "$(due "$LIB" "$tokens" "$window" "$pct" "$reserve")" "$want" \
      "agent reserve: $tokens of ${window:-unknown} at $pct with $reserve: $want"
  done <<'ROWS'
249999|1000000|90|150000|rc=0 room
250000|1000000|90|150000|rc=0 due
250001|1000000|90|150000|rc=0 due
67964|131072|90|50000|rc=0 room
67965|131072|90|50000|rc=0 due
49999|200000|50|50000|rc=0 room
50000|200000|50|50000|rc=0 due
90000|200000|90|0|rc=0 room
180000|200000|90|0|rc=0 due
0|200000|50|150000|rc=0 due
1||90|150000|rc=1
250000||90|150000|rc=0 due
0||90|999999999999999999999|rc=0 due
1|200000|90|-1|rc=2
1|200000|90|015|rc=2
1|200000|90|abc|rc=2
ROWS
fi

PANEL_BOX="$TMP_ROOT/panel-box"
PANEL_HOME="$TMP_ROOT/panel-home"
mkdir -p "$PANEL_BOX" "$PANEL_HOME"

if section pre-panel; then
  # review-pr consumes this command's room/due stdout. Start with no recorded
  # context, as lane-marker does for a new session, then refresh mid-turn from
  # the native transcript. Copilot has no status-line file in this home.
  panel_run() { # LIB_ARGUMENT...
    env -i PATH="$PATH" HOME="$PANEL_HOME" COPILOT_HOME="$PANEL_HOME/copilot" \
      DISABLE_AUTO_COMPACT=1 ORCH_HANDOFF_CONTEXT_PCT=90 ORCH_HANDOFF_AGENT_RESERVE_TOKENS=150000 \
      "$BASH" "$LIB" "$@" 2>"$T/panel.err"
  }
  panel_read() { # HARNESS TRANSCRIPT [OPERATION]
    local out rc=0
    out=$(panel_run --reading ${3:+"$3"} "$1" s1 "$2" "$PANEL_BOX" "$T") || rc=$?
    printf '%s\n' "$out" > "$T/panel-reading.json"
    if [ "$rc" -eq 0 ]; then out=$(jq -r '.verdict' "$T/panel-reading.json"); fi
    printf 'rc=%s verdict=%s' "$rc" "$out"
  }
  for row in '249999|room' '250000|due' '250001|due'; do
    IFS='|' read -r tokens want <<<"$row"
    claude_line claude-opus-5-5 "$tokens" > "$T/panel-transcript"
    assert_eq "$(panel_read claude "$T/panel-transcript" --attached-launch)" "rc=0 verdict=$want" \
      "pre-panel fresh transcript $tokens: $want" "$T/panel.err"
    assert_eq "$(jq -r '.tokens' "$PANEL_BOX/context.json" 2>/dev/null || echo absent)" "$tokens" \
      "pre-panel records the current $tokens reading without a prior record"
    assert_eq "$(jq -c '[.decision.tokens,.decision.cap,.decision.mark_pct,.decision.cap_mark,.decision.window_mark,.decision.reserve_applied,.decision.reserve_tokens,.source.harness,.source.session_id]' "$T/panel-reading.json")" \
      "[$tokens,400000,90,250000,750000,true,150000,\"claude\",\"s1\"]" \
      "attached launch decision fields at $tokens"
  done
  # A lane holding the earlier review-pr text sends the unflagged five- or
  # six-argument form before its attached panel, which keeps the reserve.
  claude_line claude-opus-5-5 300000 > "$T/panel-transcript"
  for form in five six; do
    legacy=(claude s1 "$T/panel-transcript" "$PANEL_BOX" "$T")
    [ "$form" = five ] || legacy+=("")
    rc=0
    out=$(panel_run "${legacy[@]}") || rc=$?
    assert_eq "rc=$rc verdict=$out" "rc=0 verdict=due" \
      "unflagged $form-argument pre-panel 300000 of 1000000: due" "$T/panel.err"
  done
  # The same native command guards panels, dev-fix and diagnosis launches;
  # an ordinary checkpoint asks for the plain mark.
  for row in '274811|room' '276194|room' '399999|room' '400000|due'; do
    IFS='|' read -r tokens want <<<"$row"
    claude_line claude-opus-5-5 "$tokens" > "$T/panel-transcript"
    assert_eq "$(panel_read claude "$T/panel-transcript" --checkpoint)" "rc=0 verdict=$want" \
      "ordinary checkpoint $tokens: $want" "$T/panel.err"
    assert_eq "$(jq -c '[.decision.tokens,.decision.cap_mark,.decision.reserve_applied,.decision.reserve_tokens]' "$T/panel-reading.json")" \
      "[$tokens,400000,false,0]" "ordinary checkpoint decision fields at $tokens"
  done
  "$BASH" -c 'source "$1"; lane_context_record "$2" copilot 100000 800000 "" s1 "" "" "$LANE_CONTEXT_COPILOT_CAPACITY_SOURCE"' _ "$LIB" "$PANEL_BOX"
  assert_eq "$(panel_read copilot '')" 'rc=0 verdict=room' \
    'pre-panel accepts a Copilot extension reading without a status-line record' "$T/panel.err"
  if [[ -z "${LIB_UNDER_TEST:-}" ]]; then
    mkdir -p "$PANEL_HOME/.cache/lane-mail/copilot-usage"
    touch "$PANEL_HOME/.cache/lane-mail/copilot-usage/s1"
    assert_eq "$(panel_read copilot '')" 'rc=2 verdict=' \
      'pre-panel refuses a pending Copilot reading instead of accepting its older record' "$T/panel.err"
    rm -- "$PANEL_HOME/.cache/lane-mail/copilot-usage/s1"
  fi
fi

if section codex-alternate; then
  # review-pr consumes verdict. These native rollouts reproduce the measured
  # Luna/Sol inputs; the ordinary judge still owns both plain boundaries.
  while IFS='|' read -r name model tokens window operation evidence reserve want; do
    transcript="$T/codex-panel"
    { codex_context "$model"; codex_count "$tokens" "$window"; } > "$transcript"
    overrides="$ORCH_COMPACTION_OVERRIDES"
    case "$evidence" in
      known) ;;
      absent) overrides='' ;;
      invalid) overrides=not-json ;;
      unread) cp "$T/codex-unread" "$transcript" ;;
      empty) cp "$T/codex-none" "$transcript" ;;
      missing) transcript="$T/absent-panel" ;;
      *) echo "lane_context_adapters: evidence=$evidence" >&2; exit 1 ;;
    esac
    args=(--reading)
    case "$operation" in
      legacy-five | legacy-six) ;;
      *) args+=("--$operation") ;;
    esac
    args+=(codex s1 "$transcript" "$PANEL_BOX" "$T")
    [[ "$operation" != legacy-six ]] || args+=("")
    rc=0
    out=$(env -i PATH="$PATH" HOME="$PANEL_HOME" CODEX_HOME="$PANEL_HOME/codex" \
      ORCH_COMPACTION_OVERRIDES="$overrides" ORCH_HANDOFF_CONTEXT_PCT=90 ORCH_HANDOFF_AGENT_RESERVE_TOKENS="$reserve" \
      "$BASH" "$LIB" "${args[@]}" 2>"$T/panel.err") || rc=$?
    verdict=''
    [[ "$rc" != 0 ]] || verdict=$(jq -r '.verdict' <<<"$out")
    assert_eq "$rc:$verdict" "$want" "Codex admission $name" "$T/panel.err"
    if [[ "$rc" == 0 && "$evidence" == known && "$window" != null ]]; then
      assert_eq "$(jq -c '[.decision.tokens,.source.harness,.source.session_id,.source.transcript]' <<<"$out")" \
        "[$tokens,\"codex\",\"s1\",\"$transcript\"]" "Codex admission binding $name"
      if [[ "$operation" == attached-launch && "$verdict" == alternate-review ]]; then
        assert_eq "$(jq -c '[.decision.reserve_applied,.decision.reserve_tokens]' <<<"$out")" \
          "[true,$reserve]" "Codex admission retains reserve decision $name"
      fi
    fi
  done <<'ROWS'
luna-fresh|gpt-6-luna|84140|258400|attached-launch|known|150000|0:alternate-review
luna-reserve-room|gpt-6-luna|82559|258400|attached-launch|known|150000|0:room
luna-reserve-equal|gpt-6-luna|82560|258400|attached-launch|known|150000|0:alternate-review
luna-plain-equal|gpt-6-luna|232560|258400|attached-launch|known|150000|0:alternate-review
luna-plain-due|gpt-6-luna|232561|258400|attached-launch|known|150000|0:due
sol-reserve-room|gpt-6.1-sol|249999|475000|attached-launch|known|150000|0:room
sol-reserve-equal|gpt-6.1-sol|250000|475000|attached-launch|known|150000|0:alternate-review
sol-measured|gpt-6.1-sol|269524|475000|attached-launch|known|150000|0:alternate-review
sol-successor|gpt-6.1-sol|283010|475000|attached-launch|known|150000|0:alternate-review
sol-plain-reading|gpt-6.1-sol|319607|475000|attached-launch|known|150000|0:alternate-review
sol-before-cap|gpt-6.1-sol|399999|475000|attached-launch|known|150000|0:alternate-review
sol-at-cap|gpt-6.1-sol|400000|475000|attached-launch|known|150000|0:due
luna-legacy-five|gpt-6-luna|84140|258400|legacy-five|known|150000|0:due
luna-legacy-six|gpt-6-luna|84140|258400|legacy-six|known|150000|0:due
luna-checkpoint|gpt-6-luna|84140|258400|checkpoint|known|150000|0:room
luna-checkpoint-equal|gpt-6-luna|232560|258400|checkpoint|known|150000|0:room
luna-checkpoint-due|gpt-6-luna|232561|258400|checkpoint|known|150000|0:due
unknown-point|gpt-6-luna|84140|null|attached-launch|known|150000|2:
unverified-point|gpt-6-luna|84140|258400|attached-launch|absent|150000|2:
invalid-point-evidence|gpt-6-luna|84140|258400|attached-launch|invalid|150000|2:
independent-reserve-cap|gpt-6.1-sol|300000|null|attached-launch|known|150000|0:due
independent-invalid-window-cap|gpt-6.1-sol|300000|-1|attached-launch|known|150000|0:due
invalid-window-below-cap|gpt-6-luna|84140|-1|attached-launch|known|150000|2:
independent-plain-cap|gpt-6.1-sol|400000|null|attached-launch|known|150000|0:due
unread-usage|gpt-6-luna|84140|258400|attached-launch|unread|150000|2:
absent-usage|gpt-6-luna|84140|258400|attached-launch|empty|150000|2:
missing-transcript|gpt-6-luna|84140|258400|attached-launch|missing|150000|2:
invalid-reserve|gpt-6-luna|84140|258400|attached-launch|known|-1|2:
zero-reserve|gpt-6-luna|84140|258400|attached-launch|known|0|0:room
ROWS
  "$BASH" -c 'source "$1"; lane_context_compaction_flag "$2" copilot auto s1' _ "$LIB" "$PANEL_BOX"
  out=$(env -i PATH="$PATH" HOME="$PANEL_HOME" COPILOT_HOME="$PANEL_HOME/copilot" \
    "$BASH" "$LIB" --attached-launch --reading copilot s1 '' "$PANEL_BOX" "$T")
  assert_eq "$(jq -c '[.verdict,.decision,.source.compacted]' <<<"$out")" '["due",null,true]' \
    'automatic compaction keeps the parent handoff'
fi

if section pi-panel; then
  # A Pi lane runs the pre-panel command from its Bash tool, where no payload
  # names a window. The window comes from the session's record or Pi's own
  # model registry, never from a number the lane types. The registry is read
  # through the SDK of the `pi` on PATH, so a stub install stands in for Pi: its
  # `bin/pi` links into a package whose ModelRuntime names STUB_PI_WINDOW for
  # anthropic/claude-opus-5-5 alone, and shadows any real Pi on this machine.
  PI_STUB="$TMP_ROOT/pi-stub"
  PI_STUB_PKG="$PI_STUB/lib/node_modules/@earendil-works/pi-coding-agent"
  mkdir -p "$PI_STUB/bin" "$PI_STUB_PKG/dist/bundle"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":{".":{"import":"./dist/index.js"}}}' \
    > "$PI_STUB_PKG/package.json"
  printf '%s\n' '#!/usr/bin/env node' > "$PI_STUB_PKG/dist/bundle/cli.js"
  chmod +x "$PI_STUB_PKG/dist/bundle/cli.js"
  cat > "$PI_STUB_PKG/dist/index.js" <<'STUB'
export const ModelRuntime = {
  async create() {
    return {
      getModel(provider, id) {
        const window = Number(process.env.STUB_PI_WINDOW);
        return provider === "anthropic" && id === "claude-opus-5-5" && window > 0 ? { contextWindow: window } : undefined;
      },
    };
  },
};
STUB
  ln -s ../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js "$PI_STUB/bin/pi"
  PI_PANEL_AGENT="$TMP_ROOT/pi-panel-agent"
  PI_PANEL_BOX="$TMP_ROOT/pi-panel-box"
  mkdir -p "$PI_PANEL_AGENT" "$PI_PANEL_BOX"
  pi_line claude-opus-5-5 146108 anthropic > "$T/pi-panel"
  pi_panel_read() { # STUB_WINDOW [WINDOW_ARGUMENT]
    local out rc=0
    out=$(env -i PATH="$PI_STUB/bin:$PATH" HOME="$PANEL_HOME" PI_CODING_AGENT_DIR="$PI_PANEL_AGENT" \
      STUB_PI_WINDOW="$1" ORCH_HANDOFF_CONTEXT_PCT=90 ORCH_HANDOFF_AGENT_RESERVE_TOKENS=150000 \
      "$BASH" "$LIB" --attached-launch pi s1 "$T/pi-panel" "$PI_PANEL_BOX" "$PI_READ_PROJECT" "${@:2}" 2>"$T/panel.err") || rc=$?
    printf 'rc=%s verdict=%s' "$rc" "$out"
  }
  # `row|compaction enabled|registry window|record session and model|window
  # argument, `none` for the five-argument form|answer|keyed stderr line`. At
  # 146108 tokens and the 150000 reserve, 272000 is due and 1000000 is room.
  while IFS='|' read -r row compaction stub record argument want key; do
    printf '{"compaction":{"enabled":%s}}\n' "$compaction" > "$PI_PANEL_AGENT/settings.json"
    rm -f -- "$PI_PANEL_BOX/context.json"
    if [[ -n "$record" ]]; then
      read -r record_session record_model <<<"$record"
      "$BASH" -c 'source "$1"; lane_context_record "$2" pi 100000 1000000 "$3" "$4"' _ \
        "$LIB" "$PI_PANEL_BOX" "$record_model" "$record_session"
    fi
    if [[ "$argument" == none ]]; then got=$(pi_panel_read "$stub"); else got=$(pi_panel_read "$stub" "$argument"); fi
    assert_eq "$got" "$want" "pi pre-panel $row: $want" "$T/panel.err"
    if [[ -n "$key" ]]; then
      assert_eq "$(grep -cxF -- "$key" "$T/panel.err" || true)" 1 "pi pre-panel $row reports $key"
    fi
    if [[ "$argument" == none ]]; then
      assert_eq "$(grep -c '^lane-context: window-argument=' "$T/panel.err" || true)" 0 "pi pre-panel $row warns of no window argument"
    fi
  done <<'ROWS'
registry|false|1000000|||rc=0 verdict=room|lane-context: window-argument=
typed-window|false|1000000||272000|rc=0 verdict=room|lane-context: window-argument=272000
five-arguments|false|1000000||none|rc=0 verdict=room|
no-source|false||||rc=2 verdict=|lane-context: context-unmeasured=window-unavailable
record|false||s1 anthropic/claude-opus-5-5||rc=0 verdict=room|
record-other-session|false||s2 anthropic/claude-opus-5-5||rc=2 verdict=|lane-context: context-unmeasured=window-unavailable
record-other-model|false||s1 anthropic/claude-opus-4-8||rc=2 verdict=|lane-context: context-unmeasured=window-unavailable
compaction-on|true|1000000|||rc=2 verdict=|lane-context: context-unmeasured=window-unavailable
ROWS
  printf '%s\n' '{"compaction":{"enabled":false}}' > "$PI_PANEL_AGENT/settings.json"
  pi_panel_read 1000000 "" >/dev/null
  assert_eq "$(jq -c '[.session_id, .model, .window]' "$PI_PANEL_BOX/context.json" 2>/dev/null || echo absent)" \
    '["s1","anthropic/claude-opus-5-5",1000000]' 'pi pre-panel records the window the registry named'
fi
if [[ -z "${LIB_UNDER_TEST:-}" ]]; then
  echo "=== must-fail controls ==="
  SECTION_NOW=controls
  TABLE_SITES="$TMP_ROOT/table-sites"
  cp -- "$SITES" "$TABLE_SITES"
  # control_table PATTERN SITES — the one table whose assertions begin with
  # PATTERN, as a control's FAIL line does. A pattern no table, or two tables,
  # begin with names no table: a duplicate elsewhere never lets the wrong
  # table satisfy a control.
  control_table() { # PATTERN SITES
    local tables
    tables="$(PATTERN="$1" awk -F'\t' 'index($2, ENVIRON["PATTERN"]) == 1 && !seen[$1]++ { print $1 }' "$2")"
    [[ -n "$tables" && "$tables" != *$'\n'* ]] || return 1
    printf '%s\n' "$tables"
  }
  printf 'one\tshared name\ntwo\tshared name too\nthree\tunique name\nthree\tunique name again\n' > "$TMP_ROOT/dup-sites"
  assert_eq "$(control_table 'unique name' "$TMP_ROOT/dup-sites")" three "a pattern one table holds names that table"
  assert_eq "$(control_table 'shared name' "$TMP_ROOT/dup-sites" || echo none)" none "a pattern two tables hold names no table"
  assert_eq "$(control_table 'absent name' "$TMP_ROOT/dup-sites" || echo none)" none "a pattern no table holds names no table"
  # control NAME FILE OLD NEW PATTERN — a copy of the library whose FILE has OLD
  # replaced by NEW, run through the one table PATTERN is a FAIL line of; the
  # table must print PATTERN once.
  control() { # NAME FILE OLD NEW PATTERN
    local copy="$TMP_ROOT/control-$1/lib" out table
    table="$(control_table "$5" "$TABLE_SITES" || true)"
    assert_eq "${table:+one}" one "control $1: $5 begins the assertions of one table"
    [[ -n "$table" ]] || return 0
    mkdir -p "$copy"
    cp -R "$SCRIPTS_DIR/lib/." "$copy/"
    cp "$SCRIPTS_DIR/orch-env" "$copy/../orch-env"
    assert_eq "$(grep -c -F -e "$3" "$copy/$2" || true)" "1" "control $1 finds exactly one site to mutate"
    perl -i -pe 'BEGIN { ($o, $n) = (shift, shift) } s/\Q$o\E/$n/g' -- "$3" "$4" "$copy/$2"
    out="$(LANE_CONTEXT_SUITE_ONLY="$table" LIB_UNDER_TEST="$copy/lane-context.sh" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -cF -- "FAIL  $5" <<<"$out" || true)" "1" "control $1: $5 goes red"
  }
  control copilot-share lane-context.sh 'LANE_CONTEXT_COPILOT_COMPACTION_PCT=80' 'LANE_CONTEXT_COPILOT_COMPACTION_PCT=100' \
    'copilot {"session_id":"s1","cwd":"/w","current_tokens":150000'
  control native-alias adapters/claude.sh '[[ "${2:-}" != launch ]] || model=${1:-}' 'model=${ANTHROPIC_DEFAULT_SONNET_MODEL:-$model}' \
    'launch identity sonnet pin=claude-sonnet-4-6'
  control version-identity adapters/claude.sh '  printf '\''%s\n'\'' "${model}"' '  printf '\''%s\n'\'' "${model%-20261001}"' \
    'resolved identity claude-opus-4-8-20261001 pin='
  control unresolved-model adapters/claude.sh '      *) model="" ;;' '      *) : ;;' \
    'resolved identity best pin='
  control version-spelling adapters/claude.sh 'model="claude-$model"' ':' \
    'resolved identity fable-5-1 pin='
  control capacity-spelling adapters/claude.sh 'case "${2:-}" in launch | resolved | recorded) model=${model%\[1m\]} ;; esac' ':' \
    'resolved identity claude-fable-5-1[1m] pin='
  control recorded-alias adapters/claude.sh 'if [[ "${2:-}" != resolved ]]; then' 'if false; then' \
    'recorded identity sonnet pin=claude-sonnet-4-6'
  control copilot-floor lane-context.sh '(.token_limit * $pct / 100 | floor | tostring)' '(.token_limit * $pct / 100 | ceil | tostring)' \
    'copilot {"session_id":"s1","cwd":"/w","current_tokens":0'
  control copilot-zero-limit lane-context.sh ' or .token_limit == 0 then' ' then' \
    'copilot {"current_tokens":150000,"token_limit":0}'
  control flag-any-session lane-context.sh 'else (.session_id // "") == $s end' 'else true end' \
    'another session is not'
  control scope-registry lane-context.sh '[ -f "$dir/$name.sh" ] && [ -f "$dir/$name.json" ]' '[ -f "$dir/$name.sh" ]' \
    'scope bare under none'
  control scope-start lane-context.sh 'LANE_CONTEXT_COPILOT_HOOKS="lane-mail-check lane-mail-compact lane-mail-start"' 'LANE_CONTEXT_COPILOT_HOOKS="lane-mail-check lane-mail-compact"' \
    'scope nostart under none'
  control first-reading adapters/claude.sh '| last // empty' '| first // empty' \
    'claude reads claude-last as'
  control no-synthetic-skip adapters/claude.sh ' and .model != "<synthetic>"' '' \
    'claude reads claude-synthetic as'
  control pi-spelling adapters/pi.sh 'if has("input") or has("output") or has("cacheRead") or has("cacheWrite")' 'if false' \
    'pi reads pi-last as: rc=0 1000|200000|m'
  control claude-output adapters/claude.sh ' + (.output_tokens // 0))' ')' \
    'claude reads claude-last as'
  control pi-provider adapters/pi.sh '"\(.provider)/\(.model)"' '.model' \
    'pi reads pi-provider as: rc=0 1000|200000|pi-claude/claude-opus-5-5'
  control pi-output adapters/pi.sh '(.input // 0) + (.output // 0)' '(.input // 0)' \
    'pi reads pi-last as: rc=0 1000|200000|m'
  control codex-window adapters/codex.sh '\(point($i.model_context_window))' '' \
    'codex reads codex-last as'
  control codex-evidence adapters/codex.sh 'then $window else "" end;' 'then $window else $window end;' \
    'codex configuration  gives point unresolved'
  control claude-family adapters/claude.sh '*sonnet*=200000' '*sonnet*=1000000' \
    'claude sonnet before-point 180001 is due'
  control claude-default adapters/claude.sh 'LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW=200000' 'LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW=1000000' \
    'dry launch claude-lyra-9-9 uses its budget'
  control claude-new-model-launch adapters/claude.sh '  printf '\''%s\n'\'' "$LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW"' '  return 0' \
    'dry launch claude-lyra-9-9 disables compaction'
  control claude-notice adapters/claude.sh 'LANE_ADAPTER_CLAUDE_WINDOW_NOTICED=true' ':' \
    'dry launch claude-lyra-9-9 notice count'
  control claude-evidence adapters/claude.sh '[ "${DISABLE_AUTO_COMPACT:-}" = 1 ]' '[ "${DISABLE_AUTO_COMPACT:-}" = 0 ]' \
    'claude configuration 0 gives point unresolved'
  control strict-mark lane-context.sh 'elif [ "$1" -gt "$window_mark" ]; then' 'elif [ "$1" -ge "$window_mark" ]; then' \
    '232560 of 258400 at 90: rc=0 room'
  control agent-reserve lane-context.sh '    cap_mark=$((400000 - $4))' '    cap_mark=400000' \
    'agent reserve: 250000 of 1000000 at 90 with 150000: rc=0 due'
  control plain-mark-floor lane-context.sh 'window_mark=$(($2 * pct / 100))' 'window_mark=$((($2 * pct + 99) / 100))' \
    '117965 of 131072 at 90: rc=0 due'
  control reserve-mark-ceiling lane-context.sh 'window_mark=$((($2 * pct + 99) / 100 - $4))' 'window_mark=$(($2 * pct / 100 - $4))' \
    'agent reserve: 67964 of 131072 at 90 with 50000: rc=0 room'
  control alternate-review lane-context.sh \
    '    if [ "$HARNESS" = codex ] && [ "$CLI_OPERATION" = attached-launch ] && [ "$VERDICT" = due ]; then' \
    '    if false && [ "$HARNESS" = codex ] && [ "$CLI_OPERATION" = attached-launch ] && [ "$VERDICT" = due ]; then' \
    'Codex admission luna-fresh'
  control panel-refresh lane-context.sh '  context_read_and_record "$BOX" ""' '  TOKENS=0 WINDOW=1000000 COMPACTED=false SOURCE=' \
    'pre-panel fresh transcript 250001: due'
  control launch-only-reserve lane-context.sh '    if [ "$CLI_OPERATION" != checkpoint ]; then' '    if true; then' \
    'ordinary checkpoint 274811: room'
  control unflagged-reserve lane-context.sh '    if [ "$CLI_OPERATION" != checkpoint ]; then' '    if [ "$CLI_OPERATION" = attached-launch ]; then' \
    'unflagged five-argument pre-panel 300000 of 1000000: due'
  control absolute-cap lane-context.sh 'if [ "$1" -ge "$cap_mark" ]; then' 'if [ "$1" -gt "$cap_mark" ]; then' \
    '400000 of no window at 90: rc=0 due'
  control mandatory-pct lane-context.sh '[ "$1" -gt 90 ]' '[ "$1" -gt 100 ]' \
    '180001 of 200000 at 100: rc=0 due'
  control window-read-as-room lane-context.sh "case \"\$window_mark\" in '') return 1 ;;" "case \"\$window_mark\" in '') printf 'room\\n'; return 0 ;;" \
    '5 of no window at 90: rc=1'
  control window-full-copilot lane-context.sh '    copilot) return 1 ;;' '    copilot) ;;' \
    'window full: 800000 of 800000 on copilot: rc=1'
  control window-full-limit lane-context.sh '  [ "$1" -ge "$2" ]' '  [ "$1" -gt "$2" ]' \
    'window full: 1000000 of 1000000 on claude: rc=0'
  control pi-record-session adapters/pi.sh '[ "$LANE_CTX_SESSION" = "$2" ] && ' '' \
    'pi pre-panel record-other-session: rc=2 verdict='
  control project-ignored adapters/pi.sh '[ "$LANE_ADAPTER_PI_ENABLED" = true ] && return 0' ':' \
    'user {"compaction":{"enabled":false}} and project {"compaction":{"enabled":true}}: rc=0'
  control owned-claude-session adapters/claude.sh '*) LANE_ADAPTER_OWNED_REASON=session-mismatch; return 1 ;;' '*) ;;' \
    'claude s2.jsonl for s1 under claude-home: 1 session-mismatch'
  control owned-claude-home adapters/claude.sh '*) LANE_ADAPTER_OWNED_REASON=home-mismatch; return 1 ;;' '*) ;;' \
    'claude s1.jsonl for s1 under claude-home: 1 home-mismatch'
  control owned-codex-session adapters/codex.sh '*) LANE_ADAPTER_OWNED_REASON=session-mismatch; return 1 ;;' '*) ;;' \
    'codex rollout-2026-09-27T00-00-00-s2.jsonl for s1 under codex-home: 1 session-mismatch'
  control owned-codex-home adapters/codex.sh '*) LANE_ADAPTER_OWNED_REASON=home-mismatch; return 1 ;;' '*) ;;' \
    'codex rollout-2026-09-27T00-00-00-s1.jsonl for s1 under other-codex-home: 1 home-mismatch'
  control gap-written lane-context.sh 'gap: ($gap | nul), at: $at}' 'at: $at}' \
    'a gap record names the reason and the session and pane, with no reading'
  control gap-parsed lane-context.sh 'or (.tokens == null and (.gap | type)' 'or (false and (.gap | type)' \
    'a gap record parses with its gap, its session and no tokens'
  control gap-judged lane-context.sh '[ -z "$LANE_CTX_GAP" ] || return 1' ':' \
    "the report's judge refuses a gap record as no reading"
  control owned-binding-missing lane-context.sh 'if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then' 'if false; then' \
    'claude none for s1 under claude-home: 1 binding-missing'
  control owned-home-unnamed lane-context.sh 'if [ -z "${4:-}" ]; then' 'if false; then' \
    'claude s1.jsonl for s1 under none: 1 home-unnamed'
  control owned-harness-unlisted lane-context.sh '*) LANE_CONTEXT_OWNED_REASON=harness-unlisted; return 3 ;;' '*) ;;' \
    'opencode s1.jsonl for s1 under claude-home: 3 harness-unlisted'
  control owned-unlisted-first lane-context.sh '*) LANE_CONTEXT_OWNED_REASON=harness-unlisted; return 3 ;;' \
    '*) [ -n "${3:-}" ] || { LANE_CONTEXT_OWNED_REASON=binding-missing; return 1; }; LANE_CONTEXT_OWNED_REASON=harness-unlisted; return 3 ;;' \
    'opencode s1.jsonl for none under claude-home: 3 harness-unlisted'
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
