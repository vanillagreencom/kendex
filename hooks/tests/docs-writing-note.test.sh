#!/usr/bin/env bash
# Surface: docs-writing-note.sh. Inputs: that hook, tests/lib/assert.sh, and
# the commit-guards and docs-writing skills it runs and routes to.
set -euo pipefail
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$TEST_DIR/../docs-writing-note.sh}"
CATALOG="$(cd -- "$TEST_DIR/../.." && pwd -P)"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "docs-writing-note: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "docs-writing-note: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "docs-writing-note: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/lib/assert.sh"
BASH_BIN=$BASH
JQ_BIN=$(command -v jq)
CAT_BIN=$(command -v cat)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# The edited repository: a README, a git-ignored tmp/, and no skills of its
# own, so md-type reads the docs-writing installed beside it in the hook's
# scope. A planted md-type there writes a sentinel if anything runs it.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.agents/skills/commit-guards/scripts"
git -C "$REPO" -c init.defaultBranch=main init -q
printf 'tmp/\n' >"$REPO/.gitignore"
printf '#!/bin/sh\n: >"%s/sentinel"\n' "$TMP_ROOT" >"$REPO/.agents/skills/commit-guards/scripts/md-type"
chmod +x "$REPO/.agents/skills/commit-guards/scripts/md-type"

# A scope: the hook copied where kendex renders it for HARNESS, with the
# skills PARTS names installed beside it. HOOK is read at each call, so a
# control's copy is the hook every row runs.
scope() { # NAME HARNESS PARTS — the hook's path on stdout
  local dir="$TMP_ROOT/scopes/$1" hooks part
  case "$2" in
    claude) hooks="$dir/.claude/hooks" ;;
    codex) hooks="$dir/.codex/hooks" ;;
    pi) hooks="$dir/.pi/kendex/hooks" ;;
  esac
  rm -rf -- "$dir"
  mkdir -p "$hooks" "$dir/.agents/skills"
  cp -- "$HOOK" "$hooks/docs-writing-note.sh"
  for part in $3; do cp -R -- "$CATALOG/skills/$part" "$dir/.agents/skills/$part"; done
  printf '%s\n' "$hooks/docs-writing-note.sh"
}

STATE="$TMP_ROOT/state"
# One run: the hook over PAYLOAD from the repository, under PATH and the
# state home given. Sets STATUS, CONTEXT, FIRST and ERR.
fire() { # HOOK-PATH PAYLOAD [PATH] [STATE-HOME]
  STATUS=0
  printf '%s' "$2" >"$TMP_ROOT/input"
  (cd -- "$REPO" && PATH="${3:-$PATH}" XDG_STATE_HOME="${4:-$STATE}" "$BASH_BIN" "$1" <"$TMP_ROOT/input") \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || STATUS=$?
  CONTEXT=""
  if [ -s "$TMP_ROOT/stdout" ]; then
    CONTEXT=$("$JQ_BIN" -er '.hookSpecificOutput | select(.hookEventName == "PreToolUse") | .additionalContext | strings' "$TMP_ROOT/stdout") ||
      CONTEXT="invalid-envelope"
  fi
  FIRST=${CONTEXT%%$'\n'*}
  ERR=$("$CAT_BIN" "$TMP_ROOT/stderr")
}
edit() { jq -cn --arg tool "$1" --arg path "$2" --arg s "$3" '{tool_name:$tool,session_id:$s,tool_input:{file_path:$path}}'; } # TOOL PATH SESSION
patch() { jq -cn --arg patch "$1" --arg s "$2" --arg cwd "$REPO" '{tool_name:"apply_patch",session_id:$s,cwd:$cwd,tool_input:{command:$patch}}'; } # PATCH SESSION
has() { case "$1" in *"$2"*) echo present ;; *) echo missing ;; esac; } # TEXT PART
marker() { if [ -f "$STATE/kendex/docs-writing-note/$1" ]; then "$CAT_BIN" -- "$STATE/kendex/docs-writing-note/$1"; else echo none; fi; } # KEY

# Each row: a hook, a payload, the keyed first line it must print (empty for
# silence), and the marker its session key must leave.
check() { # ROW HOOK PAYLOAD FIRST KEY MARKER-PREFIX [PATH] [STATE-HOME]
  fire "$2" "$3" "${7:-}" "${8:-}"
  assert_eq "$STATUS" 0 "$1: edit stays allowed"
  assert_eq "$ERR" "" "$1: no hidden diagnostic"
  assert_eq "$FIRST" "$4" "$1: keyed first line"
  [ -z "$5" ] || assert_eq "$(m=$(marker "$5"); printf '%s' "${m%% at=*}")" "$6" "$1: marker"
}

