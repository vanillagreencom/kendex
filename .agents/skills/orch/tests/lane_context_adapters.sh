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
# it, for the must-fail controls at the end.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LIB="${LIB_UNDER_TEST:-$SCRIPTS_DIR/lib/lane-context.sh}"

TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# A known managed launch for the ordinary transcript rows. Each configuration
# row below replaces its own evidence, independent of the developer machine.
export DISABLE_AUTO_COMPACT=1 DISABLE_COMPACT=0
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
  out="$(bash -c 'set -euo pipefail; source "$1"; lane_context_handoff_due "$2" "$3" "$4"' _ "$@")" || rc=$?
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

echo "=== each adapter reads the last reading its harness recorded ==="
# `file|harness|payload window|answer`
while IFS='|' read -r file harness window want; do
  assert_eq "$(reading "$LIB" "$harness" "$window" < "$T/$file")" "$want" "$harness reads $file as: $want"
done <<'ROWS'
claude-last|claude||rc=0 1000|1000000|claude-opus-5-5
claude-partial|claude||rc=0 1000|1000000|claude-opus-5-5
claude-synthetic|claude||rc=0 700000|1000000|claude-fable-5-1
claude-sonnet|claude||rc=0 400000||claude-sonnet-5
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

# Every harness reaches the common judge through its adapter. The due row is
# strictly before the verified point; Claude reaches the independent cap first.
while IFS='|' read -r harness tokens expected; do
  case "$harness" in
    claude) claude_line claude-opus-5-5 "$tokens" > "$T/before-point" ;;
    codex) { codex_context gpt-6-astra; codex_count "$tokens" 258400; } > "$T/before-point" ;;
    pi) pi_line m "$tokens" > "$T/before-point" ;;
  esac
  answer=$(reading "$LIB" "$harness" 200000 < "$T/before-point")
  point=${answer#*|}; point=${point%%|*}
  assert_eq "$(due "$LIB" "$tokens" "$point" 90)" "rc=0 $expected" "$harness before-point $tokens is $expected"
done <<'ROWS'
claude|399999|room
claude|400000|due
codex|232560|room
codex|232561|due
pi|180000|room
pi|180001|due
ROWS

echo "=== the one judge answers at a share of the reading's own window ==="
# `tokens|window|pct|answer`
while IFS='|' read -r tokens window pct want; do
  assert_eq "$(due "$LIB" "$tokens" "$window" "$pct")" "$want" "$tokens of ${window:-no window} at $pct: $want"
done <<'ROWS'
232560|258400|90|rc=0 room
232561|258400|90|rc=0 due
232559|258400|90|rc=0 room
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

echo "=== the reading a turn end records, and the report's judgement of it ==="
BOX="$TMP_ROOT/box"; mkdir -p "$BOX"
bash -c 'source "$1"; lane_context_record "$2" codex 232560 258400 gpt-6-astra s1 "7000 %9"' _ "$LIB" "$BOX"
assert_eq "$(jq -c 'del(.at)' "$BOX/context.json")" \
  '{"harness":"codex","model":"gpt-6-astra","tokens":232560,"window":258400,"used_pct":90,"session_id":"s1","pane_key":"7000 %9"}' \
  "the record names the reading, the share used, and the session and pane it belongs to"
assert_eq "$(bash -c 'source "$1"; lane_context_record_judged "$(cat "$2")" 90' _ "$LIB" "$BOX/context.json" | jq -c '.handoff_due')" \
  "false" "the report judges a recorded reading by the same judge"
bash -c 'source "$1"; lane_context_record "$2" pi 1000 "" m' _ "$LIB" "$BOX"
assert_eq "$(bash -c 'source "$1"; lane_context_record_judged "$(cat "$2")" 90' _ "$LIB" "$BOX/context.json" | jq -c '[.window, .used_pct, .handoff_due]')" \
  "[null,null,null]" "a reading with no window is recorded unmeasured and judged neither due nor room"
assert_eq "$(ls -A "$BOX")" "context.json" "the record lands by a rename, leaving no staged file beside it"

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

if [[ -z "${LIB_UNDER_TEST:-}" ]]; then
  echo "=== must-fail controls ==="
  # control NAME FILE OLD NEW PATTERN — a copy of the library whose FILE has OLD
  # replaced by NEW, run through this suite; PATTERN is a FAIL line it must print.
  control() { # NAME FILE OLD NEW PATTERN
    local copy="$TMP_ROOT/control-$1" out
    mkdir -p "$copy"
    cp -R "$SCRIPTS_DIR/lib/." "$copy/"
    assert_eq "$(grep -c -F -e "$3" "$copy/$2" || true)" "1" "control $1 finds exactly one site to mutate"
    perl -i -pe 'BEGIN { ($o, $n) = (shift, shift) } s/\Q$o\E/$n/g' -- "$3" "$4" "$copy/$2"
    out="$(LIB_UNDER_TEST="$copy/lane-context.sh" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -cF -- "FAIL  $5" <<<"$out" || true)" "1" "control $1: $5 goes red"
  }
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
  control claude-evidence adapters/claude.sh '[ "${DISABLE_AUTO_COMPACT:-}" = 1 ]' '[ "${DISABLE_AUTO_COMPACT:-}" = 0 ]' \
    'claude configuration 0 gives point unresolved'
  control strict-mark lane-context.sh '-gt $(($2 * pct))' '-ge $(($2 * pct))' \
    '232560 of 258400 at 90: rc=0 room'
  control absolute-cap lane-context.sh '[ "$1" -ge 400000 ]' '[ "$1" -gt 400000 ]' \
    '400000 of no window at 90: rc=0 due'
  control mandatory-pct lane-context.sh '[ "$1" -gt 90 ]' '[ "$1" -gt 100 ]' \
    '180001 of 200000 at 100: rc=0 due'
  control window-read-as-room lane-context.sh "case \"\${2:-}\" in '' | 0) return 1 ;;" "case \"\${2:-}\" in '' | 0) printf 'room\\n'; return 0 ;;" \
    '5 of no window at 90: rc=1'
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
