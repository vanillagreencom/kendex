#!/usr/bin/env bash
# Tests for the code-quality-load-check hook.
#
# The hook refuses an Edit, MultiEdit, NotebookEdit or Write onto a path
# inside a git work tree until the session transcript shows a Skill tool call
# whose skill input is `code-quality`. Pinned here: the refusal and its value,
# the pass once the skill is loaded, and what the rule deliberately does not
# reach — the work tree's own tmp/, a path outside every work tree, and a
# session that turned the hook off. Pinned beside them, the precision the
# transcript read exists for: the skill's name in a system message, in a tool
# result or in a Skill call for another skill is not a load. Then the
# fail-closed edges — an unreadable payload, a missing target or transcript
# field, a transcript that is not there, a git that cannot answer, no jq.
#
# Fixtures are throwaway git repositories and hand-written transcripts under a
# HOME of their own.
#
# Every refusal opens with `code-quality-load-check: <key>=<value>`, and that
# line is the contract: the skill that is not loaded, or why the state could
# not be read, is the value. The path refused and the skill to load are
# pinned as themselves under it, and git's own words when it could not answer.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-refuse hook) can be run against these same
# assertions.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would point the fixtures' git at the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/code-quality-load-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
ERR_FILE="$TMP_ROOT/stderr"

fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/src" "$REPO/tmp" "$REPO/crates/core/tmp"
fgit init -q "$REPO"
fgit -C "$REPO" config user.email t@example.com
fgit -C "$REPO" config user.name t
printf 'pub fn a() {}\n' >"$REPO/src/lib.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m init
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

# jq builds every fixture and payload below, so a value holding a quote, a
# backslash or a newline reaches the hook encoded the way the harness encodes
# it. Long flag names: this repository's pre-commit hook reads whitespace-
# separated words, and the short pair spells one it refuses.
JQ=(jq --null-input --compact-output)

# A transcript line: the assistant tool_use the harness records for a Skill
# call, built the way the harness builds it so a field this hook reads is
# never spelled by hand twice.
skill_call() { # SKILL -> one JSONL line
  "${JQ[@]}" --arg s "$1" \
    '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Skill",input:{skill:$s}}]}}'
}

# The transcripts the rows below name. NONE holds the skill's name everywhere
# but in a Skill call: the system message that lists the installed skills, a
# tool result that printed it, and a Skill call for a different skill.
LOADED_T="$TMP_ROOT/loaded.jsonl"
NONE_T="$TMP_ROOT/none.jsonl"
skill_call code-quality >"$LOADED_T"
{
  "${JQ[@]}" '{type:"system",content:"- code-quality: Load for any coding or development task"}'
  "${JQ[@]}" '{type:"user",message:{role:"user",content:[{type:"tool_result",content:"skills/code-quality/SKILL.md"}]}}'
  skill_call dev
} >"$NONE_T"

# run_tool TOOL FIELD VALUE TRANSCRIPT -> rc, stderr in $err
run_tool() {
  local tool="$1" field="$2" value="$3" transcript="$4"
  run_payload "$("${JQ[@]}" --arg t "$tool" --arg f "$field" --arg v "$value" --arg tr "$transcript" \
    '{tool_name: $t, tool_input: {($f): $v}, transcript_path: $tr}')"
}

