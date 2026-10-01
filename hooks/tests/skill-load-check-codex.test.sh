#!/usr/bin/env bash
# Codex 0.159.3 supplies apply_patch under tool_input.command and persists
# exec_command calls and their output under response_item.payload. Only the
# header before Output: carries the completed process status. The child
# thread already has its own transcript_path, not Claude's subagents layout.
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