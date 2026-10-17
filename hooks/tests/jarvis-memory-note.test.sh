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

run_payload() { # [PATH] [BASH_ENV]
  local status=0
  (cd -- "$ASSISTANT" && PATH="${1:-$PATH}" BASH_ENV="${2:-}" "$BASH_BIN" "$HOOK" < "$TMP_ROOT/input") \
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
  local tool field target label expected extra
  while IFS='|' read -r label tool field target expected; do
    ROW=$label
    EXPECTED=$expected
    "$JQ_BIN" -cn --arg tool "$tool" --arg field "$field" --arg path "$target" \
      '{tool_name:$tool,tool_input:{($field):$path}}' >"$TMP_ROOT/input"
    run_payload
    if [ -n "$EXPECTED" ]; then
      extra=${CONTEXT#*$'\n'}
      case "$extra" in *"$SKILL/references/memory.md"*) extra=present ;; *) extra=missing ;; esac
      assert_eq "$extra" present "$ROW: installed guide route"
      case "$CONTEXT" in *'## Notes'*) extra=present ;; *) extra=missing ;; esac
      assert_eq "$extra" present "$ROW: Notes heading route"
    fi
  done <<EOF
edit|Edit|file_path|$ASSISTANT/memory/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/fact.md
multi edit|MultiEdit|file_path|$ASSISTANT/memory/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/fact.md
notebook edit|NotebookEdit|notebook_path|$ASSISTANT/memory/fact.ipynb|jarvis-memory-note: path=$ASSISTANT/memory/fact.ipynb
new parent|Write|file_path|$ASSISTANT/memory/new/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/new/fact.md
relative|Edit|file_path|memory/fact.md|jarvis-memory-note: path=$ASSISTANT/memory/fact.md
other directory|Edit|file_path|$ASSISTANT/other/fact.md|
memory name prefix|Write|file_path|$ASSISTANT/memory-old/fact.md|
outside through parent|Edit|file_path|$ASSISTANT/memory/../other/fact.md|
plain project memory|Write|file_path|$TMP_ROOT/plain/memory/fact.md|
EOF
}
edit_rows

failure_rows() {
  local label payload expected
  while IFS='|' read -r label payload expected; do
    ROW=$label
    EXPECTED="jarvis-memory-note: $expected"
    printf '%s' "$payload" >"$TMP_ROOT/input"
    run_payload
  done <<'EOF'
invalid payload|{|reader=tool-name
missing tool name|{}|payload=invalid-json
unknown tool|{"tool_name":"apply_patch"}|payload=unknown-tool
missing file path|{"tool_name":"Edit","tool_input":{}}|payload=no-file-path
wrong file path type|{"tool_name":"Write","tool_input":{"file_path":42}}|payload=no-file-path
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

reader_rows() {
  local reader expected bin cause env_file first detail
  while IFS='|' read -r reader expected; do
    ROW="failed $reader"
    EXPECTED="jarvis-memory-note: $expected"
    bin=$(mktemp -d "$TMP_ROOT/reader-$reader.XXXXXX") || { echo 'jarvis-memory-note: reader-fixture=mktemp-failed' >&2; exit 1; }
    cause="reader-fault=$reader"
    env_file=""
    ln -s "$CAT_BIN" "$bin/cat"
    ln -s "$JQ_BIN" "$bin/jq"
    case "$reader" in
      cat)
        rm -- "$bin/cat"
        printf '#!/bin/sh\nprintf "%%s\\n" "%s" >&2\nexit 1\n' "$cause" >"$bin/cat"
        chmod +x "$bin/cat" ;;
      tool-name | target)
        rm -- "$bin/jq"
        if [ "$reader" = target ]; then
          printf '#!%s\ncase "$*" in *tool_name*) exec "%s" "$@" ;; esac\n' "$BASH_BIN" "$JQ_BIN" >"$bin/jq"
        else
          printf '#!%s\n' "$BASH_BIN" >"$bin/jq"
        fi
        printf 'printf "%%s\\n" "%s" >&2\nexit 2\n' "$cause" >>"$bin/jq"
        chmod +x "$bin/jq" ;;
      cd | pwd)
        env_file="$bin/shell-env"
        printf '%s() { printf "%%s\\n" "%s" >&2; return 1; }\n' "$reader" "$cause" >"$env_file" ;;
    esac
    printf '{"tool_name":"Edit","tool_input":{"file_path":"memory/fact.md"}}' >"$TMP_ROOT/input"
    run_payload "$bin" "$env_file"
    first=${CONTEXT%%$'\n'*}
    detail=${CONTEXT#"$first"}
    assert_eq "$detail" $'\n'"$cause" "$ROW: diagnostic below keyed line"
  done <<'EOF'
cat|payload=unreadable
tool-name|reader=tool-name
target|reader=target
cd|payload=unresolved-path
pwd|payload=unresolved-path
EOF
}
reader_rows

# These rows must detect a copy that turns the advisory reader into a refusal.
skill_load_control advisory "$HOOK" 'set -euo pipefail' 'exit 2' HOOK failure_rows \
  'invalid payload: edit stays allowed' 'unknown tool: edit stays allowed'
skill_load_control notebook-path "$HOOK" 'NotebookEdit) FIELD=notebook_path' 'FIELD=file_path' HOOK edit_rows \
  'notebook edit: keyed first line'
skill_load_control reader-cause "$HOOK" 'notice() { # KEY VALUE [DETAIL]' 'set -- "$1" "$2"' HOOK reader_rows \
  'failed cat: diagnostic below keyed line' 'failed target: diagnostic below keyed line'
printf 'passed: %s failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