# The payload reaches the hook on a here-string, never a pipe: a hook that
# exits before reading stdin — the off switch here, a no-op mutant under
# HOOK_UNDER_TEST — SIGPIPEs a writer on the other end, and the pipeline's
# 141 would stand where the hook's own status belongs.
run_payload() { # raw-json [PATH] -> rc, stderr in $err
  set +e
  if [ -n "${2:-}" ]; then
    env -i HOME="$TMP_ROOT" PWD="$TMP_ROOT" PATH="$2" "$BASH_BIN" "$HOOK" \
      >/dev/null 2>"$ERR_FILE" <<<"$1"
  else
    env HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE" <<<"$1"
  fi
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

# The first-line reader. This suite's runs vary the tool, the path and the
# transcript rather than one command, which the shared table's modes do not
# express, so `first_line` and `cause_below` are the half of that library it
# uses.
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

REFUSAL="code-quality-load-check: unloaded=code-quality"

echo "code-quality-load-check: an edit in a repository is refused until the skill is loaded"
# One row per edit tool, each with the field that tool's payload carries. The
# transcript holds every mention of the skill that is not a load, so a row
# that passed here would be a read matching the name rather than the call.
while IFS='|' read -r tool field; do
  [ -n "$tool" ] || continue
  run_tool "$tool" "$field" "$REPO/src/lib.rs" "$NONE_T"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
    "$tool is refused, the skill that is not loaded its value"
done <<'ROWS'
Edit|file_path
MultiEdit|file_path
Write|file_path
NotebookEdit|notebook_path
ROWS
run_tool Edit file_path "$REPO/src/lib.rs" "$NONE_T"
assert_contains "$err" "$REPO/src/lib.rs" "the refusal names the path it refused"
assert_contains "$err" "skill: code-quality" "the refusal names the load that would pass it"
run_tool Write file_path "$REPO/new/dir/probe.sh" "$NONE_T"
assert_eq "$rc" 2 "a new file under directories that do not exist yet is judged by the nearest existing ancestor"
run_tool Write file_path "$REPO/crates/core/tmp/notes.md" "$NONE_T"
assert_eq "$rc" 2 "a tmp/ that is not the work tree's own is not scratch"
# Which tools reach this hook is the frontmatter matcher's answer, rendered
# into the harness's registration; the script does not restate that list, so
# every call delivered to it is judged by its path alone.
run_tool Read file_path "$REPO/src/lib.rs" "$NONE_T"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
  "a call is judged by its path, whatever tool the matcher delivered"

echo "code-quality-load-check: the load passes it"
run_tool Edit file_path "$REPO/src/lib.rs" "$LOADED_T"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" "a Skill call for code-quality passes the edit, silently"
MIXED_T="$TMP_ROOT/mixed.jsonl"
cat "$NONE_T" "$LOADED_T" >"$MIXED_T"
run_tool Edit file_path "$REPO/src/lib.rs" "$MIXED_T"
assert_eq "$rc" 0 "the load is found among the mentions that are not loads"
# The harness writes the transcript as the session runs, so the last line can
# be half-written when the hook reads it. That line is skipped; the load above
# it still answers.
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_' >>"$MIXED_T"
run_tool Edit file_path "$REPO/src/lib.rs" "$MIXED_T"
assert_eq "$rc" 0 "a half-written last line is skipped rather than taken for the whole file"
TRUNCATED_T="$TMP_ROOT/truncated.jsonl"
cat "$NONE_T" >"$TRUNCATED_T"
printf '%s' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"code-qual' >>"$TRUNCATED_T"
run_tool Edit file_path "$REPO/src/lib.rs" "$TRUNCATED_T"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=$REFUSAL" \
  "a half-written Skill call is not a load"

echo "code-quality-load-check: what the rule does not reach"
run_tool Write file_path "$REPO/tmp/commit-msg.txt" "$NONE_T"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" "the work tree's own tmp/ is scratch and passes"
run_tool Write file_path "$REPO/tmp/deeper/status.md" "$TMP_ROOT/no-such-transcript"
assert_eq "$rc" 0 "tmp/ passes before the transcript is read at all"
run_tool Write file_path "$SCRATCH/probe.sh" "$NONE_T"
assert_eq "$rc" 0 "a path outside every work tree passes"
run_tool Write file_path "$SCRATCH/deeper/not/yet/probe.sh" "$NONE_T"
assert_eq "$rc" 0 "a path outside every work tree, under directories that do not exist yet, passes"
set +e
env -i HOME="$TMP_ROOT" PATH="" KENDEX_CODE_QUALITY_HOOK=off "$BASH_BIN" "$HOOK" \
  >/dev/null 2>"$ERR_FILE" <<<"$("${JQ[@]}" --arg p "$REPO/src/lib.rs" --arg tr "$NONE_T" \
    '{tool_name:"Edit",tool_input:{file_path:$p},transcript_path:$tr}')"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=-" \
  "the off switch passes before the tools it would need are looked for"

echo "code-quality-load-check: a state it cannot read refuses"
run_payload '{"tool_name":"Edit","tool_input":{"file_path":"x"}'
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: payload=invalid-json" \
  "a truncated JSON payload refuses rather than skipping the guard"
run_payload '["Edit"]'
assert_eq "$rc" 2 "a payload that is not an object refuses"
run_payload "$("${JQ[@]}" --arg tr "$NONE_T" '{tool_name:"Edit",tool_input:{content:"x"},transcript_path:$tr}')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: payload=no-file-path" \
  "a payload naming no target path refuses, and names that"
run_payload "$("${JQ[@]}" --arg tr "$NONE_T" '{tool_name:"Edit",tool_input:{file_path:7},transcript_path:$tr}')"
assert_eq "$rc" 2 "a file_path that is not a string refuses"
run_payload "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" '{tool_name:"Edit",tool_input:{file_path:$p}}')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: payload=no-transcript" \
  "a payload naming no transcript refuses, and names that"
