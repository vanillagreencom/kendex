#!/usr/bin/env bash
# Surface: jarvis-memory-note.sh. Inputs: that hook and tests/lib/assert.sh.
set -euo pipefail
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$TEST_DIR/../jarvis-memory-note.sh}"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "jarvis-memory-note: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "jarvis-memory-note: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "jarvis-memory-note: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/lib/assert.sh"
BASH_BIN=$BASH
JQ_BIN=$(command -v jq)
CAT_BIN=$(command -v cat)
ASSISTANT="$TMP_ROOT/assistant home"
SKILL="$ASSISTANT/.agents/skills/jarvis"
mkdir -p "$ASSISTANT/memory" "$ASSISTANT/other" "$SKILL/references" "$TMP_ROOT/plain/memory"
touch "$SKILL/SKILL.md" "$SKILL/references/memory.md"

run_payload() { # [PATH]
  local status=0
  (cd -- "$ASSISTANT" && PATH="${1:-$PATH}" "$BASH_BIN" "$HOOK" < "$TMP_ROOT/input") \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || status=$?
  assert_eq "$status" 0 "${ROW}: edit stays allowed"
  CONTEXT=""
  if [ -s "$TMP_ROOT/stdout" ]; then
    CONTEXT=$("$JQ_BIN" -er '.hookSpecificOutput | select(.hookEventName == "PreToolUse") | .additionalContext | strings' "$TMP_ROOT/stdout") ||
      { assert_eq invalid-json context "${ROW}: model context envelope"; return; }
  fi
  assert_eq "${CONTEXT%%$'\n'*}" "$EXPECTED" "${ROW}: keyed first line"
  assert_eq "$("$CAT_BIN" "$TMP_ROOT/stderr")" "" "${ROW}: no hidden diagnostic"
}

edit_rows() {
  local tool target label expected extra
  while IFS='|' read -r label tool target expected; do
    ROW=$label
    EXPECTED=$expected
    "$JQ_BIN" -cn --arg tool "$tool" --arg path "$target" \
      '{tool_name:$tool,tool_input:{file_path:$path}}' >"$TMP_ROOT/input"
    run_payload
    if [ -n "$EXPECTED" ]; then
      extra=${CONTEXT#*$'\n'}
      case "$extra" in *"$SKILL/references/memory.md"*) extra=present ;; *) extra=missing ;; esac
      assert_eq "$extra" present "$ROW: installed guide route"
      case "$CONTEXT" in *'## Notes'*) extra=present ;; *) extra=missing ;; esac
      assert_eq "$extra" present "$ROW: Notes heading route"
    fi
  done <<EOF
edit|Edit|$ASSISTANT/memory/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/fact.md
multi edit|MultiEdit|$ASSISTANT/memory/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/fact.md
notebook edit|NotebookEdit|$ASSISTANT/memory/fact.ipynb|jarvis-memory-note: path=$ASSISTANT/memory/fact.ipynb
new parent|Write|$ASSISTANT/memory/new/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/new/fact.md
relative|Edit|memory/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/fact.md
other directory|Edit|$ASSISTANT/other/fact.md|
memory name prefix|Write|$ASSISTANT/memory-old/fact.md|
outside through parent|Edit|$ASSISTANT/memory/../other/fact.md|
plain project memory|Write|$TMP_ROOT/plain/memory/fact.md|
EOF
}
edit_rows

failure_rows() {
  local label payload expected
  while IFS='|' read -r label payload expected; do
    ROW=$label
    EXPECTED="jarvis-memory-note: payload=$expected"
    printf '%s' "$payload" >"$TMP_ROOT/input"
    run_payload
  done <<'EOF'
invalid payload|{|invalid-json
missing tool name|{}|invalid-json
unknown tool|{"tool_name":"apply_patch"}|unknown-tool
missing file path|{"tool_name":"Edit","tool_input":{}}|no-file-path
wrong file path type|{"tool_name":"Write","tool_input":{"file_path":42}}|no-file-path
EOF
}
failure_rows

ROW='missing guide'
EXPECTED='jarvis-memory-note: payload=memory-guide-missing'
rm -- "$SKILL/references/memory.md"
printf '{"tool_name":"Edit","tool_input":{"file_path":"memory/fact.md"}}' >"$TMP_ROOT/input"
run_payload
touch "$SKILL/references/memory.md"

for missing in jq cat all; do
  mkdir -p "$TMP_ROOT/bin-$missing"
  [ "$missing" = jq ] || [ "$missing" = all ] || ln -s "$JQ_BIN" "$TMP_ROOT/bin-$missing/jq"
  [ "$missing" = cat ] || [ "$missing" = all ] || ln -s "$CAT_BIN" "$TMP_ROOT/bin-$missing/cat"
  ROW="missing $missing"
  EXPECTED="jarvis-memory-note: missing-tools=$missing"
  [ "$missing" != all ] || EXPECTED='jarvis-memory-note: missing-tools=jq,cat'
  run_payload "$TMP_ROOT/bin-$missing"
done
mkdir -p "$TMP_ROOT/broken-cat"
printf '#!/bin/sh\nexit 1\n' >"$TMP_ROOT/broken-cat/cat"
chmod +x "$TMP_ROOT/broken-cat/cat"
ln -s "$JQ_BIN" "$TMP_ROOT/broken-cat/jq"
ROW='unreadable payload'
EXPECTED='jarvis-memory-note: payload=unreadable'
run_payload "$TMP_ROOT/broken-cat"

# These rows must detect a copy that turns the advisory reader into a refusal.
skill_load_control advisory "$HOOK" 'set -euo pipefail' 'exit 2' HOOK failure_rows \
  'invalid payload: edit stays allowed' 'unknown tool: edit stays allowed'
printf 'passed: %s failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
