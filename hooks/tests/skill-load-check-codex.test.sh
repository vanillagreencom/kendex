#!/usr/bin/env bash
# Codex 0.159.3 supplies apply_patch under tool_input.command and persists
# exec_command calls and their output under response_item.payload. Only the
# header before Output: carries the completed process status. Codex 0.160.0
# functions.exec instead persists custom_tool_call and custom_tool_call_output.
# The fixtures preserve the standalone TLK-33 read and a credentialed failed
# read from gpt-6.1-sol. Script completed appears even when cat exits 1, so
# only the adjacent CommandExecution event proves shell success. The
# output-field capture is a sandbox run whose hooks added context around the
# read and whose agent printed text((await ...).output). The batched capture
# is one wrapper of three printed statements, a skill read, a failed read and
# an echo: each wrote its own CommandExecution event, in statement order and
# with no call_id, before one Script completed output. The truncated capture
# prints a read between two long seq outputs: every event completed with exit
# code 0, and the output Codex handed the model opens with its truncation
# warning and lost the read's text. The unprinted capture is a lone read
# whose script never calls text(): its event completed with exit code 0, and
# Codex recorded the output as a bare Script completed string with nothing
# under Output:, so the model never saw the skill. The fixture projections omit account
# metadata, not status; the truncated one also drops the events' output fields
# and keeps only the head, the cut marker and the tail of the long text.
# The child thread already has its own transcript_path, not Claude's layout.
# HOOK_UNDER_TEST lets the same assertions judge a planted copy of the hook.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/skill-load-check.sh}"
TMP_ROOT="$(mktemp -d)" || { echo "skill-load-check-codex: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "skill-load-check-codex: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "skill-load-check-codex: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.codex/hooks" "$REPO/.agents/skills/commit-guards/scripts/lib"
env -i PATH="$PATH" HOME="$TMP_ROOT" git init -q "$REPO"
cp -- "$HOOK" "$REPO/.codex/hooks/skill-load-check.sh"
cp "$TEST_DIR/../../skills/commit-guards/scripts/lib/command-position.sh" \
  "$REPO/.agents/skills/commit-guards/scripts/lib/command-position.sh"
JUDGE="$REPO/.codex/hooks/skill-load-check.sh"
TRANSCRIPT="$TMP_ROOT/rollout.jsonl"

run_patch() { # PATCH TRANSCRIPT [AGENT]
  local payload
  payload=$(jq -n -c --arg p "$1" --arg t "$2" --arg c "$REPO" --arg a "${3:-}" \
    '{tool_name:"apply_patch",tool_input:{command:$p},transcript_path:$t,cwd:$c}
      + if $a == "" then {} else {agent_id:$a} end')
  set +e
  (cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT" "$BASH_BIN" "$JUDGE" \
    >/dev/null 2>"$ERR_FILE" <<<"$payload")
  rc=$?
  set -e
}

# The fixture writes only Codex response items. A result can be successful,
# failed, running, absent, or under another call id. The body also spells a
# successful exit header, to prove that only the real header is read.
rollout() { # COMMAND RESULT
  jq -n -c --arg c "$1" '{type:"response_item",payload:{type:"function_call",
    name:"exec_command",arguments:({cmd:$c}|tojson),call_id:"load"}}' >"$TRANSCRIPT"
  local header id=load
  case "$2" in
    ok) header=$'Process exited with code 0\nOutput:\nfile body' ;;
    noisy)
      # Codex exec_command outputs can dwarf the read. Their ids share a
      # prefix here, and their bodies name the skill but are not skill reads.
      jq -n -c 'range(1000) | {type:"response_item",payload:{type:"function_call_output",
        call_id:("load-" + tostring),output:("Process exited with code 0\nOutput:\ndocs-writing " + ("x" * 16384))}}' >>"$TRANSCRIPT"
      header=$'Process exited with code 0\nOutput:\nfile body'
      ;;
    failed) header=$'Process exited with code 1\nOutput:\nProcess exited with code 0\nOutput:\nbody' ;;
    running) header=$'Process running with session ID 123\nOutput:\nfile body' ;;
    other) header=$'Process exited with code 0\nOutput:\nfile body'; id=other ;;
    absent) return 0 ;;
    *) echo "rollout: result=$2" >&2; exit 2 ;;
  esac
  jq -n -c --arg h "$header" --arg id "$id" '{type:"response_item",
    payload:{type:"function_call_output",call_id:$id,output:$h}}' >>"$TRANSCRIPT"
}