delivery_rows() {
  local claude codex pi rf=$REPO/README.md
  rm -rf -- "$STATE"
  claude=$(scope full-claude claude "commit-guards docs-writing")
  codex=$(scope full-codex codex "commit-guards docs-writing")
  pi=$(scope full-pi pi "commit-guards docs-writing")
  check "first edit" "$claude" "$(edit Edit "$rf" s1)" "docs-writing-note: path=$rf type=readme" s1 "harness=claude session=s1 path=$rf"
  assert_eq "$(has "$CONTEXT" "/.agents/skills/docs-writing/references/readme.md")" present "first edit: reference route"
  assert_eq "$(has "$CONTEXT" "/.agents/skills/docs-writing/examples/readme.md")" present "first edit: example route"
  check "second edit" "$claude" "$(edit Write "$REPO/docs/x.md" s1)" "" s1 "harness=claude session=s1 path=$rf"
  check "subagent edit" "$claude" "$(jq -cn --arg p "$rf" '{tool_name:"MultiEdit",session_id:"s1",agent_id:"a1",tool_input:{file_path:$p}}')" \
    "docs-writing-note: path=$rf type=readme" s1.a1 "harness=claude session=s1.a1 path=$rf"
  check "code edit" "$claude" "$(edit Edit "$REPO/src/main.rs" s2)" "" s2 none
  check "ignored file" "$claude" "$(edit Write "$REPO/tmp/plan.md" s3)" "" s3 none
  check "unclassified file" "$claude" "$(edit Write "$REPO/notes/plan.md" s4)" "docs-writing-note: path=$REPO/notes/plan.md type=unclassified" s4 "harness=claude session=s4 path=$REPO/notes/plan.md"
  check "codex update" "$codex" "$(patch $'*** Begin Patch\n*** Update File: README.md\n@@\n-a\n+b\n*** End Patch' c1)" \
    "docs-writing-note: path=$rf type=readme" c1 "harness=codex session=c1 path=$rf"
  check "codex add" "$codex" "$(patch $'*** Begin Patch\n*** Add File: docs/architecture/x.md\n+# X\n*** End Patch' c2)" \
    "docs-writing-note: path=$REPO/docs/architecture/x.md type=architecture" c2 "harness=codex session=c2 path=$REPO/docs/architecture/x.md"
  check "codex move" "$codex" "$(patch $'*** Begin Patch\n*** Update File: notes.txt\n*** Move to: README.md\n*** End Patch' c3)" \
    "docs-writing-note: path=$rf type=readme" c3 "harness=codex session=c3 path=$rf"
  check "codex patch of code" "$codex" "$(patch $'*** Begin Patch\n*** Update File: src/main.rs\n*** End Patch' c4)" "" c4 none
  check "pi write" "$pi" "$(edit Write "$rf" p1)" "docs-writing-note: path=$rf type=readme" p1 "harness=pi session=p1 path=$rf"
}
delivery_rows

failure_rows() {
  local claude bare nodocs rf=$REPO/README.md
  rm -rf -- "$STATE" "$TMP_ROOT/sentinel"
  claude=$(scope fail-claude claude "commit-guards docs-writing")
  bare=$(scope bare claude "docs-writing")
  nodocs=$(scope nodocs claude "commit-guards")
  check "invalid payload" "$claude" '{' "docs-writing-note: reader=tool-name" "" ""
  check "missing tool name" "$claude" '{}' "docs-writing-note: payload=invalid-json" "" ""
  check "unknown tool" "$claude" '{"tool_name":"Bash","tool_input":{"command":"true"}}' "docs-writing-note: payload=unknown-tool" "" ""
  check "missing file path" "$claude" '{"tool_name":"Edit","tool_input":{}}' "docs-writing-note: payload=no-file-path" "" ""
  check "patch with no header" "$claude" '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}' "docs-writing-note: payload=no-file-path" "" ""
  check "no session id" "$claude" "$(jq -cn --arg p "$rf" '{tool_name:"Edit",tool_input:{file_path:$p}}')" "docs-writing-note: payload=no-session-id" "" ""
  assert_eq "$(has "$CONTEXT" "docs-writing-note: path=$rf type=readme")" present "no session id: route still delivered"
  check "invalid session id" "$claude" "$(edit Edit "$rf" ../escape)" "docs-writing-note: payload=session-id-invalid" "" ""
  printf 'not a directory' >"$TMP_ROOT/state-file"
  check "unwritable marker" "$claude" "$(edit Edit "$rf" u1)" "docs-writing-note: path=$rf type=readme" "" "" "" "$TMP_ROOT/state-file"
  assert_eq "$(has "$CONTEXT" "docs-writing-note: marker=unwritable")" present "unwritable marker: named"
  check "judge outside the hook's scope" "$bare" "$(edit Edit "$rf" j1)" "docs-writing-note: judge=missing" j1 "harness=claude session=j1 path=$rf"
  assert_eq "$([ -e "$TMP_ROOT/sentinel" ] && echo ran || echo not-run)" not-run "judge outside the hook's scope: the edited repository's md-type never runs"
  check "no docs-writing for the route" "$nodocs" "$(edit Edit "$rf" r1)" "docs-writing-note: route=failed" r1 "harness=claude session=r1 path=$rf"
  assert_eq "$(has "$CONTEXT" "md-type: gap=docs-writing-missing")" present "no docs-writing for the route: cause below"
}
failure_rows

for missing in jq cat; do
  mkdir -p "$TMP_ROOT/bin-$missing"
  [ "$missing" = jq ] || ln -s "$JQ_BIN" "$TMP_ROOT/bin-$missing/jq"
  [ "$missing" = cat ] || ln -s "$CAT_BIN" "$TMP_ROOT/bin-$missing/cat"
  fire "$(scope "tools-$missing" claude "commit-guards docs-writing")" "$(edit Edit "$REPO/README.md" t1)" "$TMP_ROOT/bin-$missing"
  assert_eq "$STATUS:$FIRST" "0:docs-writing-note: missing-tools=$missing" "missing $missing"
done

# These rows must detect a copy that refuses, forgets its marker, or takes
# its judge from the edited repository.
skill_load_control advisory "$HOOK" 'set -euo pipefail' 'exit 2' HOOK failure_rows \
  'invalid payload: edit stays allowed' 'unknown tool: edit stays allowed'
skill_load_control marker "$HOOK" 'MARKER_NOTE=""' 'STATE_DIR=/dev/null/unwritable' HOOK delivery_rows \
  'second edit: keyed first line'
skill_load_control judge-scope "$HOOK" 'JUDGE=""' 'in_scope() { printf "%s\n" "$(git -C "${TARGET%/*}" rev-parse --show-toplevel)/.agents/skills/$1"; }' HOOK failure_rows \
  "judge outside the hook's scope: the edited repository's md-type never runs"
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