run_payload "$("${JQ[@]}" --arg p "$REPO/src/lib.rs" '{tool_name:"Edit",tool_input:{file_path:$p},transcript_path:[]}')"
assert_eq "$rc" 2 "a transcript_path that is not a string refuses"
run_tool Edit file_path "$REPO/src/lib.rs" "$TMP_ROOT/no-such-transcript"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: transcript=unreadable" \
  "a transcript that is not there refuses, and names it"
run_tool Edit file_path "$REPO/src/lib.rs" "$TMP_ROOT"
assert_eq "$rc" 2 "a transcript_path naming a directory refuses"

echo "code-quality-load-check: git cannot say where the path is"
BROKEN_BIN="$TMP_ROOT/brokengit"
mkdir -p "$BROKEN_BIN"
cat >"$BROKEN_BIN/git" <<'EOF'
#!/usr/bin/env bash
echo "fatal: unable to read the repository configuration" >&2
exit 128
EOF
chmod +x "$BROKEN_BIN/git"
set +e
env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" "$BASH_BIN" "$HOOK" \
  >/dev/null 2>"$ERR_FILE" <<<"$("${JQ[@]}" --arg p "$SCRATCH/probe.sh" --arg tr "$NONE_T" \
    '{tool_name:"Write",tool_input:{file_path:$p},transcript_path:$tr}')"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: git=unreadable" \
  "a git failure that is not 'not a git repository' refuses the edit"
assert_eq "$(cause_below)" present "the refusal carries git's own failure under the keyed line"
assert_contains "$(cat "$ERR_FILE")" "unable to read the repository configuration" "and it is git's words"

echo "code-quality-load-check: without the tools it runs"
# One world per declared dependency, each holding every other tool and not
# that one: the refusal names the missing tool and nothing is judged without
# it. A row per tool is what keeps the inventory honest — an absent grep does
# not stall this hook, it makes the transcript read empty, which is the
# unloaded answer arrived at without reading anything.
tools_table() { # TOOLS
  local tool other bin real before=$((PASS + FAIL))
  for tool in $1; do
    bin="$TMP_ROOT/without-$tool"
    rm -rf -- "$bin"
    mkdir -p "$bin"
    for other in $1; do
      [ "$other" != "$tool" ] || continue
      real="$(type -P "$other" 2>/dev/null || true)"
      [ -n "$real" ] && [ -x "$real" ] || continue
      ln -sf "$real" "$bin/$other"
    done
    run_payload '{"tool_name":"Edit","tool_input":{"file_path":"x"},"transcript_path":"y"}' "$bin"
    assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: missing-tools=$tool" \
      "without $tool the call is refused, and the value names it"
  done
  # A world holding none of them: the value is the whole list, in check order.
  # A row per tool cannot see an accumulator that overwrites instead of
  # appending, because only one name is ever missing in one.
  bin="$TMP_ROOT/without-everything"
  rm -rf -- "$bin"
  mkdir -p "$bin"
  run_payload '{"tool_name":"Edit","tool_input":{"file_path":"x"},"transcript_path":"y"}' "$bin"
  assert_eq "rc=$rc first=$(first_line)" "rc=2 first=code-quality-load-check: missing-tools=${1// /,}" \
    "with none of them the value is the whole list, in check order"
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "tools: no row was asserted" >&2; exit 2; }
}
tools_table "jq git cat grep dirname"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