PATCH="*** Begin Patch
*** Update File: $REPO/README.md
@@
-old
+new
*** End Patch"

markdown_row() {
  cp -- "$HOOK" "$JUDGE"
  rollout 'cat .agents/skills/docs-writing/SKILL.md' absent
  run_patch "$PATCH" "$TRANSCRIPT"
  assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=skill-load-check: unloaded=docs-writing' \
    'markdown before its skill load'
}
echo "=== skill-load-check: codex ==="
markdown_row
# One row per command or result shape the Codex producer emits. A successful
# command that only names the skill, or hides a failed read, is not a load.
while IFS='|' read -r label cmd result want; do
  [ -n "$label" ] || continue
  rollout "$cmd" "$result"
  run_patch "$PATCH" "$TRANSCRIPT"
  assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
done <<'ROWS'
markdown after a completed cat read|cat .agents/skills/docs-writing/SKILL.md|ok|rc=0 first=-
markdown after a read among unrelated outputs|cat .agents/skills/docs-writing/SKILL.md|noisy|rc=0 first=-
markdown after a completed sed read|sed -n '1,200p' .agents/skills/docs-writing/SKILL.md|ok|rc=0 first=-
quoted skill path|cat "/home/a user/.agents/skills/docs-writing/SKILL.md"|ok|rc=0 first=-
head read|head -n 200 .agents/skills/docs-writing/SKILL.md|ok|rc=0 first=-
tail read|tail -n 200 .agents/skills/docs-writing/SKILL.md|ok|rc=0 first=-
failed read despite exit text in body|cat .agents/skills/docs-writing/SKILL.md|failed|rc=2 first=skill-load-check: unloaded=docs-writing
unfinished process|cat .agents/skills/docs-writing/SKILL.md|running|rc=2 first=skill-load-check: unloaded=docs-writing
another call result|cat .agents/skills/docs-writing/SKILL.md|other|rc=2 first=skill-load-check: unloaded=docs-writing
only a mention|echo .agents/skills/docs-writing/SKILL.md|ok|rc=2 first=skill-load-check: unloaded=docs-writing
another skill|cat .agents/skills/not-docs-writing/SKILL.md|ok|rc=2 first=skill-load-check: unloaded=docs-writing
another file|cat .agents/skills/docs-writing/references/rules.md|ok|rc=2 first=skill-load-check: unloaded=docs-writing
masked failure|cat .agents/skills/docs-writing/SKILL.md; true|ok|rc=2 first=skill-load-check: unloaded=docs-writing
ROWS

rollout 'cat .agents/skills/docs-writing/SKILL.md' ok
run_patch "$PATCH" "$TRANSCRIPT" child-thread
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "the child reads its own rollout instead of a Claude subagent path"
CHILD="$TMP_ROOT/child.jsonl"
: >"$CHILD"
run_patch "$PATCH" "$CHILD" child-thread
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=skill-load-check: unloaded=docs-writing" \
  "the child does not inherit the parent rollout load"

delete_row() {
  cp -- "$HOOK" "$JUDGE"
  rollout 'cat .agents/skills/docs-writing/SKILL.md' ok
  run_patch "*** Delete File: $REPO/old.sh" "$TRANSCRIPT"
  assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=skill-load-check: unloaded=code-quality' delete
}
delete_row

# Every patch file line is judged, including a moved destination. The first
# target is cleared by docs-writing; a later source target is not.
while IFS='|' read -r label lines want; do
  [ -n "$label" ] || continue
  lines=${lines//@REPO@/$REPO}
  patch=$(printf '*** Begin Patch\n%b\n*** End Patch\n' "$lines")
  run_patch "$patch" "$TRANSCRIPT"
  assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
done <<'ROWS'
update then add|*** Update File: @REPO@/README.md\n*** Add File: @REPO@/new.sh|rc=2 first=skill-load-check: unloaded=code-quality
move destination|*** Update File: @REPO@/README.md\n*** Move to: @REPO@/new.sh|rc=2 first=skill-load-check: unloaded=code-quality
relative markdown target|*** Update File: README.md|rc=0 first=-
relative source target|*** Add File: new.sh|rc=2 first=skill-load-check: unloaded=code-quality
no file line|*** Begin Patch|rc=2 first=skill-load-check: payload=no-file-path
ROWS
rollout 'cat .agents/skills/code-quality/SKILL.md' ok
run_patch "*** Add File: $REPO/new.sh" "$TRANSCRIPT"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" "a source patch passes after code-quality loads"

echo "Codex Bash commands use the same required skills"
mkdir -p "$REPO/relocated/hooks"
cp -- "$HOOK" "$REPO/relocated/hooks/skill-load-check.sh"
linear_shell_row() { # INSTALL RESULT WANT
  local install="$1" result="$2" want="$3"
  cp -- "$HOOK" "$REPO/$install/hooks/skill-load-check.sh"
  rollout 'cat .agents/skills/linear/SKILL.md' "$result"
  payload=$(jq -n -c --arg t "$TRANSCRIPT" '{tool_name:"Bash",
    tool_input:{command:".agents/skills/linear/scripts/linear.sh cache issues get KEN-2337"},transcript_path:$t}')
  set +e
  env -i PATH="$PATH" HOME="$TMP_ROOT" CODEX_HOME="$REPO/$install" \
    "$BASH_BIN" "$REPO/$install/hooks/skill-load-check.sh" \
    >"$OUT_FILE" 2>"$ERR_FILE" <<<"$payload"
  rc=$?
  set -e
  assert_eq "rc=$rc first=$(first_line) stdout=$(cat -- "$OUT_FILE")" "$want stdout=" \
    "linear shell load $install $result"
}
linear_row() {
  linear_shell_row relocated absent 'rc=2 first=skill-load-check: unloaded=linear'
}
linear_row
while IFS='|' read -r install result want; do
  linear_shell_row "$install" "$result" "$want"
done <<'ROWS'
.codex|absent|rc=2 first=skill-load-check: unloaded=linear
.codex|ok|rc=0 first=-
relocated|ok|rc=0 first=-
ROWS

# The measured functions.exec wrappers run one literal shell read, or a batch
# of printed statements, and print their output. These rows keep the authentic envelope and output; each defect
# changes a private copy, never the captured fixtures.
functions_exec_row() { # FIXTURE SCENARIO WANT LABEL
  local fixture="$1" scenario="$2" want="$3" label="$4" command skill
  cp -- "$HOOK" "$JUDGE"
  jq -c --arg scenario "$scenario" '
    if $scenario == "failed-status" and .payload.item.type? == "CommandExecution" then
      .payload.item.status = "failed" | .payload.item.exit_code = 1
    elif $scenario == "missing-event" then select(.type != "event_msg")
    elif $scenario == "extra-event" and .type == "event_msg" then ., .
    elif $scenario == "wrong-command" and .type == "event_msg" then
      .payload.item.command[-1] = "cat other/SKILL.md"
    elif $scenario == "other-id" and .payload.type == "custom_tool_call_output" then
      .payload.call_id = "other"
    elif $scenario == "compound-js" and .payload.type == "custom_tool_call" then
      .payload.input += "await tools.exec_command({cmd:\"true\"});"
    elif $scenario == "compound-shell" and .payload.type == "custom_tool_call" then
      .payload.input |= sub("linear/SKILL[.]md\""; "linear/SKILL.md; true\"")
    elif $scenario == "compound-shell" and .payload.item.type? == "CommandExecution" then
      .payload.item.command[-1] = "cat .agents/skills/linear/SKILL.md; true"
    elif $scenario == "failed-wrapper" and .payload.type == "custom_tool_call_output" then
      .payload.output[0].text = "Script failed\nOutput:\n"
    elif $scenario == "misaligned" and .payload.item.command[-1]? == "cat .agents/skills/demo/SKILL.md" then
      .payload.item.command[-1] = "cat .agents/skills/other/SKILL.md"
    elif $scenario == "unprinted" and .payload.type == "custom_tool_call" then
      .payload.input |= sub("text[(][(](?<call>await tools[.]exec_command[(][{]cmd:\"echo done\"[}][)])[)][.]output[)]"; "\(.call)")
    elif $scenario == "in-script" then select(.payload.type != "custom_tool_call_output")
    elif $scenario == "leading-js" and .payload.type == "custom_tool_call" then
      .payload.input |= "text = () => {};\n" + .
    elif $scenario == "interleaved-js" and .payload.type == "custom_tool_call" then
      .payload.input |= sub("\n"; "\ntext = () => {};\n")
    elif $scenario == "printed-suffix" and .payload.type == "custom_tool_call" then
      .payload.input |= if test("[.]output[)]") then sub("[.]output[)]"; ".output.slice(0, 0))")
        else sub("[}][)][)]"; "}).slice(0, 0))") end
    else . end' "$TEST_DIR/fixtures/$fixture.jsonl" >"$TRANSCRIPT"
  case "$fixture:$scenario" in
    *-failed:*) skill=missing-KEN-2484; command=skill-capture-command ;;
    *-batched:failed-read) skill=missing; command=skill-capture-command ;;
    *-batched:* | *-truncated:* | *-unprinted:*) skill=demo; command=skill-capture-command ;;
    *) skill=linear; command=.agents/skills/linear/scripts/linear.sh ;;
  esac
  payload=$(jq -n -c --arg t "$TRANSCRIPT" --arg c "$command" \
    '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t}')
  set +e
  env -i PATH="$PATH" HOME="$TMP_ROOT" KENDEX_SKILL_LOAD_RULES="bash:^skill-capture-command$=$skill" \
    "$BASH_BIN" "$JUDGE" >"$OUT_FILE" 2>"$ERR_FILE" <<<"$payload"
  rc=$?
  set -e
  # Every Codex unloaded refusal names the read that always passes.
  case "$want" in
    rc=2*) remedy=standalone-read ;;
    *) remedy="" ;;
  esac
  assert_eq "rc=$rc first=$(first_line) remedy=$(sed -n 's/^remedy=//p' "$ERR_FILE") stdout=$(cat -- "$OUT_FILE")" \
    "$want remedy=$remedy stdout=" "$label"
  if [ "$fixture" = skill-load-check-codex-0.160.0-live ] && [ "$scenario" = failed-status ]; then
    assert_eq "$(sed -n 's/^step=//p' "$ERR_FILE")" join 'captured failed read names join'
  fi
}
exec_rows() { # optional row key for a planted-copy control
  local key fixture scenario want label
  while IFS='|' read -r key fixture scenario want label; do
    [ -z "${1:-}" ] || [ "$key" = "$1" ] || continue
    functions_exec_row "$fixture" "$scenario" "$want" "$label"
  done <<'ROWS'
success|skill-load-check-codex-0.160.0|original|rc=0 first=-|functions.exec successful skill read
captured-success|skill-load-check-codex-0.160.0-live|original|rc=0 first=-|functions.exec captured direct text read
captured-failed|skill-load-check-codex-0.160.0-live|failed-status|rc=2 first=skill-load-check: unloaded=linear|functions.exec captured failed read
captured-printed-suffix|skill-load-check-codex-0.160.0-live|printed-suffix|rc=2 first=skill-load-check: unloaded=linear|functions.exec captured printed suffix
failed|skill-load-check-codex-0.160.0-failed|original|rc=2 first=skill-load-check: unloaded=missing-KEN-2484|functions.exec authentic failed read
compound-js|skill-load-check-codex-0.160.0|compound-js|rc=2 first=skill-load-check: unloaded=linear|functions.exec compound JavaScript
compound-shell|skill-load-check-codex-0.160.0|compound-shell|rc=2 first=skill-load-check: unloaded=linear|functions.exec compound shell
printed-suffix|skill-load-check-codex-0.160.0|printed-suffix|rc=2 first=skill-load-check: unloaded=linear|functions.exec printed output suffix
failed-wrapper|skill-load-check-codex-0.160.0|failed-wrapper|rc=2 first=skill-load-check: unloaded=linear|functions.exec failed wrapper
other-id|skill-load-check-codex-0.160.0|other-id|rc=2 first=skill-load-check: unloaded=linear|functions.exec another call output
failed-status|skill-load-check-codex-0.160.0|failed-status|rc=2 first=skill-load-check: unloaded=linear|functions.exec failed shell with successful skill body
missing-event|skill-load-check-codex-0.160.0|missing-event|rc=2 first=skill-load-check: unloaded=linear|functions.exec without shell completion
extra-event|skill-load-check-codex-0.160.0|extra-event|rc=2 first=skill-load-check: unloaded=linear|functions.exec ambiguous shell completion
wrong-command|skill-load-check-codex-0.160.0|wrong-command|rc=2 first=skill-load-check: unloaded=linear|functions.exec another command completion
field-success|skill-load-check-codex-0.160.0-output-field|original|rc=0 first=-|functions.exec output field read
field-failed|skill-load-check-codex-0.160.0-output-field|failed-status|rc=2 first=skill-load-check: unloaded=linear|functions.exec output field failed read
field-compound-js|skill-load-check-codex-0.160.0-output-field|compound-js|rc=2 first=skill-load-check: unloaded=linear|functions.exec output field compound JavaScript
field-compound-shell|skill-load-check-codex-0.160.0-output-field|compound-shell|rc=2 first=skill-load-check: unloaded=linear|functions.exec output field compound shell
field-printed-suffix|skill-load-check-codex-0.160.0-output-field|printed-suffix|rc=2 first=skill-load-check: unloaded=linear|functions.exec output field printed suffix
batched|skill-load-check-codex-0.160.0-batched|original|rc=0 first=-|functions.exec batched skill read
batched-failed|skill-load-check-codex-0.160.0-batched|failed-read|rc=2 first=skill-load-check: unloaded=missing|functions.exec batched failed read
batched-misaligned|skill-load-check-codex-0.160.0-batched|misaligned|rc=2 first=skill-load-check: unloaded=demo|functions.exec batched events out of step
batched-unprinted|skill-load-check-codex-0.160.0-batched|unprinted|rc=2 first=skill-load-check: unloaded=demo|functions.exec batched unprinted statement
batched-in-script|skill-load-check-codex-0.160.0-batched|in-script|rc=2 first=skill-load-check: unloaded=demo|functions.exec batched read before its output
batched-leading-js|skill-load-check-codex-0.160.0-batched|leading-js|rc=2 first=skill-load-check: unloaded=demo|functions.exec batched JavaScript before the first statement
batched-interleaved-js|skill-load-check-codex-0.160.0-batched|interleaved-js|rc=2 first=skill-load-check: unloaded=demo|functions.exec batched JavaScript between statements
unprinted|skill-load-check-codex-0.160.0-unprinted|original|rc=2 first=skill-load-check: unloaded=demo|functions.exec lone unprinted read
truncated|skill-load-check-codex-0.160.0-truncated|original|rc=2 first=skill-load-check: unloaded=demo|functions.exec batched read cut from a truncated output
ROWS
}
# The lone unprinted capture is refused by two rules at once: no statement
# prints the read, and its output is a bare string with no printed text. No
# single defect in those rules turns that row red; it pins that the refusal
# names the read that passes, and exec-remedy is its control.
exec_success_row() { exec_rows success; }
exec_captured_row() { exec_rows captured-success; }
exec_field_row() { exec_rows field-success; }
exec_failed_row() { exec_rows failed; exec_rows field-failed; exec_rows batched-failed; }
exec_batched_row() { exec_rows batched; }
exec_batched_failed_row() { exec_rows batched-failed; }
exec_aligned_row() { exec_rows wrong-command; exec_rows batched-misaligned; }
exec_script_end_row() { exec_rows compound-js; }
exec_output_position_row() { exec_rows extra-event; }
exec_script_start_row() { exec_rows batched-leading-js; }
exec_contiguous_row() { exec_rows batched-interleaved-js; }
exec_truncated_row() { exec_rows truncated; }
exec_remedy_row() { exec_rows batched-failed; exec_rows unprinted; }
exec_compound_row() { exec_rows compound-js; exec_rows field-compound-js; }
exec_shell_row() { exec_rows compound-shell; exec_rows field-compound-shell; }
exec_suffix_row() { exec_rows printed-suffix; exec_rows captured-printed-suffix; exec_rows field-printed-suffix; }
exec_output_row() { exec_rows failed-wrapper; }
exec_id_row() { exec_rows other-id; }
exec_rows

skill_load_control exec-direct-text "$HOOK" '      | .input | strings' \
  '      | select(startswith("const"))' HOOK exec_captured_row 'functions.exec captured direct text read'
skill_load_control exec-recognition "$HOOK" '    def exec_cmds:' \
  '      empty |' HOOK exec_success_row 'functions.exec successful skill read'
skill_load_control exec-output-field "$HOOK" '      | .input | strings' \
  '      | select(startswith("text((") | not)' HOOK exec_field_row 'functions.exec output field read'
skill_load_control exec-completion "$HOOK" '    | select($kind == "function_call"' \
  '      or true' HOOK exec_failed_row 'functions.exec authentic failed read' \
  'functions.exec output field failed read' 'functions.exec batched failed read'
skill_load_control exec-batched "$HOOK" '      | [match($statement; "g")] as $statements' \
  '      | select(($statements | length) == 1)' HOOK exec_batched_row 'functions.exec batched skill read'
skill_load_control exec-own-event "$HOOK" '    | select($kind == "function_call"' \
  '      or any($items[$index + 1:$index + 1 + $count][]; .item.status == "completed" and .item.exit_code == 0)' \
  HOOK exec_batched_failed_row 'functions.exec batched failed read'
skill_load_control exec-alignment "$HOOK" '            else null end] == $cmds)' \
  '        // true' HOOK exec_aligned_row 'functions.exec another command completion' \
  'functions.exec batched events out of step'
skill_load_control exec-script-end "$HOOK" '      | [match($statement; "g")] as $statements' \
  '      | ($statements[-1] | .offset + .length) as $end' HOOK exec_script_end_row \
  'functions.exec compound JavaScript'
skill_load_control exec-script-start "$HOOK" '      | select($statements[0].offset == 0)' \
  '        // true' HOOK exec_script_start_row 'functions.exec batched JavaScript before the first statement'
skill_load_control exec-contiguous "$HOOK" '          $statements[.].offset == $statements[. - 1].offset + $statements[. - 1].length))' \
  '        // true' HOOK exec_contiguous_row 'functions.exec batched JavaScript between statements'
skill_load_control exec-truncated "$HOOK" '        | select($result.output | all(.[]; .text | strings' \
  '          | select(false)' HOOK exec_truncated_row 'functions.exec batched read cut from a truncated output'
skill_load_control exec-output-position "$HOOK" '          | .type == "custom_tool_call_output" and .call_id == $id)' \
  '        // true' HOOK exec_output_position_row 'functions.exec ambiguous shell completion'
skill_load_control exec-remedy "$HOOK" '        codex)' \
  '          return 0' HOOK exec_remedy_row 'functions.exec batched failed read' \
  'functions.exec lone unprinted read'
skill_load_control exec-standalone-js "$HOOK" '      | .input | strings' \
  '      | split("\n")[0]' HOOK exec_compound_row 'functions.exec compound JavaScript' \
  'functions.exec output field compound JavaScript'
skill_load_control exec-standalone-shell "$HOOK" '| ($skill | gsub("[.]"; "\\.")) as $escaped' \
  '    | ($cmd | split(";")[0]) as $cmd' HOOK exec_shell_row 'functions.exec compound shell' \
  'functions.exec output field compound shell'
skill_load_control exec-printed-tail "$HOOK" '      | .input | strings' \
  '      | sub("[.]slice\\(0, 0\\)"; "")' HOOK exec_suffix_row 'functions.exec printed output suffix' \
  'functions.exec captured printed suffix' 'functions.exec output field printed suffix'
skill_load_control exec-output "$HOOK" '| .text | strings' \
  '          | "Script completed\nOutput:\n"' HOOK exec_output_row 'functions.exec failed wrapper'
skill_load_control exec-call-id "$HOOK" '    | (.call_id | strings | select(. != "")) as $id' \
  '    | "other" as $id' HOOK exec_id_row 'functions.exec another call output'

# Codex exec --ephemeral's PreToolUse producer always emits transcript_path,
# null when Session::hook_transcript_path has no live_thread. Missing is not
# that protocol, and a persistent path still has to name a readable file.
ephemeral_row() { # LABEL FIELDS WANT
  local label="$1" fields="$2" want="$3"
  cp -- "$HOOK" "$JUDGE"
  payload=$(jq -n -c --arg p "$PATCH" --arg c "$REPO" --argjson f "$fields" \
    '{tool_name:"apply_patch",tool_input:{command:$p},cwd:$c} + $f')
  set +e
  (cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT" "$BASH_BIN" "$JUDGE" \
    >/dev/null 2>"$ERR_FILE" <<<"$payload")
  rc=$?
  set -e
  assert_eq "rc=$rc first=$(first_line)" "$want" "$label"
}
nonpersistent_row() {
  ephemeral_row 'Codex ephemeral session' '{"transcript_path":null}' \
    'rc=0 first=skill-load-check: gap=nonpersistent-codex'
}
nonpersistent_row
while IFS='|' read -r label fields want; do
  ephemeral_row "$label" "$fields" "$want"
done <<'ROWS'
Codex missing transcript field|{}|rc=2 first=skill-load-check: payload=no-transcript
Codex malformed transcript|{"transcript_path":[]}|rc=2 first=skill-load-check: payload=no-transcript
Codex empty transcript|{"transcript_path":""}|rc=2 first=skill-load-check: payload=no-transcript
Codex unreadable persistent transcript|{"transcript_path":"/no-such-rollout.jsonl"}|rc=2 first=skill-load-check: transcript=unreadable
Codex malformed ephemeral agent|{"transcript_path":null,"agent_id":[]}|rc=2 first=skill-load-check: payload=invalid-agent-id
ROWS

while IFS='|' read -r skill callback row; do
  skill_load_control "$skill" "$HOOK" 'require() { # SKILL' \
    "  [ \"\$1\" != $skill ] || return 0" HOOK "$callback" "$row"
done <<'ROWS'
docs-writing|markdown_row|markdown before its skill load
code-quality|delete_row|delete
linear|linear_row|linear shell load relocated absent
ROWS
skill_load_control nonpersistent "$HOOK" 'notice() { # KEY VALUE [CAUSE]' \
  '  [ "$1" != gap ] || refuse "$@"' HOOK nonpersistent_row 'Codex ephemeral session'


echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]